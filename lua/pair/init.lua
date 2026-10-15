local Config = require("pair.config")
local Session = require("pair.session")

local M = { session = nil, commands_registered = false }

local function notify(message, level)
  vim.notify("pair.nvim: " .. message, level or vim.log.levels.INFO)
end

local function project_root()
  local options = Config.options
  if options.root then return vim.fs.normalize(options.root) end
  local cwd = vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", { upward = true, path = cwd })[1]
  return git_dir and vim.fs.dirname(git_dir) or cwd
end

function M.start()
  if M.session then
    if M.session.backend.job then
      M.session.ui:open()
      return true
    end
    -- Pi exited: discard the stale sidebar before starting a fresh session so
    -- a restart does not stack a second sidebar over the dead one.
    M.session.ui:close()
    M.session = nil
  end
  local root = project_root()
  local session = Session.new(root, Config.options)
  local ok, err = session:start()
  if not ok then notify(err, vim.log.levels.ERROR); return false end
  M.session = session
  return true
end

function M.stop()
  if not M.session then return end
  M.session.backend:stop()
  M.session.ui:close()
  M.session = nil
end

function M.toggle()
  if not M.session then return M.start() end
  if M.session.ui:is_open() then M.session.ui:close() else M.session.ui:open() end
end

function M.ask()
  local context
  if M.session then
    context = M.session:context()
  else
    local root = project_root()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype == "" then
      local file = vim.api.nvim_buf_get_name(buf)
      local prefix = vim.fs.normalize(root) .. "/"
      if vim.fs.normalize(file):sub(1, #prefix) == prefix then
        context = { file = vim.fs.normalize(file):sub(#prefix + 1), line = vim.api.nvim_win_get_cursor(0)[1] }
      end
    end
    if not M.start() then return end
  end
  M.session.ui:set_context(context)
  M.session.ui:open()
end

function M.send(steer)
  if not M.session then notify("Run :PairStart first", vim.log.levels.WARN); return end
  M.session.ui:send(steer)
end

function M.context()
  if not M.session then return end
  M.session.ui:set_context(M.session:context())
  M.session.ui:focus()
end

function M.follow()
  if not M.session then notify("Run :PairStart first", vim.log.levels.WARN); return end
  M.session.follow = not M.session.follow
  notify("Follow mode " .. (M.session.follow and "enabled" or "disabled"))
end

function M.interrupt()
  if not M.session then return end
  local ok, err = M.session.backend:interrupt()
  if not ok then notify(err, vim.log.levels.ERROR) end
end

-- Why a reading could not be compared or did not exist. The reason is the
-- observation's own, so the list says what it knows instead of showing nothing.
local REASONS = {
  gone = "no file there",
  too_large = "over the 2 MiB ceiling for content revisions",
  not_a_file = "not a regular file",
  unreadable = "the file could not be read",
  budget = "content budget spent on other files",
}

local function status_text(entry)
  if entry.status == "unreadable" then return "present but unreadable: " .. (REASONS[entry.reason] or entry.reason) end
  if entry.status == "gone" then return "no longer on disk" end
  if entry.status == "unchanged" then return "left the changed set; no change measured" end
  if entry.status == "renamed" then return "renamed to " .. (entry.renamed_to or "another path") .. "; no change measured" end
  if entry.status == "new" then return "first reading of this file" end
  return "changed"
end

local function item_text(entry)
  local text = status_text(entry)
  -- A file that is gone or unreadable already says why in its status; repeating
  -- that as a missing diff would say the same thing twice.
  local explains_itself = entry.status == "gone" or entry.status == "unreadable" or entry.status == "new"
  if entry.hunks_reason and not explains_itself then
    text = text .. "; no diff available (" .. (REASONS[entry.hunks_reason] or entry.hunks_reason) .. ")"
  end
  return text
end

local function hunk_text(hunk)
  if hunk.new_count == 0 then
    return ("%d line%s removed"):format(hunk.old_count, hunk.old_count == 1 and "" or "s")
  end
  return ("%d changed line%s"):format(hunk.new_count, hunk.new_count == 1 and "" or "s")
end

function M.changes()
  if not M.session then return end
  local entries = M.session:file_entries()
  if #entries == 0 then return notify("No observed changed files yet") end
  local items = {}
  for _, entry in ipairs(entries) do
    local filename = M.session.root .. "/" .. entry.path
    if #entry.hunks == 0 then
      items[#items + 1] = { filename = filename, lnum = 1, text = item_text(entry) }
    else
      for _, hunk in ipairs(entry.hunks) do
        items[#items + 1] = {
          filename = filename,
          lnum = math.max(hunk.new_start or 1, 1),
          text = hunk_text(hunk),
        }
      end
    end
  end
  vim.fn.setqflist({}, "r", { title = "Pair observed changes", items = items })
  vim.cmd("copen")
end

function M.setup(options)
  Config.setup(options)
  if M.commands_registered then return end
  M.commands_registered = true
  local commands = {
    PairStart = M.start,
    PairStop = M.stop,
    Pair = M.toggle,
    PairAsk = M.ask,
    PairSend = function() M.send(false) end,
    PairSteer = function() M.send(true) end,
    PairContext = M.context,
    PairFollow = M.follow,
    PairInterrupt = M.interrupt,
    PairChanges = M.changes,
  }
  for name, callback in pairs(commands) do
    vim.api.nvim_create_user_command(name, callback, {})
  end
end

return M
