# check-compose 4.0.0 — from the standard's templates/check-compose; change it there, not here.
"""Check one rendered compose file against the rules of standard ENV-01.

Usage:  docker compose -f <file> config --format json | python -I scripts/check-compose.py <file>
        (scripts/check-compose.sh runs it so, in a pinned python image, from the repo root).
Reads:  the rendered file on stdin; <file> as written (the ${X:?} rules); .env.example (IMAGE_TAG);
        docker/<name>/Dockerfile of every own image.
Output: "check-compose: <file>: …" lines on stdout: the violations, the exceptions used, then OK
        or FAIL with the counts.
Exit:   0 no violation; 1 a violation (an input it cannot read stops it with a Python error).

Exceptions live in the file's top-level key x-check-compose-allow:
{<service>: {<rule>: "<reason>"}}, so they show up in diffs and reviews (`config --format json`
drops x- keys inside a service).
"""
import json
import re
import sys
from typing import Any, NamedTuple

RULES = {
    "ports": "port published on an address other than 127.0.0.1 or ::1",
    "image": "image not pinned by version and digest; write <image>:<version>@sha256:<digest>",
    "build": "build: in a stage or prod file; make stage and make prod build the own images from the commit",
    "own-image": "own image is not <repo>-<name>:${IMAGE_TAG:?}",
    "user": "service runs as root",
    "healthcheck": "no healthcheck",
    "restart": "restart is not always",
    "depends_on": "dependency without condition: service_healthy",
    "limits": "no deploy.resources.limits (cpus and memory)",
    "memswap": "memswap_limit is not equal to the memory limit, so the container may also use swap",
    "logging": "no json-file log rotation (max-size, max-file)",
    "no-new-privileges": "no security_opt no-new-privileges:true",
    "cap_drop": "cap_drop does not contain ALL",
    "cap_add": "cap_add gives capabilities back",
    "read_only": "root filesystem is not read_only",
    "privileged": "privileged: true",
    "network_mode": "network_mode: host",
    "docker-sock": "docker.sock is mounted",
}
# A secret or image variable must be ${X:?}: $X, ${X}, ${X-d}, ${X:-d} and ${X?} may render empty
# or fall back to a default. $$ is a literal $ for the container ($$POSTGRES_PASSWORD in a
# CMD-SHELL healthcheck), not a variable. A secret is a variable with a name part PASSWORD, PASS,
# SECRET, TOKEN, KEY or DSN (DB_PASSWORD, API_KEY; not KEYCLOAK_URL).
SECRET = re.compile(r"(?<!\$)(?:\$\$)*\$\{?((?:[A-Z0-9]+_)*(?:PASSWORD|PASS|SECRET|TOKEN|KEY|DSN)(?:_[A-Z0-9]+)*)(?![A-Z0-9_])(?!:\?)")
IMAGE_VAR = re.compile(r"(?<!\$)(?:\$\$)*\$\{?(IMAGE_TAG)(?![A-Z0-9_])(?!:\?)")
# A third-party image is <image>:<version>@sha256:<digest>: the digest pins the content (a tag can
# be pushed again), the tag tells a reader which version it is, so it is not latest
# (22-bookworm-slim and 2 are versions). `docker buildx imagetools inspect <image>:<version>`
# prints the digest.
PINNED = re.compile(r"[^\s@$]+:(?!latest@)\w[\w.-]{0,127}@sha256:[0-9a-f]{64}")
HEREDOC = re.compile(r"<<-?([\"']?)(\w+)\1")
# A parser directive: `# <key>=<value>` on the first lines, before any comment, blank line or
# instruction.
DIRECTIVE = re.compile(r"#\s*([A-Za-z]\w*)\s*=\s*(\S*)\s*")

Finding = tuple[str, str]  # (rule, detail); the detail may be empty


class Project(NamedTuple):
    """What tells an own image from a third-party one.

    repo: the name: of the file without -stage or -prod. An own image is
    <repo>-<name>:${IMAGE_TAG:?}; an image named <repo>-… or tagged with the IMAGE_TAG of
    .env.example (tag) is taken for one. own_name matches <repo>-<name>.
    """

    repo: str
    tag: str | None
    own_name: re.Pattern[str]


# ---- .env.example and the Dockerfiles --------------------------------------


