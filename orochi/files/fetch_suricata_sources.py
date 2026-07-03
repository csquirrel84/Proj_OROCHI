#!/usr/bin/env python3
"""Download every FREE Suricata rule source into per-source .rules files
plus a manifest.json. Run inside an ubuntu container by prep_artefacts.yml
and check_updates.yml.

"Free" = any source in the suricata-update index that needs no auth
parameters (ET Open, abuse.ch SSLbl/URLhaus, OISF traffic-id, etc.).

Output dir is argv[1] (default /output/suricata-sources).
"""
import datetime
import gzip
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.request

OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/output/suricata-sources"
INDEX = "/var/lib/suricata/update/cache/index.yaml"


def suricata_version():
    out = subprocess.run(["suricata", "-V"], capture_output=True, text=True).stdout
    m = re.search(r"version ([0-9]+\.[0-9]+\.[0-9]+)", out)
    return m.group(1) if m else "7.0.0"


def extract_rules(url, data):
    if url.endswith((".tar.gz", ".tgz")):
        rules = b""
        tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
        for mem in tf.getmembers():
            if mem.name.endswith(".rules"):
                rules += tf.extractfile(mem).read() + b"\n"
        return rules
    if url.endswith(".gz"):
        return gzip.decompress(data)
    return data


def main():
    import yaml  # provided by python3-yaml in the container
    idx = yaml.safe_load(open(INDEX))
    sources = idx.get("sources", {})
    version = suricata_version()
    os.makedirs(OUTDIR, exist_ok=True)
    manifest = {}

    for name, meta in sorted(sources.items()):
        if meta.get("deprecated") or meta.get("obsolete"):
            continue
        if meta.get("parameters"):        # needs an auth/secret code -> not free
            continue
        url = meta.get("url", "")
        if not url:
            continue
        url = url.replace("%(__version__)s", version)
        safe = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-")
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "suricata-update"})
            data = urllib.request.urlopen(req, timeout=60).read()
        except Exception as e:  # noqa: BLE001
            print(f"SKIP {name}: download failed: {e}", file=sys.stderr)
            continue
        try:
            rules = extract_rules(url, data)
        except Exception as e:  # noqa: BLE001
            print(f"SKIP {name}: extract failed: {e}", file=sys.stderr)
            continue
        if not rules.strip():
            print(f"SKIP {name}: empty ruleset", file=sys.stderr)
            continue
        open(os.path.join(OUTDIR, safe + ".rules"), "wb").write(rules)
        count = sum(1 for line in rules.splitlines() if line.strip().startswith(b"alert"))
        manifest[name] = {
            "file": safe + ".rules",
            "summary": meta.get("summary", ""),
            "license": meta.get("license", ""),
            "vendor": meta.get("vendor", ""),
            "rules": count,
        }
        print(f"OK   {name}: {count} rules")

    if not manifest:
        sys.exit("No sources downloaded — aborting")

    json.dump(
        {
            "generated": datetime.datetime.utcnow().isoformat() + "Z",
            "suricata_version": version,
            "sources": manifest,
        },
        open(os.path.join(OUTDIR, "manifest.json"), "w"),
        indent=2,
    )


if __name__ == "__main__":
    main()
