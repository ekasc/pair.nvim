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
initial:write("alpha\nbeta\ngamma\n")
initial:close()
local genbuf = vim.fn.bufadd(generated)
vim.fn.bufload(genbuf)
check("test buffer is loaded and unmodified", vim.api.nvim_buf_is_loaded(genbuf) and not vim.bo[genbuf].modified)
-- 'autoread' is global-local, so an unset local value reads as nil rather than
-- false. The invariant is that observation leaves it exactly as it found it.
local autoread_before = vim.bo[genbuf].autoread

-- Round 1: unmodified buffer.
local round_one_content = "alpha\nBETA CHANGED\ngamma\n"
local round_one_revision = vim.fn.sha256(round_one_content)
local function decisions()
  local found = {}
  for _, entry in ipairs(ui.entries) do
    if entry.role == "decision" then found[#found + 1] = entry end
  end
  return found
end
local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

prompt("Implement the thing")
check("composer clears after send", vim.api.nvim_buf_get_lines(ui.input_buf, 0, -1, false)[1] == "")
check("agent narrates before acting", wait_for("Checking round 1."))
release(1)
check("assistant text streams into the transcript", wait_for("Working on round 1."))
check("decision record becomes a timeline entry", wait_for("Round 1 decision"))
check("decision links its file", wait_for("-> gen.lua"))
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
    return buffer_text(genbuf):find("BETA CHANGED", 1, true) ~= nil
  end, 20))
  check("borrowed buffer option is restored", vim.bo[genbuf].autoread == autoread_before,
    "expected " .. tostring(autoread_before) .. ", left as " .. tostring(vim.bo[genbuf].autoread))

  local entry = session.file_log["gen.lua"]
  check("buffer holds the observed revision", buffer_text(genbuf) == round_one_content, buffer_text(genbuf))
  check("observation records that revision", entry and entry.revision == round_one_revision,
    entry and entry.revision)

  local hunk = entry and entry.hunks[1]
  check("hunk locates the exact edited line",
    hunk and hunk.old_start == 2 and hunk.old_count == 1 and hunk.new_start == 2 and hunk.new_count == 1,
    vim.inspect(entry and entry.hunks))

  local marked = vim.api.nvim_buf_get_extmarks(genbuf, require("pair.marks").namespace(), 0, -1, {})
  check("changed line is marked in the buffer", #marked == 1 and marked[1][2] == 1, vim.inspect(marked))

  pair.changes()
  local quickfix = vim.fn.getqflist()
  vim.cmd("cclose")
  check("quickfix points at the changed line", quickfix[1] and quickfix[1].lnum == 2, vim.inspect(quickfix[1]))

  -- A byte-order mark lives in an option rather than in the first line, so a
  -- buffer holding a file that has one only matches if the comparison puts it
  -- back before hashing. Real buffer, real option, no stub involved.
  local bom_path = tmp .. "/bom.lua"
  local bom_bytes = "\239\187\191local bom = 1\n"
  local bom_handle = assert(io.open(bom_path, "wb"))
  bom_handle:write(bom_bytes)
  bom_handle:close()
  local bom_buf = vim.fn.bufadd(bom_path)
  vim.fn.bufload(bom_buf)
  check("a marked buffer matches the bytes it was read from",
    vim.bo[bom_buf].bomb and require("pair.marks").matches(bom_buf, vim.fn.sha256(bom_bytes)),
    "bomb=" .. tostring(vim.bo[bom_buf].bomb))

  local first = decisions()[1]
  check("explanation is bound to the revision it describes",
    first and first.bindings["gen.lua"].revision == round_one_revision,
    first and tostring(first.bindings["gen.lua"].revision))
  check("the explanation binds the reading it was written against",
    first and first.bindings["gen.lua"].key == round_one_revision and first.bindings["gen.lua"].revision == round_one_revision)
  check("the transcript shows the revision the explanation refers to",
    wait_for("-> gen.lua  @" .. round_one_revision:sub(1, 8)))

  -- A commit leaves the changed set without touching the bytes. Real repository,
  -- real porcelain, driven on the tracker directly because no fake round needs to
  -- change a file for this. The committed file is the one the explanation above
  -- names, so what a commit does to that explanation is what this measures.
  vim.system({ "git", "-C", tmp, "add", "gen.lua" }):wait(5000)
  session.changes:before("manual-1")
  vim.system({ "git", "-C", tmp, "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-qm", "accept gen" }):wait(5000)
  session.changes:after("manual-1")
  local committed_entry = session.file_log["gen.lua"]
  check("a commit is observed as leaving the changed set",
    committed_entry and committed_entry.status == "unchanged", committed_entry and committed_entry.status)
  check("a commit reports the revision its bytes still have",
    committed_entry and committed_entry.revision == round_one_revision,
    committed_entry and tostring(committed_entry.revision))
  check("a commit is reported in the file list", wait_for("Changes observed during tool manual-1"))
  check("a commit of an explained file leaves the explanation current",
    first.bindings["gen.lua"].revised == false and first.bindings["gen.lua"].gone == false,
    first and ("revised=" .. tostring(first.bindings["gen.lua"].revised)))
  check("nothing is marked changed since by a commit", not transcript():find("(changed since)", 1, true))
else
  print("SKIP change observation: git is not installed")
end

-- Round 2: modified buffer must be protected.
vim.api.nvim_buf_set_lines(genbuf, 0, -1, false, { "local draft = true" })
check("test buffer is modified again", vim.bo[genbuf].modified)
-- The commit above was observed with no measured change, and that observation
-- cleared the marks for the revision the buffer held. Marks are placed again so
-- that the conflict check below measures the conflict path rather than that
-- earlier clear, and it is measured against a buffer that really carries them.
require("pair.marks").apply(genbuf, { { new_start = 1, new_count = 1 } })
check("the buffer carries marks for the revision it no longer holds",
  #vim.api.nvim_buf_get_extmarks(genbuf, require("pair.marks").namespace(), 0, -1, {}) == 1)
prompt("Change direction")
release(2)
if has_git then
  check("unsaved buffer is reported as a conflict", wait_for("Unsaved buffer conflicts with disk change: gen.lua"))
  check("unsaved buffer is not overwritten", table.concat(vim.api.nvim_buf_get_lines(genbuf, 0, -1, false), "\n") == "local draft = true")
  check("the earlier explanation is now marked stale", wait_for("(changed since)"))
  local first = decisions()[1]
  check("the bound revision is preserved, not rewritten",
    first and first.bindings["gen.lua"].revision == round_one_revision,
    first and tostring(first.bindings["gen.lua"].revision))
  check("marks for a superseded revision are cleared from the unsaved buffer",
    #vim.api.nvim_buf_get_extmarks(genbuf, require("pair.marks").namespace(), 0, -1, {}) == 0)
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
check("both prompts so far reached Pi", occurrences('"type":"prompt"') == 2)

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

-- Round 3 removes the file. A removal is its own observation: no reading
-- survives to compare against, so the transcript says the file is gone rather
-- than claiming the explanation is out of date.
prompt("Remove the file")
release(3)
if has_git then
  check("a removal is reported in the file list", wait_for("Changes observed during tool call-3"))
  check("an explanation naming the removed file says it is gone", wait_for("(file gone)"))
  -- Nothing is left to read, so nothing may be published as a revision for it.
  local removed = session.file_log["gen.lua"]
  check("a removal publishes no reading at all",
    removed and removed.status == "gone" and removed.revision == nil and removed.key == nil,
    removed and ("status=" .. tostring(removed.status) .. " revision=" .. tostring(removed.revision) .. " key=" .. tostring(removed.key)))
  check("no sentinel is rendered in place of a revision",
    not transcript():find("<deleted>", 1, true) and not transcript():find("<non-file>", 1, true))
  -- The earlier explanations are marked too, not only the new one that binds a
  -- file already known to be absent.
  local round_one = decisions()[1]
  check("an earlier explanation is marked absent, not merely out of date",
    round_one and round_one.bindings["gen.lua"].gone == true and round_one.bindings["gen.lua"].revised == false,
    round_one and ("gone=" .. tostring(round_one.bindings["gen.lua"].gone) .. " revised=" .. tostring(round_one.bindings["gen.lua"].revised)))
  check("the removal prompt reached Pi", occurrences('"type":"prompt"') == 3)
  pair.changes()
  local removed_qf = vim.fn.getqflist()
  vim.cmd("cclose")
  local removed_item
  for _, item in ipairs(removed_qf) do
    if item.bufnr == vim.fn.bufnr(generated) then removed_item = item end
  end
  check("the quickfix reports the removal without inventing a diff",
    removed_item and removed_item.text == "no longer on disk", removed_item and removed_item.text)
else
  print("SKIP removal observation: git is not installed")
end

-- Teardown: closing stdin must end the process rather than leave it running.
local backend = session.backend
pair.stop()
check("closing stdin stops the fake Pi process", vim.wait(5000, function() return backend.job == nil end, 20))

vim.fn.delete(tmp, "rf")
print(("\n%d passed, %d failed"):format(checks - failures, failures))
if failures > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
