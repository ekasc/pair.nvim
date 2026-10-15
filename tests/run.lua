-- Portable logic tests. Run with `texlua tests/run.lua` (Lua 5.3) or Lua 5.1+.
-- No Pi process or provider credentials needed.
local script = arg[0] or "tests/run.lua"
local root = script:match("^(.*)/tests/run.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local function deepcopy(value)
  if type(value) ~= "table" then return value end
  local next_value = {}
  for k, v in pairs(value) do next_value[k] = deepcopy(v) end
  return next_value
end
local function deep_extend(_, a, b)
  local result = deepcopy(a)
  for k, v in pairs(b) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_extend("force", result[k], v)
    else
      result[k] = deepcopy(v)
    end
  end
  return result
end
local function split(s, delimiter)
  local parts, start = {}, 1
  while true do
    local at = s:find(delimiter, start, true)
    if not at then parts[#parts + 1] = s:sub(start); return parts end
    parts[#parts + 1] = s:sub(start, at - 1)
    start = at + #delimiter
  end
end
local function json_escape(s)
  return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end
local function encode(value)
  if type(value) == "string" then return '"' .. json_escape(value) .. '"' end
  if type(value) == "number" then return tostring(value) end
  if type(value) == "boolean" then return tostring(value) end
  if type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do out[#out + 1] = encode(k) .. ":" .. encode(v) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end
local decoded_lines = {}
local sent = {}
-- Mirrors the shape change in vim.diff's "indices" result: flat integers before
-- Neovim 0.11, a list of four-element hunks after it.
local diff_shape = "nested"
vim = {
  deepcopy = deepcopy,
  tbl_deep_extend = deep_extend,
  tbl_extend = deep_extend,
  split = split,
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  defer_fn = function() end,
  diff = function(a, b)
    if a == b then return {} end
    if diff_shape == "nested" then return { { 1, 1, 1, 1 } } end
    return { 1, 1, 1, 1 }
  end,
  json = { encode = encode, decode = function(s) return assert(decoded_lines[s], "unexpected JSON input: " .. s) end },
  fn = {
    executable = function() return 1 end,
    jobstart = function() return 123 end,
    bufnr = function() return -1 end,
    chansend = function(_, record) sent[#sent + 1] = record return #record end,
    chanclose = function() return 1 end,
    sha256 = function(s) return "hash-" .. tostring(#s) .. ":" .. s end,
  },
}

local successes, failures = 0, 0
-- Scratch directories created by tests. They are removed when each test ends,
-- including when it fails part-way and never reaches its own cleanup line, so a
-- failing run cannot leave a fixture behind on every attempt.
local temporaries = {}
local function workdir(suffix)
  local base = os.tmpname():gsub("^@", "")
  local path = base .. (suffix or "-pair")
  temporaries[#temporaries + 1] = base
  temporaries[#temporaries + 1] = path
  return path
end
local function test(name, body)
  local ok, err = pcall(body)
  for _, path in ipairs(temporaries) do os.execute("rm -rf " .. string.format("%q", path)) end
  temporaries = {}
  if ok then
    successes = successes + 1
    print("PASS " .. name)
  else
    failures = failures + 1
    io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local Pi = require("pair.pi")
local Config = require("pair.config")
local Directive = require("pair.directive")

test("configuration deep merges without losing defaults", function()
  local result = Config.setup({ ui = { width = 62 }, teaching = "verbose" })
  assert(result.ui.width == 62)
  assert(result.ui.composer_height == 6)
  assert(result.teaching == "verbose")
  assert(result.agent == "pi")
end)

test("directive is a compact behavioral preference, not system replacement", function()
  local directive = Directive.build(Config.options)
  assert(directive:find("PAIR_DECISION:", 1, true))
  assert(directive:find("normal tool permissions", 1, true))
  assert(directive:find("may change these in chat", 1, true))
end)

test("Pi JSONL framing handles fragmented records and multiple records", function()
  local seen = {}
  local pi = Pi.new({}, function(kind, event) seen[#seen + 1] = { kind, event } end)
  decoded_lines.one = { type = "agent_start" }
  decoded_lines.two = { type = "agent_settled" }
  pi:feed({ "one", "tw" })
  assert(#seen == 1 and pi.busy == true)
  pi:feed({ "o", "" })
  assert(#seen == 2 and pi.busy == false)
  assert(pi.fragment == "")
end)

test("Pi uses one session and queues followups instead of interrupting", function()
  sent = {}
  local pi = Pi.new({}, function() end)
  pi.job = 123
  assert(pi:prompt("first request"))
  assert(sent[1]:find('"prompt"', 1, true))
  assert(pi.busy)
  assert(pi:prompt("why", "followUp"))
  assert(sent[2]:find('"follow_up"', 1, true))
  assert(pi:prompt("change direction", "steer"))
  assert(sent[3]:find('"steer"', 1, true))
  pi:dispatch({ type = "agent_settled" })
  assert(pi:prompt("next turn"))
  assert(sent[4]:find('"prompt"', 1, true))
end)

test("Pi reports a closed channel instead of raising on send and reply", function()
  local pi = Pi.new({}, function() end)
  pi.job = 123
  local original = vim.fn.chansend
  vim.fn.chansend = function() error("Vim:E900: Invalid channel id") end
  local send_ok, send_err = pi:send({ type = "abort" })
  local reply_ok = pi:reply("extension-dialog-abc", { cancelled = true })
  vim.fn.chansend = original
  assert(send_ok == false)
  assert(send_err == "Pi RPC channel is closed")
  assert(reply_ok == false)
end)

test("stopping Pi reaps a process that ignores stdin closure", function()
  local scheduled, reaped = nil, {}
  local saved = { defer_fn = vim.defer_fn, jobstop = vim.fn.jobstop, chanclose = vim.fn.chanclose }
  vim.defer_fn = function(fn, ms) scheduled = { fn = fn, ms = ms } end
  vim.fn.jobstop = function(job) reaped[#reaped + 1] = job return 1 end
  vim.fn.chanclose = function() return 1 end

  local pi = Pi.new({}, function() end)
  pi.job = 4242
  pi:stop()
  local delay = scheduled and scheduled.ms
  if scheduled then scheduled.fn() end
  local first_reap = reaped[1]
  pi.job = nil -- on_exit fired before the fallback ran
  if scheduled then scheduled.fn() end
  local total_reaps = #reaped

  vim.defer_fn, vim.fn.jobstop, vim.fn.chanclose = saved.defer_fn, saved.jobstop, saved.chanclose

  assert(delay == 3000, "a bounded fallback must be scheduled")
  assert(first_reap == 4242, "a process still running must be terminated")
  assert(total_reaps == 1, "a process that already exited must not be terminated twice")
end)

test("Pi extension replies preserve the originating dialog ID", function()
  sent = {}
  local pi = Pi.new({}, function() end)
  pi.job = 123
  assert(pi:reply("extension-dialog-abc", { confirmed = false }))
  assert(sent[1]:find('"extension-dialog-abc"', 1, true))
  assert(sent[1]:find('"extension_ui_response"', 1, true))
  assert(not sent[1]:find('"pair%-1"'))
end)

test("Pi correlates RPC responses by request ID", function()
  local pi = Pi.new({}, function() end)
  pi.job = 123
  local actual = {}
  pi:send({ type = "get_state" }, function(response) actual[#actual + 1] = response.data.tag end)
  pi:send({ type = "get_entries" }, function(response) actual[#actual + 1] = response.data.tag end)
  pi:dispatch({ type = "response", id = "pair-2", success = true, data = { tag = "second" } })
  pi:dispatch({ type = "response", id = "pair-1", success = true, data = { tag = "first" } })
  assert(table.concat(actual, ",") == "second,first")
end)

-- Stub Neovim presentation and actual git IO to test higher-level session behavior.
local entries = {}
local mark_calls = {}
package.loaded["pair.ui"] = {
  new = function()
    local ui = { entries = entries }
    function ui:add(role, text, files, bindings)
      local entry = { role = role, text = text or "", files = files or {}, bindings = bindings or {} }
      entries[#entries + 1] = entry
      return entry
    end
    function ui:mark_revised(path, key)
      mark_calls[#mark_calls + 1] = { name = "mark_revised", path = path, key = key }
      return 0
    end
    function ui:mark_gone(path)
      mark_calls[#mark_calls + 1] = { name = "mark_gone", path = path }
      return 0
    end
    function ui:request_render() end
    function ui:open() end
    function ui:close() end
    return ui
  end,
}
package.loaded["pair.changes"] = {
  new = function(_, _, handler)
    return { before = function() end, after = function() end, handler = handler }
  end,
}
local Session = require("pair.session")

test("first prompt contains directive once, later prompt preserves context", function()
  entries, sent = {}, {}
  local session = Session.new("/repo", Config.options)
  session.backend.job = 123
  assert(session:submit("Implement feature", false, { file = "src/app.lua", line = 10 }))
  assert(sent[1]:find("PAIR_DECISION:", 1, true))
  session.backend:dispatch({ type = "agent_settled" })
  assert(session:submit("Why?", false))
  assert(not sent[2]:find("PAIR_DECISION:", 1, true))
end)

test("decision timeline connects rationale to multiple files", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session:on_event("event", {
    type = "message_end",
    message = { role = "assistant", content = { { type = "text", text = "Implemented.\nPAIR_DECISION: Atomic updates | Prevent competing writes | src/api.lua, tests/concurrency.lua" } } },
  })
  assert(entries[#entries].role == "decision")
  assert(entries[#entries].text:find("Prevent competing writes", 1, true))
  assert(entries[#entries].files[1] == "src/api.lua")
  assert(entries[#entries].files[2] == "tests/concurrency.lua")
end)

test("decision parser tolerates a pipe inside the free-text rationale", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session:on_event("event", {
    type = "message_end",
    message = { role = "assistant", content = { { type = "text", text = "PAIR_DECISION: Queueing | Use A, then B, for ordering | src/queue.lua, src/worker.lua" } } },
  })
  assert(entries[#entries].role == "decision")
  assert(entries[#entries].text:find("Use A, then B, for ordering", 1, true))
  assert(entries[#entries].files[1] == "src/queue.lua")
  assert(entries[#entries].files[2] == "src/worker.lua")
end)

test("session never sends hidden model thinking deltas to UI", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session:on_event("event", { type = "message_start", message = { role = "assistant", content = {} } })
  session:on_event("event", { type = "message_update", assistantMessageEvent = { type = "thinking_delta", delta = "internal" } })
  session:on_event("event", { type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "Visible explanation" } })
  assert(entries[#entries].text == "Visible explanation")
end)

test("a reading that leaves the changed set is reported apart from a removal", function()
  entries, mark_calls = {}, {}
  local session = Session.new("/repo", Config.options)
  session.file_log["src/a.lua"] = { path = "src/a.lua", status = "changed", key = "rev-old", revision = "rev-old", hunks = {} }

  -- Committed: the bytes still match the reading an explanation described, so
  -- the same key is reported and nothing is marked.
  session:files_changed({ { path = "src/a.lua", status = "unchanged", key = "rev-old", revision = "rev-old", hunks = {} } }, "tool-1")
  assert(mark_calls[1].name == "mark_revised" and mark_calls[1].key == "rev-old", tostring(mark_calls[1] and mark_calls[1].key))

  -- Reverted: the reading an explanation was written against is gone.
  session:files_changed({ { path = "src/a.lua", status = "changed", key = "rev-new", revision = "rev-new", hunks = {}, hunks_reason = "budget" } }, "tool-2")
  assert(mark_calls[2].key == "rev-new", tostring(mark_calls[2].key))
  assert(session.file_log["src/a.lua"].revision == "rev-new", "the file log keeps the latest reading")
  assert(session.revisions == nil, "the session keeps one registry, not two")

  -- Removed: nothing is left to compare against, so the absence itself is what
  -- gets reported.
  session:files_changed({ { path = "src/b.lua", status = "gone", key = nil, revision = nil, hunks = {}, hunks_reason = "gone" } }, "tool-3")
  assert(mark_calls[3].name == "mark_gone" and mark_calls[3].path == "src/b.lua", tostring(mark_calls[3] and mark_calls[3].name))
end)

test("a tool end with no window is reported instead of attributed", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session:files_changed({}, "tool-9", "no baseline was recorded before it ran")
  assert(entries[#entries].role == "status", entries[#entries].role)
  assert(entries[#entries].text:find("no baseline", 1, true), entries[#entries].text)
end)

test("an explanation binds the reading of each file it names", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session.file_log["src/a.lua"] = { path = "src/a.lua", status = "changed", key = "rev-1", revision = "rev-1" }
  session.file_log["src/b.lua"] = { path = "src/b.lua", status = "gone", key = nil, revision = nil }
  -- A file past the content ceiling is tracked by a fingerprint instead of a
  -- revision. The binding has to carry that fingerprint, because it is what the
  -- comparison uses; the revision it publishes is what a reader sees, and here
  -- there is none.
  session.file_log["src/big.lua"] = { path = "src/big.lua", status = "changed", key = "3145728:11:0", revision = nil }
  session:on_event("event", {
    type = "message_end",
    message = { role = "assistant", content = { { type = "text", text = "PAIR_DECISION: T | why | src/a.lua, src/b.lua, src/big.lua, src/never.lua" } } },
  })
  local decision = entries[#entries]
  assert(decision.bindings["src/a.lua"].key == "rev-1", tostring(decision.bindings["src/a.lua"].key))
  assert(decision.bindings["src/b.lua"].gone == true, "a file that is already absent is bound as absent")
  assert(decision.bindings["src/big.lua"].key == "3145728:11:0",
    "a large file is bound by its fingerprint, not by a revision it does not have: " .. tostring(decision.bindings["src/big.lua"].key))
  assert(decision.bindings["src/big.lua"].revision == nil, "and publishes no revision")
  assert(decision.bindings["src/never.lua"] == nil, "an unobserved file has nothing to bind")
end)

test("a tool event without an id is reported instead of raised", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  local ok, err = pcall(function()
    session:on_event("event", { type = "tool_execution_start", toolName = "write" })
    session:on_event("event", { type = "tool_execution_end", toolName = "write" })
  end)
  assert(ok, "a malformed tool event must not throw out of the event callback: " .. tostring(err))
  local reported = nil
  for _, entry in ipairs(entries) do
    if entry.role == "error" then reported = entry end
  end
  assert(reported ~= nil, "an unpaired tool event must be reported")
  assert(reported.text:find("without an id", 1, true), reported.text)
end)

test("observed changes are grouped under the decisions that name their files", function()
  local GroupsReal = dofile(root .. "/lua/pair/groups.lua")
  local log = {
    ["src/a.lua"] = { path = "src/a.lua", status = "changed", key = "rev-2", revision = "rev-2", hunks = { { new_start = 3, new_count = 1 } } },
    ["src/stray.lua"] = { path = "src/stray.lua", status = "new", key = "rev-3", revision = "rev-3", hunks = {} },
    ["zz.lua"] = { path = "zz.lua", status = "changed", key = "rev-4", revision = "rev-4", hunks = {} },
  }
  local decisions = {
    { title = "Atomic updates", files = { "src/a.lua", "src/never.lua" },
      bindings = { ["src/a.lua"] = { key = "rev-1", revision = "rev-1", revised = true } } },
    { title = "Queueing", files = { "src/a.lua" },
      bindings = { ["src/a.lua"] = { key = "rev-2", revision = "rev-2" } } },
    { title = "Nothing to place", files = {} },
  }
  local groups, unclaimed = GroupsReal.build(decisions, log)
  -- A decision that names no files holds no change, so it is not a change group.
  assert(#groups == 2, "groups: " .. #groups)
  assert(groups[1].title == "Atomic updates", tostring(groups[1].title))
  -- One file can be named by more than one decision. Each group reports it and
  -- reports its own binding for it rather than a shared verdict.
  assert(#groups[1].files == 2 and #groups[2].files == 1, "files per group")
  assert(groups[1].files[1].entry == log["src/a.lua"], "the group refers to the reading itself")
  assert(groups[1].files[1].superseded == true, "the mark of the decision that moved")
  assert(groups[2].files[1].superseded == false, "a decision still bound to the current reading")
  assert(groups[1].files[2].entry == nil, "a file no observation covered is listed as such")
  assert(groups[1].files[2].superseded == false, "and nothing is claimed about it")
  -- An observed path no decision names is listed apart, in path order, so a view
  -- built on groups does not hide it.
  assert(#unclaimed == 2, "unclaimed: " .. #unclaimed)
  assert(unclaimed[1].path == "src/stray.lua" and unclaimed[2].path == "zz.lua",
    unclaimed[1].path .. "," .. unclaimed[2].path)
  assert(unclaimed[1].superseded == false and unclaimed[1].gone == false, "no decision binds an unclaimed path")
end)

test("a decision labels the group of changes it names", function()
  entries = {}
  local session = Session.new("/repo", Config.options)
  session.file_log["src/a.lua"] = { path = "src/a.lua", status = "changed", key = "rev-1", revision = "rev-1",
    hunks = { { new_start = 2, new_count = 1 } } }
  session.file_log["src/stray.lua"] = { path = "src/stray.lua", status = "new", key = "rev-2", revision = "rev-2", hunks = {} }
  session:on_event("event", {
    type = "message_end",
    message = { role = "assistant", content = { { type = "text",
      text = "Implemented.\nPAIR_DECISION: Atomic updates | Prevent competing writes | src/a.lua, src/never.lua" } } },
  })
  local groups, unclaimed = session:groups()
  assert(#groups == 1 and #unclaimed == 1, "groups: " .. #groups .. " unclaimed: " .. #unclaimed)
  assert(groups[1].title == "Atomic updates", "the label is the title, not the entry body: " .. tostring(groups[1].title))
  assert(groups[1].files[1].entry == session.file_log["src/a.lua"], "the group shows the reading the log holds")
  assert(groups[1].files[2].entry == nil, "a decision may name a file nothing observed")
  assert(unclaimed[1].path == "src/stray.lua", tostring(unclaimed[1].path))
  assert(#session:decisions() == 1, "the transcript holds one decision")
  assert(groups[1].files[1].superseded == false, "nothing is marked before a second reading")
  -- What a group reports about staleness is the binding's mark, so a view built
  -- from it follows the observations instead of freezing at decision time.
  entries[#entries].bindings["src/a.lua"].revised = true
  local moved = session:groups()
  assert(moved[1].files[1].superseded == true, "the moved reading is reported")
  assert(moved[1].files[2].superseded == false, "only the bound file is marked")
end)

-- Exercise the actual NUL-delimited Git scanner using synthetic status output
-- and real file contents, without requiring Neovim or a Git repository.
test("multi-file scanner handles dirty edits, untracked spaces, renames", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local temp = workdir("-pair")
  os.execute("mkdir -p " .. string.format("%q", temp .. "/src") .. " " .. string.format("%q", temp .. "/tests"))
  local function write(relative, text)
    local f = assert(io.open(temp .. "/" .. relative, "wb"))
    f:write(text)
    f:close()
  end
  write("src/a.lua", "old")
  write("src/with space.lua", "unchanged")
  write("gone.lua", "temporary")
  write("src/previous.lua", "previous")
  write("src/keep.lua", "kept")
  write("tests/new.lua", "new")
  local before = " M src/a.lua\0?? src/with space.lua\0?? gone.lua\0?? src/previous.lua\0?? src/keep.lua\0"
  -- A copy is reported like a rename. The original stays where it is, so the copy
  -- is a new file and must not be read as the original's reading moving.
  local after = " M src/a.lua\0?? tests/new.lua\0R  renamed.lua\0src/previous.lua\0?? src/keep.lua\0C  copied.lua\0src/keep.lua\0"
  write("renamed.lua", "renamed")
  write("copied.lua", "kept")
  local outputs = { before, after }
  local calls = 0
  vim.system = function()
    calls = calls + 1
    return { wait = function() return { code = 0, stdout = outputs[calls] } end }
  end
  vim.uv = { fs_stat = function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return { type = "file", size = #data, mtime = { sec = 1, nsec = 1 } }
  end }
  local observed
  local tracker = ChangesReal.new(temp, function(entries) observed = entries end)
  tracker:before("call-1")
  write("src/a.lua", "updated")
  -- Three ways out of the dirty set, all after the before-snapshot: committed
  -- with the bytes intact, removed from the filesystem, and renamed.
  assert(os.remove(temp .. "/gone.lua"))
  assert(os.remove(temp .. "/src/previous.lua"))
  tracker:after("call-1")

  local by_path = {}
  for _, entry in ipairs(observed) do by_path[entry.path] = entry end
  local paths = {}
  for _, entry in ipairs(observed) do paths[#paths + 1] = entry.path end
  assert(table.concat(paths, ",") == "copied.lua,gone.lua,renamed.lua,src/a.lua,src/previous.lua,src/with space.lua,tests/new.lua", table.concat(paths, ","))

  local changed = by_path["src/a.lua"]
  assert(changed.status == "changed", changed.status)
  assert(changed.revision == "hash-7:updated", changed.revision)
  assert(changed.key == changed.revision, "a hashed file uses its hash as the change key")
  assert(#changed.hunks == 1, "a changed file carries hunks")
  assert(changed.renamed_to == nil, "an ordinary change is not a rename")
  assert(by_path["tests/new.lua"].status == "new", by_path["tests/new.lua"].status)
  assert(#by_path["tests/new.lua"].hunks == 0, "a first reading has no before-side hunks")
  assert(by_path["tests/new.lua"].hunks_reason == nil, "a first reading is not a gap in the observation")
  assert(by_path["copied.lua"].status == "new", "a copy of a file that is still there is a new file: " .. tostring(by_path["copied.lua"].status))
  assert(by_path["copied.lua"].renamed_to == nil, "a copy does not claim the original moved")
  assert(by_path["src/keep.lua"] == nil, "a file that was equally dirty before and after produces no entry")

  -- A rename is the same content under a new name. The reading stays comparable,
  -- so an explanation naming the old path is not invalidated by the move, and the
  -- new file's content hash and line numbers are reported under the new path,
  -- which is the path they describe.
  local renamed = by_path["src/previous.lua"]
  assert(renamed.status == "renamed", renamed.status)
  assert(renamed.renamed_to == "renamed.lua", tostring(renamed.renamed_to))
  assert(renamed.key == by_path["renamed.lua"].key, "the rename keeps the reading comparable")
  assert(renamed.revision == nil, "the new file's content hash is not published under the old path")
  assert(#renamed.hunks == 0, "the new file's line numbers are not filed under the old path")
  local moved_to = by_path["renamed.lua"]
  assert(moved_to.status == "changed", moved_to.status)
  assert(moved_to.revision == "hash-7:renamed", tostring(moved_to.revision))
  assert(#moved_to.hunks == 1, "an edit alongside a rename is reported where the bytes are")

  -- A commit and a removal both leave the dirty set. The bytes tell them apart,
  -- and a removal has no reading left to publish as a revision.
  local committed = by_path["src/with space.lua"]
  assert(committed.status == "unchanged", committed.status)
  assert(committed.revision == "hash-9:unchanged", tostring(committed.revision))
  local removed = by_path["gone.lua"]
  assert(removed.status == "gone", removed.status)
  assert(removed.revision == nil, "a removed file has no revision left")
  assert(removed.key == nil, "and no change key either")
  assert(removed.hunks_reason == "gone", tostring(removed.hunks_reason))
  assert(next(tracker.checkpoints) == nil, "a completed checkpoint is released")
  assert(#tracker.order == 0, "the pending order is released with it")
end)

test("a repeated absence is reported once, and a return is reported", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local temp = workdir("-pair-absent")
  os.execute("mkdir -p " .. string.format("%q", temp))
  local on_disk = assert(io.open(temp .. "/gone.lua", "wb"))
  on_disk:write("")
  on_disk:close()
  -- Porcelain keeps listing a staged deletion until it is committed, so the same
  -- absence is visible in every window that follows it.
  vim.system = function()
    return { wait = function() return { code = 0, stdout = " D gone.lua\0" } end }
  end
  local state = "absent"
  vim.uv = { fs_stat = function()
    if state == "absent" then return nil end
    local probe = assert(io.open(temp .. "/gone.lua", "rb"))
    local data = probe:read("*a")
    probe:close()
    return { type = "file", size = #data, mtime = { sec = 1, nsec = 1 } }
  end }
  local reports = {}
  local tracker = ChangesReal.new(temp, function(entries, id) reports[#reports + 1] = { id = id, entries = entries } end)
  local function window(id, change)
    tracker:before(id)
    if change then change() end
    tracker:after(id)
    return reports[#reports]
  end
  local first = window("w1")
  assert(first and first.entries[1].status == "gone", "an absence is reported when it is new")
  assert(window("w2") == first, "and is not reported again in the next window")
  -- Coming back is reported when a window sees it come back. A restore that
  -- happens between two windows is invisible to both of them: the tracker
  -- compares the start of a window with its end, and neither saw the transition.
  local returned = window("w3", function() state = "present" end)
  assert(returned ~= first and returned.entries[1].status == "new", "a file that comes back is a new reading")
  local gone_again = window("w4", function() state = "absent" end)
  assert(gone_again ~= returned and gone_again.entries[1].status == "gone", "and its second absence is reported too")
end)

test("abandoned checkpoints stay bounded", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local temp = workdir("-pair-bound")
  os.execute("mkdir -p " .. string.format("%q", temp))
  local seeded = assert(io.open(temp .. "/a.txt", "wb"))
  seeded:write("x")
  seeded:close()
  vim.system = function()
    return { wait = function() return { code = 0, stdout = "?? a.txt\0" } end }
  end
  vim.uv = { fs_stat = function(path)
    local probe = io.open(path, "rb")
    if not probe then return nil end
    local data = probe:read("*a")
    probe:close()
    return { type = "file", size = #data, mtime = { sec = 1, nsec = 1 } }
  end }
  local tracker = ChangesReal.new(temp, function() end)
  -- A tool whose end never arrives is the leak this bound exists for. Snapshots
  -- hold file content now, so unlike a bare hash map they are worth capping.
  for index = 1, 20 do tracker:before("call-" .. index) end
  local held = 0
  for _ in pairs(tracker.checkpoints) do held = held + 1 end
  assert(held == 8, "held checkpoints: " .. held)
  assert(#tracker.order == 8, "pending order length: " .. #tracker.order)
end)

test("hunk extraction accepts both vim.diff result shapes", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  diff_shape = "nested"
  local nested = ChangesReal.hunks_between("one\n", "two\n")
  diff_shape = "flat"
  local flat = ChangesReal.hunks_between("one\n", "two\n")
  diff_shape = "nested"
  assert(#nested == 1 and #flat == 1, "both shapes yield one hunk")
  assert(nested[1].old_start == 1 and nested[1].old_count == 1 and nested[1].new_start == 1 and nested[1].new_count == 1)
  for key, value in pairs(nested[1]) do assert(flat[1][key] == value, "field " .. key) end
  assert(#ChangesReal.hunks_between("same\n", "same\n") == 0, "identical content has no hunks")
  assert(#ChangesReal.hunks_between(nil, "text\n") == 0, "missing content has no hunks")
end)

test("an explanation follows the reading it was bound to", function()
  local Ui = dofile(root .. "/lua/pair/ui.lua")
  local ui = Ui.new({ max_entries = 10 })
  local entry = ui:add("decision", "title", { "src/a.lua" }, { ["src/a.lua"] = { key = "rev-1", revision = "rev-1" } })
  assert(ui:mark_revised("src/a.lua", "rev-1") == 1, "the same reading is current")
  assert(entry.bindings["src/a.lua"].revised == false, "the same reading is not marked")
  assert(ui:mark_revised("src/a.lua", "rev-2") == 1, "a moved reading marks the explanation")
  assert(entry.bindings["src/a.lua"].revised == true)
  -- A file that comes back to the explained bytes is current again: the mark is
  -- a comparison, not a latch.
  assert(ui:mark_revised("src/a.lua", "rev-1") == 1)
  assert(entry.bindings["src/a.lua"].revised == false, "the mark clears when the bytes return")
  assert(entry.bindings["src/a.lua"].revision == "rev-1", "the bound revision is preserved")
  assert(ui:mark_revised("src/other.lua", "rev-9") == 0, "unrelated files are unaffected")
  assert(ui:mark_revised("src/a.lua", "rev-3") == 1, "marking repeats without error")
  -- One reading cannot establish a change, so a file with no comparable key is
  -- never claimed to have moved.
  local weak = ui:add("decision", "title", { "src/b.lua" }, { ["src/b.lua"] = { key = nil, revision = nil } })
  assert(ui:mark_revised("src/b.lua", "rev-3") == 1)
  assert(weak.bindings["src/b.lua"].revised == false, "a single reading claims nothing")
  -- An absent file is its own fact, and its return clears it.
  assert(ui:mark_gone("src/a.lua") == 1)
  assert(entry.bindings["src/a.lua"].gone == true and entry.bindings["src/a.lua"].revised == false)
  assert(ui:mark_revised("src/a.lua", "rev-2") == 1)
  assert(entry.bindings["src/a.lua"].gone == false, "a file that comes back is no longer absent")
end)

test("marks are refused for a buffer holding another reading", function()
  vim.api = {
    nvim_buf_is_valid = function() return true end,
    nvim_buf_get_lines = function() return { "line one", "line two" } end,
  }
  local Marks = dofile(root .. "/lua/pair/marks.lua")
  local revision = vim.fn.sha256("line one\nline two\n")
  vim.bo = { [1] = { endofline = true, fileformat = "unix" } }
  assert(Marks.matches(1, revision), "a buffer holding the reading matches")
  assert(not Marks.matches(1, "hash-3:old"), "another reading does not match")
  assert(not Marks.matches(1, nil), "an unknown reading cannot be matched")
  -- A file with no trailing newline must not be padded to make it match.
  vim.bo[1].endofline = false
  assert(Marks.matches(1, vim.fn.sha256("line one\nline two")))
  assert(not Marks.matches(1, revision), "assuming a trailing newline would be a false match")
  vim.bo[1] = { endofline = true, fileformat = "dos" }
  assert(Marks.matches(1, vim.fn.sha256("line one\r\nline two\r\n")), "CRLF buffers are compared as written")
  -- A byte-order mark is stripped out of the first line into an option, so the
  -- comparison has to put it back.
  vim.bo[1] = { endofline = true, fileformat = "unix", bomb = true }
  assert(Marks.matches(1, vim.fn.sha256("\239\187\191line one\nline two\n")), "a byte-order mark is put back before comparing")
  assert(not Marks.matches(1, revision), "a buffer with a mark does not match the bytes without one")
end)

test("scanner degrades to no-op when git cannot be spawned", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  -- A missing git binary makes vim.system raise ENOENT rather than return a code.
  vim.system = function() error("vim/_core/system: ENOENT: no such file or directory (cmd): 'git'") end
  local observed
  local ok = pcall(function()
    local tracker = ChangesReal.new("/repo", function(files) observed = files end)
    tracker:before("call-1")
    tracker:after("call-1")
  end)
  assert(ok, "git-absent observation must not abort the session")
  assert(observed == nil)
end)

test("a file past the content ceiling gets a change key, not a revision", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local size, clock = 3 * 1024 * 1024, 10
  vim.uv = { fs_stat = function() return { type = "file", size = size, mtime = { sec = clock, nsec = 0 } } end }
  -- Two windows over the same large file: rewritten, then committed.
  local outputs = { " M big.txt\0", " M big.txt\0", " M big.txt\0", "" }
  local calls = 0
  vim.system = function()
    calls = calls + 1
    return { wait = function() return { code = 0, stdout = outputs[calls] } end }
  end
  local observed
  local tracker = ChangesReal.new("/repo", function(entries) observed = entries end)

  tracker:before("call-1")
  clock = 11
  tracker:after("call-1")
  assert(#observed == 1, #observed)
  assert(observed[1].status == "changed", observed[1].status)
  assert(observed[1].revision == nil, "a fingerprint is not a content revision")
  assert(observed[1].key == tostring(size) .. ":11:0", tostring(observed[1].key))
  assert(observed[1].hunks_reason == "too_large", tostring(observed[1].hunks_reason))
  assert(#observed[1].hunks == 0, "no diff without content on either side")

  -- Committing does not touch the file, so the key does not move and nothing is
  -- claimed about the reading. This is what a stale mark must not fire on.
  tracker:before("call-2")
  tracker:after("call-2")
  assert(#observed == 1, #observed)
  assert(observed[1].status == "unchanged", observed[1].status)
  assert(observed[1].key == tostring(size) .. ":11:0", tostring(observed[1].key))
  assert(observed[1].revision == nil, "a commit publishes no revision for an unread file")
end)

test("the content budget favours the files whose diffs are cheapest", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local temp = workdir("-pair-budget")
  os.execute("mkdir -p " .. string.format("%q", temp))
  -- Four files fill the content budget exactly, so the fifth byte of anything is
  -- spent. The small file sorts last by path and first by size, which is the only
  -- way the two possible orders disagree about it.
  local names = { "a1.txt", "a2.txt", "a3.txt", "a4.txt", "z.txt" }
  local big, small = 2 * 1024 * 1024, "small\n"
  for _, name in ipairs(names) do
    local handle = assert(io.open(temp .. "/" .. name, "wb"))
    handle:write(name == "z.txt" and small or string.rep("x", big))
    handle:close()
  end
  local listed = {}
  for _, name in ipairs(names) do listed[#listed + 1] = " M " .. name .. "\0" end
  local porcelain = table.concat(listed)
  vim.system = function() return { wait = function() return { code = 0, stdout = porcelain } end } end
  local clock = 1
  vim.uv = { fs_stat = function(path)
    local probe = io.open(path, "rb")
    if not probe then return nil end
    local data = probe:read("*a")
    probe:close()
    return { type = "file", size = #data, mtime = { sec = clock, nsec = 0 } }
  end }
  local observed
  local tracker = ChangesReal.new(temp, function(entries) observed = entries end)
  tracker:before("call-1")
  clock = 2
  for _, name in ipairs(names) do
    local handle = assert(io.open(temp .. "/" .. name, "wb"))
    handle:write(name == "z.txt" and (small .. "more\n") or string.rep("y", big))
    handle:close()
  end
  tracker:after("call-1")

  local by_path, starved = {}, 0
  for _, entry in ipairs(observed) do
    by_path[entry.path] = entry
    if entry.hunks_reason == "budget" then starved = starved + 1 end
  end
  -- Every file moved, so every file is reported. Content that cannot fit in the
  -- budget is not quietly dropped: the reading is still published and the entry
  -- says which part of it is missing.
  assert(#observed == 5, #observed)
  assert(#by_path["z.txt"].hunks == 1, "the smallest file keeps its diff")
  assert(starved == 1, "files reporting a lost diff: " .. starved)
  assert(by_path["a4.txt"].hunks_reason == "budget", tostring(by_path["a4.txt"].hunks_reason))
  assert(by_path["a4.txt"].revision ~= nil, "the reading itself is still published")
  assert(by_path["a1.txt"].hunks_reason == nil and #by_path["a1.txt"].hunks == 1, "the others keep theirs")
end)

test("a tool end with no recorded window is reported, not attributed", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  vim.system = function() return { wait = function() return { code = 0, stdout = " M f1.txt\0" } end } end
  vim.uv = { fs_stat = function() return { type = "file", size = 1, mtime = { sec = 1, nsec = 1 } } end }
  local observed, called_id, unavailable
  local tracker = ChangesReal.new("/repo", function(entries, id, reason)
    observed, called_id, unavailable = entries, id, reason
  end)
  -- More starts than the checkpoint bound, so the first window is dropped before
  -- its tool ends. Reporting it against a later baseline would credit this tool
  -- with another tool's edits, so it is reported as unobserved instead.
  for index = 1, 20 do tracker:before("call-" .. index) end
  tracker:after("call-1")
  assert(observed ~= nil and #observed == 0, "nothing is attributed to the tool")
  assert(called_id == "call-1", tostring(called_id))
  assert(unavailable ~= nil and unavailable:find("no baseline", 1, true), tostring(unavailable))

  -- A window that was opened but could not be seen, as on a host without a
  -- usable git, stays quiet rather than reporting on every tool.
  observed, unavailable = nil, nil
  vim.system = function() error("vim/_core/system: ENOENT: no such file or directory (cmd): 'git'") end
  tracker:before("call-21")
  tracker:after("call-21")
  assert(observed == nil and unavailable == nil, "an unavailable observation says nothing")
end)

print(("\n%d passed, %d failed"):format(successes, failures))
if failures > 0 then os.exit(1) end
