# Changelog

## 0.7.0 — 2026-08-16 — guardrails with exit codes

- **`bin/credential.sh` + `bin/setup-key.sh`** — key resolution gets a single
  owner, and the skill stops requiring another CLI's config file to hold your
  key. Order: the provider's env var (`ZAI_API_KEY` / `XAI_API_KEY`), then
  this skill's own `~/.config/outsource/credentials` at mode 0600, then
  discovery of files another tool already wrote — a crush config, or z.ai's
  official Claude Code helper settings. That last one is read **only when its
  `ANTHROPIC_BASE_URL` is a z.ai host**, so a real Anthropic subscription
  token can never be lifted and sent to a third party.
  `setup-key.sh` is the interactive half: it prompts with echo off, verifies
  the key against z.ai *before* storing it, and writes 0600. The launcher
  never prompts — it runs headless in the background, where a prompt hangs a
  round instead of failing it, so it points at `setup-key.sh` and exits.
  The generated crush config now calls `credential.sh` at load time, so no
  file this skill writes ever contains a key (verified).

Shipped alongside a 14-round, three-way comparison (Opus 5 / grok-4.6 /
GLM-5.3, same spec, five real tickets, isolated worktrees) — written up in
the README. Four changes below come straight out of it.

- **`references/spec-preamble-core.md`** — a short substitute for the full
  preamble. Measured: dropping the preamble entirely was 16-37% cheaper in
  output tokens and never lost a gate, but self-verification went 5/5 to 0/5
  and "what I could not do" went 5/5 to 1/5. FAIL-first survived at 5/5
  either way, because the task spec demands it. The core file carries back
  the disclosure half and nothing else.
- **grok's strict git profile no longer blocks `git worktree list`.** The
  blanket `git worktree*` deny also blocked the read every spec asks for as
  the first line of the report; two rounds had to work around their own
  evidence requirement. The denies are now per-subcommand
  (`add`/`remove`/`prune`).
- **Lead checklist: read your own spec for clauses that cannot both hold.**
  A spec of ours asked for a rule that would overwrite user edits *and* for
  user edits to stay protected; three of four delegates implemented it and
  shipped a data-loss bug with every gate green. The delegate-side rule for
  this already existed in the preamble and did not fire, so the check moved
  to the lead.
- **Lead checklist: verify negative premises one path at a time.** A
  two-pattern `ls` in zsh printed nothing because the second glob matched
  nothing and aborted the command, so an existing file was written into a
  spec as absent. Same family as the `tail` trap.

Renamed `bin/glm-run.sh` → **`bin/outsource-run.sh`**: the launcher is no
longer GLM-specific. All references updated; the flag surface is unchanged
apart from the additions below.

- **Provider table** replaces the hardcoded z.ai constants. A provider is one
  row — base URL, credential source, default model, vision capability — read
  by both harnesses. `--provider zai|xai` (or `OUTSOURCE_PROVIDER`); adding
  one is a row, not a code branch. `ZAI_ANTHROPIC_BASE` still works for zai.
- **Model-identity assertion (exit 70).** A round that silently ran the wrong
  model is a failed round. Correction to 0.6.0's claim: `modelUsage` in the
  JSON log echoes the **requested** id and cannot prove a match (measured — a
  run that asked for `claude-opus-5` and was answered by glm-4.7 still logged
  `modelUsage {"claude-opus-5": …}`). The assertion now reads the per-turn
  `message.model` from the session transcript; no transcript means
  *unverifiable*, which also fails.
- **`bin/quota.sh`** — plan quota for the subscription backends, human or
  `--json`, with `--require-window N%` as a gate (exit 3).
  - `zai`: both rolling windows with real credit counts, plus plan identity.
    The console endpoint answers a bad credential with **HTTP 200** and
    `success:false`, so the body decides success, not the status line.
  - `grok`: the Grok CLI's billing proxy, authenticated with the OAuth token
    the CLI stores. Percent only — xAI exposes no counts. Carries three
    measured traps: `creditUsagePercent` is omitted when it is exactly zero
    (resolved via matching billing bounds), an expired token means "run grok
    once", not "log in again", and unified-billing accounts expose only a
    monthly budget in the default billing view.
  - The gate keys on the **tightest** window, not the shortest — measured, the
    weekly sat at 81.7% remaining while the 5-hour sat at 83.8%.
- **`--require-quota N`** on the launcher refuses to start a round the plan
  cannot finish (exit 66), and fails closed when it cannot be evaluated.
