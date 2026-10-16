-- Minimal stand-in for `pi --mode rpc`, used by tests/integration.lua.
-- Speaks just enough JSONL to drive one pair.nvim session with no provider.
--
-- Environment:
--   FAKE_PI_FILE  file the fake writes during each tool call
--   FAKE_PI_LOG   append-only log of every request the host sent us
--   FAKE_PI_HOLD  rounds whose tool end is followed by a hold, comma-separated:
--                 the fake keeps the turn open and answers whatever the host
--                 sends until a get_state asks for state, which is how a real Pi
--                 looks while a model is still working and the user keeps typing

local file = assert(os.getenv("FAKE_PI_FILE"), "FAKE_PI_FILE is not set")
local log_path = assert(os.getenv("FAKE_PI_LOG"), "FAKE_PI_LOG is not set")
local hold_rounds = {}
for number in (os.getenv("FAKE_PI_HOLD") or ""):gmatch("%d+") do hold_rounds[tonumber(number)] = true end

-- Round-specific content so the expected hunk offsets are fixed, not emergent.
-- A round mapped to false removes the file instead of writing it, which is how a
-- deletion is observed end to end.
local EDIT_CONTENT = {
  "alpha\nBETA CHANGED\ngamma\n",
  "alpha\nBETA CHANGED\ngamma\ndelta\n",
  false,
  -- Round 4 is written and reported in one flush, the way a tool that finishes
  -- quickly arrives from a real Pi.
  "alpha\nROUND FOUR\ngamma\n",
}

local log = assert(io.open(log_path, "ab"))
local round = 0

local function send(record)
  io.stdout:write(record, "\n")
  io.stdout:flush()
end

-- Two records in one write, so the host reads them together.
local function send_batch(records)
  io.stdout:write(table.concat(records, "\n"), "\n")
  io.stdout:flush()
end

local function edit_file(number)
  if EDIT_CONTENT[number] == false then
    os.remove(file)
    return
  end
  local handle = assert(io.open(file, "wb"))
  handle:write(EDIT_CONTENT[number] or ("round " .. number .. "\n"))
  handle:close()
end

local function escape(text)
  return (text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

-- The request object is the first thing on the line, so a non-greedy prefix
-- finds the real key before any key name that appears inside message text.
local function request_type(line)
  return line:match('^.-"type"%s*:%s*"([%a_]+)"')
end

local function request_id(line)
  return line:match('^.-"id"%s*:%s*"([^"]+)"')
end

local function respond(line, data)
  send(('{"type":"response","id":"%s","success":true,"data":%s}'):format(request_id(line) or "unknown", data))
end

local function handle(line)
  local kind = request_type(line)
  if kind == "get_state" then
    respond(line, '{"sessionId":"fake-session"}')
    return
  end
  if kind ~= "prompt" and kind ~= "follow_up" and kind ~= "steer" then
    if kind == "abort" then send('{"type":"agent_settled","aborted":true}') end
    return
  end

  round = round + 1
  respond(line, '{"disposition":"queued"}')
  send('{"type":"agent_start"}')
  send('{"type":"message_start","message":{"role":"assistant","content":{}}}')
  send('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Checking round ' .. round .. '."}}')
  send(('{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Checking round %d."}]}}'):format(round))

  local start_record = ('{"type":"tool_execution_start","toolCallId":"call-%d","toolName":"write-%d"}'):format(round, round)
  local end_record = ('{"type":"tool_execution_end","toolCallId":"call-%d","toolName":"write-%d","isError":false}'):format(round, round)

  if round <= 3 then
    send(start_record)
    -- Block until the host answers. By then it has already taken its
    -- before-snapshot, which makes change detection deterministic instead of
    -- timing-dependent.
    local gate = io.read("*l")
    if not gate then return "closed" end
    log:write(gate, "\n")
    log:flush()
    if request_type(gate) == "get_state" then respond(gate, '{"sessionId":"fake-session"}') end
    edit_file(round)
    send(end_record)
  else
    -- A real Pi sends the start and the end of a tool that finishes quickly
    -- together, with the write already on disk by the time the host reads them.
    -- A host that snapshots only when the start arrives sees nothing here, so
    -- this round has no gate and reports both events at once.
    edit_file(round)
    send_batch({ start_record, end_record })
  end

  -- The turn is not finished: a model is still working while the user keeps
  -- typing. Requests arriving now are logged and acknowledged, and an abort ends
  -- the turn the way Pi ends one.
  if hold_rounds[round] then
    while true do
      local request = io.read("*l")
      if not request then return "closed" end
      log:write(request, "\n")
      log:flush()
      local kind = request_type(request)
      if kind == "get_state" then
        respond(request, '{"sessionId":"fake-session"}')
        break
      end
      if kind == "abort" then
        send('{"type":"agent_settled","aborted":true}')
        return "aborted"
      end
      respond(request, '{"disposition":"queued"}')
    end
  end

  -- The explanation arrives after the edit, so it binds to the revision that
  -- edit produced rather than the one before it.
  send('{"type":"message_start","message":{"role":"assistant","content":{}}}')
  send('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Working on round ' .. round .. '."}}')
  send(('{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}'):format(escape(
    "Working on round " .. round .. ".\nPAIR_DECISION: Round " .. round
    .. " decision | Fake rationale for the headless test | gen.lua")))
  send('{"type":"agent_settled"}')
  return "ok"
end

while true do
  local line = io.read("*l")
  if not line then break end
  log:write(line, "\n")
  log:flush()
  if handle(line) == "closed" then break end
end

log:close()
