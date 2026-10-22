#!/usr/local/bin/python -I
# project template 1.0.0 — the status service (docs/how-to/operations.md). Python standard library only.
"""Reports the health of this compose project's containers and the free disk space as one JSON
envelope. It asks Docker only through the socket proxy (service status-proxy), which lets it list
containers and inspect those named <project>-<service>-<n>, nothing else.

The envelope's status is pass (every service healthy, or running without a healthcheck, and every
disk healthy), warn (no failure, but a service is starting: a deploy pages nobody) or fail (any
other service status, a disk below its threshold, or Docker unreadable). GET /status answers 200
for pass and warn, 503 for fail, with the same body. Every STATUS_PUSH_INTERVAL the envelope is
POSTed to STATUS_PUSH_URL on pass and warn, to STATUS_PUSH_FAIL_URL on fail; an empty address
sends nothing, so a monitor that waits for pings alerts on the silence.

Usage:  status serve    answer GET /status (Bearer STATUS_TOKEN) and GET /health; push when an
                        address is set
        status health   the container's own healthcheck: GET /health of the running server
        (the image's ENTRYPOINT is status, its CMD serve)
Reads:  STATUS_PROJECT, STATUS_TOKEN, STATUS_PUSH_URL, STATUS_PUSH_FAIL_URL, STATUS_PUSH_INTERVAL,
        DISK_WARN, DISK_RESERVE; Docker through status-proxy:2375; the folders under /disk.
Output: serve: the answers on port 8080; on stdout the start line and each change of the overall
        status; on stderr a line per request but /health, a failed push, and "status: <why>" for a
        setting that is wrong. health: the body of /health, or why the server does not answer.
Exit:   1 for a setting that is wrong or an unknown command; serve: 0 on SIGTERM; health: 0 when
        /health answers 200, else 1.
"""
import hmac
import http.client
import json
import os
import re
import signal
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, NoReturn

PROXY = ("status-proxy", 2375)
PORT = 8080
DISKS = "/disk"  # every folder mounted under it is reported by its name; / is the Docker data root
CACHE_SECONDS = 2.0  # a token holder cannot make it ask Docker more often than this
UNITS = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def die(message: str) -> NoReturn:
    """Stop with a message for docker compose logs."""
    print(f"status: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def size(text: str) -> int | None:
    """2G, 500M, 64K, 1T or 0 (as DISK_RESERVE) in bytes; None when it is not such a size."""
    m = re.fullmatch(r"(\d+)([KMGT]?)", text)
    if not m or (not m.group(2) and m.group(1) != "0"):
        return None
    return int(m.group(1)) * UNITS.get(m.group(2), 1)


def seconds(text: str) -> int | None:
    """60, 60s, 5m or 1h in seconds (at least 1); None otherwise."""
    m = re.fullmatch(r"(\d+)([smh]?)", text)
    n = int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)] if m else 0
    return n or None


