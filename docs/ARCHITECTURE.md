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

Each observation carries, per file, a revision and the hunks between revisions:

```text
Observation {
  path,
  status,             -- appeared | changed | disappeared
  revision,           -- SHA-256 of the bytes; size:mtime above the size ceiling; nil if gone
  previous_revision,
  hunks: [{old_start, old_count, new_start, new_count}]
}
```

Leaving the dirty set is reported as `disappeared` rather than `deleted`, because a commit produces the same status output as a removal. Reading the bytes settles what the status cannot: unchanged bytes mean the revision an explanation refers to still exists, changed bytes mean a revert replaced it, and no file at all leaves nothing to compare against. The last two mark the explanation as changed since; a commit marks nothing.

Hunk ranges would go stale as later edits move code, so they are never reused across observations. Instead an explanation records the revision of each file it names, and a later observation at a different revision marks that explanation as changed since. The bound revision is kept as written, so the transcript keeps saying both what was explained and what has happened to it since.

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

This must remain a *view* over real file and tool evidence. An agent-provided path should never be silently treated as proof of modification. Untracked files, renames, in-progress writes and unrelated user edits are currently handled only at the level of "this file looked different across the tool boundary".

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

- The Git observer is synchronous on tool boundaries, and it now reads file content to produce hunks. Content retention is bounded per checkpoint (8 MB total, 2 MB per file); files beyond that, or above the size ceiling, still get a revision but no hunks. Optimize asynchronously if large repositories show editor stalls.
- Git dirtiness is not equivalent to provenance. A user edit occurring during the tool window can be observed too.
- Existing non-Git workspaces are not tracked. Git worktrees with `.git` files are recognized for root discovery.
- Full-file writes may be atomic; file system watchers won't necessarily provide each intermediate line. The intended UX is revision-level diff streaming plus explanations, not simulated keystrokes.
- Model-provided decision lines are best-effort output, not a guaranteed machine contract; output should be validated before presenting hard provenance.
- Opening a file from the sidebar can be refused when the user's editor buffer is modified; this is intentional.
- The transcript timeline is currently in-memory, whereas Pi's native conversation history is persisted independently.
- Pi RPC starts its own process; this is not attached to an already-running terminal TUI.

## Test strategy

1. Portable isolated module tests: JSONL fragmentation, id correlation, follow-up vs steer, decision parsing including pipes inside rationale, first-turn directive, file scanning including renames and spaces, and degraded observation when Git is unavailable.
2. Neovim headless integration with a fake Pi process (`tests/integration.lua`): sidebar open, expected chat lines, one-time directive, tool-boundary change observation with hunk offsets and changed-line marks, revision binding and staleness, silent reload versus modified-buffer refusal, option restoration, and shutdown. Extension dialogs and follow mode are not yet covered, and the suite never commits, so a file leaving the dirty set is covered only in tier 1 against stubbed git output.
3. Live Pi smoke test with a synthetic Git repo: design discussion, file edits, one follow-up, one steer, verification and stop.
4. Visual interactive acceptance in Neovim: work in an unrelated buffer while agent edits, explore versus follow behavior, hunk navigation, restoring focus, and model/provider error recovery.

Tests (1) and (2) exist and pass: `texlua tests/run.lua` and `nvim --headless -l tests/integration.lua`. Tests (3)–(4) require a live agent and are not claimed as executed here.
