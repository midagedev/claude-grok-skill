# Changelog

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
