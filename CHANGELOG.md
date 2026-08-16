# Changelog

## Unreleased

- **The to-be-created exemption was by line, so it moved the cry-wolf defect
  one page down instead of fixing it.** A spec names the file it is creating
  more than once — in the whitelist, again in the completion criteria, again in
  a test section — and only the declaration was exempt. Measured on the next
  real spec written after 0.9.0: five findings, four of them the same three
  files named a second time. The exemption is now by resolved path, collected
  in a pre-pass so a mention *above* the declaration counts too, and
  `already-exists` still reports once at the declaration rather than at every
  mention. Four more test cases, FAIL-first against 0.9.0's version.
- The header now names a limit rather than leaving it to be rediscovered as a
  bug: a path inside a command that sets its own root (`vitest --root web
  src/…`, `make -C dir`) resolves from `--root` and the spec's directory, so it
  can read as missing. Teaching the linter every tool's cwd flag costs more
  precision than it buys.

## 0.9.0 — 2026-08-16 — the delegate is not the lead, and read-only git stays read-only

- **`bin/git-guard.sh` blocked a read-only call it was written to allow.**
  `git -C <repo> worktree list` was refused. The guard erases read-only forms
  and then runs the deny pass over what is left, but the two passes spelled
  "global flags before the subcommand" differently: the deny pass understood
  `-C <path>` and `-c <k=v>` (a flag that swallows the next word), the allow
  pass did not. So the read-only form was never erased and `worktree` tripped
  the deny list. A delegate that opened by proving which tree it was in — the
  thing the specs ask for — got blocked for it, and the next spec learns to
  drop the check that would have caught a wrong worktree. The flag grammar is
  now one definition used by both passes.
- **`tests/git-guard.test.sh`** — 54 cases, the guard's first test of any
  kind. It asserts both directions, because a security boundary fails two
  ways: a mutation that slips through costs a repository, and a read-only
  call that is refused makes agents work blind. FAIL-first recorded against
  the pre-fix script (3 red: the `-C` and `-c` forms).
- **Preamble §0: you are the executor of one spec, not the orchestrator.**
  A round was lost to this. The delegate read `git log`, saw commits made
  earlier that day, ran `ps`, saw other processes, and concluded it was the
  lead of the session — then wrote zero lines of code, filed an operations
  report about "duplicate launches", installed watchers, and spawned another
  agent of its own. The spec went untouched. The new section says the things
  that were missing: never spawn an agent, concurrent rounds beside you are
  normal and not yours to manage, recent commits are the lead's history and
  not yours, an apparent contradiction goes in the report rather than into
  taking over. `spec-preamble-core.md` carries the short form, because this
  failure costs the whole round on either preamble, and §11 names the ban
  alongside the git one.
- **`--done-marker <string>` writes `done_marker=found|absent` into the
  `<log>.rc` sentinel.** `rc` is a lifecycle signal — it says the harness
  exited cleanly and nothing about whether the round did its job. Both halves
  of that gap were measured the same day: one round exited `rc=0` having
  produced no code, and another exited `rc=0` with no edits because the
  spec's own precondition check correctly told it to stop. A failure and a
  good outcome, same exit code. The marker separates them from a file read
  instead of a transcript hunt.
- **The status line shows this session's rounds, not the machine's.** The
  registry is global by design — an orphan has to be findable from wherever
  you are — but every Claude Code window reading it unfiltered meant two
  windows on two repos narrated each other's work as if it were your own.
  Caught in the act: a diagnostic on the live status line came back carrying
  a different session's id than the one that installed it. So each launch
  records its owner and each status line asks only for its own. Two keys,
  because one does not cover it: `CLAUDE_CODE_SESSION_ID` is exact but
  differs for an in-process subagent, and `CLAUDE_PID` is the Claude Code
  process the lead shares with its teammates — either matching counts as
  yours. Unowned records (launched outside Claude Code, or predating this)
  stay out of scoped views rather than appearing in all of them, and
  `runs.sh` unfiltered still lists everything with an `OWNER` column.
  `OUTSOURCE_STATUSLINE_SCOPE=all` opts back out. Record ids also gained a
  collision suffix, since `<epoch>-<pid>` could silently overwrite another
  round when a pid was recycled inside one second.
- **`tests/run-all.sh`, and `tests/runs-owner.test.sh` under it.** The
  ownership filter that scopes the status line to one session shipped without
  a test, and it fails in two directions that look nothing alike: too wide and
  another window's rounds read as your own, too narrow and a round a teammate
  launched vanishes from the view you use to notice a round died. Twelve cases
  cover both, including the ones the status line actually produces — an empty
  `--owner-claude-pid`, which must narrow nothing and must not switch the
  filter off — and the same-second same-pid launch that the record id had to
  grow a suffix for. FAIL-first recorded against `d01bbb4`: 0 of 12.
  `run-all.sh` exists because there were by then two test files, each
  documenting its own invocation in a header comment and neither wired to
  anything; a test nobody runs is a record of a past check, not a gate.
  Dropping a `*.test.sh` into `tests/` now enrols it, and an empty directory
  exits 2 rather than reporting success.
- **`bin/spec-lint.sh` reported every file a spec asked the delegate to
  create as a missing premise.** Which is most specs, so most linting runs
  opened with guaranteed findings — the exact precision failure the file's
  own header warns about twice, arriving from the other side. A path marked
  to-be-created (a `Create:` / `New files:` heading or list, or an inline
  `Create: <path>`) is no longer a claim about the tree and is exempt. It
  gains the opposite check instead: a to-be-created path that already exists
  is reported, because then the spec and the tree disagree about what the
  round is for. The count of exemptions prints on the `ok` line, since a
  suppression nobody can see is how a linter starts lying.
