# outsource

**Your Claude session does the thinking. Cheaper model subscriptions do the typing.**

[English](./README.md) | [한국어](./README.ko.md)

A Claude Code skill that runs **third-party model CLIs as headless implementation sub-agents**. The lead Claude session keeps the work where judgment matters — specs, diff review, gates, commits — and outsources implementation, mechanical edits, investigation, and even screenshot verdicts to models whose tokens are effectively free on a subscription:

| Backend | Runs via | Use it for | Hard limit |
|---|---|---|---|
| **GLM-5.3** — the default | z.ai coding plan, driven by `bin/outsource-run.sh` on **either harness** — headless Claude Code (`claude -p`, default) or the `crush` CLI | every spec-able round: implementation, gate authoring, code investigation; honest disclosure | **cannot see images**; style/UI-interaction authoring measured weaker |
| **grok-4.6** — the exception | `grok` CLI | what GLM structurally can't do: **vision verdicts**, image/video generation, web research | escalate to Claude when a verdict contradicts instrumentation |

It's not a wrapper; it's an operating manual with receipts — two measured experiment series, one per backend, are [below](#does-it-actually-work).

Adding a provider is one table row, not a code branch: base URL, credential source, default model, vision capability.

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

You'll need [Claude Code](https://claude.com/claude-code) plus at least one backend: an authenticated `grok` CLI, and/or a z.ai coding-plan key in your `crush` config (the launcher reads the key from there and runs it on headless Claude Code by default — the `crush` CLI itself is only needed for `--harness crush`). Credentials are read at launch time and ride curl's stdin or the process environment; nothing this skill writes ever contains a key.

## Updating

Marketplace: `/plugin marketplace update outsource` then `claude plugin update outsource`. Script installs: `git pull && ./install.sh` — a checksum manifest lets unmodified installs upgrade without flags; hand-edited installs need `--force` (`references/local-overlay.md` always survives).

## Use

Say **"run this via grok"** or **"run this via glm/crush"** in any Claude Code session, or invoke `/outsource`. Claude then:

1. writes a **self-contained spec** — file paths, numeric contracts, verification commands — from the bundled preamble + template (`references/spec-authoring.md` holds the quality bundle that closed the measured quality gap),
2. **lints the spec and checks the plan's quota** before spending anything ([below](#guardrails-before-and-after-the-round)),
3. launches the backend **headless in the background** with its field-tested recipe (`references/grok.md` / `references/glm.md`),
4. **reviews the result like a lead**: reads the diff itself, re-runs the gates cold under its own ownership, and walks an 11-point checklist of the places delegated reports actually leak.

The core principle: **the delegate is an executor of tight specs.** Zero conversation context, so every delegation stands alone — and never asks for taste judgments, only numeric contracts.

## Guardrails, before and after the round

A delegated round fails in ways a human round doesn't: the spec cites a file that moved, the plan runs out of credit halfway, the endpoint quietly answers with a different model. Each of those is now a check with an exit code rather than a paragraph of advice.

**Before launch**

```bash
bin/spec-lint.sh --root <repo> <scratch>/spec.md     # 0 clean · 1 findings
bin/outsource-run.sh --require-quota 15 …            # 66 if the plan is too low
```

- **`spec-lint.sh`** resolves every `path:line` citation and path-shaped reference in the spec and fails on one that doesn't exist or a line past the end of its file. In one measured session five wrong premises (a nonexistent tool, a nonexistent column, an absent fixture, a wrong runner cwd, a wrong manifest path) each burned part of a round before the delegate caught them. A reference that resolves under any plausible base is not flagged, and templates (`<placeholder>`, `$VAR`, globs, URLs) never are — a linter people ignore is worse than none.
- **`--require-quota N`** refuses to start a round the plan can't finish, keyed on the **tightest** window rather than the shortest one (measured: the weekly window sat at 81.7% remaining while the 5-hour sat at 83.8% — the shortest is not the binding one). It fails closed: a gate that can't be evaluated is not a gate that passed.
- The **vision guard** refuses (exit 65) when a spec references an image file and the provider's table row says it can't see images. Capability comes from the table, never a provider-name test at the call site.
- The **git guard** is a `PreToolUse` hook that parses the actual command string — `git -C … commit`, `env … git push`, `sudo git …`, and chained mutations all blocked; read-only git deliberately open. It speaks both hook conventions, so the same file guards the crush and Claude Code harnesses.

**After the round**

- **Model-identity assertion** (exit 70). z.ai maps an unqualified `claude-*` request onto its plan default, so a round can silently run a model you didn't ask for. The launcher reads the model that answered from the per-turn `message.model` in the session transcript — *not* from `modelUsage`, which was measured to echo the **requested** id and therefore can never prove a match. No transcript means "unverifiable", which fails too.
- **A completion sentinel** `<log>.rc` with `rc`, `finished`, `harness`, `provider`, `model_requested`, `model_actual`, `session`. The harness's own lifecycle is not completion proof; this file is.
- **A cost line with the token counts from the log's `usage`** — the only per-round figure worth quoting. The `total_cost_usd` beside it is an Anthropic-priced estimate and is wrong for every provider here.

Plan credits are deliberately *not* reported per round. A plan quota is a plan-wide counter that concurrent rounds and other sessions move too, so a before/after delta around one round measures the machine, not the round (measured: six rounds running at once make every one of their deltas an upper bound). Quota is a **pre-flight** signal — which provider this session should use, and whether to start at all.

`bin/quota.sh` reads it, for either subscription backend:

```
$ quota.sh
z.ai coding plan: level max — GLM Coding Max (status VALID, valid 2026-08-15~09-15)
5h window: 6692/28000 consumed, 21307 remaining, 23% used / 76.1% left, resets at 12:24 (in 3h 46m)  <- tightest
1w window: 27758/140000 consumed, 112241 remaining, 19% used / 80.2% left, resets at 17:52 (in 153h 14m)

$ quota.sh --provider grok
1w window: exact counts not exposed by this API, 98.0% used / 2.0% left, resets at 15:13 (in 6h 36m)
```

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

### A three-way round: Opus 5 vs grok-4.6 vs GLM-5.3, 14 rounds on 5 real tickets

The third series, and the one that changed this skill the most. Five open tickets from a Go + Svelte product (a sync perf bug, a CLI upgrade bug, a new CLI verb, an auth-onboarding bug, a UI ordering bug), each sent to every arm as the **same task spec** in its own git worktree. Fourteen rounds. Every one of them passed `build` / `vet` / the affected suite when the lead re-ran the gates himself.

Because they all passed, the interesting differences are not in the gates.

**Where the arms agreed.** On a stated fact that is simply wrong, everyone catches it. The sync-bug spec carried the reporter's hypothesis ("the watermark window never narrows on a quiet tick") plus one instruction: *don't trust this diagnosis — confirm or refute it with an intervention.* Opus removed the window slack (`overlap 5min → 0`) and the symptom didn't move; grok pushed the watermark an hour past every page so the query matched nothing and got zero fetches. Opposite manipulations, same refutation: the cause was not the watermark but a **missing decision** between a search hit and the body fetch. Both arms then built the same shape of fix — one owner for "does this page need its body?" — instead of tuning the constant.

**Where they split: a contract that could not be satisfied.** The upgrade-bug spec asked for two things that cannot both hold — treat a file carrying `name: gadak` as ours and overwrite it, *and* keep protecting files the user authored. A user who customises our skill keeps that line; it's what makes the skill load. grok **noticed** and wrote it down ("a user who customized the body but left `name: gadak` is treated as ours and overwritten") and implemented it as specified anyway. Both GLM arms did the same without noticing. Opus refused the rule, argued why the two clauses are jointly unsatisfiable, and designed around it (an install receipt with a content hash, plus a deliberately *frozen* digest table for pre-receipt installs, with a test asserting it stays frozen).

The same shape repeated on the auth ticket, where the contract asked to distinguish three failure cases the available evidence cannot distinguish. All three arms reached that conclusion. Opus classified the one case that *is* distinguishable, flagged the rest as a partial miss, and put a self-check in the message; the GLM arms concatenated every hint into every error — which satisfies the letter of "show the user a string" while quietly failing the contract's point.

So: **a wrong fact gets caught by everyone; an impossible requirement gets caught by one.** The failure mode is not a red gate, it's a green one with an unnamed gap — the most expensive kind to review, because the lead reads the diff but cannot see an omission that was never mentioned.

Three of the four spec defects in this series were the lead's own, and the delegates found them. One was a negative claim ("this file does not exist") that came from a two-pattern `ls` in zsh: the second glob matched nothing, aborted the command, and printed nothing — so an existing file went into a spec as absent. That is now a lead-checklist item, next to the `tail` trap.

### Does the preamble earn its length? (the same 5 tickets, GLM-5.3, full vs none)

A controlled A/B inside the series: same task spec, same model, same harness, the shared preamble either prepended or omitted entirely.

| Ticket | output tokens, none ÷ full | input tokens, full → none |
|---|---|---|
| new CLI verb | 0.63× | 298k → 139k |
| sync perf | 0.78× | 146k → 112k |
| UI ordering | 0.84× | 107k → 95k |
| auth onboarding | 0.86× | 166k → 96k |
| CLI upgrade | 0.94× | 81k → 78k |

Cheaper in all five, fewer turns in four, and **not once worse on a gate**. On the sync bug the no-preamble arm even caught a second-order trap grok missed (a page skipped by the new gate must still be reachable by the comments-only pass) and wrote the regression test for it.

But the cost isn't where the preamble was earning its keep:

| | full preamble | no preamble |
|---|---|---|
| FAIL-first evidence | 5/5 | **5/5** |
| self-verification section | 5/5 | **0/5** |
| "what I could not do" | 5/5 | **1/5** |

FAIL-first survives without the preamble because the *task spec* demands it. What disappears is disclosure — and that is exactly how the auth round came back looking complete when it wasn't. So the preamble was buying honest reporting, not better code.

Hence `references/spec-preamble-core.md`: the short file carries back precisely the part that vanished, and nothing else. The full preamble stays for rounds touching shared code or a contract you're unsure is satisfiable.

Two things this experiment did **not** establish: which individual sections of the full preamble are dead weight (only all-or-nothing was measured), and any per-round cost in plan credits — a plan quota is a plan-wide counter that concurrent rounds move too, so those numbers were discarded as uninterpretable.

**The honest summary across all three series:** a cheap backend is a trustworthy implementation arm **when the spec writes the contract down**; the losses live in the judgment the spec leaves open — and the sharpest version of that is a contract which cannot be satisfied at all. That is why most of this repo is spec-authoring material, and why the lead checklist now includes reading your own spec for clauses that fight each other.

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
| `references/glm.md` | GLM-5.3 backend: harness picker, per-harness quirks, the z.ai model-mapping trap, measured behavior profile |
| `references/spec-preamble.md` | Shared rules prepended to every spec — every clause from a real incident |
| `references/spec-preamble-core.md` | The short substitute: the disclosure half, which is the part measured to vanish without it |
| `references/glm-preamble.md` | GLM runtime delta (no images, hooks not flags, evidence rules §6–§11) |
| `references/spec-authoring.md` | The quality bundle, the per-task template walkthrough, lead-side spec checks |
| `references/spec-template.md` | Per-task spec skeleton: contracts, depth requirements, verification commands |
| `bin/outsource-run.sh` | The launcher: provider table, harness picker (`--harness claude-code\|crush`), isolated config per track, session resume, vision/quota guards, model-identity assertion, completion sentinel |
| `bin/git-guard.sh` | The git-ban `PreToolUse` hook, one file for both harnesses' calling conventions (29 regression cases) |
| `bin/spec-lint.sh` | Pre-launch spec check: unresolvable paths and out-of-range `path:line` citations |
| `bin/quota.sh` | Plan quota for `zai` and `grok` — a pre-flight signal, human or `--json`, with `--require-window` as a gate |
| `scripts/grok-progress.py` · `scripts/grok-round-status.py` | Compress a grok NDJSON stream into one-line progress events; judge round state by sentinel |

Safety default on both backends: repository-state git stays with the lead — grok via enumerated deny-profiles, GLM via the command-string hook above.

## Local overlay

Project- or user-specific context (role tables, default-backend choice, house gate recipes, model assignments) goes in `references/local-overlay.md` next to the installed skill — applied automatically, preserved by `install.sh` across upgrades, never shipped by this repo.

## Known limits

- Exploratory problems that can't be specced aren't delegation material — the lead narrows first.
- Design-weight logic didn't fully close even with bundle v3; write those with Claude, review with a backend.
- GLM-5.3 cannot read images, full stop — and (measured) it says so instead of guessing.
- z.ai's Anthropic-compatible endpoint silently maps an unqualified `claude-*` request onto its plan default (measured: glm-4.7). The launcher pins the model and asserts what answered, but the assertion needs the session transcript — `modelUsage` in the log echoes the *requested* id and proves nothing.
- Plan quota is readable for the two subscription backends only. Claude and pay-per-token API keys expose no window to check, so there is nothing to gate on there.
- Grok exposes a percentage but no credit counts, so a grok round's price is a percentage delta, not a number of credits.
- Reports are largely honest on both backends; the risk is what they *don't* say — hence the lead review checklist.
- Claude Code only for now. The SKILL.md format is portable, but we publish only what we've verified end-to-end.

## License

MIT
