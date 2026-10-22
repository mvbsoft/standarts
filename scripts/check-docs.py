# Checks the standard's own documents. Run through `make check-docs`; it reads the tree under the
# current directory and needs no network.
#
# Pairs: every bilingual file has both languages with the same version and the same rule IDs in
# the same order.
#
# Links: every relative link points at a file that exists, and not into .work/, which is not in
# git. A project template links to files of the project it becomes: its links to files the
# template lacks are not checked.
#
# Anchors: a link with a #fragment, to the same file or another .md file, names a heading of that
# file by GitHub's rules: the heading text without its markup (code, links, HTML), in lower case,
# with every character that is not a letter (of any script), a digit, '_', '-' or a space removed
# and every space a '-'; a repeated heading gets -1, -2, … in order; <a id="…"> counts too. A
# fragment may be percent-encoded. Headings and links in ``` blocks do not count.
#
# Quoted messages: a message the template's docs quote as output is printed by a file of
# SCRIPTS (the project template's scripts, docker/, .githooks/, Makefile and compose files,
# check-compose, the agent hooks, the standard's scripts/*.sh). Quoted means a `code span` in
# QUOTING_DOCS (the template's README and docs/how-to, prompt/*.md, GUIDE.md and GUIDE.uk.md, whose
# messages are English too): in the first column ("What you see") of a table under a heading "When
# something fails"; right after an OUTPUT_VERB ("prints", "prints only", "says", "refuses with",
# "fails with", "stops it with", "ends with", "виводить", "відмовляється з", …), with a ':' or
# without ("says: `…`"), or joined to such a span by "and", "or", "then" or a comma; in
# parentheses that open in the clause of an OUTPUT_PAREN verb ("prints the free space it checked
# (`space: …`)", "names them (for example `…`)"); as "a `…` line"; and anywhere when it starts
# with the prefix of a message: one or two lower-case words and ': ' that start a string of a
# script (`prune: removed …` after "removes the older ones:", `check failed: <file>` after
# "after"). It must read as a message: three words or more, or a "word: word" (`parity`,
# `make status`, `GET /status` name things, and so does a `make …` span without ':' or ';'). A
# span in JSON form (`"error": "…"`) quotes each of its strings. In a message a word with a
# <placeholder>, ${VAR} or $VAR in it is a value, and `…` (or `...`) text left out. The message
# must appear in order in one string of a script (comment lines do not count), where a value is a
# variable with punctuation around it ($x, ${x}, $(…), %s, an f-string {…}; ${x:-text} also reads
# as its text, and an f-string {'a' if x else 'b'} as each of its two texts) and left-out text is
# up to 160 characters. A variable may also stand for a word the docs give a real value
# (`OK: stage runs <commit>`, printed by `say "OK: $e runs $(sha)"`), or for two words when
# text or the end of the string follows it at once (`stopping app db for the restore`, printed by
# `say "restore: stopping $(…)for the restore"`), but at least half of the words are literal, and
# all of up to two (one word alone: `log-archive: <file>`). A message may be put together, two
# levels deep at most: from a variable that holds a part which starts or ends at a placeholder or
# a ':' and itself starts a string, two thirds of its words literal (say "unhealthy: $bad" with
# bad="the last drill failed: $why"; "… and $1: …" with $1 from the caller), or is a whole string
# of one word between two values (`<name> on <host>` from printf '%s on %s'); or from a whole
# string of a script and a string with the rest (here='the backup folder (…)', then
# printf '%s %s' "$here" "$1"). Messages of other programs (Docker Compose, PostgreSQL, Python's
# urllib, the socket proxy), quoted so that the reader knows them, are in FOREIGN. A quoted
# message that is the start of another one passes.
#
# Not checked (lead decision 2026-10-22): a span after other words ("for example `…`" outside
# parentheses, "as `…`", "after `…`", a ':' that ends a phrase with no OUTPUT_VERB) or in
# parentheses after another verb ("builds the images (`…`)"), unless it starts with the prefix of
# a message: there a span is as often a command, a setting or a file as a message, and a message
# without a prefix (`WARNING: …`, a sentence) cannot be told from them. "names (`…`)" with no
# object is not quoted output either (the number the message names (`stat -c %g …`) is a command).
# So a prefix that no script prints any more (a renamed `check failed:`) makes such a span
# unchecked, and in a short message a variable may stand for the prefix (`space: not checked: …`
# passes on "check-compose: $f: not checked: …").
#
# Repeats: the same passage, one sentence or two in a row, of 200 characters or more, in the prose
# of two files of REPEAT_FILES, English with English and Ukrainian with Ukrainian: a fact has one
# place, and the other files link to it. Code blocks, tables, headings, the targets of links and
# sentences with an address (a source quoted where it proves a claim) do not count. Intended
# repeats are in REPEATS (the start of the passage).
import bisect
import functools
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(".")
BILINGUAL = [ROOT / "README.md", ROOT / "CONTRIBUTING.md", ROOT / "GUIDE.md"]
BILINGUAL += sorted((ROOT / "standard").glob("*.md")) + sorted((ROOT / "decisions").glob("*.md"))
RULE_ID = re.compile(r"^### ([A-Z]+-\d+)\.", re.M)
VERSION = re.compile(r"^> (?:Version|Версія) (\S+)", re.M)
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$", re.M)
HTML_ANCHOR = re.compile(r"<a\s[^>]*\b(?:id|name)=\"([^\"]+)\"", re.I)
TEMPLATE = ROOT / "templates" / "project"
QUOTING_DOCS = [TEMPLATE / "README.md"] + sorted((TEMPLATE / "docs" / "how-to").glob("*.md"))
QUOTING_DOCS += sorted((ROOT / "prompt").glob("*.md")) + [ROOT / "GUIDE.md", ROOT / "GUIDE.uk.md"]
SCRIPTS = sorted(p for d in ("scripts", "docker", ".githooks") for p in (TEMPLATE / d).rglob("*")
                 if p.is_file())
