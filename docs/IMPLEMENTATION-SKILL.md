# Skill: Extend an agent-backed Neovim UI without duplicating the agent

Use this procedure for pair.nvim changes:

1. **Ground the transport** in the currently installed Pi RPC commands/events, including changes to queue disposition and settling semantics. Do not assume a prompt response indicates completion.
2. **Keep model context single-owner.** Prefer native agent queues over maintaining a second agent or summaries. Preserve the stable first prompt and avoid new per-event LLM calls.
3. **Observe before explaining.** Bind claims about file changes to tool events and real Git/filesystem evidence. Separate agent intent from observed edits and verify paths before navigation.
4. **Treat the user's editor as protected.** Never `edit!` modified buffers, silently overwrite draft changes, or jump between files unless follow mode is enabled.
5. **Test wire edge cases**: LF-framing across fragmented chunks, Unicode characters, out-of-order responses, failures, extended runtime session lifecycle and extension UI request IDs.
6. **Test cross-file cases**: existing dirty worktrees, staged changes, file creation/deletion/rename, spaces in filenames, concurrent user edits, long paths and non-Git workspaces.
7. **Keep explanations honest.** A visible rationale is not hidden model reasoning, a path named by the model is not proof of a file edit, and a run acknowledgement is not test success.
8. **Run portable tests**, then verify under real Neovim and Pi; do not conflate static checks with interactive acceptance.

Important recovered trap: `extension_ui_response` must keep Pi's original dialog `id`. Do not send it through a generic RPC command function that replaces every `id` with a generated request ID.
