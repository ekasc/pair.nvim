local Changes = {}
Changes.__index = Changes

-- A file larger than this is tracked by size and mtime instead of content, so
-- it gets a revision but no line-level hunks.
local MAX_FILE_BYTES = 2 * 1024 * 1024
-- Total content a single checkpoint keeps in memory. Beyond this, files are
-- still hashed and still reported, they just cannot be diffed later.
local MAX_CHECKPOINT_BYTES = 8 * 1024 * 1024
-- A tool that never reports an end would otherwise pin its snapshot forever.
local MAX_CHECKPOINTS = 8

local function read_content(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  if stat.size > MAX_FILE_BYTES then return nil end
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

local function stat_key(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return "<deleted>" end
  if stat.type ~= "file" then return "<non-file>" end
  local mtime = stat.mtime or {}
  return table.concat({ stat.size, mtime.sec or 0, mtime.nsec or 0 }, ":")
end

local function git_paths(root)
  -- Porcelain -z preserves whitespace and non-ASCII names. Renames carry a
  -- second NUL-delimited original path, which is not the current target.
  -- A missing or unusable git binary makes vim.system raise rather than return
  -- a failure code, so observation must degrade to "unavailable" instead of
  -- aborting the session. Without this, chat cannot start on a git-less host.
  local ok, handle = pcall(vim.system, { "git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all" }, { text = false })
  if not ok then return nil end
  local result = handle:wait(5000)
  if result.code ~= 0 then return nil end
  local output = result.stdout or ""
  local paths = {}
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
      if path ~= "" then paths[#paths + 1] = path end
    end
  end
  return paths
end

-- `result_type = "indices"` returned a flat list of integers before Neovim 0.11
-- and a list of four-element hunks after it. Accept either shape.
local function group_hunks(result)
  local flat = {}
  if type(result[1]) == "table" then
    for _, hunk in ipairs(result) do
      for i = 1, 4 do flat[#flat + 1] = hunk[i] end
    end
  else
    flat = result
  end
  local hunks = {}
  for i = 1, #flat - 3, 4 do
    hunks[#hunks + 1] = {
      old_start = flat[i], old_count = flat[i + 1],
      new_start = flat[i + 2], new_count = flat[i + 3],
    }
  end
  return hunks
end

function Changes.hunks_between(before, after)
  if type(before) ~= "string" or type(after) ~= "string" then return {} end
  local ok, result = pcall(vim.diff, before, after, { result_type = "indices" })
  if not ok or type(result) ~= "table" then return {} end
  return group_hunks(result)
end

local function snapshot(root)
  local paths = git_paths(root)
  if not paths then return nil end
  local budget = MAX_CHECKPOINT_BYTES
  local files = {}
  for _, path in ipairs(paths) do
    local full = root .. "/" .. path
    local content = read_content(full)
    if content then
      local entry = { key = vim.fn.sha256(content) }
      if #content <= budget then
        budget = budget - #content
        entry.content = content
      end
      files[path] = entry
    else
      files[path] = { key = stat_key(full) }
    end
  end
  return files
end

local function forget_content(files)
  for _, entry in pairs(files) do entry.content = nil end
  return files
end

function Changes.new(root, on_change)
  local self = setmetatable({
    root = root, on_change = on_change, checkpoints = {}, order = {}, files = {}, last = {},
  }, Changes)
  -- The baseline keeps revisions but not content: its content is only needed
  -- when a tool start was never seen, and unbounded retention buys nothing.
  self.last = forget_content(snapshot(root) or {})
  return self
end

function Changes:before(id)
  self.checkpoints[id] = snapshot(self.root) or vim.deepcopy(self.last)
  self.order[#self.order + 1] = id
  while #self.order > MAX_CHECKPOINTS do
    self.checkpoints[table.remove(self.order, 1)] = nil
  end
end

function Changes:after(id)
  local before = self.checkpoints[id] or self.last
  self.checkpoints[id] = nil
  for index, pending in ipairs(self.order) do
    if pending == id then
      table.remove(self.order, index)
      break
    end
  end
  local after = snapshot(self.root)
  if not after then return end
  local observed = {}
  for path, entry in pairs(after) do
    local previous = before[path]
    if not previous or previous.key ~= entry.key then
      observed[#observed + 1] = {
        path = path,
        status = previous and "changed" or "appeared",
        revision = entry.key,
        previous_revision = previous and previous.key or nil,
        hunks = previous and Changes.hunks_between(previous.content, entry.content) or {},
      }
    end
  end
  for path, previous in pairs(before) do
    if after[path] == nil then
      -- Leaving the dirty set means a commit, a revert or a removal. Reading the
      -- file separates them without guessing: unchanged bytes mean a commit,
      -- changed bytes mean the explained revision is gone, and no file at all
      -- means there is nothing left to compare against.
      local content = read_content(self.root .. "/" .. path)
      observed[#observed + 1] = {
        path = path,
        status = "disappeared",
        revision = content and vim.fn.sha256(content) or nil,
        previous_revision = previous.key,
        hunks = content and Changes.hunks_between(previous.content, content) or {},
      }
    end
  end
  table.sort(observed, function(a, b) return a.path < b.path end)
  self.last = forget_content(after)
  for _, entry in ipairs(observed) do self.files[entry.path] = entry end
  if #observed > 0 and self.on_change then self.on_change(observed, id) end
end

return Changes
