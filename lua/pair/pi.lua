local Pi = {}
Pi.__index = Pi

function Pi.new(options, on_event)
  return setmetatable({
    options = options,
    on_event = on_event,
    job = nil,
    fragment = "",
    pending = {},
    next_id = 0,
    busy = false,
  }, Pi)
end

function Pi:emit(kind, payload)
  if self.on_event then self.on_event(kind, payload) end
end

function Pi:feed(data)
  if not data or #data == 0 then return end
  local buffer = self.fragment .. table.concat(data, "\n")
  local offset = 1
  while true do
    local eol = buffer:find("\n", offset, true)
    if not eol then break end
    local line = buffer:sub(offset, eol - 1):gsub("\r$", "")
    offset = eol + 1
    if line ~= "" then
      local ok, record = pcall(vim.json.decode, line)
      if ok and type(record) == "table" then
        self:dispatch(record)
      else
        self:emit("error", "Invalid JSONL record from Pi")
      end
    end
  end
  self.fragment = buffer:sub(offset)
end

function Pi:dispatch(record)
  if record.type == "response" then
    local callback = record.id and self.pending[record.id]
    if record.id then self.pending[record.id] = nil end
    if not record.success then
      self:emit("error", record.error or ("Pi " .. (record.command or "command") .. " failed"))
    end
    if callback then callback(record) end
    return
  end
  if record.type == "agent_start" then self.busy = true end
  if record.type == "agent_settled" then self.busy = false end
  self:emit("event", record)
end

function Pi:start(root)
  if self.job then return true end
  if vim.fn.executable(self.options.command[1]) ~= 1 then
    return false, ("Pi executable not found: %s"):format(self.options.command[1])
  end
  local argv = vim.list_extend(vim.deepcopy(self.options.command), self.options.extra_args or {})
  local job = vim.fn.jobstart(argv, {
    cwd = root,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data) self:feed(data) end,
    on_stderr = function(_, data)
      local message = table.concat(data or {}, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if message ~= "" then self:emit("stderr", message) end
    end,
    on_exit = function(_, exit_code)
      self.job = nil
      self.busy = false
      self.pending = {}
      self:emit("exit", exit_code)
    end,
  })
  if job <= 0 then return false, "Unable to launch Pi RPC subprocess" end
  self.job = job
  self:send({ type = "get_state" }, function(result)
    if result.success then self:emit("state", result.data or {}) end
  end)
  return true
end

function Pi:send(request, callback)
  if not self.job then return false, "Pi is not running" end
  self.next_id = self.next_id + 1
  request.id = "pair-" .. self.next_id
  if callback then self.pending[request.id] = callback end
  -- chansend raises on a closed/invalid channel rather than returning 0, so the
  -- write must be guarded; a failed write frees the pending callback.
  local ok, sent = pcall(vim.fn.chansend, self.job, vim.json.encode(request) .. "\n")
  if not ok or sent == 0 then
    self.pending[request.id] = nil
    return false, "Pi RPC channel is closed"
  end
  return true
end

function Pi:reply(id, fields)
  if not self.job then return false, "Pi is not running" end
  local request = vim.tbl_extend("force", { type = "extension_ui_response", id = id }, fields or {})
  local ok, sent = pcall(vim.fn.chansend, self.job, vim.json.encode(request) .. "\n")
  return ok and sent ~= 0
end

function Pi:prompt(message, behavior)
  local command
  if self.busy then
    command = behavior == "steer" and "steer" or "follow_up"
  else
    command = "prompt"
    -- Mark busy immediately, closing the interval between dispatch and agent_start.
    self.busy = true
  end
  local ok, err = self:send({ type = command, message = message }, function(result)
    if command == "prompt" and (not result.success or (result.data or {}).disposition == "handled") then
      self.busy = false
    end
  end)
  if not ok and command == "prompt" then self.busy = false end
  return ok, err, command
end

function Pi:interrupt()
  -- Explicit abort only; normal questions never cancel the active run.
  return self:send({ type = "abort" })
end

function Pi:stop()
  if not self.job then return end
  local job = self.job
  -- Pi treats a closed stdin as a request for orderly shutdown.
  pcall(vim.fn.chanclose, job, "stdin")
end

return Pi
