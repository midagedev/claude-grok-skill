---
name: grok-delegate
description: >
  Delegate implementation AND vision-verdict work to the local grok CLI as a
  cheap headless sub-agent while the lead Claude session stays
  orchestration-only. Use when the user asks to run work "via grok", to save
  tokens, or invokes /grok-delegate. grok reads images, so screenshot
  verdicts can be delegated too; escalate to a Claude agent only when a grok
  verdict contradicts instrumented measurements.
---

# grok-delegate — using the grok CLI as an implementation sub-agent

Division of labor:

| Role | Owner | Why |
|------|-------|-----|
| Orchestration, spec writing, diff review, gates, commits | Lead session (Claude) | spend expensive tokens only where judgment matters |
| Code implementation, mechanical edits, numeric harnesses — **including look/UI work** | `grok` CLI (headless) | implementation tokens are effectively free on a grok subscription |
| Screenshot / visual verdicts | `grok` CLI | passed a vision-judgment benchmark against instrumented ground truth; fall back to a Claude agent if a verdict ever contradicts measurements |

Core principle: **grok is an executor of tight specs.** It has zero
conversation context, so the spec must be self-contained (file paths,
contracts, completion criteria), and must never ask for taste judgments —
only numeric contracts.

## Invocation recipe

### One-shot task (default form)

Write the spec to a scratch file and pass it with `--prompt-file`. Run long
tasks in the background and wait for the completion notification.

```bash
# 1) Write the task spec, then prepend the shared preamble.
cat <skill-dir>/references/spec-preamble.md \
    <scratch>/task.md > <scratch>/spec.md

# 2) Run in the background; collect the log when it finishes.
SID=$(uuidgen | tr 'A-Z' 'a-z'); echo "$SID" > <scratch>/sid-<track>.txt
grok -s "$SID" --cwd <absolute-worktree-path> \
  --prompt-file <scratch>/spec.md \
  -m grok-4.6 --no-memory \
  --always-approve --permission-mode bypassPermissions \
  --reasoning-effort xhigh --max-turns 1200 \
  --no-plan --no-subagents \
  $GIT_POLICY_FLAGS \
  > <scratch>/grok-<track>.log 2>&1
```

### Git policy — pick one profile per delegation

`--deny 'Bash(git *)'` blocks *all* git, including reads — grok then cannot
inspect commit history, blame, or PRs, which hurts investigation-heavy tasks.
Choose deliberately:

```bash
# 1) strict (recommended default): block state changes, allow reads
#    (git log/show/diff/blame and gh pr list/view still work).
#    Field-tested: reads pass, `git commit` is blocked, HEAD unchanged.
GIT_POLICY_FLAGS="--deny 'Bash(git commit*)' --deny 'Bash(git push*)' \
  --deny 'Bash(git checkout*)' --deny 'Bash(git switch*)' \
  --deny 'Bash(git stash*)' --deny 'Bash(git restore*)' \
  --deny 'Bash(git add*)' --deny 'Bash(git rebase*)' \
  --deny 'Bash(git reset*)' --deny 'Bash(git merge*)' \
  --deny 'Bash(git cherry-pick*)' --deny 'Bash(git tag*)' \
  --deny 'Bash(git worktree*)' --deny 'Bash(gh pr create*)' \
  --deny 'Bash(gh pr merge*)' --deny 'Bash(gh repo *)'"

# 2) readonly-plus (paranoid): the old blanket ban. Use for parallel tracks
#    with tight file boundaries where even a git read prompt is unwanted.
GIT_POLICY_FLAGS="--deny 'Bash(git *)' --deny 'Bash(git)'"

# 3) trusted: no git denies. Only inside an isolated worktree the lead
#    created (see "Parallel tracks"), when you WANT grok to make WIP
#    commits at round boundaries. The lead still reviews history and merges.
GIT_POLICY_FLAGS=""
```

Glob denies are a safety net, not a proof — exotic forms (`git -C <path>
commit`) can slip past subcommand patterns. Keep the preamble's git rules in
the spec as the second layer, and treat profile 3 as trust + isolation, not
as enforcement.

**Always prepend the preamble** (`references/spec-preamble.md`). Every item
in it comes from a real incident. Do not tell grok to "go read that file" —
merge it into the prompt body; the spec must stand alone.

Field-tested flag notes:

- **Use `--always-approve`.** `--permission-mode acceptEdits` plus individual
  `--allow` rules silently blocks the first unmatched tool call in headless
  mode — grok prints one intent line and exits 0 with zero tree changes
  (reproduced twice). The git ban stays enforced by `--deny`.
- **Verify completion by the tree, not the exit code.** exit 0 ≠ work done.
  Check `git status --short` for real changes and the end of the log for the
  completion checklist; on an empty turn, resume with `-r <SID>` and say
  "you must call tools and do the work this turn" (this is why the default
  form pins a session id with `-s`).
