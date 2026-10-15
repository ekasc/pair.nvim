-- Minimal stand-in for `pi --mode rpc`, used by tests/integration.lua.
-- Speaks just enough JSONL to drive one pair.nvim session with no provider.
--
-- Environment:
--   FAKE_PI_FILE  file the fake writes during each tool call
--   FAKE_PI_LOG   append-only log of every request the host sent us

local file = assert(os.getenv("FAKE_PI_FILE"), "FAKE_PI_FILE is not set")
local log_path = assert(os.getenv("FAKE_PI_LOG"), "FAKE_PI_LOG is not set")

local log = assert(io.open(log_path, "ab"))
local round = 0

local function send(record)
  io.stdout:write(record, "\n")
  io.stdout:flush()
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
  send('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Working on round ' .. round .. '."}}')
  send(('{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}'):format(escape(
    "Working on round " .. round .. ".\nPAIR_DECISION: Round " .. round
    .. " decision | Fake rationale for the headless test | gen.lua")))

  send(('{"type":"tool_execution_start","toolCallId":"call-%d","toolName":"write-%d"}'):format(round, round))
  -- Block until the host answers. By then it has already taken its
  -- before-snapshot, which makes change detection deterministic instead of
  -- timing-dependent.
  local gate = io.read("*l")
  if not gate then return "closed" end
  log:write(gate, "\n")
  log:flush()
  if request_type(gate) == "get_state" then respond(gate, '{"sessionId":"fake-session"}') end

  local handle = assert(io.open(file, "wb"))
  handle:write("generated round " .. round .. "\n")
  handle:close()

  send(('{"type":"tool_execution_end","toolCallId":"call-%d","toolName":"write-%d","isError":false}'):format(round, round))
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