def example_value(var: str) -> str | None:
    """Return the value of a variable in .env.example (the file the check renders from)."""
    try:
        with open(".env.example", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    values = [line.split("=", 1)[1] for line in lines if line.startswith(var + "=")]
    return values[-1] if values else None


def heredoc_ends(instruction: str) -> list[str]:
    """Return the terminators of the heredocs a RUN, COPY or ADD opens.

    As in BuildKit, only a word that starts with << outside quotes opens one: not << inside a word
    ($((1<<3))) or in a quoted string.
    """
    if instruction.split(maxsplit=1)[0].upper() not in ("RUN", "COPY", "ADD"):
        return []
    ends, quote, i = [], "", 0
    while i < len(instruction):
        c = instruction[i]
        if quote:
            quote = "" if c == quote else quote
            i += 2 if c == "\\" and quote == '"' else 1
            continue
        if c in "'\"":
            quote = c
        elif c == "\\":
            i += 1
        elif (c == "<" and (i == 0 or instruction[i - 1].isspace())
              and (m := HEREDOC.match(instruction, i))):
            ends.append(m.group(2))
            i = m.end()
            continue
        i += 1
    return ends


def instructions(dockerfile: str) -> list[tuple[int, list[str]]] | None:
    """Return the instructions of a Dockerfile as (line number, words); None if it cannot be read.

    A line that ends in \\ goes on in the next; comments and the bodies of heredocs
    (RUN <<EOF … EOF) are left out. A syntax directive (# syntax=<image>, the BuildKit frontend)
    comes as ("#SYNTAX", <image>).
    """
    try:
        with open(dockerfile, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    found, parts, start, ends, directives = [], [], 0, [], True
    for number, line in enumerate(lines, 1):
        text = line.strip()
        directive = DIRECTIVE.fullmatch(text) if directives else None
        directives = bool(directive)
        if directive and directive.group(1).lower() == "syntax":
            found.append((number, ["#SYNTAX", directive.group(2)]))
            continue
        if ends:
            if text == ends[0]:
                ends.pop(0)
            continue
        if text.startswith("#") or not (parts or text):
            continue
        start = start if parts else number
        parts.append(text[:-1] if text.endswith("\\") else text)
        if not text.endswith("\\"):
            found.append((start, " ".join(parts).split()))
            ends = heredoc_ends(" ".join(parts))
            parts = []
    return found + ([(start, " ".join(parts).split())] if parts else [])


def runtime_user(dockerfile: str) -> str | None:
    """Return the USER the runtime stage of the Dockerfile runs as.

    That is its last USER, else that of the stage it is built FROM, and so on along the chain; None
    when no stage of the chain sets one (an image from outside counts as root); "?<file>" when the
    file cannot be read.
    """
    found = instructions(dockerfile)
    if found is None:
        return f"?{dockerfile}"
    base, user, stage = {}, {}, None
    for _, words in found:
        if words and words[0].upper() == "FROM":
            ref = [w for w in words[1:] if not w.startswith("--")]
            stage = ref[2].lower() if len(ref) >= 3 and ref[1].upper() == "AS" else None
            if stage:
                base[stage], user[stage] = ref[0].lower(), None
        elif stage and words and words[0].upper() == "USER":
            user[stage] = words[1] if len(words) > 1 else ""
    stage, seen = "runtime", set()
    while stage in base and stage not in seen:
        if user[stage] is not None:
            return user[stage]
        seen.add(stage)
        stage = base[stage]
    return None


def unpinned(dockerfile: str) -> list[str]:
    """Return the images of the Dockerfile that are not pinned by version and digest.

    The images are those of # syntax=, and of FROM, COPY --from and RUN --mount from= in every
    stage, each as "<file>:<line>: <reference>". Not images: scratch and an earlier stage, by name
    or, after --from, by number. A variable is reported too: the build may give it any value.
    """
    found, stages = [], []
    for number, words in instructions(dockerfile) or []:
        op, refs, ref = words[0].upper(), [], [w for w in words[1:] if not w.startswith("--")]
        if op == "#SYNTAX":
            refs = [("# syntax=", words[1])]
        elif op == "FROM":
            refs = [("FROM ", ref[0])] if ref else []
        elif op == "COPY":
            refs = [("COPY --from=", w[len("--from="):])
                    for w in words[1:] if w.startswith("--from=")]
        elif op == "RUN":
            refs = [("RUN --mount from=", kv[len("from="):])
                    for w in words[1:] if w.startswith("--mount=")
                    for kv in w[len("--mount="):].split(",") if kv.startswith("from=")]
        for how, image in refs:
            stage = image.lower() in stages or (
                how != "FROM " and image.isdigit() and int(image) < len(stages))
            if not (image.lower() == "scratch" or stage or PINNED.fullmatch(image)):
                found.append(f"{dockerfile}:{number}: {how}{image}")
        if op == "FROM":
            stages.append(ref[2].lower() if len(ref) >= 3 and ref[1].upper() == "AS" else "")
    return found


# ---- the rules of one service ----------------------------------------------


def port_findings(svc: dict[str, Any]) -> list[Finding]:
    """Return a ports finding for every port published on an address other than loopback."""
    found = []
    for port in svc.get("ports", []):
        if port.get("host_ip") not in ("127.0.0.1", "::1"):
            found.append(
                ("ports", f"{port.get('published') or 'a random port'}->{port.get('target')}"))
    return found


def image_findings(svc: dict[str, Any], project: Project,
                   dockerfiles: set[str]) -> tuple[list[Finding], list[str]]:
    """Return the build, own-image, image and user findings, and the problems of a Dockerfile.

    The Dockerfile of an own image (docker/<name>/Dockerfile) gives its user and its images; each
    is checked once per compose file, however many services run its image (dockerfiles holds those
    checked so far), so its problems come with the first such service.
    """
    found, problems = [], []
    image = svc.get("image", "")
    if "build" in svc:
        found.append(("build", ""))
    ref, _, tag = image.rpartition(":") if ":" in image.rsplit("/", 1)[-1] else (image, "", "")
    if ((project.repo and image.startswith(project.repo + "-"))
            or (project.tag and tag == project.tag)):
        if not project.own_name.fullmatch(ref) or tag != project.tag:
            found.append(("own-image", image))
        base = ref.rsplit("/", 1)[-1]
        own = base[len(project.repo) + 1:] if base.startswith(project.repo + "-") else base
        dockerfile = f"docker/{own}/Dockerfile"
        user = svc.get("user") or runtime_user(dockerfile)
        if user is None or user.split(":")[0] in ("", "root", "0"):
            found.append(("user", f"runs as {user or 'root (no USER in the runtime stage or a stage it is built from)'}"))
        elif user.startswith("?"):
            found.append(("user", f"cannot read {user[1:]}"))
        # No exception: an image in a registry always has a digest to pin it by.
        if dockerfile not in dockerfiles:
            dockerfiles.add(dockerfile)
            problems.extend(f"{line} is not pinned by version and digest; write <image>:<version>@sha256:<digest>, not a tag or a variable"
                            for line in unpinned(dockerfile))
    elif "build" not in svc:
        if not PINNED.fullmatch(image):
            found.append(("image", image))
        if str(svc.get("user", "")).split(":")[0] in ("", "root", "0"):
            found.append(("user", f"user: {svc.get('user', '<not set>')}"))
    return found, problems


def runtime_findings(svc: dict[str, Any]) -> list[Finding]:
    """Return the healthcheck, restart, depends_on, limits, memswap and logging findings."""
    found = []
    hc = svc.get("healthcheck")
    if not hc or hc.get("disable") or hc.get("test") in (["NONE"], None):
        found.append(("healthcheck", ""))
    if svc.get("restart") != "always":
        found.append(("restart", str(svc.get("restart"))))
    for dep, opts in (svc.get("depends_on") or {}).items():
        if opts.get("condition") != "service_healthy":
            found.append(("depends_on", f"{dep}: {opts.get('condition')}"))
    limits = svc.get("deploy", {}).get("resources", {}).get("limits", {})
    if not limits.get("cpus") or not limits.get("memory"):
        found.append(("limits", ""))
    # Compose renders both in bytes; without memswap_limit Docker allows as much swap again.
    if limits.get("memory") and str(svc.get("memswap_limit", "")) != str(limits["memory"]):
        found.append(
            ("memswap", f"memswap_limit {svc.get('memswap_limit', 'not set')}, memory {limits['memory']}"))
    log = svc.get("logging", {})
    opts = log.get("options", {})
    if log.get("driver") != "json-file" or not opts.get("max-size") or not opts.get("max-file"):
        found.append(("logging", ""))
    return found


def hardening_findings(svc: dict[str, Any]) -> list[Finding]:
    """Return the hardening findings, in rule order.

    The rules: no-new-privileges, cap_drop, cap_add, read_only, privileged, network_mode and
    docker-sock.
    """
    found = []
    if not any(o.replace("=", ":") in ("no-new-privileges:true", "no-new-privileges")
               for o in svc.get("security_opt", [])):
        found.append(("no-new-privileges", ""))
    if "ALL" not in svc.get("cap_drop", []):
        found.append(("cap_drop", ""))
    if svc.get("cap_add"):
        found.append(("cap_add", ", ".join(svc["cap_add"])))
    if svc.get("read_only") is not True:
        found.append(("read_only", ""))
    if svc.get("privileged"):
        found.append(("privileged", ""))
    if svc.get("network_mode") == "host":
        found.append(("network_mode", ""))
    if any("docker.sock" in str(v.get("source", "")) for v in svc.get("volumes", [])):
        found.append(("docker-sock", ""))
    return found


def judge(name: str, found: list[Finding], allow: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Return the problems and the exceptions used of one service.

    Args:
      name: the service, for the messages.
      found: its findings in rule order.
      allow: its entry of x-check-compose-allow, {<rule>: "<reason>"}; an unknown rule or an empty
        reason is a problem itself.
    """
    problems, used = [], []
    for rule, reason in allow.items():
        if rule not in RULES:
            problems.append(f"{name}: x-check-compose-allow: unknown rule {rule!r}")
        elif not str(reason).strip():
            problems.append(f"{name}: x-check-compose-allow: {rule}: no reason given")
    for rule, detail in found:
        if str(allow.get(rule, "")).strip():
            used.append(f"{name}: {rule} — {allow[rule]}")
        else:
            problems.append(f"{name}: {rule}: {RULES[rule]}" + (f" ({detail})" if detail else ""))
    return problems, used


# ---- the file as written ---------------------------------------------------


def variable_problems(compose_file: str) -> list[str]:
    """Return the secret and IMAGE_TAG variables of the file as written that are not ${X:?}."""
    problems = []
    with open(compose_file, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            if line.lstrip().startswith("#"):
                continue
            for match in SECRET.finditer(line):
                problems.append(f"line {number}: secret {match.group(1)} is not required (use ${{{match.group(1)}:?}})")
            for match in IMAGE_VAR.finditer(line):
                problems.append(f"line {number}: {match.group(1)} must be required (use ${{{match.group(1)}:?}})")
    return problems


# ---- main ------------------------------------------------------------------


def main(argv: list[str]) -> int:
    """Check the file argv[1], rendered on stdin; print the result and return the exit code."""
    compose_file = argv[1]
    cfg = json.load(sys.stdin)
    problems = []
    used = []
    dockerfiles = set()
    allow = cfg.get("x-check-compose-allow") or {}
    for name in allow:
        if name not in cfg.get("services", {}):
            problems.append(f"x-check-compose-allow: no service {name!r}")
    tag = example_value("IMAGE_TAG")
    repo = re.sub(r"-(stage|prod)$", "", cfg.get("name", ""))
    project = Project(repo, tag, re.compile(re.escape(repo) + r"-([a-z0-9][a-z0-9._-]*)"))

    for name, svc in sorted(cfg.get("services", {}).items()):
        ports = port_findings(svc)
        images, dockerfile_problems = image_findings(svc, project, dockerfiles)
        found = ports + images + runtime_findings(svc) + hardening_findings(svc)
        problems.extend(dockerfile_problems)
        judged, exceptions = judge(name, found, allow.get(name) or {})
        problems.extend(judged)
        used.extend(exceptions)
    problems.extend(variable_problems(compose_file))

    for line in problems:
        print(f"check-compose: {compose_file}: {line}")
    for line in used:
        print(f"check-compose: {compose_file}: exception {line}")
    print(f"check-compose: {compose_file}: {'FAIL' if problems else 'OK'}"
          f" ({len(problems)} violations, {len(used)} exceptions)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