- **Enforce the git policy mechanically** (profiles above). Commits, restores
  and stashes belong to the lead in profiles 1–2; profile 3 delegates WIP
  commits but never pushes/merges.
- **Deny only with `Bash(...)` command patterns — tool-name denies are a
  trap.** grok's native tool names are lowercase (`write`,
  `search_replace`); `--deny write` passes without error and the file still
  gets written, while an unknown name like `--deny NotebookEdit` hard-errors
  the whole call. Get file-safety from worktree isolation plus the spec's
  file boundary, not from tool denies.
- **Pin the model with `-m`.** The default drifts across accounts and CLI
  versions (4.5 ↔ 4.6), and `grok models` shows the *unauthenticated*
  default when logged out — easy to misread. Every number in this skill was
  measured on grok-4.6.
- **Pass `--no-memory`.** If `--experimental-memory` is enabled in config,
  assumptions leak between rounds and reproducibility dies — same purpose as
  the `-s` pin-once / `-r` resume discipline.
- For potentially destructive large tasks, isolate in a **lead-created git
  worktree** (recipe under "Parallel tracks") and collect only the diff.
  The CLI's own `--worktree` flag belongs to interactive sessions — in
  headless `-p`/`--prompt-file` runs no worktree is created (field-tested,
  and stated in `--help`).
- `--reasoning-effort xhigh` and `--max-turns 1200` keep depth requirements
  from being squeezed by the turn cap; with `--prompt-file` this combination
  completes multi-hundred-line packages in one turn.
- **The "implementation tokens are free" premise is measurable, not an
  article of faith**: `--output-format json` returns `usage`,
  `total_cost_usd` and `modelUsage` — sample a round and check.

### Follow-up in the same context

```bash
SID=$(uuidgen | tr 'A-Z' 'a-z')
grok -s "$SID" --prompt-file spec.md ...     # first call
grok -r "$SID" -p "apply review notes: ..." ... # follow-up
```

A session id is **pinned once** (`-s`) and only **resumed** afterwards
(`-r`). Re-invoking `-s` with a used id fails with "Session ID already in
use" — for a new round (e.g. a FIX round whose spec is self-contained
anyway), mint a fresh id instead; nothing is lost.

### Parallel tracks (worktree isolation)

When two delegations touch modules that import each other, a shared tree
produces phantom gate failures (track A's gate reads track B's half-edited
file). Isolate each track:

```bash
git -C <repo> worktree add ../<repo>-wt-<track> -b wt/<track> HEAD
ln -sfn <repo>/node_modules ../<repo>-wt-<track>/node_modules  # deps without reinstall
# launch grok with --cwd <absolute worktree path>; lead merges diffs
# sequentially after review, then removes the worktree.
```

Give each track an explicit writable-file list (code + its own gate file),
keep the gate files disjoint, and state in each spec that other tracks'
breakage is report-only. The lead applies diffs one track at a time.

### Structured results

When you need to parse a verdict, add `--json-schema '<JSON Schema>'` —
stdout becomes schema-constrained JSON.

## Quality bundle (put these sections in every spec)

These are the empirically validated additions that closed most of the
quality gap against stronger implementer models in a 9-experiment
blind-judged series (see the repo README):

1. **Contract↔assertion mapping table** — the gate/test file must open with
   a table mapping every contract clause to at least one assertion; each
   assertion needs FAIL-first evidence (one line showing it actually fails
   on a violating fixture). This alone quadrupled self-authored gate depth.
2. **Quantified depth** — do not write "be thorough". Write: "≥2 assertions
   per contract clause (one happy path, one violation/boundary)", "coverage
   table of cases × paths", and "**defend against discovered defects within
   your own output's scope** — report only what is out of scope".
3. **Self-review pass** — after finishing, "list 3 defect classes you may
   have missed; add an assertion for each or justify why not".
4. **Visual self-verification** (for anything rendered) — grok must open its
   own screenshots and compare them against the spec's checklist, log every
   find→fix, and end with a per-axis self-verdict (SHIP/FIX predictions,
   later compared against an independent blind verdict). **Checklist item #1
   must always be identity legibility**: "does this read as X? what could it
   be misread as?" — that one line caught failures numeric gates cannot.
   Inventing new looks stays banned; the only allowed fixes are convergence
   toward the numeric contract.
5. **Logic design principles** (for state machines / serialization / cores):
   derive-don't-store (derive state from phase and inputs; restoration bugs
   live in stored state) · re-normalize external input on load (don't
   validate-then-discard) · a 3-class input defense table
   (malicious / corrupted / stale-schema, each with a rejection path and an
   assertion) · adversarial API self-review ("3 ways to misuse my API",
   each blocked structurally or gated).

## Per-task spec (task.md — appended after the preamble)

