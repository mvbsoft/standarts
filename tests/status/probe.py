"""The client side of tests/status/run.sh, run inside the status container (python -I - <command>),
the only client the socket proxy accepts. Prints plain lines for the shell to grep.

  get <path> none|wrong|right   the HTTP code, then the body, of GET http://127.0.0.1:8080<path>
  proxy <method> <path>         the HTTP code the socket proxy answers to <method> <path>
  summary                       GET /status with the right token, one line per service and disk
  unit                          the branches of status.py that this engine never reaches, with a fake Docker
"""
import http.client
import json
import os
import sys


def request(host: str, port: int, method: str, path: str, headers: dict[str, str]) -> tuple[int, str]:
    """One request; the code and the body (as text)."""
    conn = http.client.HTTPConnection(host, port, timeout=10)
    conn.request(method, path, headers=headers)
    reply = conn.getresponse()
    return reply.status, reply.read().decode("utf-8", "replace")


def get(path: str, auth: str) -> tuple[int, str]:
    """GET from the status service with no token, a wrong one or the right one."""
    token = {"none": None, "wrong": "x" + os.environ["STATUS_TOKEN"], "right": os.environ["STATUS_TOKEN"]}[auth]
    return request("127.0.0.1", 8080, "GET", path, {"Authorization": f"Bearer {token}"} if token else {})


def summary() -> None:
    """The envelope of GET /status as lines: code, keys, ok, every service and every disk."""
    code, body = get("/status", "right")
    data = json.loads(body)
    print("code", code)
    print("keys", " ".join(sorted(data)))
    print("project", data["project"])
    print("status", data["status"])
    print("ok", data["ok"])
    if "error" in data:
        print("error", data["error"])
    for name, svc in sorted(data["services"].items()):
        print("service", name, svc["status"], "keys=" + ",".join(sorted(svc)),
              f"failing={svc['failing']}", f"ms={svc['ms']}", f"output={svc['output']!r}")
    for name, disk in sorted(data["disk"].items()):
        print("disk", name, disk["status"], "keys=" + ",".join(sorted(disk)))


def unit() -> None:
    """A refused (403) or failed (500) inspect with and without a health in the list (the list has
    it from Docker API 1.52 on), and the overall status of an unknown and a starting service."""
    sys.path.insert(0, "/usr/local/lib/status")
    import status  # noqa: PLC0415 (the service's own module, in the image)

    running = {"Names": ["/x"], "State": "running"}
    for name, code, summary in (("refused-no-health", 403, running), ("failed-no-health", 500, running),
                                ("refused-with-health", 403, running | {"Health": {"Status": "healthy", "FailingStreak": 0}})):
        status.docker = lambda path, code=code: (code, None)
        print(name, status.service(summary)["status"])
    print("overall-unknown", status.overall({"services": {"x": {"status": "unknown"}}, "disk": {}}))
    print("overall-starting", status.overall({"services": {"x": {"status": "starting"}, "y": {"status": "healthy"}}, "disk": {}}))


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "get":
        status, text = get(sys.argv[2], sys.argv[3])
        print(status)
        print(text)
    elif command == "proxy":
        print(request("status-proxy", 2375, sys.argv[2], sys.argv[3], {})[0])
    elif command == "unit":
        unit()
    else:
        summary()