SCRIPTS += [TEMPLATE / "Makefile"] + sorted(TEMPLATE.glob("docker-compose.*.yml"))
SCRIPTS += sorted(p for p in (ROOT / "templates" / "check-compose" / "scripts").glob("*")
                  if p.is_file())
SCRIPTS += sorted((ROOT / "templates" / "agent-hooks" / ".claude" / "hooks").glob("*"))
SCRIPTS += sorted((ROOT / "scripts").glob("*.sh"))  # the standard's own: proof.sh, release.sh
# A span right after one of these is quoted output ("prints only `exit 0`", "refuses with `…`").
# So is a span joined to such a span by "and", "or", "then" or a comma alone, and "a `…` line".
OUTPUT_LINE = r"\ba\s+`([^`]+)`\s+line\b|\bрядок\s+`([^`]+)`"
OUTPUT_VERB = (r"\b(?:prints|print|says|say|shows|refuses\s+with|refused\s+with|fails\s+with|"
               r"stops(?:\s+it)?\s+with|ends\s+with|exits\s+with|виводить|пише|каже|показує|"
               r"відмовляє\s+з|відмовляється\s+з|падає\s+з|зупиняється\s+з|завершується)"
               r"(?:\s+(?:only|лише))?:?\s+`([^`]+)`")
# A span in parentheses that opens within the clause of one of these is quoted output too
# ("prints the free space it checked (`space: …`)", "names them (for example `…`)").
OUTPUT_PAREN = (r"\b(?:prints|says|shows|names(?=\s+\w)|reports|stops\s+it|refuses|fails|"
                r"виводить|пише|каже|показує|називає(?=\s+\w)|зупиняє)\b[^.;:`()]{0,60}?"
                r"\(\s*(?:for\s+example\s+|наприклад\s+)?`([^`]+)`")
OUTPUT_NEXT = (r"\s*(?:,\s*(?:and\s+|or\s+|then\s+|і\s+|та\s+|або\s+|потім\s+)?"
               r"|\s+(?:and|or|then|і|та|або|потім)\s+)`([^`]+)`")
