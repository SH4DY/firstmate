#!/usr/bin/env bash
# fm-dashboard.sh - local-only browser dashboard for this firstmate home.
#
# Serves a read-only, self-contained HTML view on 127.0.0.1, rendering the
# canonical `fm-bearings-snapshot.sh --json` projection on every request.
# It never reads fleet state directly, never shells out to networked PR discovery,
# and performs no writes or fleet actions.
#
# Flags:
#   --port <n>      TCP port to bind on 127.0.0.1 (default: 8765)
#   --refresh <n>   browser auto-refresh interval in seconds (default: 15)
#   -h,--help       usage
set -u

usage() {
  cat <<'USAGE'
usage: fm-dashboard.sh [--port <n>] [--refresh <seconds>]

Serve a local-only, read-only firstmate dashboard at http://127.0.0.1:<port>/.
The page re-runs bin/fm-bearings-snapshot.sh --json for every request and
renders that bounded snapshot. It does not use --include-prs, does not require
network access, and never writes fleet state.

Options:
  --port <n>       port to bind on 127.0.0.1 (default: 8765)
  --refresh <n>    browser auto-refresh interval in seconds (default: 15)
  -h, --help       show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/fm-bearings-snapshot.sh"
PORT=8765
REFRESH=15

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      [ "$#" -ge 2 ] || { echo "fm-dashboard: --port requires a value" >&2; exit 2; }
      PORT=$2
      shift 2
      ;;
    --refresh)
      [ "$#" -ge 2 ] || { echo "fm-dashboard: --refresh requires a value" >&2; exit 2; }
      REFRESH=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "fm-dashboard: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PORT" in
  ''|*[!0-9]*) echo "fm-dashboard: --port must be an integer" >&2; exit 2 ;;
esac
case "$REFRESH" in
  ''|*[!0-9]*) echo "fm-dashboard: --refresh must be an integer" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "fm-dashboard: --port must be between 1 and 65535" >&2
  exit 2
fi
if [ "$REFRESH" -lt 5 ]; then
  echo "fm-dashboard: --refresh must be at least 5 seconds" >&2
  exit 2
fi
if [ ! -x "$SNAPSHOT" ]; then
  echo "fm-dashboard: snapshot source not executable: $SNAPSHOT" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "fm-dashboard: python3 is required" >&2
  exit 1
fi

exec python3 - "$SNAPSHOT" "$PORT" "$REFRESH" <<'PY'
import html
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

SNAPSHOT = sys.argv[1]
PORT = int(sys.argv[2])
REFRESH = int(sys.argv[3])
HOST = "127.0.0.1"

CSS = """
:root {
  --nord0: #2E3440;
  --nord1: #3B4252;
  --nord2: #434C5E;
  --nord3: #4C566A;
  --nord4: #D8DEE9;
  --nord5: #E5E9F0;
  --nord6: #ECEFF4;
  --nord7: #8FBCBB;
  --nord8: #88C0D0;
  --nord9: #81A1C1;
  --nord10: #5E81AC;
  --nord11: #BF616A;
  --nord12: #D08770;
  --nord13: #EBCB8B;
  --nord14: #A3BE8C;
  --nord15: #B48EAD;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--nord0);
  color: var(--nord4);
  font: 15px/1.45 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
}
a { color: var(--nord8); }
header, main { width: min(1880px, calc(100vw - 24px)); margin: 0 auto; }
header { padding: 22px 0 14px; }
h1 { margin: 0 0 6px; color: var(--nord8); font-size: 28px; letter-spacing: 0.02em; }
.subtitle { color: var(--nord5); }
.meta { color: var(--nord3); margin-top: 4px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 12px; padding-bottom: 22px; }
.panel {
  min-width: 0;
  background: var(--nord1);
  border: 1px solid var(--nord3);
  border-radius: 10px;
  padding: 12px;
  box-shadow: 0 10px 24px rgba(0, 0, 0, 0.18);
}
.panel.full { grid-column: 1 / -1; }
.panel h2 { margin: 0 0 8px; color: var(--nord8); font-size: 17px; }
.panel.me { border-color: var(--nord13); }
.panel.me h2, .wait { color: var(--nord13); }
.good { color: var(--nord14); }
.bad { color: var(--nord11); }
.muted { color: var(--nord3); }
table { width: 100%; max-width: 100%; border-collapse: collapse; }
th, td {
  min-width: 0;
  padding: 5px 6px;
  border-top: 1px solid var(--nord3);
  text-align: left;
  vertical-align: top;
  line-height: 1.28;
  overflow-wrap: anywhere;
  word-break: normal;
}
th { color: var(--nord5); font-weight: 700; }
td:first-child, th:first-child { width: 2.5rem; color: var(--nord3); }
a { overflow-wrap: anywhere; }
.empty { padding: 8px 0 0; color: var(--nord3); }
pre { white-space: pre-wrap; overflow-wrap: anywhere; word-break: normal; margin: 0; }
.badge { display: inline-block; border: 1px solid var(--nord3); border-radius: 999px; padding: 1px 7px; color: var(--nord5); }
"""


