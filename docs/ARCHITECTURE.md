# Architecture and engineering constraints

## Goal

Pair programming is an interaction mode for an *existing* coding agent. The plugin should increase the user's understanding of decisions without requiring approvals for routine code edits, duplicate agents, model session forks, or extra inference calls for each tool invocation.

## Data flow

```text
Neovim buffer & composer
      │ question / steer / interrupt
      ▼
Session controller ────────── Pi RPC (JSONL over stdin/stdout)
      │                            │
      │         text/tool/session events
      ◀────────────────────────────┘
      │
      ├── UI timeline: chat, decisions, linked paths
      └── Change observer: Git working tree checkpoints + reload unmodified buffers
```

The Pi subprocess is the only model-bearing actor. The Neovim controller has no inference capability. Source edits are performed through Pi's normal tools; Neovim does not mirror or re-apply an agent's patches.

## Session invariants

1. Exactly one Pi RPC subprocess per active Neovim pair session. No reviewer-agent duplication.
2. The first user prompt prepends a stable collaboration preference; subsequent prompts are unmodified apart from explicitly attached editor locations. The user may override preferences in chat.
3. No nonessential prompt is sent for an explanation that the active model has already provided. `PAIR_DECISION:` records come from the visible response of the same agent.
4. A normal question sent while busy uses Pi `follow_up`; an explicit redirect uses `steer`. Neither automatically kills a running tool.
5. A single model cannot answer independently while already generating. Follow-ups have response latency; this is inherent rather than something to hide with a second agent.
6. Tool events trigger *observation* of changes. The monitor must never infer agent authorship merely from a dirty Git worktree.
7. Unsaved user buffers are never overwritten or force-reloaded.
8. Ordinary Pi tool permissions and safety policy remain in effect. Extension confirmations must be resolved by the user or cancelled, never silently approved.
9. Explanations are public engineering rationale, not private chain-of-thought. Decisions are checked against actual files and tests.

## Multi-file model

One logical intent can span schema, backend, frontend and test files. A `PAIR_DECISION:` record contains a title, why and affected paths. Independent Git change checkpoints capture *observed* paths. The UI joins these conceptually without asserting perfect correspondence.

Each observation carries, per file, a reading and the hunks from the previous one:

```text
Observation {
  path,
  status,             -- new | changed | unchanged | renamed | gone | unreadable
  reason,             -- why nothing could be read: gone | too_large | not_a_file | unreadable
  key,                -- change-detection key: the content hash, or size:mtime above the ceiling
  revision,           -- the content hash, published only when the bytes were read
  renamed_to,         -- the new path, when Git reported the rename
  hunks: [{old_start, old_count, new_start, new_count}],
  hunks_reason,       -- why a diff is missing: budget | too_large | gone | not_a_file
}
```

The key and the revision are deliberately separate. A key answers "did this file change", and for a file too large to hash it is a size and mtime fingerprint. A revision answers "what is in it" and is only ever a content hash. Storing a fingerprint or a sentinel such as `<deleted>` in the revision field would publish a value no reader can interpret and no later comparison can use.

Statuses claim only what was observed. `new` is a first reading with nothing to compare against. `changed` means both keys are known and differ. `unchanged` means the file left the changed set with the same key, which is what a commit looks like. `renamed` means Git reported the rename, so the reading stays comparable under the new name. `gone` means no file is there. `unreadable` means something is there but cannot be measured: a directory, a submodule, or a file that cannot be opened. A status is only reported when the observation says something; a file that was equally dirty before and after with the same key produces no entry.

A file leaving the changed set is not assumed to be gone: reading it separates a commit (same key, nothing marked), a revert (different key, so the explained reading is gone) and a removal (no reading left, so the transcript says the file is gone rather than claiming the explanation is out of date). A rename Git detects keeps its reading. A rename that was committed in the same boundary leaves no rename record in `git status`, so the old path reports as gone; that is the honest limit of what the working tree can show.

Hunk ranges would go stale as later edits move code, so they are never reused across observations. Instead an explanation records the change key of each file it names, and a later observation at a different key marks that explanation as changed since. The bound revision is kept as written, so the transcript keeps saying both what was explained and what has happened to it since. The mark is a comparison rather than a latch: a file that comes back to the explained key stops being marked.

### Still wanted

Grouping observations into a durable object, and recording verification:

```text
ChangeGroup {
  id, intent,
  actual_hunks: [...],
  related_decisions: [...],
  verification: {commands, observed_outcomes},
  stale: boolean
}
```

