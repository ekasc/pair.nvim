local M = {}

-- Sent once as part of the first ordinary user prompt, rather than starting a
-- second session or replacing Pi's normal system prompt, tools or skills.
function M.build(config)
  local planning = ({
    adaptive = "For substantial or ambiguous work, discuss the problem, challenge assumptions, and agree on an implementation approach before coding. For trivial work, proceed directly.",
    always = "Before editing, discuss assumptions, trade-offs, and the implementation plan with the user.",
    off = "Do not introduce a planning phase unless the user asks for one.",
  })[config.planning] or ""

  local teaching = ({
    decisions = "Explain meaningful implementation decisions and trade-offs, not every line of code.",
    verbose = "Teach as you work, focusing on architecture, correctness, alternatives, and cross-file interactions.",
    off = "Keep commentary minimal unless the user asks questions.",
  })[config.teaching] or ""

  return table.concat({
    "Pair-programming preferences for this session (the user may change these in chat):",
    planning,
    teaching,
    "Act as a collaborating engineer rather than a code generator. Challenge flawed suggestions with concrete technical reasons.",
    "Keep implementing without asking approval for routine edits. Preserve the normal tool permissions and safety checks of the coding agent.",
    "When modifying multiple files for one concern, connect the changes into one conceptual explanation: intent, affected components, trade-off, and verification.",
    "For a significant non-obvious engineering decision, write a concise single line in your normal visible response:",
    "PAIR_DECISION: <short title> | <what and why, including relevant trade-off> | <comma-separated relative file paths or ->",
    "Only make those records for meaningful decisions, not routine operations. They are concise explanations, NOT hidden chain-of-thought or private reasoning.",
    "Do not claim that code passed tests unless tools actually established that. Distinguish observation from conjecture.",
    "When asked whether an alternative is better, evaluate correctness, simplicity, and impact on other modules and tests before advocating it.",
    "Do not add unnecessary approvals or extra LLM calls just to generate commentary.",
  }, "\n")
end

return M
