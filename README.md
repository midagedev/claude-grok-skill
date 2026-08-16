# outsource

**Your Claude session does the thinking. Cheaper model subscriptions do the typing.**

[English](./README.md) | [한국어](./README.ko.md)

A Claude Code skill that runs **third-party model CLIs as headless implementation sub-agents**. The lead Claude session keeps the work where judgment matters — specs, diff review, gates, commits — and outsources implementation, mechanical edits, investigation, and screenshot verdicts to models whose tokens are effectively free on a subscription.

It is not a wrapper. It is an operating manual with receipts: every rule in it came from a measured round, and the [comparison below](#the-three-models) is how the rules were found.

| Backend | Runs via | Use it for | Hard limit |
|---|---|---|---|
| **GLM-5.3** — the default | [z.ai coding plan](https://z.ai/subscribe), driven by `bin/outsource-run.sh` on **either harness** — headless Claude Code (`claude -p`, default) or the `crush` CLI | every spec-able round: implementation, gate authoring, code investigation | **cannot see images**; does not flag a contract it cannot satisfy |
| **grok-4.6** — the exception | `grok` CLI | what GLM structurally can't do: **vision verdicts**, image/video generation, web research | notices a hazard and implements it anyway unless the spec forbids it |

Adding a provider is one table row — base URL, default model, vision capability — plus its key resolution in `bin/credential.sh`. Two places, both single-owner, no code branch.

## Install

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

You need [Claude Code](https://claude.com/claude-code) plus at least one backend: an authenticated `grok` CLI, and/or a z.ai coding-plan key.

Set the key once — this prompts, verifies it against z.ai before storing, and writes `~/.config/outsource/credentials` at mode 0600:

```bash
~/.claude/skills/outsource/bin/setup-key.sh zai
```

`export ZAI_API_KEY=…` always takes precedence, and if you already use the `crush` CLI or z.ai's official Claude Code helper, your existing key is discovered automatically — nothing to do. `bin/credential.sh` is the single owner of that resolution; the launcher never prompts, because it runs headless in the background where a prompt would hang a round instead of failing it. The `crush` CLI itself is only needed for `--harness crush`.

> **Referral link — disclosed.** If you don't have the z.ai plan yet, this **referral** link gives you 10% off and credits this project: **https://z.ai/subscribe?ic=P7NR6BGEGL** (referral code `P7NR6BGEGL`).
>
> It is the only referral link in this repository, and it is never used anywhere it isn't labelled as one — every other z.ai link here goes to the plain https://z.ai/subscribe. Using it is entirely optional; the skill works identically either way.

**Updating.** Marketplace: `/plugin marketplace update outsource`, then `claude plugin update outsource`. Script installs: `git pull && ./install.sh` — a checksum manifest lets unmodified installs upgrade without flags; hand-edited installs need `--force` (`references/local-overlay.md` always survives).

## Use

Say **"run this via glm"** or **"run this via grok"** in any Claude Code session, or invoke `/outsource`. Claude then:

1. writes a **self-contained spec** — file paths, numeric contracts, verification commands,
2. **lints the spec and checks the plan's quota** before spending anything,
3. launches the backend **headless in the background**,
4. **reviews the result like a lead**: reads the diff itself, re-runs the gates cold, walks a checklist of the places delegated reports actually leak.

The core principle: **the delegate is an executor of tight specs.** It has zero conversation context, so every delegation stands alone — and it is never asked for taste judgments, only numeric contracts.

## The three models

Fourteen rounds, five real tickets from a Go + Svelte product, each ticket sent to every arm as the **same task spec** in its own git worktree.

**All fourteen passed `build` / `vet` / the affected suite when the lead re-ran the gates himself.** That is the finding that matters most: on ordinary work, the gates do not separate these models. Everything below lives outside the gates.

| | **Opus 5** | **grok-4.6** | **GLM-5.3** |
|---|---|---|---|
| Wrong *fact* in the spec | catches it | catches it | catches it |
| Contract that **cannot be satisfied** | refuses, argues why, redesigns | **notices, then implements it anyway** | doesn't notice |
| Evidence it cannot obtain | names what's undecidable, flags a partial miss | — | produces a plausible-looking answer instead |
| Second-order effects | finds them unprompted | missed one the GLM arm caught | caught one grok missed |
| Reads images | yes | **yes — the only cheap arm that does** | **no, at all** (`supports_attachments: false`) |
| Self-verification / disclosure | unprompted | with the preamble | **only with the preamble** |
| Relative cost | highest | subscription | **lowest** |

Two of those cells decide the routing. **GLM cannot see pixels**, so vision verdicts and image generation go to grok. **Neither cheap arm reliably stops at an impossible contract**, so that judgment stays with the lead — or with a Claude agent when the round is design-weight.

### How we found out

The method is the point, because "which model is better" is not answerable without one.

- **Same spec, isolated worktrees.** Every arm gets a byte-identical task spec and its own `git worktree`, so nothing is confounded by phrasing or by arms colliding.
- **The lead re-runs every gate.** A delegate's green is not evidence. When all fourteen came back green under the lead's own runs, the comparison moved to the reports and the diffs.
- **Seeded spec defects.** Specs carried the reporter's hypothesis plus one line: *don't trust this diagnosis — confirm or refute it with an intervention.* One spec also happened to contain two clauses that cannot both hold; that accident turned out to be the sharpest discriminator in the series.
- **A/B with one variable.** The preamble question was answered by sending the same spec to the same model on the same harness, with the preamble and without it.

<details>
<summary><b>The intervention experiment</b> — why "I changed it and the symptom went away" is not a diagnosis</summary>

A sync tick spent **19.4 s of 21.4 s** re-reading 71 unchanged Confluence pages. The spec carried the reporter's hypothesis: *"the watermark window never narrows on a quiet tick."*

| | Manipulation | Result | What it settles |
|---|---|---|---|
| **Opus 5** | **removed** the window slack (`overlap 5min → 0`) | still **6/6 bodies** re-read | the slack is **not** the cause — no constant can close this |
| **grok-4.6** | pushed the watermark **1 h past** every page, so the query matched nothing | **0 body fetches** | an empty match is already free — "stalled floor → full backfill" is false |

Opposite manipulations, same refutation. The cause was neither: there was simply **no decision between a search hit and the body fetch**, and minute-granularity CQL re-matches the same cluster forever. Both arms then built the same shape of fix — one owner for "does this page need its body?" — instead of tuning a constant.

The asymmetry is why that line is in the spec at all: making a suspected cause *false* and watching the symptom **stay** refutes it. Watching a symptom disappear proves nothing, because it may only be masked.

(The 6/6 is the test fixture; the 71 pages is the production measurement.)

</details>

<details>
<summary><b>The contract that could not be satisfied</b> — the one place the arms genuinely split</summary>

One ticket asked for two things at once: treat a file carrying `name: gadak` as ours and overwrite it, **and** keep protecting files the user authored. A user who customises our skill keeps that line — it is what makes the skill load — so the two clauses are jointly unsatisfiable.

- **grok** noticed and wrote it down — *"a user who customized the body but left `name: gadak` is treated as ours and overwritten"* — and implemented it as specified anyway.
- **Both GLM arms** implemented it without noticing.
- **Opus** refused, argued why, and designed around it: an install receipt with a content hash, plus a deliberately **frozen** digest table for pre-receipt installs, with a test asserting it stays frozen.

Three of four arms shipped a data-loss bug **with every gate green**. That is the failure mode this skill now spends the most effort on: not a red gate, but a green one with a gap nobody named.

The same shape repeated on an auth ticket whose contract asked to distinguish three failure cases the available evidence cannot distinguish. All three arms reached that conclusion; only Opus said so, classifying the one case that *is* decidable and flagging the rest as a partial miss. The GLM arms concatenated every hint into every error — satisfying the letter of "show the user a string" while quietly failing its point.

</details>

<details>
<summary><b>Does the preamble earn its length?</b> — same five tickets, GLM-5.3, full preamble vs none</summary>

| Ticket | output tokens, none ÷ full | input tokens, full → none |
|---|---|---|
| new CLI verb | 0.63× | 298k → 139k |
| sync perf | 0.78× | 146k → 112k |
| UI ordering | 0.84× | 107k → 95k |
| auth onboarding | 0.86× | 166k → 96k |
| CLI upgrade | 0.94× | 81k → 78k |

Cheaper in all five, fewer turns in four, **never worse on a gate**. On the sync bug the no-preamble arm even caught a second-order trap the grok arm missed (a page skipped by the new gate must still be reachable by the comments-only pass) and wrote the regression test for it.

But the cost was not where the preamble was earning its keep:

| | full preamble | no preamble |
|---|---|---|
| FAIL-first evidence | 5/5 | **5/5** |
| self-verification section | 5/5 | **0/5** |
| "what I could not do" | 5/5 | **1/5** |

FAIL-first survives without the preamble because the *task spec* demands it. What disappears is disclosure — which is exactly how the auth round came back looking complete when it wasn't.

**Not established, and not claimed:** which individual sections of the full preamble are dead weight. Only all-or-nothing was measured.

</details>

### How each weakness was closed

Every row is a mechanism with an exit code, not advice in a document.

| Weakness found | What now stops it |
|---|---|
| GLM cannot see images, but a spec might hand it a screenshot | **Vision guard, exit 65** — driven by the provider table's capability column, never a provider-name test at the call site. `--no-vision-check` overrides. |
| z.ai silently answers an unqualified `claude-*` request as its plan default | **Model-identity assertion, exit 70** — read from the per-turn `message.model` in the session transcript. *Not* from `modelUsage`, which was measured to echo the **requested** id and so can never prove a match. No transcript means "unverifiable", which also fails. |
| A cheap arm doesn't stop at an unsatisfiable contract | **A lead checklist item, before launch.** The delegate-side rule for this already existed in the preamble and did **not** fire, so it moved to the lead rather than becoming more prose. |
| Without the preamble, disclosure vanishes | **`references/spec-preamble-core.md`** — the short substitute carrying back exactly the half that vanished, and nothing else. |
| Specs carry wrong premises (five in one session — a nonexistent tool, a nonexistent column, an absent fixture, a wrong runner cwd, a wrong manifest path) | **`bin/spec-lint.sh`**, before launch: every `path:line` citation and path-shaped reference resolved, exit 1 on a miss. Bare filenames only when they carry a `:line`; anything resolving under any plausible base is not flagged, because a linter people ignore is worse than none. |
| A negative premise ("this file does not exist") that a linter can't check | **Lead checklist: verify absence one path at a time.** A two-pattern `ls` in zsh printed nothing because the *second* glob matched nothing and aborted the command — so a file that exists went into a spec as absent. |
| grok blocked from producing its own required evidence | **Per-subcommand git denies.** A blanket `git worktree*` also blocked `git worktree list`, which every spec asks for as the first line of the report. |
| The plan runs dry mid-round | **`--require-quota N`, exit 66** — keyed on the **tightest** window, not the shortest (measured: weekly at 81.7% remaining while the 5-hour sat at 83.8%). Fails closed. |
| A delegate reports "done" that isn't | **Completion sentinel `<log>.rc`** with `rc`, `finished`, `harness`, `provider`, `model_requested`, `model_actual`, `session`. The harness's own lifecycle is not completion proof. |
| Repository-state git from a delegate | **`bin/git-guard.sh`**, a `PreToolUse` hook parsing the real command string — `git -C … commit`, `env … git push`, `sudo git …`, chained mutations all blocked; read-only git deliberately open. One file, both harnesses' calling conventions. |

<details>
<summary><b>Earlier series</b> — 9 blind-judged grok rounds, and three shipped GLM rounds + an A/B</summary>

**grok-4.6, nine blind-judged rounds vs Opus 5 / Fable 5.** Each round: implement a module *and author its own verification gate* in a Three.js/WebGPU project, judged blind with labels swapped.

- Baseline: clear loss, 0:5 — grok wrote 14 test assertions where Opus wrote 24.
- With the quality bundle the gap closed where it matters: assertion depth 14 → 42 → 67 → **81**; the visual axis flipped to grok in the last two rounds; grok ran 2–4× faster throughout.
- What stayed hard: design-weight logic cores (state machines, serialization) stayed with the Claude side all three times tested.
- Best finding: grok's blind losses were mostly **missing defaults, not missing capability** — and defaults can be written into a spec.

| Exp | Task | Device added | Verdict | Measured |
|---|---|---|---|---|
| E1 | hit ripple + rim shader with a numeric gate | — (baseline) | lost 0:5 | assertions 14 vs 24 |
| E2 | debris burst + flash timing | — (replication) | lost | assertions 12 vs 32; 1.5× faster |
| E3 | 3-plane parallax cloud billboards | fairness + self visual verification | lost — didn't read as clouds | failure traced to the checklist |
| E5 | exposure flash + hitstop | contract↔assertion mapping table | **won 2:0:1** | assertions 10 → 42 |
| E6 | near-miss graze sparks | reference-image injection (A/B) | **injection rejected 4:0:1** | references help only same-effect |
| E7 | timeScale state machine + cel clock motif | quantified depth, self-review | **split: visual won**, logic lost | assertions 67 vs 95; 2.2× faster |
| E8 | camera FOV ladder | v2, vs Fable 5 | split | Fable caught a defect in *our own spec* |
| E9 | QTE hit windows + combo state machine | 4 logic design principles | lost; design credited | assertions 81; fastest run |

**GLM-5.3, three shipped solo rounds and a same-spec A/B vs an Opus subagent.** A CLI/MCP warning feature, a store-level schema-divergence repair with a FAIL-first test, and a docs-contract CI gate — each landed on main after lead review with no rework, and GLM corrected five wrong premises in the lead's own specs along the way. In the A/B (N=3) both arms independently chose the same shared utility and independently invented the same AST-based test workaround; the Opus arm won all three artifact picks, on second-order state interactions, evidence strength, and naming the failure modes a script's options handle. Each of those three became a spec rule here.

</details>

## Guardrails

**Before launch**

```bash
bin/spec-lint.sh --root <repo> <scratch>/spec.md     # 0 clean · 1 findings
bin/outsource-run.sh --require-quota 15 …            # 66 if the plan is too low
```

**After the round** — the model-identity assertion (exit 70), the completion sentinel, and a cost line carrying the round's token counts from the log's `usage`. The `total_cost_usd` beside them is Anthropic-priced and wrong for every provider here.

Plan credits are deliberately **not** reported per round: a plan quota is a plan-wide counter that concurrent rounds and other sessions move too, so a before/after delta around one round measures the machine, not the round. Quota is a pre-flight signal — which provider this session should use, and whether to start at all.

```
$ bin/quota.sh
z.ai coding plan: level max — GLM Coding Max (status VALID, valid 2026-08-15~09-15)
5h window: 6692/28000 consumed, 21307 remaining, 23% used / 76.1% left, resets at 12:24 (in 3h 46m)  <- tightest
1w window: 27758/140000 consumed, 112241 remaining, 19% used / 80.2% left, resets at 17:52 (in 153h 14m)

$ bin/quota.sh --provider grok
1w window: exact counts not exposed by this API, 98.0% used / 2.0% left, resets at 15:13 (in 6h 36m)
```

## What's inside

| File | Purpose |
|---|---|
| `skills/outsource/SKILL.md` | The router: backend table, spec assembly, lead review checklist |
| `references/grok.md` · `references/glm.md` | Per-backend operating manuals: flags, git-safety profiles, harness quirks, measured behavior |
| `references/spec-preamble.md` | Shared rules prepended to every spec — every clause from a real incident |
| `references/spec-preamble-core.md` | The short substitute: the disclosure half, measured to vanish without it |
| `references/glm-preamble.md` | GLM runtime delta (no images, hooks not flags, evidence rules) |
| `references/spec-authoring.md` · `references/spec-template.md` | The quality bundle, and the per-task spec skeleton |
| `bin/outsource-run.sh` | The launcher: provider table, harness picker, isolated config per track, session resume, vision/quota guards, model-identity assertion, completion sentinel |
| `bin/git-guard.sh` | The git-ban `PreToolUse` hook, one file for both harnesses (29 regression cases) |
| `bin/credential.sh` · `bin/setup-key.sh` | The single owner of key resolution (env var → this skill's 0600 store → discovery), and its interactive half |
| `bin/spec-lint.sh` · `bin/quota.sh` | Pre-launch spec check; plan quota with `--require-window` as a gate |
| `scripts/grok-progress.py` · `scripts/grok-round-status.py` | Compress a grok NDJSON stream into progress events; judge round state by sentinel |

## The quality bundle

What closed the measured quality gap, each device with an effect behind it:

1. **Contract↔assertion mapping table** + FAIL-first evidence — quadrupled self-authored test depth on its own
2. **Quantified depth** — never "be thorough"; instead "≥2 assertions per contract clause, coverage table"
3. **Self-review pass** — "list 3 defect classes you may have missed; assert or justify"
4. **Visual self-verification** — the implementer opens its own captures; item #1 is always *identity legibility*
5. **Logic design principles** — derive-don't-store · re-normalize on load · 3-class input defense
6. **Evidence rules** — verify from a cold start and compare test counts with CI; every number carries the command that produced it; the recurrence layer lands as a file, not a sentence

## Local overlay

Project- or user-specific context (role tables, default-backend choice, house gate recipes) goes in `references/local-overlay.md` next to the installed skill — applied automatically, preserved by `install.sh` across upgrades, never shipped by this repo.

## Known limits

- Exploratory problems that can't be specced aren't delegation material — the lead narrows first.
- Design-weight logic didn't fully close even with bundle v3; write those with Claude, review with a backend.
- GLM-5.3 cannot read images, full stop — and, measured, it says so instead of guessing.
- Neither cheap arm reliably stops at a contract it cannot satisfy. That check is the lead's.
- Plan quota is readable for the two subscription backends only; pay-per-token API keys expose no window to gate on.
- Claude Code only for now. The SKILL.md format is portable, but we publish only what we've verified end to end.

## License

MIT