The preamble owns shared constraints and the report format. The task spec
contains only what is unique to this task:

```markdown
# Task: <one line>

## Files to read before starting (all of them — confirm in the report)
- <the project's contract docs / the modules being touched / prior-art files>

## Background (self-contained — the spec alone must be enough)
- Target file: <exact path:line>
- Current behavior / desired behavior
- <Quote the project pitfalls that apply to THIS task into the body>

## Contract (violations are failures)
- <pin the contract as values: supported range, behavior when unsupported, boundaries>

## Constraints unique to this task
- <file boundary: writable paths + "everything else read-only">
- <if parallel tracks exist: their broken builds are not your fault — report only>

## Verification commands (completion criteria — paste real output, never hide exit codes behind pipes)
- [ ] <command and expected output>
- [ ] <a real end-to-end artifact — build it and open it>

## Last line
DONE-<track>
```

### What the lead checks while writing the spec

- **Quote the applicable pitfalls yourself.** The preamble tells grok to go
  find the trap docs, but what the lead already knows, the lead should quote.
- **Never put 3+ independent jobs in one spec.** Defect rates rise with spec
  length; split boundaries into parallel tracks instead.
- **Put a real artifact in the completion criteria.** Unit tests alone cover
  only pure functions; force a snapshot/roundtrip/`--help` execution and the
  integration defects surface immediately.
- **Fake-server coverage ≠ the real system.** If credentials exist, the lead
  runs one real pass; if not, mark "unverified" and run it when they appear.
  Mix localized/non-ASCII values into fixtures on purpose.
- **When secrets are involved, demand a whitelist implementation** plus a
  test that fails on unclassified fields — blacklists leak future fields.

## What the lead always does

1. **grok "done" ≠ done.** The lead reads `git diff` directly and re-runs the
   affected gates under its own ownership.
2. **Anything visual gets one blind vision verdict before commit** (a fresh
   judge each round; give it numeric context first, narrow the question, and
   include a "do not judge" list for things other tracks are still fixing).
   If the verdict says FIX, translate the prescription into numbers and
   resume the same grok session with `-r <SID>`.
3. **Never mix look-core changes with UI/mechanical work** in one spec or
   one commit.
4. Confirm the completion-criteria output in the log; if missing, resume the
   same session and demand it.
5. Parallelize grok instances only when file boundaries do not overlap.

### Review checklist (where defects actually leak)

grok reports are largely honest — the problem is what the report does *not*
say. Verified leak points, in order:

1. **grep for newly invented mapping/constant tables** — the data often
   already has an equivalent field.
2. **Compare against equivalent implementations on other surfaces** (web/TUI/
   CLI parity).
3. **Execute user-facing text yourself** (`--help`, error strings) and check
   it against the code — invented copy passes tests.
4. **For refactors, ask "what was lost"** — ordering, caches, fallbacks,
   shortcuts. A honest comment acknowledging a regression is still a
   regression.
5. **Read changed test assertions in the diff** — a bumped constant means a
   contract was rewritten; demand the original contract.
6. **Check new imports** for inverted dependency directions.
7. **Re-run secret scanners *after* committing** new files — `git ls-files`
   based scanners skip untracked files, which looks like a pass.
8. **For conditional features, verify the disabled path is unchanged** —
   hot-path costs don't show up in tests.

Fix small precision defects yourself on the spot; re-delegate only repeated
patterns or large volumes.

## Image generation (built-in `image_gen` / `image_edit`)

Headless grok CLI sessions have image generation built in — the `image_gen`
and `image_edit` tools work under `grok -p/--prompt-file` with
`--always-approve` (field-verified 2026-08-13, grok-4.6). **Video generation
is also present**: `image_to_video` and `reference_to_video` report available
in the same headless sessions (availability field-verified 2026-08-13;
generation itself not yet exercised — 6s/10s shots per the bundled `imagine`
skill, frame-harvest pipeline per `game-animation-frames`). Guidance for the
tools themselves ships with grok at `~/.grok/bundled/skills/imagine/SKILL.md`
(prompt-craft, reference-first rules, consistency via `image_edit`
anchoring); related bundled skills cover game assets
(`game-tilesets`, `game-asset-core`, `game-animation-frames`, ...).

Field-tested facts the spec must account for:

- **Output lands outside the worktree**: the tool writes to
  `~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/images/N.jpg`. Always
  instruct grok to **copy the result into the worktree** at an explicit path
  and `ls -la` it in the report.
- **Output is JPEG** even when you ask for PNG — no alpha channel. If the
  asset needs transparency (sprites, atlases), the spec must include a
  matting step (generate on a distinct flat key color, then key it out in
  post) or accept opaque cards.
- Observed resolution tier: 1024×1024 at `aspect_ratio 1:1`. `aspect_ratio`
  works (`16:9`, `9:16`, ...); there is **no `n`/count parameter** — issue
  multiple calls for variations.
