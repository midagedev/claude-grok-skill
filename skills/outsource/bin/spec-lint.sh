#!/usr/bin/env bash
# Lint a delegation spec for mechanically wrong premises before launch:
# file/path references that do not resolve from --root, and `path:line`
# citations beyond the end of the file they point at.
#
# Why this exists (measured 2026-08-15/16): five wrong premises in one
# session's specs — a nonexistent tool name, a nonexistent column, an absent
# fixture label, a wrong runner cwd, a wrong manifest path. The delegate
# caught each one mid-round, but each cost part of a round. This runs on the
# lead's side, before launch, on the class that is checkable without a
# model: paths and line citations.
#
#   spec-lint.sh [--root <dir>] [--quiet] <spec.md> [<spec.md>...]
#
#   --root    base for resolving relative references (default: cwd)
#   --quiet   drop the per-file "ok" lines; findings are always printed
#
# Checked: `path:line` / `path:line-line` citations (first number checked)
# and bare tokens that contain "/" and end in a known file extension.
# Absolute paths are checked as-is; a relative one must resolve under at
# least one plausible base — --root, --root's git toplevel, or the spec
# file's own directory — because a path that exists somewhere sane is not
# a wrong premise, only a differently-rooted one.
#
# A bare filename with no directory part (CLAUDE.md, spec.md, install.sh)
# is checked ONLY when it carries a :line citation. Measured 2026-08-16:
# checking bare names produced ~30 findings across this repo's own docs
# with zero real defects — every one was prose naming a file as a concept
# ("copy the relevant CLAUDE.md clauses"), not claiming a path. A linter
# at that precision gets ignored, which costs more than the class it
# catches. A :line suffix is an explicit claim about a specific file, so
# bare names carrying one are still checked.
#
# Never checked (templates are not claims): URLs and www.* domains, bare
# domains (no known extension), tokens containing "<" or ">" or $VAR/${VAR},
# globs with * or ?, "..."-abbreviated paths, and anything inside a
# <...> span. References are checked everywhere in the file, fences
# included — only the placeholder/glob/URL skip rules apply inside them.
#
# Exit: 0 clean · 1 findings · 2 usage error or unreadable spec.
set -euo pipefail

SELF="${0##*/}"
usage() { echo "usage: $SELF [--root <dir>] [--quiet] <spec.md> [<spec.md>...]" >&2; }

ROOT="$PWD" QUIET=0
SPECS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "$SELF: --root needs a value" >&2; usage; exit 2; }
      ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) echo "usage: $SELF [--root <dir>] [--quiet] <spec.md> [<spec.md>...]"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do SPECS+=("$1"); shift; done ;;
    -*) echo "$SELF: unknown flag: $1" >&2; usage; exit 2 ;;
    *) SPECS+=("$1"); shift ;;
  esac
done