- **Cost honesty.** The launcher prints the round's token counts from the
  log's `usage` — the only per-round figure worth quoting — and says plainly
  that `total_cost_usd` is an Anthropic-priced estimate. Plan credits are
  deliberately *not* reported per round: the quota is a plan-wide counter
  that concurrent rounds and other sessions move too, so a before/after
  delta around one round measures the machine, not the round. Quota stays a
  pre-flight signal.
- **Completion sentinel `<log>.rc`** for both harnesses: `rc`, `finished`,
  `harness`, `provider`, `model_requested`, `model_actual`, `session`. The
  harness's lifecycle is not completion proof.
- **`bin/spec-lint.sh`** — pre-launch spec check for unresolvable paths and
  out-of-range `path:line` citations, the class behind five measured wrong
  premises in one session. Bare filenames are only checked when they carry a
  `:line` citation, and a reference resolving under any plausible base is not
  flagged: at the first cut it produced 30+ findings on this repo's own docs
  with zero real defects, and a linter people ignore is worse than none.
- **Vision guard (exit 65)** when a spec references an image file and the
  provider's row says it cannot see images. Driven by the table, never by a
  provider-name test at the call site.
- Lead checklist: never pipe a gate through `tail`/`head` — the pipeline's
  exit status becomes the pager's, and a hard failure reads as green
  (measured: a `vitest run` that exited 1 looked clean through `| tail`).

## 0.6.0 — 2026-08-16 — GLM on two harnesses

- `bin/glm-run.sh` gains `--harness claude-code|crush`. **claude-code is now
  the default**: `claude -p` against z.ai's Anthropic-compatible endpoint,
  with an isolated `CLAUDE_CONFIG_DIR`, the git guard attached as a
  `PreToolUse` hook, and `--session` mapped to `--resume`. The crush path is
  unchanged and still available.
- `bin/git-guard.sh` now accepts **both call conventions** — the command in
  `$CRUSH_TOOL_INPUT_COMMAND` (crush) or hook JSON on stdin (claude-code) —
  so one guard serves every harness. Regression-tested on both.
- Documented the measured z.ai model-mapping trap: an unqualified
  `claude-*` request comes back as the plan default (glm-4.7), so the
  launcher pins `ANTHROPIC_MODEL`; `modelUsage` in the log is the proof of
  which model answered. Also: `ANTHROPIC_BASE_URL`/`AUTH_TOKEN` are honoured
  (an invalid token 401s), and the harness's `total_cost_usd` is an
  Anthropic-priced estimate, not the plan's charge.

## 0.5.0 — 2026-08-16 — one skill, two backends: outsource

- **Renamed** grok-delegate → **outsource**, and absorbed the glm-delegate
  skill: one skill now routes to two backends — grok-4.6 (grok CLI) and
  GLM-5.3 (z.ai coding plan via the crush CLI).
- **Restructured**: SKILL.md is a thin router (backend table, spec assembly,
  unified 11-point lead review checklist); per-backend operating manuals
  moved to `references/grok.md` / `references/glm.md`; spec-authoring
  material (quality bundle, per-task template checks) to
  `references/spec-authoring.md`. The shared `spec-preamble.md` is
  backend-neutral; `glm-preamble.md` carries the GLM runtime delta
  (no images, hook-based git ban, evidence rules §6–§11).
- **New GLM backend tooling**: `bin/glm-run.sh` (isolated
  `CRUSH_GLOBAL_CONFIG`, scratch data dir, `SESSION <id>` resume) and
  `bin/git-guard.sh` (command-string PreToolUse guard, 29 regression cases).
- **New receipts** in the README: three shipped GLM solo rounds plus a
  same-spec A/B vs an Opus subagent (N=3) — parity on pattern discovery,
  premise correction and FAIL-first; three measured gaps, each promoted to
  a spec rule.


All notable changes to the `grok-delegate` skill/plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions track `.claude-plugin/plugin.json`. Every rule added to the skill
maps to a real field incident — the sections below say which.

## [Unreleased]

### Added
- README "Updating" sections (marketplace and script paths, EN/KO).
- **Round-completion evidence protocol** (SKILL.md) + `scripts/grok-round-status.py`.
  Incident (2026-08-15, third in class): a lead nested the launch recipe one
  background layer deep (`launch.sh &` inside a harness background command);
  the harness fired "task completed" when the wrapper exited while grok kept
  working as an orphan, and the truncated log plus clean tree read as a dead
  round. Earlier members of the class: a watcher `pgrep` matching itself, and
  exit-0-with-empty-turn. Structural fix: the launch recipe now writes a
  `done-<track>.rc` sentinel after grok exits, the sentinel is the ONLY
  completion proof, one-background-layer-only is an explicit rule, and the
  status script renders the verdict (COMPLETED / RUNNING / DIED-NO-SENTINEL,
  the last split by ndjson `end` into "sentinel lost" vs "killed mid-run").
  Validated against live data: a running round, a finished pre-sentinel
  round, and a missing track each got the correct verdict.

