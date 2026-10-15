# pair.nvim (prototype)

A native Neovim interface for **pair programming with one existing coding agent**. The first adapter uses **Pi RPC**. It is not a replacement for Pi, an additional reviewer agent, or an approval gate.

## Scope of this prototype

- One persistent Pi subprocess and one conversation: prompts, teaching, challenges, redirects and coding all share its context.
- Split chat with streaming assistant text and a multiline composer.
- A configurable pair-programming directive is sent only with the **first user prompt** in the session, without replacing Pi's system instructions or installing extensions.
- Significant decisions can appear in a timeline, with rationale and linked files, when the model emits `PAIR_DECISION:` records.
- Git-working-tree file changes are observed around tool execution and grouped by execution event (not falsely attributed as proven agent edits).
- Each observation carries a line-level diff and a content revision **when it could read the bytes**: files over 2 MiB are tracked by size and mtime, so they get no content revision and no hunks. Changed lines are highlighted in the file buffer, and `:PairChanges` lists one quickfix entry per hunk, or the reason a diff is missing. A rename moves the reading: the old path is reported as renamed, and the new path's diff is computed against the reading the old path had.
- An explanation is bound to the reading of each file it names, so a later edit or revert marks it as changed since, and a file that is gone says so, instead of silently reusing the old rationale.
- A **change group** is one stated decision plus the files it names, shown with the readings those files were observed at. `:PairGroups` lists them together, so the edits that belong to one implementation decision read as one unit instead of as a run of unrelated files. A file is in a group because a decision named it; the grouping never claims the agent authored the edit. Observed changes no decision names are listed in their own section rather than hidden.
- `:PairChanges` opens every observed reading in quickfix, one entry per hunk. `<CR>` on a file in the chat opens it in the editor.
- User questions are **follow-ups** by default while the agent is working. Explicit steering enters at the next Pi turn boundary.
- Follow mode is opt-in, so the agent does not seize the buffer you are reading.
- Buffers with unsaved changes are never force-reloaded.

## Requirements

- Neovim 0.10+ and the `pi` CLI installed **by you**, configured with your normal model/provider credentials.
- Git for multi-file change observation. Without Git, Pi chat still works but working-tree tracking is unavailable, including line-level hunks and revision binding.
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
| `:PairChanges` | Quickfix list of observed changes: one entry per hunk, or one entry saying why a diff is missing |
| `:PairGroups` | Quickfix list grouped by decision: a header per decision that names files, with those files under it, then observed changes no decision names |
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
7. A long chat currently renders into a capped Neovim scratch buffer. Rendering hunks inside the transcript, and durable timeline storage across restarts, are still future work. Changed-line marks live in the file buffers instead.
8. Current UI operates on the same machine/filesystem as Neovim. Remote execution adapters are not built in.

## Verification

```sh
texlua tests/run.lua                      # portable logic suite, no Neovim required
nvim --headless -l tests/integration.lua  # real plugin driven by a fake Pi RPC process
bash tests/mutation-sweep.sh              # patches one behaviour at a time, expects checks to fail
```

The logic suite runs under Lua 5.3 via `texlua` (29 checks). The integration suite runs the plugin inside headless Neovim with `tests/fake-pi.lua` standing in for `pi --mode rpc` (60 checks), so neither needs provider credentials or the `pi` CLI. The mutation sweep is a development tool: it patches one behaviour at a time, restores each file it patches, fails if any patch does not make the checks that cover it fail, and fails if it leaves the repository in a different state than it found it.

What the integration suite covers: session start, the first-prompt-only directive, streamed assistant text, decision records with linked files, tool-boundary change observation, line-level hunks at the expected offsets, changed-line marks in the file buffer, per-hunk quickfix entries, change groups with their decision headers and the section for observed changes no decision names, a group that reports how much of its evidence a later reading superseded, revision binding of explanations, staleness after a later edit, a real commit of an explained file that does not mark the explanation, a real removal that does, the silent reload of an unmodified buffer, the refusal to overwrite a modified one with its marks cleared, the refusal to abandon unsaved changes when opening a file, a byte-order mark matching its buffer, a sidebar whose Pi has exited being replaced rather than reopened, and shutdown.

What it does not cover: extension dialogs, follow mode, and anything involving a live model. A real Neovim plus Pi acceptance pass with actual edits, steering and interruption is still required and has not been executed here.

## Development sequence

- **Now:** chat + Pi RPC + queued and steering prompts + per-tool hunk observation with revision-bound explanations + linked decisions + change groups that connect the observed edits of one decision.
- **Next:** session-history recovery, and rendering hunks inside the transcript instead of only in the file buffers.
- **Afterward:** OpenCode adapter, Git-independent watchers, richer what-if navigation, and automated end-to-end tests with real Pi.
