# pair.nvim (prototype)

A native Neovim interface for **pair programming with one existing coding agent**. The first adapter uses **Pi RPC**. It is not a replacement for Pi, an additional reviewer agent, or an approval gate.

## Scope of this prototype

- One persistent Pi subprocess and one conversation: prompts, teaching, challenges, redirects and coding all share its context.
- Split chat with streaming assistant text and a multiline composer.
- A configurable pair-programming directive is sent only with the **first user prompt** in the session, without replacing Pi's system instructions or installing extensions.
- Significant decisions can appear in a timeline, with rationale and linked files, when the model emits `PAIR_DECISION:` records.
- Git-working-tree file changes are observed around tool execution and grouped by execution event (not falsely attributed as proven agent edits).
- `:PairChanges` opens all observed files in quickfix; `<CR>` on a file in the chat opens it in the editor.
- User questions are **follow-ups** by default while the agent is working. Explicit steering enters at the next Pi turn boundary.
- Follow mode is opt-in, so the agent does not seize the buffer you are reading.
- Buffers with unsaved changes are never force-reloaded.

## Requirements

- Neovim 0.10+ and the `pi` CLI installed **by you**, configured with your normal model/provider credentials.
- Git for multi-file change observation (without Git, Pi chat still works but working-tree tracking is unavailable).
- No daemon, npm package, model, or separate language server is installed by this plugin.

## Install

With lazy.nvim (example after copying/cloning this repository to a local path):

```lua
{
  dir = "/path/to/pair-nvim",
  config = function()
    require("pair").setup({
      pi = { command = { "pi", "--mode", "rpc" } },
      teaching = "decisions",     -- decisions | verbose | off
      planning = "adaptive",      -- adaptive | always | off
      follow_edits = false,
      ui = { width = 48, composer_height = 6 },
    })
  end,
}
```

Or add its root to `runtimepath` and run `:PairStart` (the `plugin/` entry point auto-registers commands).

## Commands and keys

| Command | Effect |
|---|---|
| `:PairStart` | Start Pi RPC in the project root and open the sidebar |
| `:Pair` | Toggle sidebar |
| `:PairAsk` | Open composer with current code location attached |
| `:PairContext` | Refresh the composer context from the current editor window |
| `:PairSend` / `<C-s>` in composer | Send; if Pi is working, queue for after its run |
| `:PairSteer` / `<C-t>` in composer | Steer; if working, deliver after current assistant turn's tool calls |
| `:PairChanges` | Quickfix list of observed modified files |
| `:PairFollow` | Toggle automatic navigation to changed files |
| `:PairInterrupt` | Explicitly abort the active Pi run |
| `:PairStop` | Close Pi's stdin to request shutdown and close sidebar |
| `<CR>` in transcript | Open linked file on current line |

Press `i` in transcript to focus the composer. Compose multiple lines with normal Enter; use `<C-s>` to submit.

## Design and limitations

This is a **first vertical slice**, not a production-ready plugin:

1. Only Pi is implemented; OpenCode remains an adapter to add later.
2. Pi is launched in RPC mode as a **new client**, not attached to an already-running interactive Pi TUI. Pi retains its own session persistence; resuming a previous one can be configured through the CLI args, but UI session selection is not implemented.
3. Files are tracked using git status + content fingerprints on tool boundaries. This catches disk edits after tools, including untracked files, but not an exact keystroke-by-keystroke stream, non-Git workspace files, or definitive agent attribution when other processes edit concurrently.
4. Rationales are *visible explanations* provided by the working agent, not access to hidden model reasoning. Decision records are best-effort, and cross-file links provided by the model must be checked against actual code.
5. The single model cannot answer a second prompt concurrently with an ongoing generation. A follow-up answers when the active run finishes; steer processes at a supported turn boundary. No extra model, session fork, or synthetic summary is created.
6. Pi extensions requiring direct TUI capabilities may not work in RPC mode. Basic extension dialogs are bridged via `vim.ui.*`.
7. A long chat currently renders into a capped Neovim scratch buffer; richer diff hunks, visual extmarks and durable custom timeline storage are future work.
8. Current UI operates on the same machine/filesystem as Neovim. Remote execution adapters are not built in.

## Verification

Run the portable logic suite (Lua 5.3 via `texlua` is sufficient):

```sh
texlua tests/run.lua
```

A real Neovim+Pi RPC end-to-end acceptance run is still required.

These tests mock Pi events and do not need provider credentials.

## Development sequence

- **Now:** chat + Pi RPC + queued and steering prompts + coarse multi-file tracking + linked decisions.
- **Next:** reliable per-tool code-hunk snapshots, changed-line extmarks and code-window follow behavior, then session-history recovery.
- **Afterward:** OpenCode adapter, Git-independent watchers, richer what-if navigation, and automated end-to-end tests with real Pi.