FOREIGN = [  # regexes of messages that another program prints
    r"required variable \S+ is missing a value",  # Docker Compose: a ${VAR:?} without a value
    r"no configuration file provided",  # Docker Compose: no compose file named, none by default
    r"dependency failed to start",  # Docker Compose: a depends_on service did not become healthy
    r"socket not available .* permission denied",  # the socket proxy image of status-proxy
    r"password authentication failed",  # PostgreSQL
    r"HTTP Error \d+: .*",  # Python's urllib, for an answer that is no 2xx
]
REPEAT_FILES = sorted(ROOT.glob("GUIDE*.md")) + sorted(ROOT.glob("README*.md"))
REPEAT_FILES += sorted((ROOT / "standard").glob("*.md")) + sorted((ROOT / "decisions").glob("*.md"))
REPEAT_FILES += sorted((ROOT / "templates").glob("**/docs/**/*.md")) + [TEMPLATE / "README.md"]
REPEATS = []
VAR = "\x00"  # a variable of a script, after script_text()
GAP = "…"  # text the docs leave out (…), after message_tokens()
HOLE = "<>"  # a value the docs leave open (<sha>, $VAR), after message_tokens()
GAPS = (GAP, HOLE)
GAP_SIZE = 80  # characters a HOLE stands for, at most; a GAP twice as many
WORD_START = r"(?<![\w./-])"
STRING_START = r"(?<=[\"'])"  # a part made elsewhere: bad="the last drill failed: $why"
problems = []
sys.stdout.reconfigure(encoding="utf-8")


def pair(path):
    if path.name.endswith(".uk.md"):
        return path.with_name(path.name[: -len(".uk.md")] + ".md"), path
    return path, path.with_name(path.stem + ".uk.md")


def without_code(text):
    """The text with every ``` block blanked, its lines kept, so line numbers stay."""
    return re.sub(r"```.*?```", lambda m: "\n" * m.group().count("\n"), text, flags=re.S)


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def slug(heading):
    text = re.sub(r"<[^>]+>", "", heading)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[^\w\- ]", "", text.strip().lower())
    return text.replace(" ", "-")


anchor_cache = {}


def anchors(path):
    if path not in anchor_cache:
        text = without_code(path.read_text(encoding="utf-8"))
        found, seen = set(HTML_ANCHOR.findall(text)), {}
        for _, heading in HEADING.findall(text):
            base = slug(heading)
            n = seen.get(base, 0)
            seen[base] = n + 1
            found.add(base if n == 0 else f"{base}-{n}")
        anchor_cache[path] = found
    return anchor_cache[path]


seen = set()
for path in BILINGUAL:
    en, uk = pair(path)
    if en in seen:
        continue
    seen.add(en)
    for p in (en, uk):
        if not p.exists():
            problems.append(f"{p.as_posix()}: missing (every bilingual file needs .md and .uk.md)")
    if not (en.exists() and uk.exists()):
        continue
    en_text, uk_text = en.read_text(encoding="utf-8"), uk.read_text(encoding="utf-8")
    en_ver, uk_ver = VERSION.findall(en_text), VERSION.findall(uk_text)
    if en_ver != uk_ver:
        problems.append(f"{uk.as_posix()}: version {uk_ver} differs from {en.as_posix()} {en_ver}")
    en_ids, uk_ids = RULE_ID.findall(en_text), RULE_ID.findall(uk_text)
    if en_ids != uk_ids:
        problems.append(f"{uk.as_posix()}: rule IDs {uk_ids} differ from {en.as_posix()} {en_ids}")

