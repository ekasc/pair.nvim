local Changes = {}
Changes.__index = Changes

local function fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return "<deleted>" end
  if stat.type ~= "file" then return "<non-file>" end
  -- Only read files that git has already identified as dirty. Binary safe.
  if stat.size <= 2 * 1024 * 1024 then
    local handle = io.open(path, "rb")
    if handle then
      local bytes = handle:read("*a")
      handle:close()
      return vim.fn.sha256(bytes)
    end
  end
  local mtime = stat.mtime or {}
  return table.concat({ stat.size, mtime.sec or 0, mtime.nsec or 0 }, ":")
end

local function dirty_files(root)
  -- Porcelain -z preserves whitespace and non-ASCII names. Renames carry a
  -- second NUL-delimited original path, which is not the current target.
  -- A missing or unusable git binary makes vim.system raise rather than return
  -- a failure code, so observation must degrade to "unavailable" instead of
  -- aborting the session. Without this, chat cannot start on a git-less host.
  local ok, result = pcall(vim.system, { "git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all" }, { text = false })
  if not ok then return nil end
  result = result:wait(5000)
  if result.code ~= 0 then return nil end
  local output = result.stdout or ""
  local files = {}
  local index = 1
  while index <= #output do
    local eol = output:find("\0", index, true)
    if not eol then break end
    local record = output:sub(index, eol - 1)
    index = eol + 1
    if #record >= 4 then
      local status = record:sub(1, 2)
      local path = record:sub(4)
      if status:find("R", 1, true) or status:find("C", 1, true) then
        local previous = output:find("\0", index, true)
        if previous then index = previous + 1 end
      end
      if path ~= "" then files[path] = fingerprint(root .. "/" .. path) end
    end
  end
  return files
end

function Changes.new(root, on_change)
  local self = setmetatable({ root = root, on_change = on_change, checkpoints = {}, files = {}, last = {} }, Changes)
  self.last = dirty_files(root) or {}
  return self
end

function Changes:before(id)
  self.checkpoints[id] = dirty_files(self.root) or vim.deepcopy(self.last)
end

function Changes:after(id)
  local before = self.checkpoints[id] or self.last
  self.checkpoints[id] = nil
  local after = dirty_files(self.root)
  if not after then return end
  local paths = {}
  for path, hash in pairs(after) do
    if before[path] ~= hash then paths[#paths + 1] = path end
  end
  for path in pairs(before) do
    if after[path] == nil then paths[#paths + 1] = path end
  end
  table.sort(paths)
  self.last = after
  for _, path in ipairs(paths) do self.files[path] = true end
  if #paths > 0 and self.on_change then self.on_change(paths, id) end
end

return Changes
