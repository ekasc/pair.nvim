local Changes = {}
Changes.__index = Changes

-- A file larger than this is tracked by size and mtime instead of content. It
-- gets no content revision and no line-level diff: reading it to hash it would
-- cost as much memory as the file itself.
local MAX_FILE_BYTES = 2 * 1024 * 1024
-- Published so that wording about the ceiling is derived from the ceiling.
Changes.MAX_FILE_BYTES = MAX_FILE_BYTES
-- Total content a single checkpoint keeps so it can be diffed later. Files past
-- the budget are still reported, with the reason their diff is missing.
local MAX_CHECKPOINT_BYTES = 8 * 1024 * 1024
-- A tool that never reports an end would otherwise pin its snapshot forever.
local MAX_CHECKPOINTS = 8

-- Returns the file's bytes, or nil plus why they are unavailable: "gone" when
-- nothing is there, "not_a_file" for a directory or submodule, "too_large" past
-- the ceiling, "unreadable" when a regular file cannot be opened.
local function read_bytes(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, "gone" end
  if stat.type ~= "file" then return nil, "not_a_file" end
  if stat.size > MAX_FILE_BYTES then return nil, "too_large" end
  local handle = io.open(path, "rb")
  if not handle then return nil, "unreadable" end
  local bytes = handle:read("*a")
  handle:close()
  return bytes, nil
end

-- A change-detection key. It answers "did this file change", not "what is in
-- it", so it is never published as a revision. Content that can be hashed gets
-- its hash; a file past the ceiling gets a size and mtime fingerprint; anything
-- that cannot be measured gets nothing.
local function stat_key(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size <= MAX_FILE_BYTES then return nil end
  local mtime = stat.mtime or {}
  return table.concat({ stat.size, mtime.sec or 0, mtime.nsec or 0 }, ":")
end

-- Returns the changed paths plus a map from each rename's original path to its
-- current one. Nil means git itself is unavailable.
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
  local renamed = {}
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
        if previous then
          renamed[output:sub(index, previous - 1)] = path
          index = previous + 1
        end
      end
      if path ~= "" then paths[#paths + 1] = path end
    end
  end
  return paths, renamed
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

-- Hunks from an earlier reading to the current one, or nil hunks plus the reason
-- they are missing. `gap` is nil exactly when a reading kept its content, so a
-- gap on either side is why the diff cannot be computed.
local function diff_pair(previous, entry)
  -- A first reading has nothing to compare against, which is expected rather
  -- than a gap in the observation.
  if not previous or not previous.key then return {}, entry.gap end
  local missing = previous.gap or entry.gap
  if missing then return {}, missing end
  return Changes.hunks_between(previous.content, entry.content), nil
end

-- Why a reading has no content, or nil when the bytes were read. "budget" means
-- they were read and then dropped to stay inside the checkpoint budget, so it is
-- a reason a diff is missing rather than a reason nothing could be read.
local function read_reason(entry)
  if entry.gap == "budget" then return nil end
  return entry.gap
end

-- The status of a path whose bytes cannot be read: "gone" when nothing is there,
-- "unreadable" when something is but cannot be measured, and nil when the reader has
-- already been told the same thing. Porcelain keeps listing a staged deletion in
-- every window that follows it, and committing that deletion leaves the changed set
-- without changing what is on disk, so both directions of the comparison ask this
-- one question rather than one of them assuming the answer.
local function unread_state(changes, path, entry)
  local reported = changes.files[path]
  local state = entry.gap == "gone" and "gone" or "unreadable"
  if reported == nil or reported.status ~= state or reported.reason ~= read_reason(entry) then
    return state
  end
  return nil
end

local function snapshot(root)
  local paths, renamed = git_paths(root)
  if not paths then return nil end
  local candidates = {}
  for _, path in ipairs(paths) do
    local full = root .. "/" .. path
    local content, reason = read_bytes(full)
    candidates[#candidates + 1] = { path = path, full = full, content = content, gap = reason }
  end
  -- Spend the content budget on the cheapest files first. A large file's diff is
  -- the expensive one to compute, so which files lose theirs should not come
  -- down to alphabetical order.
  table.sort(candidates, function(a, b)
    local left = a.content and #a.content or math.huge
    local right = b.content and #b.content or math.huge
    if left == right then return a.path < b.path end
    return left < right
  end)
  local budget = MAX_CHECKPOINT_BYTES
  local files = {}
  for _, candidate in ipairs(candidates) do
    local entry = { gap = candidate.gap }
    if candidate.content then
      entry.revision = vim.fn.sha256(candidate.content)
      entry.key = entry.revision
      if #candidate.content <= budget then
        budget = budget - #candidate.content
        entry.content = candidate.content
      else
        entry.gap = "budget"
      end
    else
      entry.key = stat_key(candidate.full)
    end
    files[candidate.path] = entry
  end
  return files, renamed
end

-- A reading of a path that is no longer in the changed set: its bytes when they
-- can be read, a fingerprint when the file is too large to read, and nothing when
-- no readable file is there.
local function reading_of(full)
  local content, reason = read_bytes(full)
  if content then
    local entry = { key = vim.fn.sha256(content), content = content }
    entry.revision = entry.key
    return entry
  end
  local key = stat_key(full)
  if key then return { key = key, gap = reason } end
  return { gap = reason }
end

function Changes.new(root, on_change)
  return setmetatable({
    root = root, on_change = on_change, checkpoints = {}, order = {}, files = {},
    -- The state at the previous observation, which is what the next window
    -- compares against. See `before`.
    baseline = nil,
  }, Changes)
end

-- Whether a snapshot is already the baseline of an open window. Two tools can be
-- in flight at once, and each window must compare against a state that precedes
-- it rather than sharing one the other has already moved past.
local function held(self, taken)
  for _, pending in ipairs(self.order) do
    if self.checkpoints[pending] == taken then return true end
  end
  return false
end

function Changes:before(id)
  -- A tool event with no id cannot be paired with its end and cannot index a
  -- checkpoint either, so there is no window to open. Pi omits the id only on
  -- malformed input, and a raise here would land in the event callback.
  if id == nil then return end
  -- The baseline is the state at the previous observation, not one taken now. Pi
  -- reports a tool that finishes quickly by sending its start and its end
  -- together, and by then the write is already on disk, so a snapshot taken when
  -- the start arrives would hold the very change this window exists to report.
  -- The first window of a session, and a tool that opens while another is still
  -- in flight, have no shared past observation and take the state now. `false`
  -- records that a window was opened but nothing could be seen in it, so a host
  -- without a usable git stays quiet instead of reporting on every tool.
  local baseline = self.baseline
  if type(baseline) ~= "table" or held(self, baseline) then
    baseline = snapshot(self.root) or false
  end
  self.checkpoints[id] = baseline
  self.order[#self.order + 1] = id
  while #self.order > MAX_CHECKPOINTS do
    -- Dropping the oldest window is reported when its tool ends: the comparison
    -- is skipped rather than silently run against an older baseline.
    self.checkpoints[table.remove(self.order, 1)] = nil
  end
end

function Changes:after(id)
  if id == nil then return end
  local before = self.checkpoints[id]
  self.checkpoints[id] = nil
  for index, pending in ipairs(self.order) do
    if pending == id then
      table.remove(self.order, index)
      break
    end
  end
  if before == nil then
    -- No window was opened for this id, so there is no baseline. Reporting
    -- against an older one would credit this tool with changes it never made.
    if self.on_change then self.on_change({}, id, "no baseline was recorded before it ran") end
    return
  end
  if before == false then return end
  local after, renamed = snapshot(self.root)
  if not after then return end
  -- What this window just read becomes the baseline of the next one, so a tool
  -- whose start and end arrive together is still compared against the state
  -- before it ran.
  self.baseline = after
  -- A rename moves a reading rather than ending it. The new path is compared
  -- against the reading its old path had, so the diff is computed from the right
  -- baseline and reported where the file actually is: hunks carry line numbers
  -- in the new file, which the old path no longer is. Git reports a copy the same
  -- way, and a copy leaves the original in place, so a file that happens to hold
  -- the same bytes as one that is still there is a new file, not a moved reading.
  local origin_of = {}
  for origin, target in pairs(renamed or {}) do
    if after[origin] == nil then origin_of[target] = origin end
  end
  local observed = {}
  for path, entry in pairs(after) do
    local origin = origin_of[path]
    local previous = before[path] or (origin and before[origin])
    local status
    if entry.key == nil then
      -- Gone, a directory, a submodule, a file that cannot be opened: there is
      -- nothing to compare, so the state is news when the reader has not been
      -- told it.
      status = unread_state(self, path, entry)
    elseif previous == nil or previous.key == nil then
      status = "new"
    elseif previous.key ~= entry.key then
      status = "changed"
    end
    -- No status means nothing measurable changed during this window: the file was
    -- in the changed set before and after with the same key, or it was
    -- unmeasurable in the same way as before.
    if status then
      local hunks, hunks_reason = diff_pair(previous, entry)
      observed[#observed + 1] = {
        path = path,
        status = status,
        reason = read_reason(entry),
        key = entry.key,
        revision = entry.revision,
        hunks = hunks,
        hunks_reason = hunks_reason,
      }
    end
  end
  for path, previous in pairs(before) do
    if after[path] == nil then
      -- Leaving the changed set means a commit, a revert, a rename or a removal.
      -- Reading the file separates them without guessing: the same key means a
      -- commit, a different key means the explained reading is gone, and no file
      -- at all means there is nothing left to compare against.
      local full = self.root .. "/" .. path
      local renamed_to = renamed and renamed[path]
      local moved = renamed_to and after[renamed_to]
      local entry, status
      if moved then
        -- Git reported the rename, so the earlier reading still describes these
        -- bytes under the new name and the key keeps the comparison possible.
        -- The revision and the hunks describe the new path, and that is where
        -- they are reported; claiming them here would attach the new file's
        -- content hash and line numbers to a path holding neither.
        status = "renamed"
        entry = moved
      else
        entry = reading_of(full)
        if entry.key == nil then
          -- Nothing can be read at the path, so the same absence is not news when
          -- the reader has already been told it: committing a deletion takes the
          -- path out of the changed set while leaving the disk as it was, and
          -- reporting it again would date the removal to the commit.
          status = unread_state(self, path, entry)
        elseif previous.key == nil then
          status = "new"
        elseif previous.key == entry.key then
          status = "unchanged"
        else
          status = "changed"
        end
      end
      -- Hunks and the content hash describe the new path when a rename moved
      -- them, so neither is published under this one. No status means the path has
      -- left the changed set without saying anything the reader does not already
      -- have, and an entry is only added for a state worth reporting.
      if status then
        local hunks, hunks_reason, revision = {}, nil, entry.revision
        if moved then
          revision = nil
        else
          hunks, hunks_reason = diff_pair(previous, entry)
        end
        observed[#observed + 1] = {
          path = path,
          status = status,
          reason = read_reason(entry),
          renamed_to = moved and renamed_to or nil,
          key = entry.key,
          revision = revision,
          hunks = hunks,
          hunks_reason = hunks_reason,
        }
      end
    end
  end
  -- A rename whose old path had already left the changed set: the loop above walks
  -- the baseline, and this path is not in it, so nothing would report the move and
  -- a reader would keep being told that the old path holds the reading. Git did
  -- report it, and the last reading the reader was given is what the move keeps
  -- comparable, because the bytes did not change when the name did.
  for origin, target in pairs(renamed or {}) do
    if before[origin] == nil and after[origin] == nil and after[target] ~= nil then
      local known = self.files[origin]
      observed[#observed + 1] = {
        path = origin,
        status = "renamed",
        renamed_to = target,
        key = known and known.key or nil,
        revision = nil,
        hunks = {},
        hunks_reason = nil,
      }
    end
  end
  table.sort(observed, function(a, b) return a.path < b.path end)
  for _, entry in ipairs(observed) do self.files[entry.path] = entry end
  if #observed > 0 and self.on_change then self.on_change(observed, id) end
end

return Changes