class Settings:
    """The environment, checked once at start."""

    def __init__(self, env: dict[str, str]) -> None:
        self.project = env.get("STATUS_PROJECT", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", self.project):
            die(f"STATUS_PROJECT is '{self.project}', not a compose project name (the compose file passes ${{COMPOSE_PROJECT_NAME}})")
        self.token = env.get("STATUS_TOKEN", "")
        if len(self.token) < 16:
            die("STATUS_TOKEN has fewer than 16 characters: set a long random one in .env (openssl rand -hex 32)")
        self.push_url = env.get("STATUS_PUSH_URL", "")
        self.push_fail_url = env.get("STATUS_PUSH_FAIL_URL", "")
        for name, url in (("STATUS_PUSH_URL", self.push_url), ("STATUS_PUSH_FAIL_URL", self.push_fail_url)):
            if url and urllib.parse.urlsplit(url).scheme not in ("http", "https"):
                die(f"{name} is not an http:// or https:// address (empty: no push)")
        every = env.get("STATUS_PUSH_INTERVAL", "60s")
        self.push_every = seconds(every) or die(f"STATUS_PUSH_INTERVAL is '{every}', not like 60, 60s, 5m or 1h")
        warn = env.get("DISK_WARN", "10%")
        m = re.fullmatch(r"(\d+(?:\.\d+)?)%", warn)
        self.warn_pct = float(m.group(1)) if m else None
        self.warn_bytes = None if m else size(warn)
        if (self.warn_pct is None and self.warn_bytes is None) or (self.warn_pct or 0) > 100:
            die(f"DISK_WARN is '{warn}', not a percentage like 10% or a size like 20G (0: DISK_RESERVE alone)")
        reserve = env.get("DISK_RESERVE", "2G")
        self.reserve = size(reserve)
        if self.reserve is None:
            die(f"DISK_RESERVE is '{reserve}', not a size like 2G or 500M")


def docker(path: str) -> tuple[int, Any]:
    """GET <path> from the socket proxy: the code and, on 200, the parsed body."""
    conn = http.client.HTTPConnection(*PROXY, timeout=5)
    try:
        conn.request("GET", path)
        reply = conn.getresponse()
        body = reply.read()
    finally:
        conn.close()
    return reply.status, json.loads(body) if reply.status == 200 else None


def when(stamp: str) -> datetime:
    """An RFC 3339 time with nanoseconds, as Docker writes it, cut to microseconds."""
    m = re.fullmatch(r"([^.Z+]+)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)", stamp)
    if not m:
        raise ValueError(stamp)
    fraction = (m.group(2) or "0")[:6].ljust(6, "0")
    return datetime.fromisoformat(f"{m.group(1)}.{fraction}{'+00:00' if m.group(3) == 'Z' else m.group(3)}")


def service(summary: dict[str, Any]) -> dict[str, Any]:
    """status, failing, ms and output of one container. Stopped, paused or restarting is down,
    whatever its last health was. ms and output come from the last check since the container
    started (after a restart Docker keeps the old results); they are null when no check has run
    since then, or when the inspect is refused (a container_name outside <project>-<service>-<n>)
    or fails. Then the health comes from the list, which has it from Docker API 1.52 on; without
    it the status is unknown, a failure."""
    code, inspect = docker(f"/containers/{summary['Names'][0].lstrip('/')}/json")
    state = inspect["State"] if code == 200 else {}
    health = (state.get("Health") or {"Status": "none"}) if code == 200 else (summary.get("Health") or {})
    status = health.get("Status") or "unknown"
    found = {"status": status if summary.get("State") == "running" else "down",
             "failing": health.get("FailingStreak"), "ms": None, "output": None}
    log = health.get("Log") or []
    if log and state.get("StartedAt") and when(log[-1]["Start"]) >= when(state["StartedAt"]):
        found["ms"] = round((when(log[-1]["End"]) - when(log[-1]["Start"])).total_seconds() * 1000)
        found["output"] = log[-1]["Output"]
    return found


def disk(path: str, settings: Settings) -> dict[str, Any]:
    """Free space of the filesystem that holds <path>, for a non-root writer (f_bavail, as df shows
    it; untested against f_bfree: the tests' tmpfs reserves no blocks, so the two are equal there).
    Unhealthy below DISK_WARN, and never below DISK_RESERVE. A deploy needs more than the reserve
    (twice the own images plus DISK_RESERVE), so DISK_WARN is set above that to warn before."""
    st = os.statvfs(path)
    total = (st.f_bavail + st.f_blocks - st.f_bfree) * st.f_frsize
    free = st.f_bavail * st.f_frsize
    need = settings.warn_bytes if settings.warn_pct is None else int(total * settings.warn_pct / 100)
    need = max(need or 0, settings.reserve or 0)
    return {"status": "healthy" if free >= need else "unhealthy", "free_bytes": free,
            "free_pct": round(100 * free / total, 1) if total else 0.0, "min_free_bytes": need}


def overall(data: dict[str, Any]) -> str:
    """pass, warn or fail of an envelope (the module docstring)."""
    states = {s["status"] for s in data["services"].values()}
    if "error" in data or states - {"healthy", "none", "starting"} or any(
            d["status"] != "healthy" for d in data["disk"].values()):
        return "fail"
    return "warn" if "starting" in states else "pass"


class Monitor:
    """Builds the envelope, at most once per CACHE_SECONDS, and remembers every service it has
    seen since it started: one whose container is gone is reported as missing."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.seen: set[str] = set()
        self.lock = threading.Lock()
        self.last: tuple[float, dict[str, Any]] = (0.0, {})

    def services(self) -> dict[str, dict[str, Any]]:
        """Every container of the project except one-off runs (docker compose run), by service."""
        labels = [f"com.docker.compose.project={self.settings.project}", "com.docker.compose.oneoff=False"]
        query = urllib.parse.quote(json.dumps({"label": labels}))
        code, found = docker(f"/containers/json?all=1&filters={query}")
        if code != 200:
            raise OSError(f"the socket proxy answered {code} to the container list")
        result = {}
        for c in found:
            labels = c.get("Labels") or {}
            name = labels.get("com.docker.compose.service", c["Names"][0].lstrip("/"))
            number = labels.get("com.docker.compose.container-number", "1")
            result[name if number == "1" else f"{name}-{number}"] = service(c)
        self.seen |= set(result)
        for name in self.seen - set(result):
            result[name] = {"status": "missing", "failing": None, "ms": None, "output": None}
        return dict(sorted(result.items()))

    def envelope(self) -> dict[str, Any]:
        """The answer of GET /status, fresh or at most CACHE_SECONDS old."""
        with self.lock:
            if time.monotonic() - self.last[0] < CACHE_SECONDS:
                return self.last[1]
            data: dict[str, Any] = {"project": self.settings.project, "ok": False,
                                    "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
            try:
                data["services"] = self.services()
            except (OSError, ValueError, KeyError) as e:
                data["services"], data["error"] = {}, f"cannot read the containers: {e}"
            paths = {"docker": "/"}
            if os.path.isdir(DISKS):
                paths |= {n: os.path.join(DISKS, n) for n in sorted(os.listdir(DISKS))}
            data["disk"] = {name: disk(path, self.settings) for name, path in paths.items()}
            # Running without a healthcheck (none) counts as up: check-compose requires one anyway.
            data["status"] = overall(data)
            data["ok"] = data["status"] != "fail"
            self.last = (time.monotonic(), data)
            return data


def handler(monitor: Monitor) -> type[BaseHTTPRequestHandler]:
    """The HTTP handler: GET /status with the token, GET /health without one, nothing else."""
    expected = f"Bearer {monitor.settings.token}".encode()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (the name http.server calls)
            """Answer one GET."""
            if self.path == "/health":
                ok = "error" not in monitor.envelope()
                return self.reply(200 if ok else 503, {"status": "pass" if ok else "fail"})
            if self.path != "/status":
                return self.reply(404, {"error": "not found"})
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
                return self.reply(401, {"error": "Authorization: Bearer <STATUS_TOKEN> required"})
            data = monitor.envelope()
            self.reply(503 if data["status"] == "fail" else 200, data)

        def reply(self, code: int, body: dict[str, Any]) -> None:
            """Send <body> as JSON; never cached, since every answer is a snapshot."""
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            if code == 401:
                self.send_header("WWW-Authenticate", "Bearer")
            self.end_headers()
            self.wfile.write(data)

        def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
            """Log every request but the healthcheck's; headers (the token) are never logged."""
            if self.path != "/health":  # the healthcheck would fill the log
                super().log_request(code, size)

    return Handler


def push(monitor: Monitor) -> None:
    """Every STATUS_PUSH_INTERVAL, POST the envelope to STATUS_PUSH_URL on pass and warn, to
    STATUS_PUSH_FAIL_URL on fail; an empty address sends nothing. A failure, or an answer other
    than 2xx, is only logged (without the address, which may hold a key) and the next round tries
    again. Each change of the overall status is logged once."""
    s = monitor.settings
    last = ""
    while True:
        try:
            data = monitor.envelope()
            fail = data["status"] == "fail"
            url = s.push_fail_url if fail else s.push_url
            if data["status"] != last:
                where = "STATUS_PUSH_FAIL_URL" if fail else "STATUS_PUSH_URL"
                print(f"status: now {data['status']}: {'pushing to' if url else 'no push, empty'} {where}", flush=True)
                last = data["status"]
            if url:
                body = json.dumps(data).encode()
                req = urllib.request.Request(url, body, {"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req, timeout=10) as reply:
                    reply.read()
        except Exception as e:  # noqa: BLE001 (any failure of one push is logged, never fatal)
            print(f"status: push failed: {type(e).__name__}: {getattr(e, 'reason', e)}", file=sys.stderr, flush=True)
        time.sleep(s.push_every)


def health() -> int:
    """The container healthcheck: 0 when the server answers /health with 200."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
        conn.request("GET", "/health")
        reply = conn.getresponse()
        print(reply.read().decode())
        return 0 if reply.status == 200 else 1
    except OSError as e:
        print(f"the status server does not answer: {e}")
        return 1


def main(argv: list[str]) -> int:
    """status serve | status health."""
    command = argv[1] if len(argv) > 1 else "serve"
    if command == "health":
        return health()
    if command != "serve":
        die(f"unknown command '{command}': serve or health")
    # As PID 1 without init: true, Python would ignore the SIGTERM of docker stop.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    monitor = Monitor(Settings(dict(os.environ)))
    pushing = bool(monitor.settings.push_url or monitor.settings.push_fail_url)
    if pushing:
        threading.Thread(target=push, args=(monitor,), daemon=True).start()
    print(f"status: project {monitor.settings.project}, port {PORT}, push {'on' if pushing else 'off'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), handler(monitor)).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
