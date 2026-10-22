"""A minimal LSP client for tests/stacks/run.sh (standard AI-07).

  lsp-client.py args <plugin.json> <server> <project dir>
      prints the command and the arguments of that server, one per line, as the docker-lsp plugin
      starts it: ${CLAUDE_PROJECT_DIR} replaced by the project folder.
  lsp-client.py check <project dir> <file> <language id> <expected text>
      speaks LSP on stdin (the server's output) and stdout (its input): initialize, initialized,
      didOpen of the file, then waits for publishDiagnostics of that file with a message that
      contains the expected text; prints a JSON report on stderr. Exit 0: found; 1: not found.
"""

import json
import os
import select
import sys
import time

TIMEOUT = 240


def args(plugin, server, project):
    with open(plugin, encoding="utf-8") as f:
        conf = json.load(f)["lspServers"][server]
    for word in [conf["command"], *conf.get("args", [])]:
        print(word.replace("${CLAUDE_PROJECT_DIR}", project))


class Conn:
    def __init__(self):
        self.inp = sys.stdin.buffer.raw
        self.buf = b""
        self.next_id = 0

    def send(self, msg):
        body = json.dumps(msg).encode()
        sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        sys.stdout.buffer.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        return self.next_id

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def read(self, deadline):
        while True:
            head, sep, rest = self.buf.partition(b"\r\n\r\n")
            if sep:
                length = next(int(line.split(b":")[1]) for line in head.split(b"\r\n")
                              if line.lower().startswith(b"content-length:"))
                if len(rest) >= length:
                    self.buf = rest[length:]
                    return json.loads(rest[:length])
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.inp], [], [], left)[0]:
                return None
            chunk = os.read(self.inp.fileno(), 65536)
            if not chunk:
                return None
            self.buf += chunk


def check(project, path, language, expected):
    start = time.monotonic()
    report = {"initialized_s": None, "diagnostics_s": None, "diagnostics": [], "server_requests": []}
    conn = Conn()
    root = "file://" + project
    uri = "file://" + path
    init = conn.request("initialize", {
        "processId": None,
        "rootUri": root,
        "workspaceFolders": [{"uri": root, "name": os.path.basename(project)}],
        "capabilities": {
            "workspace": {"configuration": True, "workspaceFolders": True},
            "textDocument": {"publishDiagnostics": {"relatedInformation": True},
                             "synchronization": {"didSave": True}},
        },
    })
    deadline = start + TIMEOUT
    found = False
    while True:
        msg = conn.read(deadline)
        if msg is None:
            break
        if "method" in msg and "id" in msg:  # a request of the server: answer it
            report["server_requests"].append(msg["method"])
            result = None
            if msg["method"] == "workspace/configuration":
                result = [None for _ in msg["params"]["items"]]
            conn.send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif msg.get("id") == init:
            if "error" in msg:
                report["init_error"] = msg["error"]
                break
            report["initialized_s"] = round(time.monotonic() - start, 2)
            report["server"] = msg["result"].get("serverInfo")
            conn.notify("initialized", {})
            with open(path, encoding="utf-8") as f:
                text = f.read()
            conn.notify("textDocument/didOpen", {"textDocument": {
                "uri": uri, "languageId": language, "version": 1, "text": text}})
        elif msg.get("method") == "textDocument/publishDiagnostics" and msg["params"]["uri"] == uri:
            diags = msg["params"]["diagnostics"]
            report["diagnostics"] = [
                {"line": d["range"]["start"]["line"] + 1, "message": d["message"]} for d in diags]
            if any(expected.lower() in d["message"].lower() for d in diags):
                report["diagnostics_s"] = round(time.monotonic() - start, 2)
                found = True
                break
    if report["initialized_s"] is not None:
        conn.request("shutdown", None)
        conn.read(time.monotonic() + 5)
        conn.notify("exit", None)
    report["found"] = found
    print(json.dumps(report), file=sys.stderr)
    matched = [d["message"] for d in report["diagnostics"] if expected.lower() in d["message"].lower()]
    if matched:
        print("diagnostic: " + matched[0].replace("\n", " "), file=sys.stderr)
    return 0 if found else 1


if __name__ == "__main__":
    if sys.argv[1] == "args":
        args(*sys.argv[2:5])
    else:
        sys.exit(check(*sys.argv[2:6]))
