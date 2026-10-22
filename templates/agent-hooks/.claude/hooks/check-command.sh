#!/bin/sh
# agent-hooks template 1.1.0 — from the standard's templates/agent-hooks; change it there, not here.
# The check of a shell command an agent is about to run (standard AI-06, D-0008), the same for any
# agent. It blocks a command that would run a language tool on the host (python, pip, uv, node,
# npm, npx, pnpm, composer, php and the like, or anything under node_modules/.bin, vendor/bin or a
# virtualenv's bin) and names what to run instead. Everything else passes: git, docker, make, sh
# and read-only shell commands (standard PRN-01), and any command run through docker compose.
#
# Usage:   sh .claude/hooks/check-command.sh '<command>'
#          printf '%s' '<command>' | sh .claude/hooks/check-command.sh -
#            (a long command, on stdin)
#          An agent's adapter takes the command from what the agent sends and runs this:
#          pre-bash.sh for Claude Code.
# Reads:   checks.conf next to it: the project adds tools with `block` lines and lets its
#          registered host exceptions (registry section E) through with `allow` lines.
# Output:  nothing; for a blocked command the reason and what to run instead, on stderr.
# Exit:    2 blocked; 0 not blocked (without a command nothing is).
# Shell:   POSIX sh and awk.
#
# It reads each command of a pipeline, a list, `$( )`, backticks, `sh -c '…'` and a here-document
# a shell reads, after leading VAR=value words and wrappers such as env, sudo, time, timeout, nohup
# and xargs with their options (sudo -u bob, timeout -s KILL 5). The body of any other
# here-document is text (a commit message), and `command -v` / `command -V` only look a name up.
# It does not read scripts, aliases, functions or eval: it guards against habit, not against a
# deliberate bypass.
set -u
here=$(cd "$(dirname "$0")" && pwd)
conf=$here/checks.conf

if [ "${1-}" = - ]; then cmd=$(cat); else cmd=${1-}; fi
[ -n "$cmd" ] || exit 0

block='' allow=''
if [ -f "$conf" ]; then
  block=$(sed -n 's/^block[[:space:]]\{1,\}//p' "$conf" | tr '\n' ' ')
  allow=$(sed -n 's/^allow[[:space:]]\{1,\}//p' "$conf" | tr '\n' ' ')
fi

