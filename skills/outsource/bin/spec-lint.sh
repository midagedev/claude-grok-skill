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
# Paths the spec marks as ones to create — under a `Create:` / `New files:`
# heading or list, or after `Create: <path>` inline — are not premises about
# the tree, and are exempt from the missing check. They get the opposite one
# instead: a to-be-created path that already exists is reported, because the
# spec and the tree then disagree about what the round is for. The count of
# exemptions is printed on the ok line, so the suppression stays visible.
#
# Known limit, and not a bug to fix: a path inside a command that sets its own
# root (`npx vitest run --root web src/lib/x.test.ts`, `make -C dir`) is
# resolved from --root and the spec's directory, not from that command's base,
# so it can report missing for a file that exists. Teaching the linter every
# tool's cwd flag would cost more precision than it buys; write such paths
# repo-relative in the spec instead.
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
# An HTML comment is a note to the lead about the skill's own layout — how to
# assemble the spec, which file owns which rule — not a citation the delegate
# will act on. Linting it meant every assembled spec reported the preamble's
# own `references/…` paths as missing from the *target* repo, which is one
# guaranteed finding per round: the fastest way to teach someone to stop
# reading a linter. Real citations live in the spec body, which is still
# checked. (Kept as its own pattern rather than folded into SPAN: SPAN caps
# its length to survive a stray "<<", and a comment block is legitimately long.)
COMMENT = re.compile(r"<!--.*?-->", re.S)

# A spec that has the delegate create files names those files, and they do
# not exist yet — that is the point. Linting them as missing premises meant
# every creating spec (most of them) opened with guaranteed findings, which
# is the precision problem this file's header keeps warning about, arriving
# from the other direction.
#
# So a path the spec marks as to-be-created is exempt from the missing check
# — and gains a different one. If it already exists, the spec and the tree
# disagree about what this round is: the lead is about to send someone to
# create a file that is already there, and either the path is stale or the
# work is done. That is a real finding, and it is only visible here.
CREATE_OPEN = re.compile(
    r"^\s*(?:[-*+]\s+)?(?:#+\s*)?(?:\*\*)?"
    r"(?:create|creates?d?|new files?|files? to create|to create|add files?)"
    r"(?:\*\*)?\s*:\s*$", re.I)
CREATE_INLINE = re.compile(
    r"^\s*(?:[-*+]\s+)?(?:#+\s*)?(?:\*\*)?"
    r"(?:create|new files?|files? to create|to create|add files?)"
    r"(?:\*\*)?\s*:\s+\S", re.I)
# Inside a creation block: a list item, or a wrapped continuation of one.
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\S")
CONTINUATION = re.compile(r"^\s{2,}\S")


def creation_lines(lines):
    """Line numbers (1-based) whose path references are to-be-created."""
    marked, in_block = set(), False
    for i, line in enumerate(lines, 1):
        if CREATE_INLINE.match(line):
            marked.add(i)
            in_block = False
            continue
        if CREATE_OPEN.match(line):
            in_block = True
            continue
        if not in_block:
            continue
        if not line.strip():
            continue  # a blank line inside a list does not end it
        if LIST_ITEM.match(line) or CONTINUATION.match(line):
            marked.add(i)
        else:
            in_block = False
    return marked


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
    exempt_count = 0
    seen = set()
    bases = [root]
    for extra in (toplevel(root), os.path.dirname(os.path.abspath(spec))):
        if extra and extra not in bases:
            bases.append(extra)
    with open(spec, "r", errors="replace") as f:
        lines = f.readlines()
    # Spans are matched over the whole file (they may wrap lines); tokens
    # below carry file-level offsets to match.
    whole = "".join(lines)
    to_create = creation_lines(lines)
    sp = [(m.start(), m.end()) for m in SPAN.finditer(whole)]
    sp += [(m.start(), m.end()) for m in COMMENT.finditer(whole)]

    def walk():
        """(lineno, tok, path, n) for every reference in the spec, in order."""
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
                    yield lineno, tok, m.group(1), int(m.group(2))
                elif "/" in tok and has_ext(tok):
                    yield lineno, tok, tok, None
                # Otherwise: a bare filename with no citation — prose naming a
                # file, not a path claim. See the header note on precision.

    # Pre-pass, so the exemption is by path and not by position. A spec is free
    # to name a file it is creating before it declares the creation — in an
    # intro paragraph, in a heading — and reporting those was the same
    # cry-wolf defect one line higher up.
    created_paths = set()
    for lineno, _tok, path, _n in walk():
        if lineno in to_create:
            created_paths.add(resolve(path, bases)[0])

    for lineno, tok, path, n in walk():
        key = (lineno, tok)
        if key in seen:
            continue
        seen.add(key)
        resolved, exists = resolve(path, bases)
        if resolved in created_paths:
            # A file the spec is creating, at its declaration or anywhere else
            # it is named — the completion criteria, a test section, prose.
            # Declaring it once is the claim; every later mention is the same
            # claim, and reporting those was this exemption's own bug, one
            # line further down the page.
            exempt_count += 1
            if exists and lineno in to_create:
                print(f"{spec}:{lineno}: already-exists: {tok} "
                      f"(spec says create it; resolved: {resolved})")
                spec_findings += 1
            continue
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
        # The exemption count is printed rather than kept quiet: a
        # suppression nobody can see is how a linter starts lying.
        note = f" ({exempt_count} to-be-created exempt)" if exempt_count else ""
        print(f"{spec}: ok{note}")
    findings += spec_findings

sys.exit(1 if findings else 0)
PY
exit $rc
