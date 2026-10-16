local Config = require("pair.config")
local Session = require("pair.session")
local Changes = require("pair.changes")

local M = { session = nil, commands_registered = false }

local function notify(message, level)
  vim.notify("pair.nvim: " .. message, level or vim.log.levels.INFO)
end

-- The project root as one canonical name. A directory can be reached by more than
-- one name, such as a temporary path on macOS, where `/var` resolves to
-- `/private/var`: the editor reports the resolved name for a buffer, so a root kept
-- in the other spelling would never match the file the cursor is in, and a question
-- asked there would be sent without the location it was asked at. Resolving once,
-- where the root is discovered, keeps every later comparison between one name and
-- the same name.
local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function project_root()
  local options = Config.options
  if options.root then return canonical(options.root) end
  local cwd = vim.fn.getcwd()
  local git_dir = vim.fs.find(".git", { upward = true, path = cwd })[1]
  return canonical(git_dir and vim.fs.dirname(git_dir) or cwd)
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
  if M.session.ui:is_open() then
    M.session.ui:close()
  elseif M.session.backend.job then
    M.session.ui:open()
  else
    -- Pi exited: the sidebar it left behind cannot send, so :Pair opens a live
    -- session instead of showing the dead one. M.start discards it.
    M.start()
  end
end

function M.ask()
  local context
  if M.session and M.session.backend.job then
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
  too_large = ("over the %d MiB ceiling for content revisions"):format(Changes.MAX_FILE_BYTES / (1024 * 1024)),
  not_a_file = "not a regular file",
  unreadable = "the file could not be read",
  budget = "content budget spent on other files",
}

local function status_text(entry)
  if entry.status == "unreadable" then return "present but unreadable: " .. (REASONS[entry.reason] or entry.reason) end
  if entry.status == "gone" then return "no longer on disk" end
  if entry.status == "unchanged" then return "left the changed set; no change measured" end
  if entry.status == "renamed" then return "renamed to " .. (entry.renamed_to or "another path") end
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

local function plural(count, singular)
  return ("%d %s%s"):format(count, singular, count == 1 and "" or "s")
end

-- A reading that found nothing to read is not a location. {1:valid = 0} only keeps the
-- `:cnext` family away, and Neovim loads an empty buffer for a path that does not
-- exist, so an item that pointed at one would move the reader to a file they never
-- had.
local function openable(entry)
  return entry.status ~= "gone" and entry.status ~= "unreadable" and entry.status ~= "renamed"
end

-- Items for one file: one per hunk, so each is a jump target, or a single item
-- saying what the reading knows when there is nothing to point at.
local function add_file_items(items, root, path, entry, note)
  if not entry or not openable(entry) then
    -- A decision may name a file no observation has covered, and an observation may
    -- find nothing readable at the path. Neither is a location, so the item says
    -- what it knows without pointing anywhere.
    local text = entry and item_text(entry) or "no observation has covered this file"
    items[#items + 1] = { text = text .. note }
    return
  end
  local filename = root .. "/" .. path
  if #entry.hunks == 0 then
    items[#items + 1] = { filename = filename, lnum = 1, text = item_text(entry) .. note }
    return
  end
  for _, hunk in ipairs(entry.hunks) do
    items[#items + 1] = { filename = filename, lnum = math.max(hunk.new_start or 1, 1), text = hunk_text(hunk) .. note }
  end
end

-- A group item's standing relative to the decision that named the file. The item
-- text already reports an absent file, so the note is added only when it says
-- something that text does not.
local function file_note(file)
  if file.superseded then return "  (changed since the decision)" end
  -- A binding exists only for an observed path, so the reading behind it exists.
  if file.gone and file.entry.status ~= "gone" then return "  (file gone)" end
  return ""
end

-- What a group holds: the files the decision named, the hunks their readings
-- cover, and how much of that evidence no longer matches the decision.
local function group_header(group)
  local hunks, superseded, gone, unobserved = 0, 0, 0, 0
  for _, file in ipairs(group.files) do
    hunks = hunks + (file.entry and #file.entry.hunks or 0)
    if file.superseded then superseded = superseded + 1 end
    if file.gone then gone = gone + 1 end
    if not file.entry then unobserved = unobserved + 1 end
  end
  local text = ("[decision] %s - %s, %s"):format(group.title, plural(#group.files, "file"), plural(hunks, "hunk"))
  if superseded > 0 then text = text .. ", " .. superseded .. " superseded" end
  if gone > 0 then text = text .. ", " .. gone .. " gone" end
  if unobserved > 0 then text = text .. ", " .. unobserved .. " not observed" end
  return text
end

function M.changes()
  if not M.session then return end
  local entries = M.session:file_entries()
  if #entries == 0 then return notify("No observed changed files yet") end
  local items = {}
  for _, entry in ipairs(entries) do
    add_file_items(items, M.session.root, entry.path, entry, "")
  end
  vim.fn.setqflist({}, "r", { title = "Pair observed changes", items = items })
  vim.cmd("copen")
end

-- The same evidence as :PairChanges, arranged under the decisions that name the
-- files, so one implementation decision reads as one unit instead of as a run of
-- unrelated files. A group label is not a location, so headers are text-only
-- entries.
function M.groups()
  if not M.session then return end
  local groups, unclaimed = M.session:groups()
  if #groups == 0 and #unclaimed == 0 then return notify("No observed changed files yet") end
  local items = {}
  for _, group in ipairs(groups) do
    items[#items + 1] = { text = group_header(group), valid = 0 }
    for _, file in ipairs(group.files) do
      add_file_items(items, M.session.root, file.path, file.entry, file_note(file))
    end
  end
  if #unclaimed > 0 then
    local hunks = 0
    for _, file in ipairs(unclaimed) do hunks = hunks + #file.entry.hunks end
    items[#items + 1] = { text = ("[no decision] observed changes - %s, %s"):format(plural(#unclaimed, "file"), plural(hunks, "hunk")), valid = 0 }
    for _, file in ipairs(unclaimed) do
      add_file_items(items, M.session.root, file.path, file.entry, "")
    end
  end
  vim.fn.setqflist({}, "r", { title = "Pair change groups", items = items })
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
    PairGroups = M.groups,
  }
  for name, callback in pairs(commands) do
    vim.api.nvim_create_user_command(name, callback, {})
  end
end

return M
