<!--
This file is the shared front matter for every grok spec. The lead writes a
per-task spec, then merges:

  cat skills/grok-delegate/references/spec-preamble.md task.md > spec.md

and passes it via --prompt-file. Every rule here came from a real incident.
If a task spec must relax one of these rules, state the exception explicitly
in that spec.
-->

# Shared rules (read these before the task spec)

You have no conversation context. The rules below come from incidents that
actually happened in projects run this way, and the lead keeps having to
revert the same mistakes. Obey these before the task content.

## 1. Investigate before writing code

- **Use the repository's "trap docs" — but don't re-read what you already
  have.** The CLI auto-injects `CLAUDE.md` and `.claude/rules/*` into your
  context wholesale; treat those as already read and quote from them
  directly. Spend search turns only on what is **not** auto-injected:
  `docs/decisions/`, module-header contract comments, "hard-won knowledge"
  sections, and any file the task spec names. Quote the items that apply to
  this task in your final report. If none apply, say "none apply" and list
  the files you checked.
  - Two real defects were things *already written* in such a doc. One was
    "the issue tracker localizes status/priority names per account — key all
    logic on ids or categories", the other was "the sync-health badge reads
    `sources.synced_at`". Reading the doc would have prevented both.
- **Before inventing a new mapping/constant table, grep for an existing
  field with the same meaning.** A priority-sorting name table
  (`"highest"→0` …) was once hand-built when the data already carried a
  `priority_rank`. If you do add a table, report "I searched for an existing
  axis and found none".
- **Check whether the same logic already exists on another surface.** When a
  project has web / TUI / CLI / server over the same data, find the other
  implementation and make **the same input produce the same result** — or
  report why it must differ.

## 2. Do not lose existing behavior

- When moving storage, deleting code, or refactoring: **first list what the
  old code did**, then verify each item still works afterward. Put that list
  in the report.
  - Migrating favorites from localStorage to a server once silently made
    **drag-ordering** session-only. The comment said "session-only" — for
    the user it was a regression that shuffled their sidebar every reload.
- Losing side behaviors (ordering, caches, fallbacks, shortcuts) is also a
  regression. "The core works" is not done.

## 3. Never invent user-facing copy

- Every sentence in help text, error messages, and docs must state **only
  what you verified in the code**.
- Hand-written flag/behavior descriptions need a supporting `file:line` in
  the report.
  - `--spread` was once described as "filters rows" and `--scale 2` as
    "doubles the size" (actually: timestamp redistribution, and "two total").
    The spec said "don't invent" — it still happened. Now we demand line
    references.
- Prefer **mechanically generated** copy (e.g. iterating a flag set). Hand
  copied strings drift from the code eventually.

## 4. Never edit assertions to make gates green

- When an existing test fails, **first ask what that assertion protected.**
  Bumping a constant to the new value is usually the wrong fix.
  - `schema_version == 5` was once bumped to `== 6`. The real contract was
    "snapshots are created at this binary's migration level", so the right
    fix asked the store for its current level (never needs bumping again).
- If you changed an assertion, report **what and why, and why it could not
  be rewritten as a direct contract assertion**.
- Loosening thresholds/tolerances is forbidden. If unavoidable — don't;
  report instead.

## 5. When spec requirements conflict, do not resolve silently

- If A and B cannot both hold, **don't quietly drop one** — find a third way
  that satisfies both, or report the conflict and pick the safer side. Always
  state what you chose and what you gave up.
  - "Must be deterministic" once collided with "distribute around the
    current time"; the time base was silently dropped and outputs were
    forever dated in the past. One flag would have satisfied both.

## 6. Dependency direction and scope

- **Report every new package import.** If the direction looks wrong (e.g. a
  config exporter importing a snapshot generator), extract to a shared spot.
- If you must step outside the spec's file boundary, make the **minimal**
  change and report it. Silently fixing and silently leaving gates broken
  are both wrong.
- Other agents may be editing other files concurrently. **A broken
  whole-tree build caused by files outside your scope is not your fault** —
  verify per package and report.

## 7. Hot paths

- If you added allocations or O(n) scans to a per-render / per-keystroke /
  per-request path, report it. For conditional features, **the disabled path
  must be byte-identical to the old path.**
  - A grouping feature once allocated a full row slice every render even
    with grouping off.

## 8. Absolute bans

- **No git commands**: commit / checkout / stash / restore / add / push /
  rebase. Read-only (`git log` / `show` / `diff` / `-S`) is allowed. The lead
  commits and restores.
- **No taste/visual judgment calls.** Never pick new colors, spacing, or
  layout on your own. Implement the numeric/structural changes as specified
  and reuse existing style tokens. (When the task spec explicitly includes a
  *visual self-verification protocol*, follow it: open your own captures and
  converge toward the numeric contract — that is verification, not taste.)
- Comments follow **the language of the surrounding code** (varies by file).

## 9. Progress checkpoints

At every stage boundary, append exactly one line to the progress log the
task spec names (default `<scratch>/progress-<track>.log`):

    PROGRESS <ISO-8601-UTC> <stage> <one line, no newline inside>

Never rewrite the file. If it is not writable, skip and say so in the
report. The lead uses this file when the NDJSON stream is missing or
unparsable.

---

# Final report format (missing items = incomplete)

1. Changed/new file list + one line each
2. The task spec's completion-criteria commands with **their real output**
   (paste, don't summarize)
3. **Self-verification** — answer all eight; "not applicable" is an answer
   but include the evidence (file names, grep results):
   1. Trap-doc items that applied to this task (with the files you checked)
   2. New mappings/constants/tables, and the search for existing equivalents
   3. Whether other surfaces (web/tui/cli/server) produce identical results
   4. Existing behavior that this change removed or weakened
   5. New user-facing copy and its supporting file:line
   6. Changed test assertions and why (incl. why not a contract assertion)
   7. Spec conflicts / out-of-scope edits / new dependencies
   8. Costs added to hot paths
4. What you could not implement or verify (do not hide it — the lead reads
   the diff anyway)
