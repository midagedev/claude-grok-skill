---
name: outsource
description: >
  Outsource implementation, investigation/research, numeric harnesses and
  vision-verdict work to third-party model CLIs running as headless
  sub-agents — the grok CLI (grok-4.6) and GLM-5.3 (z.ai coding plan, run
  through headless Claude Code or the crush CLI) — while the lead Claude
  session stays orchestration-only. Use when the user asks to run work via
  grok / glm / crush, to save tokens, or invokes /outsource. Pick the backend by task: GLM-5.3 cannot
  read images, so vision verdicts go to grok (or a Claude agent).
---

# outsource — third-party models as headless implementation sub-agents

Division of labor, whatever the backend:

| Role | Owner |
|------|-------|
| Orchestration, spec writing, diff review, gates, commits, deploys | Lead session (Claude) |
| Implementation, mechanical edits, numeric harnesses, investigation, report writing | Outsourced backend (below) |

Core principle: **the delegate is an executor of tight specs.** It has zero
conversation context, so the spec must be self-contained (file paths,
contracts, completion criteria) and must never ask for taste judgments —
only numeric contracts.

## Backends — GLM-5.3 by default, grok when the task needs eyes

| Backend | Runs via | Use it for | Hard limits |
|---|---|---|---|
| **GLM-5.3** — the default | z.ai coding plan, via `bin/outsource-run.sh` on either harness — `claude -p` (default) or the `crush` CLI (`references/glm.md`) | **every spec-able round**: implementation, mechanical edits, gate authoring, code investigation, reports. Strong disclosure and premise-correction | **cannot see images at all**; style/look/UI-interaction authoring measured weaker — route those elsewhere |
| **grok-4.6** — the exception | `grok` CLI, headless (`references/grok.md`) | what GLM structurally cannot do: **vision verdicts** and image reading, image/video generation, and web research when GLM's harness lacks the tool | verdicts contradicting instrumentation escalate to a Claude agent |

Selection rules:

- **Default to GLM-5.3.** Reach for grok when the task needs eyes (pixels,
  framing, colour), pixels generated (image/video), or a web tool the GLM
  harness does not have. "It feels exploratory" is not a reason — narrow the
  cause first, then delegate (see *When NOT to outsource*).
- Anything that must **look at pixels** → grok or a Claude agent; never
  GLM-5.3. This is a capability fact, not a preference: the model reports
  `supports_attachments: false`.
- Both backends parallelize: disjoint file whitelists, one worktree and one
  config/session scope per track. Spreading tracks across the two providers —
  and, for GLM, across its two harnesses — multiplies headroom.
- **Model vs harness are separate choices.** The harness is only how a model
  is driven headlessly; the same spec, preamble and review checklist apply
  whichever one runs. GLM-5.3 ships with two (`--harness claude-code|crush`);
  pin the model explicitly, because z.ai maps an unqualified `claude-*`
  request onto its plan default (measured: glm-4.7).
- Site-local defaults (which backend is *your* default, model overrides)
  belong in `references/local-overlay.md`, not here.

## Spec assembly (every delegation)

```bash
cat <skill-dir>/references/spec-preamble.md \      # shared rules — every clause from a real incident
    <skill-dir>/references/glm-preamble.md \       # GLM runs only: the runtime delta
    <skill-dir>/references/local-overlay.md \      # if it exists
    <scratch>/task.md > <scratch>/spec.md
```

Write the per-task spec from `references/spec-template.md`, and read
`references/spec-authoring.md` before writing it — the quality bundle and
the lead-side checks there are where delegated quality is actually won.

**Lint the assembled spec before launching it:**

```bash
<skill-dir>/bin/spec-lint.sh --root <repo> <scratch>/spec.md
```

It resolves every `path:line` citation and every path-shaped reference, and
exits 1 on one that does not exist or a line number past the end of its
file. Wrong premises are the measured tax on delegation — in one session
five of them (a nonexistent tool, a nonexistent column, an absent fixture,
a wrong runner cwd, a wrong manifest path) each cost part of a round. The
delegate catches them, but only after it has started.

