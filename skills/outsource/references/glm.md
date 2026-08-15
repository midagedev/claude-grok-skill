# GLM-5.3 backend — z.ai coding plan through the crush CLI

The model is the point; the **crush CLI is just the harness** that runs it
headlessly. Division of labor: the lead writes specs, reviews diffs, runs
gates, commits; GLM-5.3 burns the implementation tokens, which are close to
free on a z.ai coding plan.

The shared implementer preamble (`references/spec-preamble.md`) carries the
backend-agnostic rules; `references/glm-preamble.md` is the GLM-runtime
delta. Assemble both in front of every task spec.

**Hard limit (measured):** GLM-5.3 has `supports_attachments: false` — it
cannot see images. Every visual verdict — and style/look/UI-interaction
authoring (A/B-measured, below) — goes to a vision-capable frontier agent
(we use an Opus subagent). GLM-5.3 can still do the numeric half of visual
work: pixel-decoding scripts, capture harness wiring, gate authoring.

## Invocation

```bash
SP=<scratch-dir>
cat ~/.claude/skills/outsource/references/spec-preamble.md \
    ~/.claude/skills/outsource/references/glm-preamble.md \
    $SP/task.md > $SP/spec.md

~/.claude/skills/outsource/bin/glm-run.sh \
  --cwd /absolute/path/to/worktree --spec $SP/spec.md \
  --config-dir $SP/glm-cfg-<track> --log $SP/glm-<track>.log
```

Run with `run_in_background: true`; collect the log on completion. The last
stdout line is `SESSION <id>` — pass it back with `--session <id>` for a
follow-up in the same context (keep that rare; a fresh round with a
summarized spec is usually better).

Flags: `--model provider/id` (default `zai/glm-5.3`, or `GLM_DELEGATE_MODEL`);
`--config-dir` — one per parallel track (`session last/list` is scoped by
data dir, not cwd); `--allow-agent` re-enables crush's sub-agent tools and
**weakens the git ban** (hooks fire only on top-level tool calls) — only for
tasks with zero repository-state risk.

## Harness facts (crush CLI quirks; do not rediscover)

- `crush run` has no `--yolo`, `--deny`, `--prompt-file`, or `--max-turns`.
  The launcher maps everything to config in a scratch directory named by
  `CRUSH_GLOBAL_CONFIG` (a directory, not a file). The user's
  `~/.config/crush` stays untouched; the API key is read from it at load
  time and never written into our files or logs.
- Auto-approval = `permissions allow …`; sub-agents off = `permissions deny
  agent task`; there is no turn cap — rely on the `DONE-<track>` marker.
- The git ban is a `PreToolUse` hook (`git-guard.sh`) that reads the actual
  command string, so `git -C <path> commit`, `env FOO=1 git push`,
  `sudo git …`, and mutations chained after a listing are all blocked.
  Read-only git (`log`/`show`/`diff`/`blame`/`status`/`worktree list`/
  `branch -a`/`remote -v`/`config --get`, `gh pr list|view`) is allowed on
  purpose. Regression-tested at 29 cases; after editing the guard re-run:
  `CRUSH_TOOL_INPUT_COMMAND='git -C /tmp commit -am x' bash ~/.claude/skills/outsource/bin/git-guard.sh; echo $?  # 2 = blocked`
- The launcher passes `-D <scratch>/data`; without it crush drops a multi-MB
  `.crush/` session DB into the tree it edits (self-gitignored — invisible
  in `git status`, which is why it goes unnoticed).
- The session id is `.meta.id` in `--json` output, not top level.

## How GLM-5.3 behaves (measured on delivered rounds, 2026-08)

The code it returns is usually sound; prose and disclosure are strong — it
reports its own mistakes and corrects wrong spec premises prominently.
Audit the **evidence around the code**, not the style. Failure modes that
actually happened, and the preamble rail that now blocks each:

| Tendency | Rail |
|---|---|
| Trusts a warm environment (claimed 167 green; CI ran 173 and failed — a reused dev server had served the pre-edit bundle) | §6 |
| Reports counts as sentences, without the producing command | §7 |
| Takes benchmark numbers on a busy machine without saying so | §8 |
| Narrates the cause in a commit message, fixes only the symptom | §9 |
| Ships a committed artifact the code can no longer produce, undetected | §10 |
| Flips tickets to done silently; files discovered defects in docs, not the tracker | §11 |

**A/B vs an Opus arm, identical specs (N=3: web UI fix, self-verifying doc,
shell scripts).** Parity on pattern discovery (both arms independently chose
the same shared popover util and invented the same AST-test workaround),
premise correction, FAIL-first, and boundaries. GLM lost all three artifact
picks, each to a specific gap — write the spec against these:

- **Second-order state interactions.** It left two popovers able to occupy
  the same slot and Escape doing two things at once; the Opus arm arbitrated
  both. For UI tasks, the spec must enumerate what else occupies the same
  space/keys and demand an explicit precedence decision.
- **Evidence strength.** It proved claims with greps plus a prose comment
  where a focused `go test -run` existed; the Opus arm ran the tests. For
  verification-carrying docs, the spec says: prefer invoking an existing
  test over a grep, and a comment inside a command block must not carry the
  claim.
- **Silent hazard avoidance.** Its `sh`/`set -eu` choice happened to dodge a
  SIGPIPE failure mode the Opus arm measured and designed around — luck and
  judgment are indistinguishable in review. For robustness-sensitive
  scripts, the spec demands naming the failure modes the chosen options
  handle (empty selection, missing binary, SIGPIPE, cron PATH).

**Standalone caveat:** when the user drives the model directly (no lead, no
hook), nothing enforces lead-only commits — that is how a red main once got
a second unrelated push. A spec for a maybe-standalone task carries three
lines: CI green is the definition of done, not the push; never push onto a
red main; one commit at a time through the gate.