### Changed
- `install.sh` now writes a checksum manifest (`.install-checksums`) and
  refuses only when the installed copy was **hand-edited since the last
  install** — plain upgrades no longer need `--force`. Installs are now
  clean (stale files removed); `references/local-overlay.md` is still
  preserved and never checksummed.

## [0.4.0] — 2026-08-14

Two field-audit rounds folded in: a 9-delegation live session (2026-08-13:
5 investigations, 3 implementations, 1 mixed) and a 5-PR CHANGES_REQUESTED
audit (2026-08-14: PRs 13791/13798/13828/13842/13858 — 8 blocking findings,
all with tests and typecheck green).

### Added
- **Profile picker table**: delegation type (implementation single/parallel,
  investigation, vision verdict, asset generation) → git profile, extra
  flags, required spec sections.
- **Read-only investigation profile** (`--deny Write --deny Edit
  --disallowed-tools write,search_replace`), field-tested 5/5 with zero tree
  changes, plus guidance for consuming investigation output: trust the
  file:line facts, re-derive the verdicts; treat premise corrections as
  top-priority findings.
- **Vision-verdict one-shot recipe**: fresh SID, retire after one verdict,
  readonly belt, `--json-schema`, and the 3-element briefing (numeric
  context first · narrowed question · "do not judge" list).
- Preamble: **file list is a whitelist** (list wins over folder-level
  wording; out-of-list files are reported, never touched), **tests must earn
  their green** (no proxy waits; negative assertions right after render;
  reuse neighboring mock patterns), **shared-lib consumer census** (importer
  grep + per-consumer lost-behavior table; fences mean "report regressions",
  not "ignore the app"), **no dead-code deletion without repo-wide grep
  evidence** (even when the spec orders it), **options/guards kept-vs-dropped
  table** for moved/replaced functions, **file moves check references in both
  directions** with a code-file-aware link counter ("newly broken: 0" as a
  number).
- Report format: "deliberately left untouched" is now separate from
  "could not verify".
- Lead spec-writing rules: never pair a file list with a folder phrase,
  never fence at an app boundary when editing a shared lib, never order an
  unconditional "delete the dead code", and treat green as necessary but
  not sufficient — the report tables are completion criteria in their own
  right.
- Review checklist: duplicated helpers diffed against the latest sibling for
  dropped guards; proxy-wait detection in test diffs; bidirectional
  reference grep after moves.

### Fixed
- **Corrected a wrong claim in the preamble**: CLAUDE.md files are injected
  from the ancestor path of `--cwd` only (measured via `grok inspect`) —
  nested `apps/*/CLAUDE.md` and `libs/*/CLAUDE.md` never inject, so specs
  must enumerate them explicitly. The previous text said they were injected
  wholesale.

## [0.3.0] — 2026-08-13

### Added
- Plugin marketplace distribution (`.claude-plugin/plugin.json`,
  `marketplace.json`) and bilingual READMEs with the 9-experiment
  blind-judged evidence table.
- Mid-round visibility: `--output-format streaming-json` recipe,
  `scripts/grok-progress.py`, ACP `updates.jsonl` notes, and the honest
  intervention path (a second client cannot steer a live `-p` turn — stop
  with SIGTERM, resume with `-r` and a revised spec).
- Built-in `image_gen`/`image_edit` (and video tool availability) field
  notes; bundled grok skill index (`imagine`, `game-*`, `pdf`, ...).
- Social preview card assets.

### Fixed
- 7 field-audit findings applied to the skill (flag corrections, session
  pin/resume discipline, completion-by-tree verification).

## [0.2.0] — 2026-08-13 (pre-manifest)

### Added
- Git policy profiles (strict / readonly-plus / trusted) replacing the
  blanket git ban, so investigation-heavy tasks keep read access.
- Local overlay hook (`references/local-overlay.md`) for project/user
  context, preserved across installer upgrades.

## [0.1.0] — 2026-08-13 (pre-manifest)

### Added
- Initial `grok-delegate` skill: invocation recipe, shared spec preamble,
  spec template, quality bundle, lead review checklist, `install.sh`.