def esc(value):
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        value = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return html.escape(str(value), quote=True)


def value(row, key):
    return row.get(key, "") if isinstance(row, dict) else ""


def link(url):
    text = esc(url)
    if isinstance(url, str) and url.startswith("https://"):
        return f'<a href="{text}" title="{text}">{text}</a>'
    return text


def run_snapshot():
    proc = subprocess.run(
        [SNAPSHOT, "--json"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "snapshot failed").strip())
    return json.loads(proc.stdout)


def table(headers, rows, cells):
    if not rows:
        return '<div class="empty">Nothing here.</div>'
    out = ["<table><thead><tr><th>#</th>"]
    out.extend(f"<th>{esc(h)}</th>" for h in headers)
    out.append("</tr></thead><tbody>")
    for idx, row in enumerate(rows, start=1):
        out.append(f"<tr><td>{idx}</td>")
        for cell in cells(row):
            out.append(f"<td>{cell}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def listify(value):
    return value if isinstance(value, list) else []


def render_page(data, error=None):
    generated = esc(data.get("generated", "")) if isinstance(data, dict) else ""
    decisions = listify(data.get("decisions_open")) if isinstance(data, dict) else []
    workers = listify(data.get("in_flight")) if isinstance(data, dict) else []
    waiting = listify(data.get("gates")) if isinstance(data, dict) else []
    landed = listify(data.get("landed")) if isinstance(data, dict) else []
    prs = listify(data.get("recorded_prs")) if isinstance(data, dict) else []
    unhealthy = listify(data.get("unhealthy_endpoints")) if isinstance(data, dict) else []
    omitted = listify(data.get("omitted")) if isinstance(data, dict) else []

    if error:
        body = f'<section class="panel full"><h2 class="bad">Dashboard could not read the fleet picture</h2><pre>{esc(error)}</pre></section>'
    else:
        body = "".join([
            '<section class="panel me full"><h2>What needs me</h2>',
            table(["Decision", "Requested action", "Owner"], decisions, lambda r: [
                f'<span class="wait">{esc(value(r, "summary") or value(r, "key"))}</span>',
                esc(value(r, "verb")),
                esc(value(r, "owner") or value(r, "id")),
            ]),
            "</section>",
            '<section class="panel full"><h2>Workers</h2>',
            table(["Worker", "Status", "Doing"], workers, lambda r: [
                esc(value(r, "id")), esc(value(r, "state")), esc(value(r, "doing")),
            ]),
            "</section>",
            '<section class="panel full"><h2>Waiting or queued</h2>',
            table(["Work", "Waiting on", "Reason"], waiting, lambda r: [
                esc(value(r, "title") or value(r, "id")), esc(value(r, "owner") or value(r, "blocked_by")), esc(value(r, "reason")),
            ]),
            "</section>",
            '<section class="panel full"><h2>PRs</h2>',
            table(["Work", "URL"], prs, lambda r: [esc(value(r, "id")), link(value(r, "url"))]),
            "</section>",
            '<section class="panel full"><h2>Workers needing attention</h2>',
            table(["Worker", "Problem", "Detail"], unhealthy, lambda r: [
                esc(value(r, "id") or value(r, "window")), '<span class="bad">needs attention</span>', esc(value(r, "reason") or value(r, "summary") or value(r, "state")),
            ]),
            "</section>",
            '<section class="panel"><h2>Recently landed</h2>',
            table(["Work", "Result", "Artifact"], landed, lambda r: [
                esc(value(r, "id")), f'<span class="good">{esc(value(r, "what"))}</span>', link(value(r, "artifact")),
            ]),
            "</section>",
            '<section class="panel"><h2>Available if expanded</h2>',
            table(["Area", "How to show it"], omitted, lambda r: [esc(value(r, "surface")), esc(value(r, "reveal"))]),
            "</section>",
        ])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="{REFRESH}">
<title>Firstmate dashboard</title>
<style>{CSS}</style>
</head>
<body>
<header>
  <h1>Firstmate dashboard</h1>
  <div class="subtitle">Local-only fleet picture.</div>
  <div class="meta">Generated {generated} · refreshes every {REFRESH}s · <span class="badge">localhost only</span></div>
</header>
<main class="grid">{body}</main>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path not in ("/", "/index.html"):
            self.send_error(404)
            return
        try:
            page = render_page(run_snapshot())
            status = 200
        except Exception as exc:  # show the read-only failure in the page.
            page = render_page({}, str(exc))
            status = 500
        payload = page.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return


try:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
except OSError as exc:
    print(f"fm-dashboard: cannot bind http://{HOST}:{PORT}/ - {exc}", file=sys.stderr)
    sys.exit(1)

print(f"fm-dashboard: serving http://{HOST}:{PORT}/", file=sys.stderr, flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
PY
