-- Headless Neovim integration test: real plugin code driven by a fake Pi RPC
-- process. No provider credentials and no `pi` CLI are needed.
--
-- Run from the repository root:
--   nvim --headless -l tests/integration.lua
--
-- Covers: session start, the one-time directive, streamed assistant text,
-- decision records with linked files, tool-boundary change observation,
-- silent reload of an unmodified buffer, refusal to overwrite a modified one,
-- and restoration of the buffer option the observer borrows.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local checks, failures = 0, 0

local function check(name, condition, detail)
  checks = checks + 1
  if condition then
    print("PASS " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local wire_log = tmp .. "/wire.log"
vim.env.FAKE_PI_FILE = tmp .. "/gen.lua"
vim.env.FAKE_PI_LOG = wire_log

local has_git = vim.fn.executable("git") == 1
if has_git then vim.system({ "git", "-C", tmp, "init", "-q" }):wait(5000) end

local pair = require("pair")
pair.setup({
  root = tmp,
  pi = { command = { "texlua", root .. "/tests/fake-pi.lua" } },
})

local started = pair.start()
check("session starts with a fake Pi process", started)
if not started then
  print("\n0 passed, 1 failed")
  vim.cmd("cquit 1")
  return
end

local session = pair.session
local ui = session.ui
local generated = session.root .. "/gen.lua"

local function transcript()
  local buf = ui.transcript_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function wait_for(text, ms)
  return vim.wait(ms or 8000, function() return transcript():find(text, 1, true) ~= nil end, 20)
end

local function prompt(text)
  vim.api.nvim_buf_set_lines(ui.input_buf, 0, -1, false, { text })
  ui:send(false)
end

-- Gate the fake's file write on our own observation of the tool starting, so
-- the before-snapshot is guaranteed to precede the write.
local function release(round)
  local seen = wait_for("Running write-" .. round)
  check("tool execution is reported for round " .. round, seen)
  session.backend:send({ type = "get_state" })
  return seen
end

check("sidebar opens", ui:is_open())
check("RPC state response is shown", wait_for("Session: fake-session"))

-- A pre-existing, unmodified buffer for a file the fake is about to rewrite.
-- bufadd/bufload loads it without disturbing the sidebar windows.
local initial = assert(io.open(generated, "wb"))
initial:write("initial\n")
initial:close()
local genbuf = vim.fn.bufadd(generated)
vim.fn.bufload(genbuf)
check("test buffer is loaded and unmodified", vim.api.nvim_buf_is_loaded(genbuf) and not vim.bo[genbuf].modified)
-- 'autoread' is global-local, so an unset local value reads as nil rather than
-- false. The invariant is that observation leaves it exactly as it found it.
local autoread_before = vim.bo[genbuf].autoread

-- Round 1: unmodified buffer.
prompt("Implement the thing")
check("composer clears after send", vim.api.nvim_buf_get_lines(ui.input_buf, 0, -1, false)[1] == "")
check("assistant text streams into the transcript", wait_for("Working on round 1."))
check("decision record becomes a timeline entry", wait_for("Round 1 decision"))
check("decision links its file", wait_for("-> gen.lua"))
release(1)
check("agent settles after the tool call", wait_for("Agent idle"))

if has_git then
  check("observed change reaches the file list", vim.wait(8000, function()
    for _, path in ipairs(session:files()) do
      if path == "gen.lua" then return true end
    end
    return false
  end, 20))
  check("change is reported as observation, not authorship", wait_for("not proof of authorship"))
  check("unmodified buffer silently reloads from disk", vim.wait(8000, function()
    local lines = vim.api.nvim_buf_get_lines(genbuf, 0, -1, false)
    return table.concat(lines, "\n"):find("generated round 1", 1, true) ~= nil
  end, 20))
  check("borrowed buffer option is restored", vim.bo[genbuf].autoread == autoread_before,
    "expected " .. tostring(autoread_before) .. ", left as " .. tostring(vim.bo[genbuf].autoread))
else
  print("SKIP change observation: git is not installed")
end

-- Round 2: modified buffer must be protected.
vim.api.nvim_buf_set_lines(genbuf, 0, -1, false, { "local draft = true" })
check("test buffer is modified again", vim.bo[genbuf].modified)
prompt("Change direction")
release(2)
if has_git then
  check("unsaved buffer is reported as a conflict", wait_for("Unsaved buffer conflicts with disk change: gen.lua"))
  check("unsaved buffer is not overwritten", table.concat(vim.api.nvim_buf_get_lines(genbuf, 0, -1, false), "\n") == "local draft = true")
else
  print("SKIP unsaved-buffer guard: git is not installed")
end

-- The directive is a first-prompt-only collaboration preference.
local wire = table.concat(vim.fn.readfile(wire_log), "\n")
local function occurrences(needle)
  local count = 0
  for _, line in ipairs(vim.fn.readfile(wire_log)) do
    if line:find(needle, 1, true) then count = count + 1 end
  end
  return count
end
check("first prompt carries the directive", occurrences("PAIR_DECISION:") == 1, wire:sub(1, 200))
check("both prompts reached Pi", occurrences('"type":"prompt"') == 2)

-- open_file must report a refusal instead of throwing E37 when the target
-- window holds unsaved changes. Neovim enables 'hidden' by default, so the
-- strict case has to be forced.
local hidden_before = vim.o.hidden
vim.o.hidden = false
vim.cmd("split")
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/draft.lua"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
ui.origin_win = vim.api.nvim_get_current_win()
session:open_file("gen.lua")
check("refusal to abandon unsaved changes is reported, not thrown", wait_for("Refused to open gen.lua"))
vim.o.hidden = hidden_before

-- Teardown: closing stdin must end the process rather than leave it running.
local backend = session.backend
pair.stop()
check("closing stdin stops the fake Pi process", vim.wait(5000, function() return backend.job == nil end, 20))

vim.fn.delete(tmp, "rf")
print(("\n%d passed, %d failed"):format(checks - failures, failures))
if failures > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
