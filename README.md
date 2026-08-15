# outsource

**Your Claude session does the thinking. Cheaper model subscriptions do the typing.**

[English](./README.md) | [한국어](./README.ko.md)

A Claude Code skill that runs **third-party model CLIs as headless implementation sub-agents**. The lead Claude session keeps the work where judgment matters — specs, diff review, gates, commits — and outsources implementation, mechanical edits, investigation, and even screenshot verdicts to models whose tokens are effectively free on a subscription:

| Backend | Runs via | Good at | Hard limit |
|---|---|---|---|
| **grok-4.6** | `grok` CLI | implementation, web research, **vision verdicts**, image/video generation | escalate to Claude when a verdict contradicts instrumentation |
| **GLM-5.3** | z.ai coding plan, through the `crush` CLI (`bin/glm-run.sh`) | implementation, gate authoring, code investigation, honest disclosure | **cannot see images**; style/UI-interaction authoring measured weaker |

It's not a wrapper; it's an operating manual with receipts — two measured experiment series, one per backend, are [below](#does-it-actually-work).

## Install

From the plugin marketplace:

```
/plugin marketplace add midagedev/outsource
/plugin install outsource@outsource
```

Or with the install script (preferred if you'll use a [local overlay](#local-overlay)):

```bash
git clone https://github.com/midagedev/outsource
cd outsource
./install.sh            # user scope: ~/.claude/skills/outsource/
./install.sh --project  # project scope: ./.claude/skills/outsource/
```

You'll need [Claude Code](https://claude.com/claude-code) plus at least one backend: an authenticated `grok` CLI, and/or the `crush` CLI configured with a `zai` provider key.

## Updating

Marketplace: `/plugin marketplace update outsource` then `claude plugin update outsource`. Script installs: `git pull && ./install.sh` — a checksum manifest lets unmodified installs upgrade without flags; hand-edited installs need `--force` (`references/local-overlay.md` always survives).

## Use

Say **"run this via grok"** or **"run this via glm/crush"** in any Claude Code session, or invoke `/outsource`. Claude then:

1. writes a **self-contained spec** — file paths, numeric contracts, verification commands — from the bundled preamble + template (`references/spec-authoring.md` holds the quality bundle that closed the measured quality gap),
2. launches the backend **headless in the background** with its field-tested recipe (`references/grok.md` / `references/glm.md`) — git safety enforced by deny-profiles on grok and by a `PreToolUse` command-string guard on crush (29 regression cases),
3. **reviews the result like a lead**: reads the diff itself, re-runs the gates cold under its own ownership, and walks an 11-point checklist of the places delegated reports actually leak.

The core principle: **the delegate is an executor of tight specs.** Zero conversation context, so every delegation stands alone — and never asks for taste judgments, only numeric contracts.

## The quality bundle

What actually closed the quality gap, each device with a measured effect:

1. **Contract↔assertion mapping table** + FAIL-first evidence — quadrupled self-authored test depth on its own
2. **Quantified depth** — never "be thorough"; instead "≥2 assertions per contract clause, coverage table, defend discovered defects within your own scope"
3. **Self-review pass** — "list 3 defect classes you may have missed; assert or justify"
4. **Visual self-verification** — the implementer opens its own captures; checklist item #1 is always *identity legibility* ("does this read as X? what could it be misread as?")
5. **Logic design principles** — derive-don't-store · re-normalize on load · 3-class input defense · adversarial API self-review
6. **Evidence rules** (added after the GLM rounds) — verify from a cold start and compare test counts with CI; every number carries the command that produced it; the recurrence layer lands as a file, not a sentence; artifact/code divergence gets a detector

## Does it actually work?

Two measured series, one per backend. Same method both times: **the same spec** goes to the outsourced backend and to a frontier Claude model in parallel git worktrees, on real production work, judged blind or lead-reviewed line by line.

### grok-4.6 — 9 blind-judged rounds vs Opus 5 / Fable 5

Each round: implement a module *and author its own verification gate* in a Three.js/WebGPU project. Outputs judged **blind** — unlabeled sources, labels swapped every round.

- **Baseline: clear loss.** 0:5 blind verdict; grok wrote 14 test assertions where Opus 5 wrote 24.
- **With the bundle: the gap closed where it matters.** Assertion depth 14 → 42 → 67 → **81**; the visual axis flipped to grok wins in the last two rounds (once over Opus 5, once over Fable 5); grok ran 2–4× faster throughout.
- **What stayed hard:** design-weight logic cores (state machines, serialization) stayed with the Claude side all three times tested.
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

</details>

### GLM-5.3 — three shipped solo rounds, then a same-spec A/B vs an Opus subagent

Different repo (a Go + Svelte product with gated CI), different method: no blind panel — the lead reviewed every diff line by line and re-ran every gate cold.

- **Three solo rounds, all shipped**: a CLI/MCP warning feature, a store-level schema-divergence repair with a FAIL-first test, and a docs-contract CI gate — each landed on main after lead review with no rework. Along the way GLM corrected five wrong premises in the leads' own specs (a nonexistent tool, a nonexistent column, a wrong working directory among them).
- **Same-spec A/B (N=3: a web UI touch-bug fix, a self-verifying promises doc, ecosystem shell scripts).** Parity where it surprised us: both arms independently chose the same shared popover utility, independently invented the **same AST-based test workaround** when the unit harness couldn't mount components, caught the same spec-premise errors, and produced FAIL-first evidence unprompted.
- **The Opus arm won all three artifact picks**, each on a describable gap — and each gap became a spec rule in this skill:
  1. **Second-order state interactions.** GLM left two popovers able to occupy the same slot and Escape doing two things at once; Opus arbitrated the slot and the key order. → UI specs must enumerate what else occupies the same space/keys and demand a precedence decision.
  2. **Evidence strength.** GLM proved claims with greps plus a prose comment where a focused `go test -run` existed; Opus ran the tests, narrowed two claims its commands couldn't prove, and deliberately omitted one unprovable promise. → prefer invoking an existing test over a grep; a comment inside a command block must not carry the claim.
  3. **Silent hazard avoidance.** GLM's `sh`/`set -eu` choice happened to dodge a SIGPIPE failure mode that Opus measured (nondeterministic exit 141 under `pipefail`) and designed around — luck and judgment are indistinguishable in review. → robustness-sensitive scripts must name the failure modes their options handle.
- GLM's own wins inside those rounds: it dug up a documented `GADAK_NO_OPEN`-style env var the Opus arm missed and used it for an unmodified end-to-end smoke, and its FAIL-first proof ran in **both directions** (add *and* remove).

**The honest summary across both series:** a cheap backend is a trustworthy implementation arm **when the spec writes the contract down**; the losses live in the judgment the spec leaves open. That is why most of this repo is spec-authoring material.

Where it settled (our production assignment table):

| Task type | Assignment |
|---|---|
| Mechanical edits, FIX rounds, porting, tuning, gate authoring, investigation | **outsourced backend** |
| New visual systems | outsourced first draft + blind vision gate; Claude rewrite after 2 failed FIXes |
| Style / look / UI-interaction authoring | Claude (A/B-measured) |
| Logic cores (state machines, serialization) | Claude first, backend reviews |
| Verdicts (vision, code review) | grok — rejected its own implementations multiple times; no self-bias observed |

## What's inside

| File | Purpose |
|---|---|
| `skills/outsource/SKILL.md` | The router: backend table, spec assembly, lead review checklist |
| `references/grok.md` | grok backend: flag combo, git-safety profiles, sentinel completion proof, vision-verdict recipe, image generation, visibility/intervention |
| `references/glm.md` | GLM-5.3 backend: `glm-run.sh` launcher, crush-harness quirks, measured behavior profile |
| `references/spec-preamble.md` | Shared rules prepended to every spec — every clause from a real incident |
| `references/glm-preamble.md` | GLM runtime delta (no images, hooks not flags, evidence rules §6–§11) |
| `references/spec-authoring.md` | The quality bundle, the per-task template walkthrough, lead-side spec checks |
| `references/spec-template.md` | Per-task spec skeleton: contracts, depth requirements, verification commands |
| `bin/glm-run.sh` · `bin/git-guard.sh` | GLM launcher (isolated config, session resume) and the git-ban hook (29 regression cases) |
| `scripts/grok-progress.py` · `scripts/grok-round-status.py` | Compress a grok NDJSON stream into one-line progress events; judge round state by sentinel |

Safety default on both backends: repository-state git stays with the lead — grok via enumerated deny-profiles, GLM via a hook that parses the actual command string (`git -C … commit`, `env … git push`, `sudo git …` and chained mutations all blocked; read-only git deliberately open).

## Local overlay

Project- or user-specific context (role tables, default-backend choice, house gate recipes, model assignments) goes in `references/local-overlay.md` next to the installed skill — applied automatically, preserved by `install.sh` across upgrades, never shipped by this repo.

## Known limits

- Exploratory problems that can't be specced aren't delegation material — the lead narrows first.
- Design-weight logic didn't fully close even with bundle v3; write those with Claude, review with a backend.
- GLM-5.3 cannot read images, full stop — and (measured) it says so instead of guessing.
- Reports are largely honest on both backends; the risk is what they *don't* say — hence the lead review checklist.
- Claude Code only for now. The SKILL.md format is portable, but we publish only what we've verified end-to-end.

## License

MIT
