# RITA - Real Intelligence Threat Analytics

RITA v5 is deployed as a Docker Compose stack on the orochi node. It analyses Zeek connection logs and surfaces beaconing, long connections, DNS-based C2, and other threat patterns.

## Architecture

RITA runs three containers under `/opt/rita/docker-compose.yml`:

| Container   | Role                                      |
|-------------|-------------------------------------------|
| `clickhouse` | Time-series database storing analysis results |
| `syslog-ng`  | Log ingestion pipeline                    |
| `rita`       | One-shot analysis container (run on demand) |

The `/usr/local/bin/rita` wrapper script handles all interaction — you never need to call `docker compose` directly.

---

## Basic Usage

### Import Zeek logs

```bash
rita import --logs /opt/zeek/logs/ --database <name>
```

- `--logs` — path to a directory of Zeek logs (current or historical)
- `--database` — name for the dataset (alphanumeric, no spaces)

For live/current logs:

```bash
rita import --logs /opt/zeek/logs/current --database live-$(date +%Y%m%d)
```

For a specific date's logs:

```bash
rita import --logs /opt/zeek/logs/2026-05-22 --database 2026-05-22
```

### View results (TUI)

```bash
rita view <name>
```

Launches an interactive terminal dashboard. Navigate with arrow keys, `Tab` to switch panels, `q` to quit.

### Generate HTML report

```bash
rita html-report <name>
```

Writes a self-contained HTML file to the current directory. Open in a browser for a full drilldown view with sortable tables.

---

## Threat Categories

| Category           | What it finds                                              |
|--------------------|------------------------------------------------------------|
| **Beaconing**      | Hosts making periodic connections — C2 check-ins          |
| **Long connections** | Sessions open for hours — data staging, tunnels          |
| **DNS C2**         | High-entropy or high-volume DNS queries — DNS tunnelling  |
| **Threat Intel**   | IPs/domains matched against built-in threat intel feeds   |
| **Port scanning**  | Hosts probing many ports/hosts in short windows           |
| **MIME mismatch**  | HTTP responses where content-type doesn't match body      |

Scores are 0–1; anything above **0.8** warrants investigation.

---

## Typical Workflow

```bash
# 1. Import yesterday's logs
rita import --logs /opt/zeek/logs/2026-05-21 --database 2026-05-21

# 2. Review in the TUI
rita view 2026-05-21

# 3. Generate a shareable report
rita html-report 2026-05-21
# → opens report in current directory
```

---

## Managing Databases

```bash
# List all databases
rita list

# Delete a database
rita delete <name>
```

---

## Notes

- Zeek must be running and writing logs to `/opt/zeek/logs/` before importing.
- RITA reads `conn.log`, `dns.log`, `http.log`, and `ssl.log` — all produced by the orochi Zeek deployment by default.
- The ClickHouse container must be healthy before importing. Check with:
  ```bash
  cd /opt/rita && docker compose ps
  ```
- The rita wrapper mounts the log directory read-only inside the container as `/tmp/zeek_logs`. The path you pass to `--logs` is always the **host** path.
- HTML reports are written to whichever directory you run the command from. Run from `/opt/rita` or your home directory to keep them organised.
- RITA has no web GUI — the TUI (`rita view`) and HTML reports are the two interfaces.
