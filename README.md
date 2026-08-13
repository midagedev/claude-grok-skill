# grok-delegate

**Your Claude session does the thinking. Your grok subscription does the typing.**

[English](./README.md) | [한국어](./README.ko.md)

A Claude Code skill that turns the local **grok CLI** into a headless implementation sub-agent. The lead Claude session keeps the work where judgment matters — specs, diff review, gates, commits — and delegates code implementation, mechanical edits, and even screenshot verdicts to grok, where implementation tokens are effectively free on a grok subscription.

Everything in this skill is field-tested. We ran a 9-experiment series giving the *same spec* to grok and to stronger implementer models (Claude Opus / Fable) in parallel worktrees, then judged the outputs **blind** (unlabeled, labels swapped every round). The skill is the distillation of what actually closed the quality gap.

## The evidence: how prompt devices closed the gap

The single most useful finding: **most of the gap was never model capability — it was missing defaults**, and defaults can be written into the spec.

| Exp | Task | Device added to grok's spec | Blind verdict | Measured effect |
|---|---|---|---|---|
| E1 | VFX module (energy barrier) | — (baseline) | lost 0:5 | self-authored test assertions: **14** vs 24 |
| E2 | VFX (destruction burst) | — (replication) | lost | assertions **12** vs 32; grok 1.5× faster |
| E3 | VFX (cloud parallax) | fairness fixes + *self visual verification* | lost — output didn't read as its subject | root cause traced to the checklist, not the model (below) |
| E5 | exposure flash + hitstop | + `--rules` preamble injection, **contract↔assertion mapping table** (bundle v1) | **won 2:0:1** (grok-vs-grok A/B) | assertions **10 → 42** with the mapping table alone |
| E6 | graze sparks | reference-image injection | **rejected 4:0:1** | references only help for the *same effect type* — otherwise they transplant the wrong visual language |
| E7 | bullet-time system | + quantified depth, self-review pass, max-turns 1200 (bundle v2) | **split: visual axis won** (first visual win of the series), logic axis lost | assertions **67** vs 95 — gap down from 3×+ to 1.4×; wall-clock 2.2× faster |
| E8 | FOV cue system (vs a stronger model) | bundle v2 | split: visual won, code lost | opponent found a defect in *our own spec*; adopted a merge of both |
| E9 | timing-judge state machine | + 4 logic design principles (bundle v3) | lost, but reviewer explicitly credited grok's single-time-axis design | assertions **81**, fastest run of the series (1,112 s) |

Assertion-depth trajectory across the series: **14 → 12 → 10 → 42 → 67 → 81**. That is prompt devices, not fine-tuning.

The E3 lesson deserves its own line. grok self-reported SHIP on all six checklist axes, then lost the blind verdict because the render *didn't read as a cloud*. Every axis it checked was valid — the failure lived outside the checklist. Since making **identity legibility** ("does this read as X? what could it be misread as?") mandatory item #1, grok's self-verdicts started matching the independent blind verdicts — and it went on to win the visual axis twice (E7, E8).

Where the series settled (our production assignment table):

| Task type | Assignment |
|---|---|
| Mechanical edits, FIX rounds, porting, tuning, merge rounds | **grok** — undefeated across the series |
| New visual systems | **grok first draft** (bundle v2) + a blind vision gate; rewrite by Claude after 2 failed FIX rounds |
| Logic cores (state machines, serialization) | stronger model first, or grok draft + Claude review — design-weight tasks stayed a Claude-family win (3 for 3) |
| Verdicts (vision, code review) | **grok** — no self-bias observed; it rejected its own implementations multiple times |

## How it works

| Role | Owner |
|---|---|
| Orchestration, spec writing, diff review, gates, commits | Lead Claude session |
| Code implementation, mechanical edits, numeric harnesses | `grok` CLI (headless) |
| Screenshot / visual verdicts | `grok` CLI (escalate to Claude only if a verdict contradicts instrumentation) |