for md in sorted(ROOT.rglob("*.md")):
    if ".work" in md.parts or ".git" in md.parts:
        continue
    text = without_code(md.read_text(encoding="utf-8"))
    for link in LINK.finditer(text):
        target = link.group(1)
        if re.match(r"^[a-z]+:", target):
            continue
        file_part, _, fragment = target.partition("#")
        resolved = (md.parent / file_part).resolve() if file_part else md.resolve()
        if ".work" in resolved.parts:
            problems.append(f"{md.as_posix()}: links into .work/ ({target}), which is not in git")
            continue
        if not resolved.exists():
            if not ("templates" in md.parts and "project" in md.parts):
                problems.append(f"{md.as_posix()}: broken link {target}")
            continue
        if fragment and resolved.suffix == ".md" and resolved.is_file():
            if urllib.parse.unquote(fragment) not in anchors(resolved):
                where = f"{md.as_posix()}:{line_of(text, link.start())}"
                problems.append(f"{where}: broken anchor {target}")


def script_text(path):
    """A file of the template as one line: no comment lines, its strings joined, its variables
    VAR; ${x:-text} as its text, and then the whole file once more with it as a VAR; a .py file
    once with the first text of each {'a' if x else 'b'} and once with the second."""
    text = re.sub(r"(?m)^[ \t]*#.*\n", "", path.read_text(encoding="utf-8", errors="replace"))
    joined = "" if path.suffix == ".py" else " "  # "a" \ "b": two arguments, which die joins by " "
    text = re.sub(r"[\"']\s*\\?\n\s*[frbFRB]{0,2}[\"']", joined, text)
    text = text.replace("\\\n", " ").replace("'\\''", "'").replace('\\"', '"').replace("$$", "$")
    text = re.sub(r"\\[nt]", " ", text)  # printf '%s\n'
    texts = [text]
    if path.suffix == ".py":  # {'pushing to' if url else 'no push, empty'}: each branch once
        choice = r"""\{\s*(['"])([^'"{}\n]*)\1\s+if\s[^{}\n]*?\selse\s+(['"])([^'"{}\n]*)\3\s*\}"""
        texts = sorted({re.sub(choice, r"\2", text), re.sub(choice, r"\4", text)})
        texts = [re.sub(r"\{[^{}\n]*\}", VAR, t) for t in texts]
    variable = r"\$\((?:[^()]|\([^()]*\))*\)|\$[A-Za-z_]\w*|\$[0-9@*#?]|%[-0-9.]*[sdrif]"
    default = re.compile(r"\$\{\w+:?[-=]([^{}$]*)\}")  # ${2:-nothing was replaced}
    out = set()
    for text in texts:
        while (new := re.sub(variable, VAR, text)) != text:  # $(( $(date +%s) - s )): inside out
            text = new
        out |= {default.sub(r"\1", text), default.sub(VAR, text)}
    out = (re.sub(r"\$\{[^}]*\}", VAR, t) for t in sorted(out))
    return "\n".join(re.sub(r"[ \t\r\n]+", " ", t) for t in out)


def message_tokens(message):
    """The words of the message, a word with a value in it (<sha>, $VAR, <repo>-<image>,
    docker-compose.<env>.yml) as HOLE, an omission (…) as GAP, and a ':' at the end of a word as a
    token of its own; without punctuation at either end."""
    words = []
    for word in re.sub(r"(\S):(?=\s|$)", r"\1 :", re.sub(r"<[^<>]+>", "<x>", message)).split():
        if re.search(r"<x>|\$\{[^}]*\}|\$[A-Za-z_]\w*", word):
            words.append(HOLE)
        else:
            words += re.sub(r"…|\.\.\.", f" {GAP} ", word).split()
    tokens = ()
    for token in words:
        if token in GAPS and tokens and tokens[-1] in GAPS:  # <n> …: one GAP
            tokens = tokens[:-1] + (GAP,)
        else:
            tokens += (token,)
    while tokens and tokens[0] not in GAPS and not re.search(r"\w", tokens[0]):
        tokens = tokens[1:]
    while tokens and tokens[-1] not in GAPS and not re.search(r"\w", tokens[-1]):
        tokens = tokens[:-1]
    return tokens


