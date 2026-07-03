#!/usr/bin/env python3
"""OROCHI Suricata Manager — tiny stdlib-only control API for the node.

Lets an analyst enable/disable cached rule sources and rebuild the live
ruleset, and pull a refreshed source bundle from the management box artifact
server — all offline, all on the node.

No third-party deps (the node has no pip/venv). Runs as a systemd service,
bound to the analyst interface only. Endpoints:

  GET  /api/sources          -> manifest + which sources are enabled
  POST /api/sources          {"enabled": ["ET Open", ...]}  rebuild + reload
  POST /api/update           re-pull bundle from artifact server, rebuild
  GET  /api/status           suricata service state + loaded rule count
  GET  /                      the management sub-page (served by nginx too)

Environment (set by the systemd unit):
  OROCHI_ARTIFACT_URL   e.g. http://10.16.255.253:8888
  OROCHI_BIND_HOST      analyst IP to bind (default 0.0.0.0)
  OROCHI_BIND_PORT      default 8443-free port 7000
"""
import json
import os
import re
import subprocess
import tarfile
import tempfile
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCES_DIR = "/var/lib/suricata/sources"          # per-source .rules + manifest.json
STATE_FILE = "/var/lib/suricata/sources/enabled.json"
RULES_OUT = "/var/lib/suricata/rules/suricata.rules"
MANIFEST = os.path.join(SOURCES_DIR, "manifest.json")

ARTIFACT_URL = os.environ.get("OROCHI_ARTIFACT_URL", "").rstrip("/")
BIND_HOST = os.environ.get("OROCHI_BIND_HOST", "0.0.0.0")
BIND_PORT = int(os.environ.get("OROCHI_BIND_PORT", "7000"))


def load_manifest():
    if not os.path.exists(MANIFEST):
        return {}
    return json.load(open(MANIFEST)).get("sources", {})


def load_enabled():
    if os.path.exists(STATE_FILE):
        try:
            return set(json.load(open(STATE_FILE)))
        except Exception:
            pass
    # Default: everything enabled (matches the initial merged deploy).
    return set(load_manifest().keys())


def save_enabled(names):
    os.makedirs(SOURCES_DIR, exist_ok=True)
    json.dump(sorted(names), open(STATE_FILE, "w"))


def rebuild_rules(enabled):
    """Concatenate the enabled per-source files into the live suricata.rules."""
    manifest = load_manifest()
    os.makedirs(os.path.dirname(RULES_OUT), exist_ok=True)
    written = 0
    with open(RULES_OUT, "wb") as out:
        for name in sorted(enabled):
            meta = manifest.get(name)
            if not meta:
                continue
            path = os.path.join(SOURCES_DIR, meta["file"])
            if os.path.exists(path):
                out.write(open(path, "rb").read())
                out.write(b"\n")
                written += 1
    return written


def reload_suricata():
    """Live rule reload via the unix socket; no service restart."""
    try:
        r = subprocess.run(
            ["suricatasc", "-c", "reload-rules"],
            capture_output=True, text=True, timeout=60,
        )
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except FileNotFoundError:
        return False, "suricatasc not found"
    except subprocess.TimeoutExpired:
        return False, "reload timed out"


def suricata_status():
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "suricata"],
            capture_output=True, text=True, timeout=10,
        )
        active = r.stdout.strip()
    except Exception:
        active = "unknown"
    loaded = 0
    if os.path.exists(RULES_OUT):
        loaded = sum(
            1 for line in open(RULES_OUT, "rb")
            if line.strip().startswith(b"alert")
        )
    return {"service": active, "loaded_rules": loaded}


def pull_bundle():
    """Fetch suricata-sources.tar.gz from the artifact server and extract."""
    if not ARTIFACT_URL:
        return False, "OROCHI_ARTIFACT_URL not set"
    url = ARTIFACT_URL + "/suricata-sources.tar.gz"
    try:
        with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
            with urllib.request.urlopen(url, timeout=120) as resp:
                tmp.write(resp.read())
            tmp_path = tmp.name
    except Exception as e:  # noqa: BLE001
        return False, f"download failed: {e}"
    try:
        with tarfile.open(tmp_path, "r:gz") as tf:
            # bundle root dir is 'suricata-sources/'
            base = os.path.dirname(SOURCES_DIR)
            _safe_extract(tf, base)
        return True, "bundle updated"
    except Exception as e:  # noqa: BLE001
        return False, f"extract failed: {e}"
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _safe_extract(tf, dest):
    dest = os.path.abspath(dest)
    for m in tf.getmembers():
        target = os.path.abspath(os.path.join(dest, m.name))
        if not target.startswith(dest + os.sep) and target != dest:
            raise ValueError(f"unsafe path in tar: {m.name}")
    tf.extractall(dest)


