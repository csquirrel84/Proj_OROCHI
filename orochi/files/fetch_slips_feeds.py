#!/usr/bin/env python3
"""Mirror every Slips threat-intelligence feed to a local directory and emit a
rewritten TI_feeds.csv pointing at the management box.

Run inside the Slips container by prep_artefacts.yml:
    python3 /fetch.py <outdir> <artifact_base_url>

The deployed orochi node has NO internet. Slips' feeds_update_manager fetches
every URL in TI_feeds.csv on startup and every TI_files_update_period after,
so the file shipped to the node must reference the management box instead of
the real feed hosts. Same pattern as fetch_suricata_sources.py.

Failed feeds are SKIPped, not fatal: a single dead upstream must not break a
prep run. They are simply absent from the rewritten CSV, so the node never
requests a file the management box does not have.
"""
import csv
import os
import re
import sys
import urllib.request

SRC = "/StratosphereLinuxIPS/config/TI_feeds.csv"
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/output/slips-feeds"
BASE = (sys.argv[2] if len(sys.argv) > 2 else "").rstrip("/")


def safe_name(url):
    """Stable, slash-free filename derived from the feed URL.

    Keeps the real extension where there is one — Slips dispatches its parser
    on the suffix (.txt/.csv/.netset/.intel), so flattening everything to .txt
    would silently change how a feed is read.
    """
    tail = url.rstrip("/").split("/")[-1]
    stem, dot, ext = tail.rpartition(".")
    if not dot or len(ext) > 6 or not ext.isalnum():
        stem, ext = tail, "txt"
    stem = re.sub(r"[^a-zA-Z0-9]+", "-", stem).strip("-") or "feed"
    host = re.sub(r"[^a-zA-Z0-9]+", "-", url.split("//")[-1].split("/")[0])
    return f"{host}-{stem}.{ext.lower()}"


def main():
    if not BASE:
        sys.exit("usage: fetch_slips_feeds.py <outdir> <artifact_base_url>")
    if not os.path.exists(SRC):
        sys.exit(f"No TI_feeds.csv at {SRC} — is this the Slips image?")

    os.makedirs(OUTDIR, exist_ok=True)
    rows_out = []
    seen = set()
    ok = skipped = 0

    with open(SRC, newline="") as fh:
        for row in csv.reader(fh):
            if not row:
                continue
            url = row[0].strip()
            # Comments and the header row: preserved verbatim so the shipped
            # file still reads like the upstream one.
            if url.startswith("#") or not url.startswith("http"):
                rows_out.append(row)
                continue

            print(f'  fetching {url}', file=sys.stderr, flush=True)
            name = safe_name(url)
            if name in seen:                       # two feeds, same filename
                name = f"{len(seen)}-{name}"
            seen.add(name)

            try:
                req = urllib.request.Request(url, headers={"User-Agent": "slips"})
                data = urllib.request.urlopen(req, timeout=20).read()
            except Exception as e:                 # noqa: BLE001
                print(f"SKIP {url}: {e}", file=sys.stderr)
                skipped += 1
                continue

            if not data.strip():
                print(f"SKIP {url}: empty", file=sys.stderr)
                skipped += 1
                continue

            with open(os.path.join(OUTDIR, name), "wb") as out:
                out.write(data)

            # Rewrite column 0 only — threat_level and tags must survive
            # untouched or every indicator from this feed changes severity.
            rows_out.append([f"{BASE}/slips-feeds/{name}"] + row[1:])
            ok += 1
            print(f"OK   {name}: {len(data)} bytes")

    if not ok:
        sys.exit("No Slips feeds downloaded — aborting")

    with open(os.path.join(OUTDIR, "TI_feeds.csv"), "w", newline="") as fh:
        csv.writer(fh).writerows(rows_out)

    print(f"OK   TI_feeds.csv rewritten: {ok} feeds mirrored, {skipped} skipped")


if __name__ == "__main__":
    main()