@functools.lru_cache(maxsize=None)
def compiled(tokens, first, tag="v"):
    """A regex of tokens without a GAP, and their words. A word may be a VAR, or a word with a VAR
    in it, or nothing right after the VAR of the word before; the groups of a word: literal, with
    a VAR in it, a VAR."""
    out, words = [], []
    mark = rf"[^\w\s{VAR}]{{0,3}}"  # the punctuation around a variable: ($m):
    for token in tokens:
        word = re.fullmatch(r"(\W*)(\w(?:[\w./-]*\w)?)(\W*)", token)
        if token == VAR:
            out.append(f"{mark}{VAR}{mark}")
        elif not word:
            out.append(re.escape(token))
        else:
            words.append(word[2])
            literal = re.escape(word[1]) + f"({re.escape(word[2])})" + re.escape(word[3])
            part = rf"{mark}([\w./-]+{VAR}[\w./-]*|[\w./-]*{VAR}[\w./-]+){mark}"  # ${k}_USER
            # A variable may stand for two words of the docs (stopping $others: app db) when text
            # or the end of the string follows it at once: the word before is that variable.
            n = len(words)
            after_word = n > 1 and out[-1].startswith("(?:")
            more = f"|(?({tag}{n - 1})(?<={VAR})(?! )|(?!))" if after_word else ""
            out.append(f"(?:{literal}|{part}|(?P<{tag}{n}>{mark}{VAR}{mark}){more})")
    return re.compile(first + " ?".join(out)), words


