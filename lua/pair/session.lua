local Pi = require("pair.pi")
local Ui = require("pair.ui")
local Changes = require("pair.changes")
local Directive = require("pair.directive")
local Groups = require("pair.groups")
local Marks = require("pair.marks")

local Session = {}
Session.__index = Session

local function extract_text(message)
  if not message then return "" end
  if type(message.content) == "string" then return message.content end
  local parts = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "text" and type(block.text) == "string" then parts[#parts + 1] = block.text end
  end
  return table.concat(parts, "\n")
end

local function collect_decisions(text)
  local decisions = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    -- The rationale is free text and may itself contain "|". Only the first and
    -- last separators delimit the record, so a pipe inside the rationale cannot
    -- shift the title or the file list.
    local body = line:match("^%s*PAIR_DECISION:%s*(.-)%s*$")
    local first = body and body:find("|", 1, true)
    local last = body and body:match(".*()|")
    if body and first and last and last > first then
      local title = vim.trim(body:sub(1, first - 1))
      local rationale = vim.trim(body:sub(first + 1, last - 1))
      local files = vim.trim(body:sub(last + 1))
      if title ~= "" and rationale ~= "" then
        -- One path written two ways, or named twice, is one file. The records that
        -- compare these names against the editor's do it by exact equality, and a
        -- buffer's path has already been normalized by then, so a "./src/a.lua"
        -- left as written would name nothing at all.
        local paths, seen = {}, {}
        if files ~= "-" then
          for file in files:gmatch("[^,]+") do
            file = vim.fs.normalize(vim.trim(file))
            if file ~= "" and not seen[file] then
              seen[file] = true
              paths[#paths + 1] = file
            end
          end
        end
        decisions[#decisions + 1] = { title = title, rationale = rationale, files = paths }
      end
    end
  end
  return decisions
end

local function buffer_context(root)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then return nil end
  local full = vim.api.nvim_buf_get_name(buf)
  if full == "" then return nil end
  full = vim.fs.normalize(full)
  local prefix = vim.fs.normalize(root) .. "/"
  if full:sub(1, #prefix) ~= prefix then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return { file = full:sub(#prefix + 1), line = line }
end

function Session.new(root, config)
  local self = setmetatable({
    root = root, config = config, initialized = false, follow = config.follow_edits,
    file_log = {}, status = "idle", active_message = nil, backend = nil,
  }, Session)
  self.ui = Ui.new(config.ui,
    function(text, steer, context) return self:submit(text, steer, context) end,
    function(file) self:open_file(file) end)
  self.changes = Changes.new(root, function(files, id, unavailable) self:files_changed(files, id, unavailable) end)
  self.backend = Pi.new(config.pi, function(kind, event) self:on_event(kind, event) end)
  return self
end

function Session:start()
  local ok, err = self.backend:start(self.root)
  if not ok then return false, err end
  self.ui:add("status", "Connected to Pi RPC. One session; chat, coding and teaching share context.")
  self.ui:open()
  return true
end

-- What a question is attached to, on one line for the transcript: where it was
-- asked, and, for a file a decision named, that decision and the files the record
-- named. The link is by name, which is the only one the plugin has.
local function context_label(context)
  local parts = { context.file .. ":" .. context.line }
  if context.decision then
    parts[#parts + 1] = "decision: " .. context.decision
    if #(context.files or {}) > 0 then parts[#parts + 1] = "files: " .. table.concat(context.files, ", ") end
  end
  return table.concat(parts, " · ")
end

local function context_message(context, text)
  local message = ("Neovim location (may change during execution): %s:%d"):format(context.file, context.line)
  if context.decision then
    -- Named, never attributed: the record names this file, and saying so gives the
    -- question the context the session actually holds.
    message = message .. "\nA recorded decision that named this file: " .. context.decision
      .. "\nFiles that decision named: " .. table.concat(context.files or {}, ", ")
  end
  return message .. "\n\n" .. text
end

function Session:submit(text, steer, context)
  local message = context and context_message(context, text) or text
  if not self.initialized then
    message = Directive.build(self.config) .. "\n\n---\nUser request:\n" .. message
  end
  local ok, err, command = self.backend:prompt(message, steer and "steer" or "followUp")
  if not ok then
    self.ui:add("error", err or "Unable to send prompt")
    return false
  end
  self.initialized = true
  self.ui:add("user", text .. (context and ("\n[" .. context_label(context) .. "]") or ""))
  if command == "follow_up" then
    self.ui:add("status", "Question queued after the current run. Use <C-t> to steer at a turn boundary.")
  elseif command == "steer" then
    self.ui:add("status", "Steering request queued for the next agent turn.")
  end
  return true
end

function Session:on_event(kind, event)
  if kind == "error" then
    self.ui:add("error", tostring(event))
  elseif kind == "stderr" then
    self.ui:add("error", "Pi diagnostic: " .. event)
  elseif kind == "exit" then
    self.status = "stopped"
    self.ui:add("status", "Pi exited with code " .. tostring(event))
  elseif kind == "state" then
    if event.sessionId then self.ui:add("status", "Session: " .. event.sessionId) end
  elseif kind ~= "event" then
    return
  elseif event.type == "agent_start" then
    self.status = "working"
    self.ui:add("status", "Agent working")
  elseif event.type == "agent_settled" then
    self.status = "idle"
    self.ui:add("status", event.aborted and "Agent interrupted" or "Agent idle")
  elseif event.type == "message_start" and event.message and event.message.role == "assistant" then
    -- The answer entry is created with the first text of the turn, not at its
    -- start: a turn can end with no text at all, such as one a provider refused,
    -- and an empty answer section would present that as a reply.
    self.active_message = nil
  elseif event.type == "message_update" then
    local update = event.assistantMessageEvent or {}
    if update.type == "text_delta" then
      if not self.active_message then self.active_message = self.ui:add("agent", "") end
      self.active_message.text = self.active_message.text .. (update.delta or "")
      self.ui:request_render()
    elseif update.type == "text_end" and self.active_message then
      -- message_end will replace this with authoritative complete text.
      self.ui:request_render()
    end
  elseif event.type == "message_end" and event.message and event.message.role == "assistant" then
    local text = extract_text(event.message)
    if self.active_message then
      self.active_message.text = text
    elseif text ~= "" then
      self.ui:add("agent", text)
    end
    self.active_message = nil
    -- A turn can end in a provider or model failure, which Pi reports on the
    -- message rather than as a failed command: the prompt response says success,
    -- the message carries stopReason "error" and the reason, and its content is
    -- empty or partial. Without that reason the transcript would show a silence
    -- from the model that never happened. Whatever text did arrive is still read
    -- for decision records.
    if event.message.stopReason == "error" then
      self.ui:add("error", "Pi reported a failed turn: " .. (event.message.errorMessage or "no reason given"))
    end
    for _, decision in ipairs(collect_decisions(text)) do
      -- Bind the explanation to the reading each file it names was last observed
      -- at, so a later change can be recognised as having invalidated it. The key
      -- is what the comparison uses; the revision is what a reader sees.
      local bindings = {}
      for _, path in ipairs(decision.files) do
        local observed = self.file_log[path]
        if observed then
          bindings[path] = {
            key = observed.key,
            revision = observed.revision,
            gone = observed.status == "gone",
          }
        end
      end
      -- The rationale is the body a reader sees; the title is kept as its own
      -- field so a view can label the decision without parsing that body.
      local entry = self.ui:add("decision", decision.title .. "\n" .. decision.rationale, decision.files, bindings)
      entry.title = decision.title
    end
    self.ui:request_render()
  elseif event.type == "tool_execution_start" then
    if event.toolCallId == nil then
      -- A tool with no id cannot be paired with its end, so its window cannot be
      -- observed. Reported rather than thrown: this runs inside an event callback.
      self.ui:add("error", "A tool started without an id; its changes cannot be observed.")
    else
      self.changes:before(event.toolCallId)
    end
    if event.toolName then self.ui:add("tool", "Running " .. event.toolName) end
  elseif event.type == "tool_execution_end" then
    if event.toolCallId ~= nil then self.changes:after(event.toolCallId) end
    if event.isError then self.ui:add("error", "Tool failed: " .. tostring(event.toolName)) end
  elseif event.type == "extension_ui_request" then
    self:extension_dialog(event)
  elseif event.type == "compaction_start" then
    self.ui:add("status", "Pi compacting its context")
  elseif event.type == "auto_retry_start" then
    self.ui:add("status", "Pi retrying after provider error")
  end
end

function Session:extension_dialog(event)
  if event.method == "notify" then
    self.ui:add("status", event.message or "Extension notification")
    return
  end
  if event.method == "set_editor_text" then
    if self.ui.input_buf and vim.api.nvim_buf_is_valid(self.ui.input_buf) then
      vim.api.nvim_buf_set_lines(self.ui.input_buf, 0, -1, false, vim.split(event.text or "", "\n", { plain = true }))
    end
    return
  end
  if event.method == "setStatus" or event.method == "setTitle" or event.method == "setWidget" then return end
  if event.method == "confirm" then
    vim.ui.select({ "No", "Yes" }, { prompt = (event.title or "Pi request") .. ": " .. (event.message or "") }, function(choice)
      self.backend:reply(event.id, { confirmed = choice == "Yes", cancelled = choice == nil })
    end)
    return
  end
  if event.method == "select" then
    vim.ui.select(event.options or {}, { prompt = event.title or "Pi selection" }, function(choice)
      self.backend:reply(event.id, { value = choice, cancelled = choice == nil })
    end)
    return
  end
  if event.method == "input" or event.method == "editor" then
    vim.ui.input({ prompt = event.title or "Pi input", default = event.prefill or "" }, function(value)
      self.backend:reply(event.id, { value = value, cancelled = value == nil })
    end)
    return
  end
  self.ui:add("error", "Unsupported Pi extension dialog: " .. tostring(event.method))
  self.backend:reply(event.id, { cancelled = true })
end

function Session:files_changed(entries, tool_id, unavailable)
  if unavailable then
    self.ui:add("status", "No change observation for tool " .. tostring(tool_id) .. ": " .. unavailable .. ".")
    return
  end
  local paths = {}
  for _, entry in ipairs(entries) do paths[#paths + 1] = entry.path end
  self.ui:add("files", "Changes observed during tool " .. tostring(tool_id) .. " (not proof of authorship):", paths)
  for _, entry in ipairs(entries) do
    local file = entry.path
    self.file_log[file] = entry
    if entry.key then
      -- An explanation recorded against a different reading no longer describes
      -- what is on disk. When the key is unchanged this call changes nothing, so
      -- a commit does not invalidate anything, and a file that comes back to the
      -- explained bytes stops being marked.
      self.ui:mark_revised(file, entry.key)
    elseif entry.status == "gone" then
      -- No key exists to compare with, but the file an explanation names is no
      -- longer there, which is its own fact.
      self.ui:mark_gone(file)
    else
      -- The window reported this path, so something is at it and the absence an
      -- explanation recorded has ended. Nothing was read, because a directory,
      -- a submodule or a file that cannot be opened is not a reading, so no
      -- comparison is claimed either: no key means the explanation stops being
      -- marked as stale without being called current.
      self.ui:mark_revised(file, nil)
    end
    self:refresh_buffer(file, entry)
  end
  if self.follow and #entries > 0 then self:open_file(entries[#entries].path) end
end

-- The buffer holding this file, found by name rather than by pattern. `bufnr()`
-- matches its argument as a glob, so a file called `a[1].lua` resolves to `a1.lua`
-- when both are open: the observation would then reload and mark a buffer holding
-- another file, leaving the file it did observe stale.
local function buffer_for(path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(candidate) == path then return candidate end
  end
  return -1
end

function Session:refresh_buffer(file, entry)
  local full = self.root .. "/" .. file
  local bufnr = buffer_for(full)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  if vim.bo[bufnr].modified then
    self.ui:add("status", "Unsaved buffer conflicts with disk change: " .. file)
    -- The buffer holds neither the revision it was marked at nor the one just
    -- observed, and the user's own edits have already moved any mark on it. Line
    -- numbers belonging to neither revision are cleared rather than left behind.
    Marks.clear(bufnr)
    return
  end
  -- Force one silent reload, then put the user's option back. Observation
  -- must not leave editor settings changed behind it.
  local autoread = vim.bo[bufnr].autoread
  vim.bo[bufnr].autoread = true
  vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! checktime") end)
  vim.bo[bufnr].autoread = autoread
  -- Marks describe line numbers in the revision just observed. The buffer is
  -- checked against that revision instead of being trusted to have reloaded:
  -- line numbers from another revision would point at the wrong code.
  if Marks.matches(bufnr, entry.revision) then
    Marks.apply(bufnr, entry.hunks)
  else
    Marks.clear(bufnr)
  end
end

function Session:open_file(file)
  local full = vim.fs.normalize(self.root .. "/" .. file)
  local prefix = vim.fs.normalize(self.root) .. "/"
  if full:sub(1, #prefix) ~= prefix then
    self.ui:add("error", "Refusing to open a file outside the project root")
    return
  end
  local real_root = vim.uv.fs_realpath(self.root)
  local real_path = vim.uv.fs_realpath(full)
  if not real_path then
    self.ui:add("status", "File no longer exists: " .. file)
    return
  end
  if real_root and real_path:sub(1, #real_root + 1) ~= real_root .. "/" then
    self.ui:add("error", "Refusing to follow a symlink outside the project root: " .. file)
    return
  end
  local win = self.ui.origin_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    for _, candidate in ipairs(vim.api.nvim_list_wins()) do
      if candidate ~= self.ui.input_win and candidate ~= self.ui.transcript_win then win = candidate break end
    end
  end
  if not win then return end
  vim.api.nvim_set_current_win(win)
  -- `:edit` refuses to abandon a modified buffer. That refusal is intended, but
  -- it must surface as a reported outcome rather than as E37 thrown out of a
  -- keymap or an event callback.
  if not pcall(vim.cmd, "edit " .. vim.fn.fnameescape(full)) then
    self.ui:add("status", "Refused to open " .. file .. ": the target window has unsaved changes")
    return
  end
  local entry = self.file_log[file]
  if entry then
    local bufnr = vim.api.nvim_get_current_buf()
    if Marks.matches(bufnr, entry.revision) then
      Marks.apply(bufnr, entry.hunks)
    else
      Marks.clear(bufnr)
    end
  end
end

-- The decision a question asked at `file` is about: the most recent one whose
-- record named that file. Titles are labels, so a file named by several decisions
-- answers with the newest, which is the one the code most likely still follows.
-- This reads the transcript, so a decision the entry cap has pruned is no longer
-- found, and the question then carries its location alone.
function Session:decision_naming(file)
  for index = #self.ui.entries, 1, -1 do
    local entry = self.ui.entries[index]
    if entry.role == "decision" then
      for _, path in ipairs(entry.files or {}) do
        if path == file then return entry end
      end
    end
  end
  return nil
end

function Session:context()
  local context = buffer_context(self.root)
  if not context then return nil end
  local decision = self:decision_naming(context.file)
  if decision then
    -- Referred to rather than copied: the transcript entry is the record, and the
    -- files it named are the ones this question is about.
    context.decision = decision.title
    context.files = decision.files
  end
  return context
end

function Session:files()
  local paths = vim.tbl_keys(self.file_log)
  table.sort(paths)
  return paths
end

function Session:file_entries()
  local entries = {}
  for _, entry in pairs(self.file_log) do entries[#entries + 1] = entry end
  table.sort(entries, function(a, b) return a.path < b.path end)
  return entries
end

-- The decisions stated in this session, oldest first. This reads the transcript,
-- so a decision the entry cap has pruned is no longer named here.
function Session:decisions()
  local found = {}
  for _, entry in ipairs(self.ui.entries) do
    if entry.role == "decision" then found[#found + 1] = entry end
  end
  return found
end

-- Observed changes connected to the decisions that name their files.
function Session:groups()
  return Groups.build(self:decisions(), self.file_log)
end

return Session