- **`tests/spec-lint.test.sh`** — 12 cases, half of them the defects that
  must stay loud next to the ones that went quiet: prose after a creation
  block is still linted, a heading ends the block, the inline form exempts
  one line, and a sentence that merely begins with "Create" and ends in a
  colon does not swallow the rest of the document. FAIL-first against the
  pre-change script: exactly the 5 new-behaviour cases red, the 7 regression
  cases green — which is what makes them regression cases rather than
  decoration.

## 0.8.0 — 2026-08-16 — a round you can see while it runs

- **`bin/runs.sh`** — a registry of delegated runs. Every launch records what
  it launched (label, provider, harness, model, spec, log, pid, start time)
  and, on the way out, how it ended. `runs.sh` lists it back with elapsed
  time; `runs.sh line` compresses it to one line; `runs.sh json` is the same
  data for scripts. The state that motivates the whole file is **orphan** —
  started, pid gone, no exit code. A killed round leaves no process at all,
  so `ps` answers the same nothing for "finished cleanly" and "died an hour
  ago holding your worktree"; started-but-never-finished is a state only a
  written record can hold. Records are `key=value` lines, the same shape as
  the launcher's `<log>.rc` sentinel, and this script is their only writer.
- **`bin/outsource-run.sh --label <name>`** says what the track is *for*.
  Parallel rounds are the only time the listing matters, and they are also
  where a derived label fails: this skill's documented layout writes every
  track's spec to `<scratch>/spec.md`, one dir per track, so a basename
  default would register three rounds as `spec`. The default falls back to
  the directory holding the spec, a label that still collides renders as
  `name`, `name#2`, and both are fallbacks — the docs now ask for a real
  label at launch. Registration happens after the vision and
  quota guards and before the harness dispatch — a guard that refuses to
  launch has not started a round — and an `EXIT` trap covers the paths the
  normal completion path does not, so a killed launcher cannot leave a round
  reading "running" forever. Registry failures never fail a round.
- **Stall detection, measured on output rather than elapsed time.** Neither
  harness can stop itself — `crush run` exposes no turn or time limit in its
  flag set at all, and the `claude` CLI has no `--max-turns`, only
  `--max-budget-usd` at Anthropic's prices, which says nothing about a z.ai
  plan. The obvious response is a time limit, and ten local rounds read back
  from the harness session stores say it is the wrong one: they ran 13
  minutes to **1h50m**, duration tracking message count almost linearly (66
  messages / 13m … 848 messages / 1h50m). Long rounds were long because
  there was a lot of work; cutting at an hour truncates a working delegate
  mid-edit and still misses a round that wedged at minute three.

  So the registry records where each harness leaves a live trail —
  `data/crush.db-wal` and `data/logs/crush.log` for crush,
  `claude/projects/**.jsonl` for the claude-code harness, deliberately *not*
  the `--log` file, which that harness writes once at the end — and reports
  an `IDLE` column. `⏳` fires only when a running round has written nothing
  for ten minutes (`OUTSOURCE_RUN_STALL`). Verified against both halves at
  once: a real 1h41m round that had written a second earlier stayed `▶`,
  while a live pid whose directory had been silent 30 minutes flagged. An
  elapsed-time rule would have inverted both.
- **`--max-seconds N`** hard-kills at N seconds — SIGTERM then SIGKILL to
  the harness's whole *process group*, because a signal to the shell alone
  leaves the model CLI running and only looks like a stop. The round
  finishes as exit 124 in both the sentinel and the registry, with the
  session id still recovered so a follow-up can resume. No default, and it
  should not get one: the kill lands mid-edit. It is an escape hatch for
  rounds whose loss is accepted up front, not the answer to a slow round.
- **`bin/statusline.sh`** — a Claude Code status line built from the two
  scripts above plus `bin/quota.sh`: model, account, context, the 5-hour and
  weekly Claude windows, the z.ai and grok plan windows, and the rounds in
  flight. Every budget is one token, `NAME used%/until-it-resets`, because
  neither half is actionable without the other — which is also why there is
  no bar. Quota APIs are never called on the render path: a lock-guarded
  background refresh writes a small cache (default 180 s), and unmeasured
  shows `…` rather than a `0%` that would read like good news.
  Silence means one specific thing — "this backend is not set up here" — so
  a failed refresh never erases the last good numbers: they carry forward
  prefixed `~`. Found by shipping it: an expired grok sign-in made the whole
  segment disappear, reporting a backend that had just stopped working
  exactly like one that was never configured. ~120 ms per render.

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
- **z.ai's own installer counts as setup.** Discovery reads
  `~/.chelper/config.yaml`, where `npx @z_ai/coding-helper` — the vendor's
  documented path — keeps the key it verified, so following z.ai's own
  instructions leaves nothing to paste here.
- **The plan's two regions.** `credential.sh <provider> --base-url <default>`
  now owns which host an account lives on: the global coding plan is
  `api.z.ai`, the mainland-China one `open.bigmodel.cn`, and the same key 401s
  against the wrong one. It reads the helper's `plan:` field, falls back to
  Claude Code's `ANTHROPIC_BASE_URL`, and otherwise hands back the provider
  table's default untouched; `$ZAI_BASE_URL` overrides all of it. The launcher
  and `quota.sh` both resolve through it — z.ai's own usage script derives its
  monitor endpoints from the base URL the same way. Measured end to end on the
  global plan; the China host is wired from the vendor's source, not verified.

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

## Pre-0.5.0 — shipped before this file carried version headings

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
