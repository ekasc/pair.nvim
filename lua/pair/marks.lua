-- Changed-line marks on real code buffers. Kept separate from the sidebar UI
-- because these extmarks live in the user's files, not in the pair windows.

local M = {}

local namespace = nil

-- Created on first use so the module can be required where vim.api is absent.
function M.namespace()
  if not namespace then
    namespace = vim.api.nvim_create_namespace("pair.nvim.changed_lines")
    vim.api.nvim_set_hl(0, "PairChangedLine", { link = "DiffChange", default = true })
  end
  return namespace
end

function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.namespace(), 0, -1)
  end
end

-- Whether a buffer holds the same bytes as an observed revision. Marks are line
-- numbers in one revision, so placing them in a buffer holding another revision
-- would point at the wrong code. Bytes that do not round-trip through a buffer
-- (NUL bytes, an empty file read as one empty line) mismatch, which costs marks
-- on files where they would be meaningless anyway.
function M.matches(bufnr, revision)
  if type(revision) ~= "string" then return false end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if vim.bo[bufnr].endofline then text = text .. "\n" end
  if vim.bo[bufnr].fileformat == "dos" then text = text:gsub("\n", "\r\n") end
  return vim.fn.sha256(text) == revision
end

-- Marks the new-side line ranges of each hunk. A pure deletion has no new
-- lines, so it produces no mark; the quickfix list is where those show up.
function M.apply(bufnr, hunks)
  M.clear(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return 0 end
  local marked = 0
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  for _, hunk in ipairs(hunks or {}) do
    if hunk.new_count and hunk.new_count > 0 and hunk.new_start and hunk.new_start >= 1 and hunk.new_start <= last_line then
      local first = hunk.new_start
      local final = math.min(hunk.new_start + hunk.new_count - 1, last_line)
      vim.api.nvim_buf_set_extmark(bufnr, M.namespace(), first - 1, 0, {
        end_row = final,
        end_col = 0,
        line_hl_group = "PairChangedLine",
      })
      marked = marked + 1
    end
  end
  return marked
end

return M
