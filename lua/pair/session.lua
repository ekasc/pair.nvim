local Pi = require("pair.pi")
local Ui = require("pair.ui")
local Changes = require("pair.changes")
local Directive = require("pair.directive")

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
        local paths = {}
        if files ~= "-" then
          for file in files:gmatch("[^,]+") do
            file = vim.trim(file)
            if file ~= "" then paths[#paths + 1] = file end
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
  self.changes = Changes.new(root, function(files, id) self:files_changed(files, id) end)
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

function Session:submit(text, steer, context)
  local message = text
  if context then
    message = ("Neovim location (may change during execution): %s:%d\n\n%s"):format(context.file, context.line, text)
  end
  if not self.initialized then
    message = Directive.build(self.config) .. "\n\n---\nUser request:\n" .. message
  end
  local ok, err, command = self.backend:prompt(message, steer and "steer" or "followUp")
  if not ok then
    self.ui:add("error", err or "Unable to send prompt")
    return false
  end
  self.initialized = true
  self.ui:add("user", text .. (context and ("\n[" .. context.file .. ":" .. context.line .. "]") or ""))
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
    self.active_message = self.ui:add("agent", "")
  elseif event.type == "message_update" then
    local update = event.assistantMessageEvent or {}
    if update.type == "text_delta" and self.active_message then
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
    for _, decision in ipairs(collect_decisions(text)) do
      self.ui:add("decision", decision.title .. "\n" .. decision.rationale, decision.files)
    end
    self.ui:request_render()
  elseif event.type == "tool_execution_start" then
    self.changes:before(event.toolCallId)
    if event.toolName then self.ui:add("tool", "Running " .. event.toolName) end
  elseif event.type == "tool_execution_end" then
    self.changes:after(event.toolCallId)
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

function Session:files_changed(files, tool_id)
  self.ui:add("files", "Changes observed during tool " .. tostring(tool_id) .. " (not proof of authorship):", files)
  for _, file in ipairs(files) do
    self.file_log[file] = true
    local full = self.root .. "/" .. file
    local bufnr = vim.fn.bufnr(full)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.bo[bufnr].modified then
        self.ui:add("status", "Unsaved buffer conflicts with disk change: " .. file)
      else
        vim.bo[bufnr].autoread = true
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! checktime") end)
      end
    end
  end
  if self.follow and #files > 0 then self:open_file(files[#files]) end
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
  vim.cmd("edit " .. vim.fn.fnameescape(full))
end

function Session:context()
  return buffer_context(self.root)
end

function Session:files()
  local paths = vim.tbl_keys(self.file_log)
  table.sort(paths)
  return paths
end

return Session