This must remain a *view* over real file and tool evidence. An agent-provided path should never be silently treated as proof of modification. Untracked files, renames and unrelated user edits are handled only at the level of "this file looked different across the tool boundary", which is why a status reports what was measured rather than what it is taken to mean.

## Protocol baseline

Pi RPC documented event families as of 2026-10:

- Commands: `get_state`, `prompt`, `follow_up`, `steer`, `abort`, extension UI responses.
- Events: `message_update.assistantMessageEvent` with `text_delta`, `message_end`, `tool_execution_start`, `tool_execution_end`, `agent_settled`.
- A prompt's successful RPC response acknowledges acceptance, **not** completion.
- JSONL framing splits on literal LF, not arbitrary Unicode separators.
- Pi may issue extension UI dialogs; the host must correlate dialog IDs and reply with the same ID.

Upstream references:

- https://upd.dev/badlogic/pi-mono/src/branch/main/packages/coding-agent/docs/rpc.md
- https://upd.dev/badlogic/pi-mono/src/branch/main/packages/coding-agent/docs/rpc-commands.md
- https://upd.dev/badlogic/pi-mono/src/branch/main/packages/coding-agent/docs/json.md
- https://upd.dev/badlogic/pi-mono/src/branch/main/packages/coding-agent/docs/rpc-extension-ui.md

## Known limitations and edge cases

- The Git observer is synchronous on tool boundaries, and it reads file content to produce hunks. Content retention is bounded per checkpoint (8 MB total, 2 MB per file), and the budget is spent on the smallest files first, because a large file's diff is the expensive one to compute and the least useful to read. Files beyond the ceiling get no content revision and no hunks, and files whose content could not be retained say so in the quickfix instead of reporting a change with nothing behind it. Optimize asynchronously if large repositories show editor stalls.
- Marks are placed in a file buffer only when the buffer holds the bytes of the observed revision, compared by hashing its contents, rather than trusting that a reload succeeded. Bytes that do not round-trip through a buffer, such as NUL bytes, therefore get no marks.
- A file above the size ceiling is tracked by size and mtime, so a rewrite that restores both is invisible. It has no content revision to compare, which also means an explanation naming it is never marked by content.
- A tool end with no recorded start, or one whose checkpoint was dropped past the bound of 8 outstanding windows, is reported as unobserved rather than compared against an older baseline, which would credit one tool with another's edits.
- Git dirtiness is not equivalent to provenance. A user edit occurring during the tool window can be observed too.
- Existing non-Git workspaces are not tracked. Git worktrees with `.git` files are recognized for root discovery.
- Full-file writes may be atomic; file system watchers won't necessarily provide each intermediate line. The intended UX is revision-level diff streaming plus explanations, not simulated keystrokes.
- Model-provided decision lines are best-effort output, not a guaranteed machine contract; output should be validated before presenting hard provenance.
- Opening a file from the sidebar can be refused when the user's editor buffer is modified; this is intentional.
- The transcript timeline is currently in-memory, whereas Pi's native conversation history is persisted independently.
- Pi RPC starts its own process; this is not attached to an already-running terminal TUI.

## Test strategy

1. Portable isolated module tests: JSONL fragmentation, id correlation, follow-up vs steer, decision parsing including pipes inside rationale, first-turn directive, file scanning including renames and spaces, and degraded observation when Git is unavailable.
2. Neovim headless integration with a fake Pi process (`tests/integration.lua`): sidebar open, expected chat lines, one-time directive, tool-boundary change observation with hunk offsets and changed-line marks, revision binding and staleness, a real commit that must not mark an explanation, a real removal that must, silent reload versus modified-buffer refusal, option restoration, and shutdown. Extension dialogs and follow mode are not yet covered.
3. Mutation checks (`tests/mutation-sweep.sh`) patch one fixed behaviour at a time and require the checks that cover it to fail, so the suite is known to be load-bearing rather than merely green.
4. Live Pi smoke test with a synthetic Git repo: design discussion, file edits, one follow-up, one steer, verification and stop.
5. Visual interactive acceptance in Neovim: work in an unrelated buffer while agent edits, explore versus follow behavior, hunk navigation, restoring focus, and model/provider error recovery.

Tests (1) and (2) exist and pass: `texlua tests/run.lua` and `nvim --headless -l tests/integration.lua`. Tests (4)–(5) require a live agent and are not claimed as executed here.