def least_literal(words, strict):
    if strict:  # a part made elsewhere: two thirds, and all of up to three words
        return max((2 * len(words) + 2) // 3, min(len(words), 3))
    return len(words) if len(words) < 3 else max(2, (len(words) + 1) // 2)


def literal_words(groups, words):
    """How many words a match has literally: the word itself, or a word with a VAR in it whose
    letters start or end the word of the docs (${k}_USER for BACKUP_DB_USER)."""
    n = 0
    for word, whole, part in zip(words, groups[::3], groups[1::3]):
        if whole:
            n += 1
        elif part:
            before, after = part.split(VAR)[0], part.split(VAR)[-1]
            n += bool(re.search(r"\w", before + after)) and word.startswith(before) \
                and word.endswith(after)
    return n


def gap_ok(text, end, start, kind):
    """Text of one string of one file: for a HOLE up to GAP_SIZE characters, a variable (or a
    <placeholder>) and punctuation, no other words; for a GAP up to twice as many, any."""
    if kind == HOLE:
        gap = re.sub(r"<\w+>", VAR, text[end:start])
        if VAR not in gap or re.search(r"[^\W\d]", re.sub(rf"[^\s\"]*{VAR}[^\s\"]*", "", gap)):
            return False
    return 0 <= start - end <= (GAP_SIZE if kind == HOLE else 2 * GAP_SIZE) + 2 \
        and text.find('"', end, start) < 0 and text.find("\n", end, start) < 0


@functools.lru_cache(maxsize=None)
def found(tokens, strict=False):
    """Whether the tokens appear in order in one string of a file of SCRIPTS, a GAP standing for
    a short stretch of it; at least half of the words literal (two from three words on), and one
    of every stretch of two words or more. Strict: a part made elsewhere, which starts a string
    and has two thirds of its words literal."""
    text = script_all
    if not any(t in GAPS or t == VAR for t in tokens) and " ".join(tokens) in text:
        return True
    segments, kinds, current = [], [], []  # kinds: the GAP or HOLE before each segment
    for token in tokens + (GAP,):
        if token not in GAPS:
            current.append(token)
            continue
        if current:
            if segments:
                first = ""
            elif strict:
                # A placeholder at the start of a string: variables and punctuation, no words.
                first = STRING_START + (rf'[^\w"\n]*{VAR}[^\w"\n]*' if tokens[0] in GAPS else "")
            else:
                first = WORD_START
            segments.append(compiled(tuple(current), first))
            current = []
        kinds.append(token)
    kinds = kinds[1:] if tokens and tokens[0] in GAPS else kinds
    words = [w for _, ws in segments for w in ws]
    least = least_literal(words, strict)
    # At least `least` words are literal, so one of any len(words) - least + 1 of them is: look
    # only around the rarest of them.
    rare, covered = [], 0
    for w in sorted(set(words), key=lambda w: len(occurrences(w))):
        if covered > len(words) - least:
            break
        rare.append(w)
        covered += words.count(w)
    span = 2 * len(" ".join(tokens)) + 2 * GAP_SIZE * (sum(t in GAPS for t in tokens) + 1) + 100
    # Around the rarest word first, which a message printed as it is quoted has.
    for around in ([rare[:1], rare] if len(rare) > 1 else [rare]):
        windows = [] if words else [[0, len(text)]]
        for at in sorted(at for w in around for at in occurrences(w)):
            if windows and at - span <= windows[-1][1]:
                windows[-1][1] = at + span
            else:
                windows.append([max(0, at - span), at + span])
        if chained(text, segments, kinds, windows, least):
            return True
    return False


def overlapping(pattern, text, start, end):
    """Every match, one from each place: a match that starts earlier does not hide one inside it."""
    while (m := pattern.search(text, start, end)) is not None:
        yield m
        start = m.start() + 1


def chained(text, segments, kinds, windows, least):
    """Whether, in one of the windows, the segments follow each other with a GAP or HOLE between
    and at least `least` literal words."""
    for start, end in windows:
        ends, counts = [start], [0]  # where a chain of segments ends, and its literal words
        for i, (pattern, segment_words) in enumerate(segments):
            next_ends, next_counts = [], []
            for m in overlapping(pattern, text, start, end):
                literal = literal_words(m.groups(), segment_words)
                if len(segment_words) >= 2 and not literal:
                    continue
                if i == 0:
                    best = 0
                else:
                    kind = kinds[i - 1] if i - 1 < len(kinds) else GAP
                    lo = bisect.bisect_left(ends, m.start() - 2 * GAP_SIZE - 2)
                    hi = bisect.bisect_right(ends, m.start())
                    best = max((counts[k] for k in range(lo, hi)
                                if gap_ok(text, ends[k], m.start(), kind)), default=None)
                if best is not None:
                    next_ends.append(m.end())
                    next_counts.append(best + literal)
            ends, counts = next_ends, next_counts
            if not ends:
                break
        if any(n >= least for n in counts):
            return True
    return False


@functools.lru_cache(maxsize=None)
def occurrences(word):
    return [m.start() for m in re.finditer(re.escape(word), script_all)]


@functools.lru_cache(maxsize=None)
def next_to_var(token):
    """Whether a VAR can follow the token: a placeholder, or a word some script has before one."""
    word = re.fullmatch(r"\W*(\w(?:[\w./-]*\w)?)\W*", token)
    if token in GAPS or not word:
        return True
    return re.search(re.escape(word[1]) + rf"[^\w\s{VAR}]{{0,3}} ?[^\w\s{VAR}]{{0,3}}{VAR}",
                     script_all) is not None


def words_of(tokens):
    return sum(1 for t in tokens if t not in GAPS and t != VAR and re.search(r"\w", t))


def printed(tokens, strict=False, depth=0):
    """Whether a script prints the message: in order in one string; or with a part that a variable
    holds, printed on its own, two levels deep at most (say "unhealthy: $bad",
    bad="${bad:-$what … ago}", what="the newest $kind of $s was made"; die "… and $1: …" with $1
    from the caller; describe() { printf '%s on %s' …; } for <name> on <host>); or as a whole
    string of a script and a string with the rest (here='the backup folder (…)', then
    printf '%s %s' "$here" "$1")."""
    if words_of(tokens) < 2:  # a part made elsewhere: two words at least, or a whole '%s on %s'
        if strict and words_of(tokens) == 1 and tokens[0] == tokens[-1] == HOLE:
            whole = " ".join(rf"\S*{VAR}\S*" if t == HOLE else re.escape(t) for t in tokens)
            return any(re.fullmatch(whole, s) for s in script_strings_var)
        return not strict and (words_of(tokens) == 0 or found(tokens))  # log-archive: <file>
    if found(tokens, strict):
        return True
    n = len(tokens)
    for k in range(2, n - 1) if depth == 0 else ():
        if tokens[k - 1] in GAPS:
            continue
        segments = re.split(f" ?(?:{GAP}|{HOLE}) ?", " ".join(tokens[:k]))
        start = re.compile(" ?.{0,160}? ?".join(compiled(tuple(s.split()), "", f"s{q}_")[0].pattern
                                                 for q, s in enumerate(segments)))
        if words_of(tokens[:k]) < 2 or words_of(tokens[k:]) < 2:
            continue
        if any(start.fullmatch(s) for s in script_strings) and found(tokens[k:], True):
            return True
    if depth == 2:
        return False

    def at_edge(k):  # a placeholder or a ':' on that side of the part
        return 0 < k < n and (tokens[k] in GAPS or tokens[k - 1] == ":" or tokens[k] == ":")

    for i in sorted(range(n), key=lambda k: not at_edge(k)):  # the likely ones first
        if i and not (next_to_var(tokens[i - 1]) and found(tokens[:i] + (VAR,), strict)):
            continue
        for j in sorted(range(i + 1, n + 1), key=lambda k: not at_edge(k)):
            if (i, j) == (0, n) or not (at_edge(i) or at_edge(j)):
                continue
            outer, part = tokens[:i] + (VAR,) + tokens[j:], tokens[i:j]
            # Two words around the variable, or one with it after a ':' ("unhealthy: $bad"), or
            # at the start of a string ("$what … ago").
            after_colon = i == 0 or tokens[i - 1] == ":"
            if words_of(outer) < 2 and not (words_of(outer) == 1 and after_colon):
                continue
            if (j == n or found((VAR,) + tokens[j:], strict)) and found(outer, strict or i == 0) \
                    and printed(part, True, depth + 1):
                return True
    return False


def quoted_messages(text):
    """(position, message) of every message the doc quotes as output."""
    spans = []
    for m in re.finditer(OUTPUT_VERB, text):
        spans.append((m.start(1), m.group(1)))
        while m := re.compile(OUTPUT_NEXT).match(text, m.end()):
            spans.append((m.start(1), m.group(1)))
    for m in re.finditer(OUTPUT_PAREN, text):
        spans.append((m.start(1), m.group(1)))
    for m in re.finditer(r"`(([a-z][a-z0-9-]*(?: [a-z]+)?): [^`]+)`", text):
        if m.group(2) in MESSAGE_PREFIXES:
            spans.append((m.start(1), m.group(1)))
    for m in re.finditer(OUTPUT_LINE, text):
        group = 1 if m.group(1) else 2
        spans.append((m.start(group), m.group(group)))
    section = None
    for m in re.finditer(r"^(#{1,6}) .*$|^\|.*$", text, re.M):
        if m.group(1):
            if section is None or len(m.group(1)) <= section:
                section = len(m.group(1)) if "When something fails" in m.group() else None
            continue
        if section is not None:
            cell = re.split(r"(?<!\\)\|", m.group())[1]
            start = m.start() + 1
            spans += [(start + s.start(1), s.group(1)) for s in re.finditer(r"`([^`]+)`", cell)]
    for pos, span in dict(spans).items():
        span = span.replace("\\|", "|")  # a | in a table is written \|
        for message in re.findall(r'"([^"]*)"', span) if span.startswith('"') else [span]:
            command = message.startswith("make ") and not re.search(r"[:;]", message)
            if (len(message.split()) >= 3 or re.search(r"\w: \w", message)) and not command:
                yield pos, message


script_all = "\n".join(script_text(p) for p in SCRIPTS if p.exists())  # a GAP stops at a \n
script_strings = set()  # every whole string on one line of a script: here='the backup folder (…)'
for p in SCRIPTS:
    if p.exists():
        code = re.sub(r"(?m)^[ \t]*#.*\n", "", p.read_text(encoding="utf-8", errors="replace"))
        for single, double in re.findall(r"'([^'\n]*)'|\"([^\"\n]*)\"", code):
            script_strings.add(" ".join((single or double).split()))
script_strings_var = {re.sub(r"\$\{[^}]*\}|\$\(.*?\)|\$\w+|%[-0-9.]*[sdrif]|\{[^{}]*\}", VAR, s)
                      for s in script_strings}
# The prefixes of the messages: a word and ': ' that start a string of a script ("prune: …").
MESSAGE_PREFIXES = {m[1] for s in script_strings
                    if (m := re.match(r"([a-z][a-z0-9-]*(?: [a-z]+)?): \S", s))}
for doc in QUOTING_DOCS:
    if not doc.exists():
        continue
    text = without_code(doc.read_text(encoding="utf-8"))
    for pos, message in quoted_messages(text):
        if any(re.fullmatch(f, message) for f in FOREIGN):
            continue
        if not printed(message_tokens(message)):
            problems.append(f"{doc.as_posix()}:{line_of(text, pos)}: quoted message is in no "
                            f"script of the template: `{message}`")


def passages(path):
    """(line, sentence) of every sentence of the prose, by paragraph."""
    lines = without_code(path.read_text(encoding="utf-8")).split("\n")
    paragraphs, current = [], []
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        starts_item = re.match(r"^\s*(?:[-*+]|\d+\.)\s", line)
        if not stripped or stripped.startswith(("#", "|", "<")) or starts_item:
            if current:
                paragraphs.append(current)
            current = []
            if not stripped or not starts_item:
                continue
            stripped = re.sub(r"^(?:[-*+]|\d+\.)\s+", "", stripped)
        current.append((n, re.sub(r"^>\s?", "", stripped)))
    if current:
        paragraphs.append(current)
    for paragraph in paragraphs:
        text, starts = "", []
        for n, part in paragraph:
            starts.append((len(text), n))
            text += part + " "
        text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # the targets differ by folder
        sentences = []
        for m in re.finditer(r".+?(?:[.!?](?=\s|$)|$)", text):
            if m.group().strip():
                line = max((n for off, n in starts if off <= m.start()), default=paragraph[0][0])
                sentences.append((line, " ".join(m.group().split())))
        yield sentences


repeats = {}
for path in sorted(set(REPEAT_FILES)):
    if not path.exists():
        continue
    language = "uk" if path.name.endswith(".uk.md") else "en"
    for paragraph, sentences in enumerate(passages(path)):
        whole = [s[-1:] in ".!?" and not re.search(r"https?://", s) for _, s in sentences]
        for i, (line, first) in enumerate(sentences):
            if not whole[i]:
                continue
            more = i + 1 < len(sentences) and whole[i + 1]
            two = [f"{first} {sentences[i + 1][1]}"] if more else []
            for passage in [first] + two:
                if len(passage) >= 200:
                    place = (path.as_posix(), line, paragraph)
                    repeats.setdefault((language, passage), []).append(place)
reported = set()
for (_, passage), places in repeats.items():
    files = sorted({f: (n, p) for f, n, p in reversed(places)}.items())
    if len(files) < 2 or any(passage.startswith(r) for r in REPEATS):
        continue
    (first, (line, paragraph)), others = files[0], files[1:]
    key = (tuple(f for f, _ in files), paragraph)
    if key in reported:
        continue  # the next sentences of a passage already reported
    reported.add(key)
    where = ", ".join(f"{f}:{n}" for f, (n, _) in others)
    problems.append(f"{first}:{line}: the same passage as {where} (one place, and a link from "
                    f"the other): \"{passage[:90]}…\"")

for line in problems:
    print(f"check-docs: {line}")
print(f"check-docs: {'FAIL' if problems else 'OK'} ({len(problems)} problems)")
sys.exit(1 if problems else 0)