[ "${#SPECS[@]}" -gt 0 ] || { usage; exit 2; }
[ -d "$ROOT" ] || { echo "$SELF: --root is not a directory: $ROOT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "$SELF: python3 is required but not on PATH" >&2; exit 2; }

# An unreadable spec is a usage-class error: check them all before linting
# any, so a typo'd path cannot hide findings from an earlier file.
for s in "${SPECS[@]}"; do
  [ -f "$s" ] || { echo "$SELF: spec is not a readable file: $s" >&2; exit 2; }
done

rc=0
python3 - "$ROOT" "$QUIET" ${SPECS[@]+"${SPECS[@]}"} <<'PY' || rc=$?
import os
import re
import sys

root, quiet = sys.argv[1], sys.argv[2] == "1"
specs = sys.argv[3:]

# Extensions a dotted token must end in to count as a file reference.
# Dotted non-paths (domains like example.com, versions like v0.14.1 and
# glm-5.3, abbreviations like "e.g.") fail this test and are skipped.
# No equivalent table existed in this repo before this file (searched
# skills/, scripts/, install.sh — only install.sh's copy/manifest diffs).
EXTS = frozenset("""
md markdown rst txt text log lock
sh bash zsh fish
py rb pl pm lua rake
go rs swift m mm c cc cpp cxx h hh hpp java kt scala cs
js jsx ts tsx mjs cjs json jsonc yaml yml toml xml html htm css scss sass less
svelte vue astro elm sql graphql gql proto
png jpg jpeg gif bmp svg webp ico mp3 mp4 mov wav csv tsv
diff patch env ini cfg conf properties plist
""".split())

# `path.md:12` or `path.md:12-34` — the range's first number is the claim.
CITE = re.compile(r"^([^:]+):(\d+)(?:-\d+)?$")
DOLLAR = re.compile(r"\$\{?[A-Za-z_][A-Za-z0-9_]*")
# Punctuation that may hug a token in prose, code fences, or markdown.
EDGE = "`\"'()[]{}<>,;:.!?*|\\…—–«»“”‘’"
# A <...> span is template text: everything inside it is a placeholder,
# even when the brackets sit on other whitespace tokens ("<e.g. root
# CLAUDE.md sections ...>") or wrap several lines, as the spans in
# references/spec-template.md do. The length cap keeps a stray "<<"
# heredoc from opening a span that swallows the rest of the document.
SPAN = re.compile(r"<[^<>]{0,300}>")


def is_template(tok):
    if "://" in tok or tok.startswith("www."):
        return True  # URL, scheme-full or www-prefixed
    if "<" in tok or ">" in tok:
        return True  # <scratch>/task.md, DONE-<track>, ...
    if "*" in tok or "?" in tok:
        return True  # .claude/agents/*.md, libs/**
    if "..." in tok:
        return True  # /private/tmp/.../os/task-speclint.md (prose ellipsis)
    if DOLLAR.search(tok):
        return True  # $VAR/x.md, ${VAR}/x.md
    return False


def has_ext(path):
    seg = path.rsplit("/", 1)[-1]
    base, _, ext = seg.rpartition(".")
    return bool(base) and ext.lower() in EXTS


SPLIT = re.compile(r"(\]\(|`)")


def tokens(line):
    # Whitespace tokens with their offsets, split further at "](" and at
    # backticks so a markdown link yields both label and target, and prose
    # hugging inline code ("레시피(`references/grok.md`") yields the code
    # span on its own. Offsets stay exact because each separator is
    # accounted for by length.
    out = []
    for m in re.finditer(r"\S+", line):
        pos = m.start()
        # SPLIT captures its separator, so the pieces alternate
        # text, sep, text, ... and every character is accounted for.
        for i, p in enumerate(SPLIT.split(m.group(0))):
            if i % 2 == 0:
                out.append((pos, p))
            pos += len(p)
    return out


def toplevel(start):
    # Nearest ancestor holding .git — a reference written repo-relative in a
    # spec whose --root is a subdirectory still resolves there.
    d = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def resolve(path, bases):
    # Absolute/~ paths are the claim itself. A relative one is a wrong
    # premise only when it resolves under none of the plausible bases;
    # the first base is what the failure message names.
    if path.startswith("~"):
        p = os.path.expanduser(path)
        return p, os.path.exists(p)
    if path.startswith("/"):
        p = path
        if os.path.exists(p):
            return p, True
        # A leading "/" that does not exist on disk is usually a markdown
        # root-relative link ("[English](/README.md)"), which GitHub
        # resolves against the repo root — retry it that way before
        # calling it a wrong premise.
        for b in bases:
            q = os.path.join(b, path.lstrip("/"))
            if os.path.exists(q):
                return q, True
        return p, False
    first = None
    for b in bases:
        p = os.path.join(b, path)
        if first is None:
            first = p
        if os.path.exists(p):
            return p, True
    return first, False


def line_count(path):
    # Iterating in binary counts "a\nb" as 2 lines (editor view), unlike
    # wc -l, which would say 1 — and is immune to non-UTF-8 bytes.
    with open(path, "rb") as f:
        return sum(1 for _ in f)


findings = 0
for spec in specs:
    spec_findings = 0
    seen = set()
    bases = [root]
    for extra in (toplevel(root), os.path.dirname(os.path.abspath(spec))):
        if extra and extra not in bases:
            bases.append(extra)
    with open(spec, "r", errors="replace") as f:
        lines = f.readlines()
    # Spans are matched over the whole file (they may wrap lines); tokens
    # below carry file-level offsets to match.
    sp = [(m.start(), m.end()) for m in SPAN.finditer("".join(lines))]
    off = 0
    for lineno, line in enumerate(lines, 1):
        base, off = off, off + len(line)
        for pos, raw in tokens(line):
            if is_template(raw):
                continue
            tok = raw.strip(EDGE)
            if not tok or is_template(tok):
                continue
            if any(a <= base + pos < b for a, b in sp):
                continue  # inside a <...> template span
            m = CITE.match(tok)
            if m and ("/" in m.group(1) or has_ext(m.group(1))):
                # A :line citation is an explicit claim, bare name or not.
                path, n = m.group(1), int(m.group(2))
            elif "/" in tok and has_ext(tok):
                path, n = tok, None
            else:
                # Bare filename, no citation — prose naming a file, not a
                # path claim. See the header note on precision.
                continue
            key = (lineno, tok)
            if key in seen:
                continue
            seen.add(key)
            resolved, exists = resolve(path, bases)
            if not exists:
                print(f"{spec}:{lineno}: missing: {tok} (resolved: {resolved})")
                spec_findings += 1
            elif n is not None and not os.path.isdir(resolved):
                total = line_count(resolved)
                if n < 1 or n > total:
                    print(f"{spec}:{lineno}: line-out-of-range: {tok} "
                          f"(file has {total} lines)")
                    spec_findings += 1
    if spec_findings == 0 and not quiet:
        print(f"{spec}: ok")
    findings += spec_findings

sys.exit(1 if findings else 0)
PY
exit $rc
