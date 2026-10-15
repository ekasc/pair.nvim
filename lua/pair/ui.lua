local Ui = {}
Ui.__index = Ui

local function scratch(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name .. "/" .. buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function window_options(win, wrap)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = wrap
  vim.wo[win].spell = false
end

function Ui.new(options, on_submit, on_jump)
  local self = setmetatable({
    options = options,
    on_submit = on_submit,
    on_jump = on_jump,
    entries = {},
    transcript_buf = nil,
    input_buf = nil,
    transcript_win = nil,
    input_win = nil,
    origin_win = nil,
    targets = {},
    context = nil,
    pending_render = false,
  }, Ui)
  return self
end

function Ui:is_open()
  return self.transcript_win and vim.api.nvim_win_is_valid(self.transcript_win)
    and self.input_win and vim.api.nvim_win_is_valid(self.input_win)
end

function Ui:open()
  if self:is_open() then return self:focus() end
  -- One :q on a single sidebar window leaves the other stranded. Clear any
  -- surviving window before rebuilding so a second sidebar is never stacked.
  for _, win in ipairs({ self.input_win, self.transcript_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  self.input_win, self.transcript_win = nil, nil
  local current = vim.api.nvim_get_current_win()
  if current ~= self.transcript_win and current ~= self.input_win then self.origin_win = current end
  if not self.transcript_buf or not vim.api.nvim_buf_is_valid(self.transcript_buf) then
    self.transcript_buf = scratch("pair://conversation", "markdown")
    vim.bo[self.transcript_buf].modifiable = false
    vim.keymap.set("n", "<CR>", function() self:jump() end, { buffer = self.transcript_buf, silent = true, desc = "Open linked file" })
    vim.keymap.set("n", "q", function() self:close() end, { buffer = self.transcript_buf, silent = true })
    vim.keymap.set("n", "i", function() self:focus() end, { buffer = self.transcript_buf, silent = true })
  end
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then
    self.input_buf = scratch("pair://composer", "markdown")
    vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
    vim.keymap.set({ "n", "i" }, "<C-s>", function() self:send(false) end, { buffer = self.input_buf, silent = true, desc = "Send pair message" })
    vim.keymap.set({ "n", "i" }, "<C-t>", function() self:send(true) end, { buffer = self.input_buf, silent = true, desc = "Steer pair agent" })
  end

  vim.cmd("botright " .. self.options.width .. "vsplit")
  self.transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.transcript_win, self.transcript_buf)
  vim.wo[self.transcript_win].winfixwidth = true
  window_options(self.transcript_win, true)

  vim.cmd("belowright " .. self.options.composer_height .. "split")
  self.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.input_win, self.input_buf)
  vim.wo[self.input_win].winfixheight = true
  window_options(self.input_win, true)
  self:render()
  self:focus()
end

function Ui:close()
  for _, win in ipairs({ self.input_win, self.transcript_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  self.input_win = nil
  self.transcript_win = nil
  if self.origin_win and vim.api.nvim_win_is_valid(self.origin_win) then
    vim.api.nvim_set_current_win(self.origin_win)
  end
end

function Ui:focus()
  if not self:is_open() then return self:open() end
  vim.api.nvim_set_current_win(self.input_win)
  vim.cmd("startinsert")
end

function Ui:set_context(context)
  self.context = context
end

function Ui:send(steer)
  if not self.input_buf or not vim.api.nvim_buf_is_valid(self.input_buf) then return end
  local lines = vim.api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  local value = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" then return end
  if self.on_submit then
    local ok = self.on_submit(value, steer, self.context)
    if not ok then return end
  end
  vim.api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
  self.context = nil
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.api.nvim_set_current_win(self.input_win)
    vim.cmd("startinsert")
  end
end

function Ui:add(role, text, files)
  local entry = { role = role, text = text or "", files = files or {} }
  self.entries[#self.entries + 1] = entry
  if #self.entries > self.options.max_entries then table.remove(self.entries, 1) end
  self:request_render()
  return entry
end

function Ui:request_render()
  if self.pending_render then return end
  self.pending_render = true
  vim.defer_fn(function()
    self.pending_render = false
    self:render()
  end, 40)
end

function Ui:render()
  if not self:is_open() or not vim.api.nvim_buf_is_valid(self.transcript_buf) then return end
  local lines = { "PAIR  ·  <C-s> send  ·  <C-t> steer  ·  :PairChanges files", "" }
  local targets = {}
  for _, entry in ipairs(self.entries) do
    local heading = ({ user = "You", agent = "Agent", decision = "Decision", files = "Files", status = "Status", error = "Error", tool = "Tool" })[entry.role] or entry.role
    lines[#lines + 1] = "## " .. heading
    for _, line in ipairs(vim.split(entry.text or "", "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
    for _, file in ipairs(entry.files or {}) do
      lines[#lines + 1] = "  -> " .. file
      targets[#lines] = file
    end
    lines[#lines + 1] = ""
  end
  if #lines == 0 then lines = { "" } end
  local win = self.transcript_win
  local cursor = vim.api.nvim_win_get_cursor(win)
  local old_count = vim.api.nvim_buf_line_count(self.transcript_buf)
  local should_follow = cursor[1] >= old_count - 2
  vim.bo[self.transcript_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, lines)
  vim.bo[self.transcript_buf].modifiable = false
  self.targets = targets
  if should_follow then
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  else
    vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], #lines), cursor[2] })
  end
end

function Ui:jump()
  if not self.transcript_win or not vim.api.nvim_win_is_valid(self.transcript_win) then return end
  local row = vim.api.nvim_win_get_cursor(self.transcript_win)[1]
  local file = self.targets[row]
  if file and self.on_jump then self.on_jump(file) end
end

return Ui
