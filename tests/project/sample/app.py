"""The sample application of tests/project. It answers / with its version, and /health is green
only when the data has the schema of this version, so it starts only after its migration ran."""
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = 1
HEALTHY = True
DATA_DIR = os.environ.get("DATA_DIR", "/data")
SCHEMA = os.path.join(DATA_DIR, "schema")


def schema_version():
    try:
        with open(SCHEMA, encoding="utf-8") as schema:
            return int(schema.read())
    except (OSError, ValueError):
        return 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            ready = HEALTHY and schema_version() >= VERSION
            status, body = (200, "ok") if ready else (503, "not ready")
        else:
            status, body = 200, f"version {VERSION}"
        self.send_response(status)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass


def get(path):
    """Print the answer of the application running in this container; fail unless it is 200."""
    with urllib.request.urlopen(f"http://127.0.0.1:8000{path}", timeout=2) as answer:
        print(answer.read().decode())


if __name__ == "__main__":
    if sys.argv[1:2] == ["get"]:
        get(sys.argv[2])
    else:
        # A log line, which the log archive of a deploy keeps when this container is replaced.
        print(f"app: version {VERSION} serves", flush=True)
        HTTPServer(("", 8000), Handler).serve_forever()