The core principle: **grok is an executor of tight specs.** It has zero conversation context, so every delegation is a self-contained spec file — file paths, numeric contracts, completion criteria, verification commands — assembled from a shared preamble plus a per-task section, and launched headless in the background.

## Install

### Claude Code plugin marketplace

```
/plugin marketplace add midagedev/claude-grok-skill
/plugin install grok-delegate@claude-grok-skill
```

### Or the install script

```bash
git clone https://github.com/midagedev/claude-grok-skill
cd claude-grok-skill
./install.sh            # user scope: ~/.claude/skills/grok-delegate/
./install.sh --project  # project scope: ./.claude/skills/grok-delegate/
```

Prefer the script if you plan to use a [local overlay](#local-overlay) — the script preserves it across upgrades.

### Prerequisites

- [Claude Code](https://claude.com/claude-code)
- `grok` CLI installed and authenticated (a grok subscription)

Then say "run this via grok" in any Claude Code session, or invoke `/grok-delegate`.

## What's inside

| File | Purpose |
|---|---|
| `skills/grok-delegate/SKILL.md` | The skill: invocation recipe (verified flag combos), git policy profiles, quality bundle, parallel-track isolation, lead review checklist |
| `skills/grok-delegate/references/spec-preamble.md` | Shared rules prepended to every delegated spec — every clause comes from a real incident |
| `skills/grok-delegate/references/spec-template.md` | Per-task spec skeleton: contracts, depth requirements, visual self-verification protocol |

## The quality bundle (summary)

Five devices, each with a measured effect in the table above:

1. **Contract↔assertion mapping table** + FAIL-first evidence — quadrupled self-authored gate depth on its own
2. **Quantified depth** — never "be thorough"; instead "≥2 assertions per contract clause, coverage table, defend discovered defects within your own scope"
3. **Self-review pass** — "list 3 defect classes you may have missed; assert or justify"
4. **Visual self-verification** — grok opens its own captures; checklist item #1 is always identity legibility
5. **Logic design principles** — derive-don't-store · re-normalize on load · 3-class input defense · adversarial API self-review

Standard flags: `--reasoning-effort xhigh --max-turns 1200 --always-approve` + a git policy profile.

## Git policy profiles

A blanket `--deny 'Bash(git *)'` blocks *reads* too — grok can't inspect history, blame, or PRs. Pick per delegation:

1. **strict (default)** — enumerated denies on state-changing subcommands only; `git log/show/diff/blame`, `gh pr list/view` still work. Field-tested: reads pass, `git commit` blocked, HEAD unchanged.
2. **readonly-plus** — the blanket ban, for parallel tracks with tight file boundaries.
3. **trusted** — no denies, **isolated worktree only**, when you want grok making WIP commits at round boundaries. Push/merge stays with the lead.

Glob denies are a safety net, not a proof (`git -C <path> commit` can slip past) — the preamble's git rules stay in the spec as the second layer.

## Local overlay

Project- or user-specific context that doesn't belong in the shared skill (role tables, house gate recipes, model assignment tables, trap-doc lists) goes in `references/local-overlay.md` next to the installed skill. The skill applies it automatically; `install.sh` preserves it across upgrades. This repo never ships one — and if you install via the plugin marketplace, keep your overlay elsewhere and re-copy after updates, since managed plugin dirs can be replaced wholesale.

## Known limits (honestly)

- Exploratory problems that can't be specced (multi-turn cause narrowing) are not delegation material — the lead narrows first.
- Subtle state-machine design didn't fully close even with bundle v3: principles moved the loss to a deeper layer (live-vs-restored dual paths, repair-vs-reject boundaries). Design-weight cores are safer written by Claude and reviewed by grok.
- Reference images only help when they show the same effect type as the task (E6 was rejected 4:0:1 for exactly this).
- grok's reports are largely honest; the risk is what the report *doesn't* say — follow the 8-point lead review checklist in SKILL.md.
- This repo ships Claude Code support only. The SKILL.md format is portable to other agents, but we only publish what we've verified end-to-end.

## License

MIT
