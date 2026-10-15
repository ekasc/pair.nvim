local M = {}

M.defaults = {
  agent = "pi",
  pi = {
    command = { "pi", "--mode", "rpc" },
    extra_args = {},
  },
  root = nil,
  teaching = "decisions", -- "decisions" | "verbose" | "off"
  planning = "adaptive", -- "adaptive" | "always" | "off"
  follow_edits = false,
  ui = { width = 48, composer_height = 6, max_entries = 250 },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  assert(M.options.agent == "pi", "pair.nvim: only the pi adapter is implemented")
  return M.options
end

return M