class Handler(BaseHTTPRequestHandler):
    server_version = "OrochiSuricataMgr/1.0"

    def _send(self, code, obj, ctype="application/json"):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass  # quiet

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/suricata", "/index.html"):
            page = PAGE.encode()
            return self._send(200, page, "text/html; charset=utf-8")
        if self.path == "/api/sources":
            manifest = load_manifest()
            enabled = load_enabled()
            out = []
            for name, meta in sorted(manifest.items()):
                out.append({
                    "name": name,
                    "summary": meta.get("summary", ""),
                    "vendor": meta.get("vendor", ""),
                    "license": meta.get("license", ""),
                    "rules": meta.get("rules", 0),
                    "enabled": name in enabled,
                })
            return self._send(200, {"sources": out})
        if self.path == "/api/status":
            return self._send(200, suricata_status())
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})

        if self.path == "/api/sources":
            manifest = load_manifest()
            requested = set(body.get("enabled", []))
            enabled = {n for n in requested if n in manifest}
            save_enabled(enabled)
            written = rebuild_rules(enabled)
            ok, msg = reload_suricata()
            return self._send(200 if ok else 500, {
                "enabled": sorted(enabled),
                "sources_written": written,
                "reloaded": ok,
                "detail": msg,
            })

        if self.path == "/api/update":
            ok, msg = pull_bundle()
            if not ok:
                return self._send(502, {"updated": False, "detail": msg})
            enabled = load_enabled()
            written = rebuild_rules(enabled)
            rok, rmsg = reload_suricata()
            return self._send(200, {
                "updated": True,
                "sources_written": written,
                "reloaded": rok,
                "detail": rmsg,
            })

        return self._send(404, {"error": "not found"})


PAGE = """<!DOCTYPE html><html lang=en><head><meta charset=UTF-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>OROCHI · Suricata Manager</title><style>
:root{--mono:'Cascadia Code',Consolas,'DejaVu Sans Mono',monospace;--sans:-apple-system,'Segoe UI',Ubuntu,sans-serif}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:var(--sans);background:#0a0e1a;color:#fff;min-height:100vh;padding:30px}
h1{font-family:var(--mono);font-size:1.8em;letter-spacing:4px;color:#00ff88}
.sub{color:rgba(255,255,255,.4);margin:6px 0 24px;font-size:.85em;letter-spacing:2px;text-transform:uppercase}
.bar{display:flex;gap:12px;align-items:center;margin-bottom:20px;flex-wrap:wrap}
button{font-family:var(--sans);border:1px solid rgba(0,255,136,.3);background:rgba(0,255,136,.08);color:#00ff88;
padding:10px 18px;border-radius:8px;cursor:pointer;font-size:.9em;transition:all .2s}
button:hover{background:rgba(0,255,136,.18)}
button:disabled{opacity:.4;cursor:wait}
button.upd{border-color:rgba(0,170,255,.4);background:rgba(0,170,255,.1);color:#5cf}
.status{font-family:var(--mono);font-size:.8em;color:rgba(255,255,255,.5)}
table{width:100%;border-collapse:collapse;margin-top:8px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid rgba(255,255,255,.06);font-size:.9em}
th{color:rgba(255,255,255,.35);font-weight:500;text-transform:uppercase;font-size:.7em;letter-spacing:1px}
td.n{font-family:var(--mono);font-size:.8em;color:#00ff88;text-align:right}
.desc{color:rgba(255,255,255,.4);font-size:.8em}
#msg{margin-top:16px;font-family:var(--mono);font-size:.82em;min-height:1.2em}
a.back{color:rgba(255,255,255,.4);font-size:.8em;text-decoration:none}
</style></head><body>
<a class=back href="/">&larr; Portal</a>
<h1>SURICATA MANAGER</h1>
<div class=sub>Rule source control &middot; offline</div>
<div class=bar>
  <button id=apply onclick=apply()>Apply &amp; Reload</button>
  <button class=upd id=update onclick=update()>Update rules from mgmt box</button>
  <span class=status id=st>&hellip;</span>
</div>
<table><thead><tr><th></th><th>Source</th><th>Description</th><th>Rules</th></tr></thead>
<tbody id=rows></tbody></table>
<div id=msg></div>
<script>
async function load(){
  const r=await fetch('/api/sources');const d=await r.json();
  const tb=document.getElementById('rows');tb.innerHTML='';
  for(const s of d.sources){
    const tr=document.createElement('tr');
    tr.innerHTML=`<td><input type=checkbox ${s.enabled?'checked':''} data-n="${s.name.replace(/"/g,'&quot;')}"></td>
    <td>${s.name}</td><td class=desc>${s.summary||''}</td><td class=n>${s.rules}</td>`;
    tb.appendChild(tr);
  }
  status();
}
async function status(){
  const r=await fetch('/api/status');const d=await r.json();
  document.getElementById('st').textContent=`suricata: ${d.service} · ${d.loaded_rules} rules loaded`;
}
function checked(){return [...document.querySelectorAll('#rows input:checked')].map(c=>c.dataset.n);}
async function apply(){
  const b=document.getElementById('apply');b.disabled=true;msg('Rebuilding & reloading…');
  const r=await fetch('/api/sources',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({enabled:checked()})});
  const d=await r.json();
  msg(d.reloaded?`Reloaded: ${d.sources_written} sources, live.`:`Rebuilt but reload failed: ${d.detail}`);
  b.disabled=false;status();
}
async function update(){
  const b=document.getElementById('update');b.disabled=true;msg('Pulling latest bundle from management box…');
  const r=await fetch('/api/update',{method:'POST'});
  const d=await r.json();
  msg(d.updated?`Updated & reloaded (${d.sources_written} sources).`:`Update failed: ${d.detail}`);
  b.disabled=false;await load();
}
function msg(t){document.getElementById('msg').textContent=t;}
load();setInterval(status,15000);
</script></body></html>"""


def main():
    os.makedirs(SOURCES_DIR, exist_ok=True)
    # First boot: if no state file, enable everything present.
    if not os.path.exists(STATE_FILE):
        save_enabled(load_manifest().keys())
    httpd = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    print(f"Suricata Manager on {BIND_HOST}:{BIND_PORT}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
