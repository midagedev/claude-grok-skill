# grok-delegate

**Your Claude session does the thinking. Your grok subscription does the typing.**

[English](./README.md) | [한국어](./README.ko.md)

A Claude Code skill that turns the local **grok CLI** into a headless implementation sub-agent. The lead Claude session keeps the work where judgment matters — specs, diff review, gates, commits — and delegates implementation, mechanical edits, and even screenshot verdicts to grok, where tokens are effectively free on a grok subscription.

It's not a wrapper; it's an operating manual, distilled from a 9-round blind-judged comparison against stronger implementer models. Applying the skill's prompt devices took grok's self-authored test depth from **14 assertions to 81** and turned a 0:5 blind loss into wins on the visual axis — the receipts are [below](#does-it-actually-work).

## Install

From the plugin marketplace:

```
/plugin marketplace add midagedev/claude-grok-skill
/plugin install grok-delegate@claude-grok-skill
```

Or with the install script (preferred if you'll use a [local overlay](#local-overlay)):

```bash
git clone https://github.com/midagedev/claude-grok-skill
cd claude-grok-skill
./install.sh            # user scope: ~/.claude/skills/grok-delegate/
./install.sh --project  # project scope: ./.claude/skills/grok-delegate/
```

You'll need [Claude Code](https://claude.com/claude-code) and an authenticated `grok` CLI (a grok subscription).

## Use

Say **"run this via grok"** in any Claude Code session, or invoke `/grok-delegate`. Claude then:

1. writes a **self-contained spec** — file paths, numeric contracts, verification commands — from the bundled preamble + template,
2. launches grok **headless in the background** with the field-tested flag combo (`--output-format streaming-json --reasoning-effort xhigh --max-turns 1200 --always-approve` + a git-safety profile),
3. **reviews the result like a lead**: reads the diff itself, re-runs the gates under its own ownership, and walks an 8-point checklist of the places grok's reports actually leak. Mid-round, it can compress the NDJSON log with `scripts/grok-progress.py` (one line per tool call). `--output-format plain` still works.

| Role | Owner |
|---|---|
| Orchestration, specs, diff review, gates, commits | Lead Claude session |
| Implementation, mechanical edits, numeric harnesses | `grok` CLI (headless) |
| Screenshot / visual verdicts | `grok` CLI — escalates to Claude only if a verdict contradicts instrumentation |

The core principle: **grok is an executor of tight specs.** It has zero conversation context, so every delegation must stand alone — and never asks for taste judgments, only numeric contracts.

## The quality bundle

What actually closed the quality gap, each device with a measured effect:

1. **Contract↔assertion mapping table** + FAIL-first evidence — quadrupled self-authored test depth on its own
2. **Quantified depth** — never "be thorough"; instead "≥2 assertions per contract clause, coverage table, defend discovered defects within your own scope"
3. **Self-review pass** — "list 3 defect classes you may have missed; assert or justify"
4. **Visual self-verification** — grok opens its own captures; checklist item #1 is always *identity legibility* ("does this read as X? what could it be misread as?")
5. **Logic design principles** — derive-don't-store · re-normalize on load · 3-class input defense · adversarial API self-review

## Does it actually work?

We measured it, 9 rounds. Each round: the *same spec* went to **grok-4.6** (headless CLI) and to **Claude Opus 5** — one round to **Claude Fable 5** — in parallel git worktrees. The task was always real production work from a Three.js/WebGPU project: implement a module *and author its own verification gate*. Outputs were judged **blind** — unlabeled sources, labels swapped every round, judge forbidden to guess authorship. The short version:

- **Baseline: clear loss to Opus 5.** 0:5 blind verdict; grok wrote 14 test assertions where Opus 5 wrote 24.
- **With the bundle: the gap closed where it matters.** grok's assertion depth went 14 → 42 → 67 → **81**; the visual axis flipped to grok wins in the last two rounds (once over Opus 5, once over Fable 5); grok ran 2–4× faster throughout.
- **What stayed hard:** design-weight logic cores (state machines, serialization) stayed with the Claude side all three times it was tested — so the skill says to keep those with Claude and let grok review.
- **Best single finding:** grok's blind losses were mostly **missing defaults, not missing capability** — and defaults can be written into a spec.

<details>
<summary>Full experiment table (E1–E9)</summary>

Opponent is **Claude Opus 5** in every round except E8 (**Claude Fable 5**). E5/E6 are grok-vs-grok A/B rounds isolating one device. "Assertions" counts each model's self-authored gate depth for the same contract.

| Exp | The actual task | Device added to grok's spec | Blind verdict | Measured |
|---|---|---|---|---|
| E1 | Energy-barrier VFX: hit ripple + rim shader (TSL) with a numeric gate | — (baseline) | lost 0:5 to Opus 5 | assertions 14 vs 24 |
| E2 | Shoot-down destruction: debris burst + flash timing | — (replication) | lost to Opus 5 | assertions 12 vs 32; grok 1.5× faster |
| E3 | Cel-sky cloud layer: 3-plane parallax billboards | fairness fixes + self visual verification | lost — render didn't read as clouds | failure traced to the checklist, not the model |
| E5 | Screen exposure flash + hitstop on impact | + `--rules` preamble, contract↔assertion mapping table (v1) | **won 2:0:1** (grok A/B) | assertions 10 → 42 |
| E6 | Near-miss graze sparks | reference-image injection (A/B) | **injection rejected 4:0:1** | references only help for the same effect type |
| E7 | Bullet-time: timeScale state machine + cel clock-motif visual | + quantified depth, self-review, 1200 turns (v2) | **split vs Opus 5: visual axis won**, logic lost | assertions 67 vs 95 — gap 3×+ → 1.4×; 2.2× faster |
| E8 | Camera FOV cues: tele hold/release ladder tied to engagement phases | v2, **vs Claude Fable 5** | split: visual won, code lost | Fable also caught a defect in *our own spec* |
| E9 | QTE timing judge: hit windows + combo state machine over a replay timeline | + 4 logic design principles (v3) | lost to Opus 5; reviewer credited grok's single-time-axis design | assertions 81; fastest run of the series (1,112 s) |

The E3 lesson: grok self-reported SHIP on all six checklist axes and still lost — the render didn't *read as a cloud*. Every axis it checked was valid; the failure lived outside the checklist. Making **identity legibility** mandatory item #1 is what preceded the E7/E8 visual wins.

Where it settled (our production assignment table):

| Task type | Assignment |
|---|---|
| Mechanical edits, FIX rounds, porting, tuning | **grok** — undefeated |
| New visual systems | **grok first draft** + blind vision gate; Claude rewrite after 2 failed FIXes |
| Logic cores (state machines, serialization) | Claude first, grok reviews |
| Verdicts (vision, code review) | **grok** — rejected its own implementations multiple times; no self-bias observed |

</details>

## What's inside

| File | Purpose |
|---|---|
| `skills/grok-delegate/SKILL.md` | Invocation recipes, git-safety profiles, quality bundle, parallel-track isolation, visibility/intervention, lead review checklist |
| `references/spec-preamble.md` | Shared rules prepended to every spec — every clause from a real incident |
| `references/spec-template.md` | Per-task spec skeleton: contracts, depth requirements, visual self-verification |
| `scripts/grok-progress.py` | Compress a `streaming-json` (or session `updates.jsonl`) log into one-line progress events |

Safety default: delegations run with an enumerated git-deny profile — grok can read history and PRs but can't commit, push, or rewrite state; that stays with the lead. Three profiles (strict / read-only / trusted-in-worktree) are documented in SKILL.md.

## Local overlay

Project- or user-specific context (role tables, house gate recipes, model assignments) goes in `references/local-overlay.md` next to the installed skill — applied automatically, preserved by `install.sh` across upgrades, never shipped by this repo.

## Known limits

- Exploratory problems that can't be specced aren't delegation material — the lead narrows first.
- Design-weight logic didn't fully close even with bundle v3; write those with Claude, review with grok.
- Reference images only help when they show the same effect type as the task.
- grok's reports are largely honest; the risk is what they *don't* say — hence the lead review checklist.
- Claude Code only for now. The SKILL.md format is portable, but we publish only what we've verified end-to-end.

## Changelog

### 2026-08-13 — visibility, intervention, and grok's built-in tools

Everything below was measured, not inferred; what failed is documented as failing.

- **Mid-round visibility.** `--output-format streaming-json` marks tool-call
  boundaries (`plain`, the CLI default, does not). New
  `scripts/grok-progress.py` compresses either that stream **or** the session's
  own `~/.grok/sessions/<url-encoded-cwd>/<sid>/updates.jsonl` into one line
  per tool call, capped at 100 lines so a lead can check a running round
  without flooding its context. `updates.jsonl` is written regardless of
  output format, so past `plain` runs are observable too.
- **Progress checkpoints** (§9 of the shared preamble): the delegate appends
  `PROGRESS <ISO-8601-UTC> <stage> <one line>` at every stage boundary, so the
  lead has a fallback when the stream is missing or unparsable.
- **Intervention, honestly.** A second client *cannot* steer a live `-p` turn:
  `grok -r <SID> -p ...`, the same with a shared `--leader-socket`, and ACP
  `session/load` + `session/prompt` all queue instead of redirecting — the
  original turn ran to completion in every trial. The supported path is
  `kill` (SIGTERM) then `-r <SID>` with a revised spec; completed tool results
  survive, work after the last completed tool is lost, and on-disk edits are
  not rolled back. `--stream-events` does not exist; `grok dashboard` was not
  verified as a window onto a separate headless process.
- **grok's built-in image and video tools.** `image_gen` / `image_edit` work in
  headless sessions (`image_to_video` / `reference_to_video` report available).
  Field notes now in SKILL.md: output lands outside the worktree under
  `~/.grok/sessions/...`, it is JPEG (no alpha — chroma-key and matte if you
  need transparency), 1024px at `1:1`, no `n`/count parameter, and consistency
  across a set comes from one canonical generation plus `image_edit` derivations.
- **Index of grok's bundled skills** (`~/.grok/bundled/skills/`): `imagine`,
  the `game-*` asset family (`game-tilesets` enforces a real 2x2 tiling check),
  document skills, `resume-*` session interop, and grok's own multi-agent loops
  — with the caveat that those loops need `--no-subagents` dropped.

## License

MIT