- For a recurring look across assets, generate one canonical reference and
  derive the rest with `image_edit` (independent `image_gen` calls drift).
- Moderation blocks are terminal: the spec should say "report the block,
  do not paraphrase-retry".
- Treat generated assets like any other artifact: numeric contract
  (palette bands, coverage) + the lead's independent vision verdict before
  commit. Generation quality is high enough to beat procedural texturing
  for painterly/organic assets (clouds, terrain washes), so prefer
  generate→post-process→gate over shader-only approaches there.

## Bundled grok skills — index

grok ships built-in skills at `~/.grok/bundled/skills/<name>/SKILL.md`.
grok auto-loads them when the task matches; **naming the skill in the spec**
("load the imagine skill", "follow game-tilesets") force-loads it. This is
the notable subset — read the SKILL.md at that path for details:

| Skill | What it gives a delegated task |
|---|---|
| `imagine` | `image_gen`/`image_edit` prompt-craft, reference-first rules, consistency anchoring (see section above) |
| `game-asset-core` | Core rules + engine-ready defaults for generated game assets — base skill for the `game-*` family |
| `game-tilesets` | Seamless/transition tilesets **that actually tile** — use for ground/terrain textures |
| `game-animation-frames` | Video-first animation frame sets that actually cycle |
| `game-character-consistency` | Same character across every generated image |
| `game-ui-icons` | Game UI kits and icon sets |
| `design` / `implement` / `review` / `execute-plan` | grok-internal multi-agent loops (writer↔reviewer consensus, implement-review-fix, PR-plan DAG execution). NOTE: these spawn grok subagents — drop `--no-subagents` if a spec asks for them; normally we keep our own lead-owned loop instead |
| `code-review` | Strict maintainability audit (abstraction quality, giant files, condition growth) |
| `pr-babysit` | Monitor PRs: fix CI, address review comments, resolve conflicts, restack |
| `pdf` / `docx` / `pptx` | Read/create/transform documents and slide decks |
| `resume-claude` / `resume-codex` / `resume-cursor` | Continue from another agent's recent session — lets grok pick up a Claude Code session's context |
| `create-skill` / `create-workflow` / `skill-design-principles` | Author new grok skills/workflows |

## When NOT to delegate to grok

- Problems too exploratory to spec (lead narrows the cause first, then delegates)
- git / deploy / release actions (lead only)
- Vision verdicts that contradict instrumentation (escalate to a Claude agent)

## Operational tips (field-tested)

- Headless grok sometimes finishes a `-p` turn with partial work. Define a
  completion marker (`DONE-<track>`) in the spec and, as a safety net, loop
  `-r <SID> -p "continue"` until the marker appears. `--no-plan` is required.
  With `--prompt-file` + xhigh + high turn caps this is rarely needed.
- Keep gates from dumping data:URL bundle stacks — trap
  `process.on('uncaughtException')` and print the message only.
- **Scope gates per package for parallel tracks.** Whole-tree builds fail on
  other tracks' half-finished code; the lead runs the full gate serially
  after tracks close.
- Entry-point files (CLI switch tables, help text) attract every track —
  schedule those tasks sequentially, not in parallel.
- With browser E2E suites, kill zombie server processes first; a wiped suite
  looks like a code regression when it is a port squatter (0ms failures =
  suspect the environment).
- Reference images help only when they show **the same effect type** as the
  task. A reference of a different effect type transplants the wrong visual
  language — if you attach references, say "borrow the color/edge
  discipline, not the shapes".
- **Absolute paths everywhere**: `--prompt-file` resolves against `--cwd`,
  and shell cwd resets between the lead's own tool calls — relative paths
  have produced "the edit didn't land" misdiagnoses (it read the wrong
  copy). Put absolute paths in the spec's file lists and verification
  commands too.
- **Don't wrap grok in `timeout`.** Killing it mid-run leaves a half-written
  tree that reads as a grok defect on review. (Stock macOS also lacks
  `timeout(1)`; coreutils adds one — but the half-written-tree reason holds
  everywhere.) Run it in the background through your harness and watch the
  log/tree instead.
- Before diagnosing a hung delegation or lock contention, `pgrep -fl grok` —
  idle sessions left over from earlier rounds are common and easy to
  mistake for your run.

## Local overlay (project/user-specific context)

If `references/local-overlay.md` exists next to this skill, **read it and
apply it on top of these instructions** — it holds the project- or
user-specific context that does not belong in the shared skill: role tables,
project trap docs to quote, scratch-path conventions, model-assignment
tables, house gate recipes. When merging spec preambles
(`cat spec-preamble.md [local-overlay.md] task.md`), include it between the
shared preamble and the task spec. The installer preserves an existing
overlay on upgrade; this repository never ships one.
