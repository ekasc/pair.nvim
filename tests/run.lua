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
vim = {
  deepcopy = deepcopy,
  tbl_deep_extend = deep_extend,
  tbl_extend = deep_extend,
  split = split,
  trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  json = { encode = encode, decode = function(s) return assert(decoded_lines[s], "unexpected JSON input: " .. s) end },
  fn = {
    executable = function() return 1 end,
    jobstart = function() return 123 end,
    chansend = function(_, record) sent[#sent + 1] = record return #record end,
    chanclose = function() return 1 end,
    sha256 = function(s) return "hash-" .. tostring(#s) .. ":" .. s end,
  },
}

local successes, failures = 0, 0
local function test(name, body)
  local ok, err = pcall(body)
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
package.loaded["pair.ui"] = {
  new = function()
    local ui = { entries = entries }
    function ui:add(role, text, files)
      local entry = { role = role, text = text or "", files = files or {} }
      entries[#entries + 1] = entry
      return entry
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


-- Exercise the actual NUL-delimited Git scanner using synthetic status output
-- and real file contents, without requiring Neovim or a Git repository.
test("multi-file scanner handles dirty edits, untracked spaces, renames", function()
  local ChangesReal = dofile(root .. "/lua/pair/changes.lua")
  local temp = os.tmpname():gsub("^@", "") .. "-pair"
  os.execute("mkdir -p " .. string.format("%q", temp .. "/src") .. " " .. string.format("%q", temp .. "/tests"))
  local function write(relative, text)
    local f = assert(io.open(temp .. "/" .. relative, "wb"))
    f:write(text)
    f:close()
  end
  write("src/a.lua", "old")
  write("src/with space.lua", "unchanged")
  write("tests/new.lua", "new")
  local before = " M src/a.lua\0?? src/with space.lua\0"
  local after = " M src/a.lua\0?? src/with space.lua\0?? tests/new.lua\0R  renamed.lua\0src/previous.lua\0"
  write("renamed.lua", "renamed")
  local outputs = { before, before, after }
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
  local tracker = ChangesReal.new(temp, function(files) observed = files end)
  tracker:before("call-1")
  write("src/a.lua", "updated")
  tracker:after("call-1")
  assert(table.concat(observed, ",") == "renamed.lua,src/a.lua,tests/new.lua", table.concat(observed, ","))
  os.execute("rm -rf " .. string.format("%q", temp))
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

print(("\n%d passed, %d failed"):format(successes, failures))
if failures > 0 then os.exit(1) end
