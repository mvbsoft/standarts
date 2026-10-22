# agent-hooks template 1.1.0 — from the standard's templates/agent-hooks; change it there, not here.
# Prints the string at the dotted object path `want` (awk -v want=tool_input.command) of the JSON
# document on stdin, with its escapes decoded; prints nothing when the path is absent or holds no
# string. The hooks use it because the host has no JSON tool (standard PRN-01). Run it with
# LC_ALL=C, so that strings are bytes and \u escapes become UTF-8.
#
# Usage:   LC_ALL=C awk -v want=<path> -f json-get.awk < <JSON document>. A key of an object adds
#          .<key> to the path, an element of an array [] (tool_input.command, a[].b).
# Output:  that string, without a newline, or nothing.
# Exit:    0, also when the path is absent; 1 when it finds the document malformed.
# Globals: doc the document, n its length, p the position being read, chr[0..255] the character of
#          each byte, want the path asked for.
{ doc = doc $0 "\n" }
END {
  n = length(doc); p = 1
  for (i = 0; i < 256; i++) chr[i] = sprintf("%c", i)
  value("")
}
# ws(): move p past white space.
function ws() { while (p <= n && index(" \t\r\n", substr(doc, p, 1))) p++ }
# value(path): read the value at p, whose path is path; print it and exit 0 when it is the string
# at want. Moves p; exit 1 when the document is malformed there.
function value(path,    c, key) {
  ws(); c = substr(doc, p, 1)
  if (c == "{") {
    p++; ws()
    if (substr(doc, p, 1) == "}") { p++; return }
    while (p <= n) {
      ws(); key = str(); ws()
      if (substr(doc, p, 1) != ":") exit 1
      p++
      value(path == "" ? key : path "." key)
      ws(); c = substr(doc, p++, 1)
      if (c == "}") return
      if (c != ",") exit 1
    }
  } else if (c == "[") {
    p++; ws()
    if (substr(doc, p, 1) == "]") { p++; return }
    while (p <= n) {
      value(path "[]")
      ws(); c = substr(doc, p++, 1)
      if (c == "]") return
      if (c != ",") exit 1
    }
  } else if (c == "\"") {
    c = str()
    if (path == want) { printf "%s", c; exit 0 }
  } else {
    while (p <= n && index("-+.0123456789eEtruefalsn", substr(doc, p, 1))) p++
  }
}
# str(): read the string at p and return it with its escapes decoded. Moves p; exit 1 when p is
# not at a string or the string does not end.
function str(    out, c, e, u, v) {
  if (substr(doc, p, 1) != "\"") exit 1
  p++; out = ""
  while (p <= n) {
    c = substr(doc, p++, 1)
    if (c == "\"") return out
    if (c != "\\") { out = out c; continue }
    e = substr(doc, p++, 1)
    if (e == "n") out = out "\n"
    else if (e == "t") out = out "\t"
    else if (e == "r") out = out "\r"
    else if (e == "b") out = out "\b"
    else if (e == "f") out = out "\f"
    else if (e == "u") {
      u = hex(substr(doc, p, 4)); p += 4
      if (u >= 55296 && u <= 56319 && substr(doc, p, 2) == "\\u") {
        v = hex(substr(doc, p + 2, 4))
        if (v >= 56320 && v <= 57343) { u = 65536 + (u - 55296) * 1024 + (v - 56320); p += 6 }
      }
      out = out utf8(u)
    } else out = out e
  }
  exit 1
}
# hex(s): the number that the first four hex digits of s write.
function hex(s,    i, v) {
  v = 0
  for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
  return v
}
# utf8(u): the UTF-8 bytes of the code point u (from chr).
function utf8(u) {
  if (u < 128) return chr[u]
  if (u < 2048) return chr[192 + int(u / 64)] chr[128 + u % 64]
  if (u < 65536) return chr[224 + int(u / 4096)] chr[128 + int(u / 64) % 64] chr[128 + u % 64]
  return chr[240 + int(u / 262144)] chr[128 + int(u / 4096) % 64] chr[128 + int(u / 64) % 64] chr[128 + u % 64]
}