Then invoke the backend exactly as its reference describes:

- grok: `references/grok.md` — flag combo, git-safety profiles, sentinel
  completion proof, vision-verdict recipe, image generation, mid-round
  visibility and intervention.
- GLM-5.3: `references/glm.md` — `bin/outsource-run.sh` launcher (provider
  table, harness picker, isolated config per track, `SESSION <id>` resume,
  `--require-quota` pre-flight gate, model-identity assertion, `<log>.rc`
  sentinel), `bin/git-guard.sh` PreToolUse hook (works on both harnesses),
  z.ai model-mapping trap, measured behavior profile.

## What the lead always does (backend-independent)

1. **Delegate "done" ≠ done.** Read `git diff` yourself and re-run the
   affected gates under your own ownership. Verify by the tree and the
   spec's completion marker (`DONE-<track>`), never by exit codes or
   harness lifecycle notifications.
2. **Re-run the suite it called green from cold** and compare the test
   count with CI's — a differing count is a failed verification. **Never
   pipe a gate through `tail`/`head`**: the pipeline's exit status becomes
   the pager's, and a hard failure reads as green (measured: a `vitest run`
   that exited 1 with "No test files found" looked clean through `| tail`).
   Capture the full output to a file and grep that.
3. **Ask where the cause was closed.** A commit message or report paragraph
   is not a recurrence layer; demand the gate/test/config `file:line`.
4. **Look for artifact/code divergence** the change introduced, and check
   the tracker: closed tickets carry commit refs, discovered defects got
   filed as their own items.
5. Anything visual gets **one blind vision verdict before commit** (fresh
   judge per round; numeric context first, narrowed question, "do not
   judge" list). Never mix look-core changes with mechanical work in one
   spec or commit.
6. Commits, pushes, merges, deploys: **lead-only**, on every backend.

### Review checklist (where delegated defects actually leak)

Reports are largely honest — the problem is what they do *not* say. Review
the `git diff`, not the report:

1. grep for newly invented mapping/constant tables and duplicated helpers;
   diff near-copies against the **latest** sibling for dropped guards.
2. Compare against equivalent implementations on other surfaces
   (web/TUI/CLI parity).
3. Execute user-facing text yourself (`--help`, error strings) against the
   code — invented copy passes tests.
4. For refactors ask "what was lost" — ordering, caches, fallbacks,
   shortcuts.
5. Read changed test assertions in the diff — a bumped constant means a
   rewritten contract; demand the original.
6. Check new imports for inverted dependency directions.
7. Re-run secret scanners *after* committing new files (`git ls-files`
   scanners skip untracked files).
8. For conditional features, verify the disabled path is unchanged.
9. Read test wait conditions — a `waitFor` on anything but the asserted
   state is a proxy wait; PASS means "it ran", not "it's right".
10. After moves/renames, grep reference integrity in both directions
    yourself; a `.claude/**`/skill link repointed into an archive is a red
    flag, not a fix.
11. Grep for **dangerous defaults** — an empty/omitted field that means
    "all" (a `{"id": ""}` once destroyed every tab; the tell was the
    delegate's own mock getting the case wrong first).

Fix small precision defects yourself on the spot; re-delegate only repeated
patterns or large volumes.

## When NOT to outsource

- Problems too exploratory to spec — the lead narrows the cause first.
- git / deploy / release actions (lead only).
- Design-weight logic cores (state machines, serialization): measured to
  stay with Claude — write with Claude, have a backend review.
- Vision work on GLM-5.3, ever.

## Local overlay (project/user-specific context)

If `references/local-overlay.md` exists next to this skill, read it and
apply it on top of these instructions — role tables, house gate recipes,
default-backend and model-assignment tables, scratch-path conventions.
Include it between the shared preamble and the task spec when assembling.
The installer preserves an existing overlay on upgrade; this repository
never ships one.