# Prints "<tool>\t<the command that runs it>" for the first host language tool found, else nothing.
found=$(printf '%s' "$cmd" | LC_ALL=C awk -v block="$block" -v allow="$allow" '
# The program: BEGIN builds the tables (tool, wrapper, optarg, keyword, shell), the main rule reads
# the command into text, and END scans it and every text queued on the way (queue[1..nq]: the -c
# of a shell, a here-document a shell reads, a $(( )) with a command in it). The other globals:
# w[1..nw] the words of one simple command; word, raw and inword the word being read; bq, bqdq and
# savedq the quoting around backticks and $( ); hd, hdstrip, nhd, wanthd and hdshell the
# here-documents of the line.
BEGIN {
  split("python python2 python3 pip pip2 pip3 uv uvx pipx poetry pdm hatch pytest ruff mypy pyright " \
    "black isort flake8 pylint node nodejs npm npx pnpm pnpx yarn bun bunx deno tsc tsx ts-node " \
    "eslint prettier vitest jest php composer phpunit phpstan psalm php-cs-fixer rector " \
    "ruby gem bundle rake go cargo rustc java javac mvn gradle dotnet " block, t, " ")
  for (i in t) tool[t[i]] = 1
  split(allow, t, " ")
  for (i in t) delete tool[t[i]]
  split("env sudo command exec builtin nohup time nice timeout xargs stdbuf", t, " ")
  for (i in t) wrapper[t[i]] = 1
  # The options of a wrapper whose value is the next word (sudo -u bob, timeout -s KILL).
  optarg["sudo"] = "^-([A-Za-z]*[ugCDhprtTU]|-(user|group|chdir|close-from|host|prompt|role|type|command-timeout|other-user))$"
  optarg["timeout"] = "^-([A-Za-z]*[sk]|-(signal|kill-after))$"
  optarg["env"] = "^-([A-Za-z]*[uC]|-(unset|chdir))$"
  optarg["xargs"] = "^-([A-Za-z]*[aEdILnPs]|-(arg-file|delimiter|max-args|max-lines|max-procs|max-chars|process-slot-var))$"
  optarg["nice"] = "^-(n|-adjustment)$"
  optarg["stdbuf"] = "^-([ioe]|-(input|output|error))$"
  split("if then else elif fi do done while until for case esac ! { } in", t, " ")
  for (i in t) keyword[t[i]] = 1
  split("sh bash dash zsh ash ksh", t, " ")
  for (i in t) shell[t[i]] = 1
}
{ text = text (NR > 1 ? "\n" : "") $0 }
END {
  queue[1] = text; nq = 1
  for (q = 1; q <= nq; q++) scan(queue[q])
}
# scan(s): split s into simple commands, word by word, with sh quoting, and check each one. The
# body of a here-document is text, not commands (unless a shell reads it), and is skipped. raw
# follows word with each quoted or escaped character replaced by q, so a quoted << is not taken
# for an operator.
function scan(s,    n, i, c, sq, dq, depth, mode, start, j, pd, ar, r) {
  n = length(s); nw = 0; word = ""; raw = ""; inword = 0; sq = 0; dq = 0; bq = 0; depth = 0; start = 1
  nhd = 0; wanthd = 0; hdshell = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (sq) { if (c == "\047") sq = 0; else { word = word c; raw = raw "q" }; continue }
    if (c == "\\" && i < n) { i++; if (substr(s, i, 1) != "\n") { word = word substr(s, i, 1); raw = raw "q"; inword = 1 }; continue }
    if (dq && c == "\"") { dq = 0; continue }
    if (!dq && c == "\047") { sq = 1; inword = 1; continue }
    if (!dq && c == "\"") { dq = 1; inword = 1; continue }
    # $(( … )) is arithmetic: part of the word up to its matching )), so its << is a shift. A $( or
    # a backtick inside it is read as commands.
    if (c == "$" && substr(s, i + 1, 2) == "((") {
      pd = 0
      for (j = i + 1; j < n; j++) { r = substr(s, j, 1); if (r == "(") pd++; else if (r == ")" && --pd == 0) break }
      ar = substr(s, i, j - i + 1); r = ar; gsub(/./, "q", r)
      word = word ar; raw = raw r; inword = 1; i = j
      if (ar ~ /\$\(|`/) queue[++nq] = substr(ar, 2)
      continue
    }
    # $( and backticks start a command of their own, also inside double quotes.
    if (c == "$" && substr(s, i + 1, 1) == "(") {
      push(); check(s, start, i - 1); i++; start = i + 1; depth++; savedq[depth] = dq; dq = 0; continue
    }
    if (c == "`") {
      push(); check(s, start, i - 1); start = i + 1
      if (bq) { bq = 0; dq = bqdq } else { bq = 1; bqdq = dq; dq = 0 }
      continue
    }
    if (dq) { word = word c; raw = raw "q"; inword = 1; continue }
    if (c == ")" && depth > 0) {
      push(); check(s, start, i - 1); start = i + 1; dq = savedq[depth]; depth--; continue
    }
    if (index(";&|()\n", c)) {
      push(); check(s, start, i - 1); start = i + 1
      if (c == "\n" && nhd) { i = body(s, i + 1) - 1; start = i + 1 }
      continue
    }
    if (c == " " || c == "\t") { push(); continue }
    word = word c; raw = raw c; inword = 1
  }
  push()
  check(s, start, n)
}
# push(): end the word being read and add it to w; note the delimiter of a here-document (<<EOF,
# <<"EOF", <<-EOF) in hd and hdstrip (wanthd: the next word is one). Only a << that was neither
# quoted nor escaped is the operator (echo "<<EOF" prints text).
function push() {
  if (!inword) return
  if (wanthd) { hd[++nhd] = word; hdstrip[nhd] = wanthd == 2; wanthd = 0 }
  else if (raw ~ /^[0-9]*<<-?$/) wanthd = raw ~ /-$/ ? 2 : 1
  else if (match(raw, /^[0-9]*<<-?[^<]/)) {
    hdstrip[++nhd] = substr(raw, RLENGTH - 1, 1) == "-"; hd[nhd] = substr(word, RLENGTH)
  }
  w[++nw] = word; word = ""; raw = ""; inword = 0
}
# body(s, p): skip the bodies of the here-documents noted on the line that ended before position
# p; return the position after them. The body of one a shell reads (hdshell) is queued as
# commands.
function body(s, p,    h, e, line, l, text) {
  for (h = 1; h <= nhd; h++) {
    text = ""
    while (p <= length(s)) {
      e = index(substr(s, p), "\n")
      line = e ? substr(s, p, e - 1) : substr(s, p)
      p = e ? p + e : length(s) + 1
      l = line; if (hdstrip[h]) sub(/^\t+/, "", l)
      if (l == hd[h]) break
      text = text line "\n"
    }
    if (hdshell) queue[++nq] = text
  }
  nhd = 0; hdshell = 0
  return p
}
# check(s, a, b): look at the simple command in w[1..nw] (its text is s from a to b), then empty
# w. A host tool: print "<tool><tab><its command>" and exit, which ends the program. A shell:
# queue the text after -c, or mark its here-document as commands (hdshell).
function check(s, a, b,    k, x, base, m) {
  k = 1
  while (k <= nw) {
    x = w[k]
    if (x ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || keyword[x]) { k++; continue }
    if (x ~ /^[0-9]*[<>]/) { k += (x ~ /^[0-9]*[<>]+&?$/) ? 2 : 1; continue }
    if (wrapper[x]) {
      m = x; k++
      # command -v and command -V only say what a name is.
      if (m == "command" && k <= nw && w[k] ~ /^-[A-Za-z]*[vV]/) { nw = 0; return }
      while (k <= nw) {
        if ((m in optarg) && w[k] ~ optarg[m]) { k += 2; continue }
        if (w[k] ~ /^-/ || w[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || (m == "timeout" && w[k] ~ /^[0-9.]+[smhd]?$/)) { k++; continue }
        break
      }
      continue
    }
    break
  }
  if (k <= nw) {
    x = w[k]; base = x; sub(/.*\//, "", base)
    if (shell[base]) {
      for (m = k + 1; m < nw; m++) if (w[m] ~ /^-[a-z]*c[a-z]*$/) { queue[++nq] = w[m + 1]; break }
      if (m >= nw && nhd) hdshell = 1  # sh <<EOF: the body is commands of that shell
    } else if (tool[base] || base ~ /^(python|pip|php|node)[0-9.]+$/ || \
        x ~ /(^|\/)(node_modules\/\.bin|vendor\/bin|\.?venv\/bin)\//) {
      seg = substr(s, a, b - a + 1)
      gsub(/^[ \t\n]+|[ \t\n]+$/, "", seg)
      gsub(/[\t\n]+/, " ", seg)
      printf "%s\t%s\n", base, seg
      exit 0
    }
  }
  nw = 0
}
')

[ -n "$found" ] || exit 0
tool=$(printf '%s' "$found" | cut -f1)
what=$(printf '%s' "$found" | cut -f2-)
cat >&2 <<EOF
blocked: \`$what\` would run $tool on the host. Language tools run in the dev container (standard PRN-01, AI-06).
Use a make target instead (make help lists them; make gates runs the checks, make dev starts the stack),
or run the command in the dev container:
  docker compose -f docker-compose.dev.yml exec -T dev $what
EOF
exit 2
