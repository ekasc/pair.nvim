-- Headless Neovim integration test: real plugin code driven by a fake Pi RPC
-- process. No provider credentials and no `pi` CLI are needed.
--
-- Run from the repository root:
--   nvim --headless -l tests/integration.lua
--
-- Covers: session start, the one-time directive, streamed assistant text,
-- decision records with linked files, tool-boundary change observation, change
-- groups arranged under the decisions that name their files, silent reload of an
-- unmodified buffer, refusal to overwrite a modified one, and restoration of the
-- buffer option the observer borrows.

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

local real = vim.fn.tempname()
vim.fn.mkdir(real, "p")
-- The fixture is reached through a symlink, the way a project under /tmp, on a
-- mounted volume or behind a symlinked home is. The editor reports a buffer's
-- resolved name, so the root and the buffer name differ in spelling until the root
-- is canonicalised where it is discovered.
local tmp = real .. "-link"
os.execute("ln -sfn " .. string.format("%q", real) .. " " .. string.format("%q", tmp))
-- The wire log lives outside the fixture, which is a git repository the test
-- observes: a log written inside it would itself be reported as a working-tree
-- change, and the fixture would be measuring a repository it also edits.
local wire_log = real .. "-wire.log"
vim.env.FAKE_PI_FILE = tmp .. "/gen.lua"
vim.env.FAKE_PI_LOG = wire_log
-- Rounds 6 and 7 hold their turns open, so the agent is still working while the
-- user types: that is the state queueing and steering are about. A real Pi holds a
-- turn open for as long as a model takes; the fake holds when asked.
vim.env.FAKE_PI_HOLD = "6,7"

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

local function prompt(text, steer)
  vim.api.nvim_buf_set_lines(ui.input_buf, 0, -1, false, { text })
  ui:send(steer or false)
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

  -- Multi-file change groups: the same evidence arranged under the decision that
  -- names each file, instead of a run of unrelated files. A manual window brings
  -- in a file no decision names, which is the bucket the view must not hide.
  local scratch = tmp .. "/scratch.lua"
  session.changes:before("manual-2")
  local scratch_handle = assert(io.open(scratch, "wb"))
  scratch_handle:write("scratch\n")
  scratch_handle:close()
  session.changes:after("manual-2")
  local scratch_buf = vim.fn.bufadd(scratch)
  pair.groups()
  local grouped = vim.fn.getqflist()
  vim.cmd("cclose")
  local headers, grouped_items, separate = {}, {}, {}
  for _, item in ipairs(grouped) do
    if item.valid == 0 then
      headers[#headers + 1] = item.text
    elseif item.bufnr == scratch_buf then
      separate[#separate + 1] = item
    else
      grouped_items[#grouped_items + 1] = item
    end
  end
  check("a change group names the decision that holds its file",
    headers[1] ~= nil and headers[1]:find("Round 1 decision", 1, true) ~= nil
      and headers[1]:find("1 file, 1 hunk", 1, true) ~= nil, headers[1])
  check("a group item points at the line its hunk covers",
    grouped_items[1] ~= nil and grouped_items[1].bufnr == vim.fn.bufnr(generated) and grouped_items[1].lnum == 2,
    vim.inspect(grouped_items[1]))
  check("observed changes no decision names are listed apart",
    #headers == 2 and headers[2]:find("no decision", 1, true) ~= nil
      and #separate == 1 and separate[1].text == "first reading of this file",
    table.concat(headers, " / ") .. " separate: " .. #separate)

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

  -- The group view follows the binding: the round-one decision is marked, and the
  -- reading under it is the one round two wrote.
  pair.groups()
  local stale_groups = vim.fn.getqflist()
  vim.cmd("cclose")
  local stale_item
  for _, item in ipairs(stale_groups) do
    if item.valid == 1 and item.bufnr == vim.fn.bufnr(generated) then stale_item = item break end
  end
  check("a group says how much of its evidence is superseded",
    stale_groups[1] ~= nil and stale_groups[1].text:find("1 superseded", 1, true) ~= nil,
    stale_groups[1] and stale_groups[1].text)
  check("a superseded item says which decision it no longer matches",
    stale_item ~= nil and stale_item.text:find("changed since the decision", 1, true) ~= nil,
    stale_item and stale_item.text)
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
    if item.text == "no longer on disk" then removed_item = item end
  end
  check("the quickfix reports the removal without inventing a diff",
    removed_item ~= nil and removed_item.text == "no longer on disk", removed_item and removed_item.text)
  check("and a removed file offers no location to jump to",
    removed_item ~= nil and removed_item.bufnr == 0 and removed_item.valid == 0,
    removed_item and ("bufnr=" .. removed_item.bufnr .. " valid=" .. removed_item.valid) or "no item")

  -- An absent file's own reading already says it is absent, so the group item for
  -- it does not say so twice, and it points nowhere because there is nowhere to go.
  pair.groups()
  local gone_groups = vim.fn.getqflist()
  vim.cmd("cclose")
  local gone_group_item
  for _, item in ipairs(gone_groups) do
    if item.text == "no longer on disk" then gone_group_item = item break end
  end
  check("a group item for an absent file reports the absence once",
    gone_group_item ~= nil and gone_group_item.text == "no longer on disk", gone_group_item and gone_group_item.text)
  check("and the group item for it points nowhere either",
    gone_group_item ~= nil and gone_group_item.bufnr == 0, gone_group_item and tostring(gone_group_item.bufnr))
else
  print("SKIP removal observation: git is not installed")
end

-- A decision may name a file that no observation ever covered. The item says so and
-- points nowhere: Neovim would load an empty buffer for a path that does not exist.
if has_git then
  session:on_event("event", {
    type = "message_end",
    message = { role = "assistant", content = { { type = "text",
      text = "PAIR_DECISION: Never observed | a path no tool ever touched | never-seen.lua" } } },
  })
  pair.groups()
  local never_groups = vim.fn.getqflist()
  vim.cmd("cclose")
  local never_item
  for _, item in ipairs(never_groups) do
    if item.text == "no observation has covered this file" then never_item = item end
  end
  check("an unobserved file is listed as unobserved",
    never_item ~= nil, table.concat(vim.tbl_map(function(item) return item.text end, never_groups), " | "))
  check("and it offers no location to jump to",
    never_item ~= nil and never_item.bufnr == 0 and never_item.valid == 0,
    never_item and ("bufnr=" .. never_item.bufnr .. " valid=" .. never_item.valid) or "no item")
  check("and asking for the view created no buffer for it",
    vim.fn.bufexists(tmp .. "/never-seen.lua") == 0)
end

-- Round 4 is a tool that finished before the host could look. A real Pi sends the
-- start and the end of a fast tool together, with the write already on disk by
-- the time the host reads them, so a window must compare against the state at the
-- previous observation. Snapshotting when the start arrives would already contain
-- the change and report nothing.
prompt("A tool that returns as soon as it is done")
check("a tool that finished before the host could look is still observed",
  wait_for("Changes observed during tool call-4"), transcript():sub(-300))
if has_git then
  local batched = session.file_log["gen.lua"]
  check("the write that arrived with its tool end is reported as a reading",
    batched ~= nil and batched.status == "new" and batched.key ~= nil,
    batched and ("status=" .. tostring(batched.status) .. " key=" .. tostring(batched.key)))
  check("the absence recorded earlier no longer stands",
    not transcript():find("(file gone)", 1, true), transcript():sub(-400))
  pair.groups()
  local batched_groups = vim.fn.getqflist()
  vim.cmd("cclose")
  check("the group counts the file now that it has been observed",
    batched_groups[1] ~= nil and batched_groups[1].text:find("not observed", 1, true) == nil,
    batched_groups[1] and batched_groups[1].text)
end

-- Contextual chat: a question asked at a location in a file a decision named
-- carries that decision and the files it named, into the prompt and onto the
-- question itself.
if has_git then
  local editor_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= ui.input_win and win ~= ui.transcript_win then editor_win = win break end
  end
  vim.api.nvim_set_current_win(editor_win or 0)
  vim.api.nvim_win_set_buf(0, genbuf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  pair.context()
  vim.api.nvim_buf_set_lines(ui.input_buf, 0, -1, false, { "Why this shape?" })
  ui:send(false)
  check("a question about a named file keeps the decision that named it",
    wait_for("[gen.lua:1 · decision: Round 4 decision · files: gen.lua]", 60000), transcript():sub(-300))
  check("the reference reaches the model",
    occurrences("A recorded decision that named this file: Round 4 decision") == 1, wire:sub(-400))
  check("and names the files that decision held",
    occurrences("Files that decision named: gen.lua") == 1)
  check("the question is still the user's own text", transcript():find("## You\nWhy this shape?", 1, true) ~= nil)
end

-- Non-disruptive execution. While a turn is open, a question is queued rather
-- than interrupting, an explicit steer redirects the run without aborting it, and
-- none of it moves the user: the window, the buffer, the cursor and the view stay
-- where they were put.
if has_git then
  -- An editor window: not either half of the sidebar. The checks below are about
  -- this window not moving, so it has to be found rather than assumed.
  local function editor_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= ui.input_win and win ~= ui.transcript_win then return win end
    end
  end
  local function focus_snapshot()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(win)
    return ("%s|%s|%d:%d|%d"):format(tostring(win), vim.api.nvim_buf_get_name(buf),
      cursor[1], cursor[2], vim.fn.line("w0"))
  end
  local function request_kinds(from)
    local kinds = {}
    local file = vim.fn.readfile(wire_log)
    for index = from + 1, #file do
      local kind = file[index]:match('"type"%s*:%s*"([%a_]+)"')
      if kind then kinds[#kinds + 1] = kind end
    end
    return table.concat(kinds, ",")
  end

  -- Put the editor back on gen.lua holding what is on disk, with a known cursor.
  local editor = editor_window()
  check("the fixture has an editor window to sit in", editor ~= nil)
  vim.api.nvim_set_current_win(editor or 0)
  vim.api.nvim_win_set_buf(0, genbuf)
  check("the cursor is in the editor window, not the sidebar",
    vim.api.nvim_get_current_win() == editor and vim.api.nvim_get_current_buf() == genbuf)
  vim.cmd("silent! edit!")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local mark = #vim.fn.readfile(wire_log)
  local resting = focus_snapshot()

  prompt("A round the agent has not finished")
  check("the held round reports its tool", wait_for("Running write-6", 60000), transcript():sub(-200))
  check("the agent is working while the user types", session.backend.busy == true)
  check("the observation of a held round does not move the user", focus_snapshot() == resting,
    focus_snapshot() .. " expected " .. resting)
  check("the rewritten file is reloaded under the cursor", buffer_text(genbuf):find("round 6", 1, true) ~= nil,
    buffer_text(genbuf))

  prompt("First question while it works")
  check("a question while the agent works is queued after the run",
    wait_for("Question queued after the current run", 60000), transcript():sub(-300))
  prompt("Second question while it works")
  check("the queue does not move the user", focus_snapshot() == resting, focus_snapshot())
  prompt("A redirect while it works", true)
  check("an explicit steer is reported as steering", wait_for("Steering request queued", 60000),
    transcript():sub(-300))
  check("the three requests reached Pi in the order they were written",
    request_kinds(mark) == "prompt,follow_up,follow_up,steer", request_kinds(mark))
  check("a steer did not abort the run", not request_kinds(mark):find("abort", 1, true), request_kinds(mark))

  -- A send from anywhere else is checked above by the focus snapshots, which is
  -- what makes them worth having: a check written for the composer case alone
  -- passes with or without the rule, because restoring focus to the window that
  -- already has it changes nothing.

  session.backend:send({ type = "get_state" })
  check("the held round finishes when the agent is done", wait_for("Working on round 6.", 60000))

  -- An explicit interruption is its own action: it ends the turn and says so.
  vim.api.nvim_set_current_win(editor or 0)
  vim.api.nvim_win_set_buf(0, genbuf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local before_interrupt = focus_snapshot()
  local interrupt_mark = #vim.fn.readfile(wire_log)
  prompt("A round that will be interrupted")
  check("the interrupted round reports its tool", wait_for("Running write-7", 60000), transcript():sub(-200))
  pair.interrupt()
  check("an explicit interruption is reported", wait_for("Agent interrupted", 60000), transcript():sub(-300))
  check("the interruption reached Pi as an abort", request_kinds(interrupt_mark) == "prompt,abort",
    request_kinds(interrupt_mark))
  check("interrupting does not move the user", focus_snapshot() == before_interrupt,
    focus_snapshot() .. " expected " .. before_interrupt)
  session.backend:send({ type = "get_state" })
  vim.wait(500)

  -- A reader part-way up the transcript keeps their place while it grows.
  vim.api.nvim_set_current_win(ui.transcript_win)
  vim.api.nvim_win_set_cursor(ui.transcript_win, { 1, 0 })
  local reader = focus_snapshot()
  ui:add("status", "A line the reader did not ask for")
  vim.wait(300)
  check("a growing transcript does not move a reader", focus_snapshot() == reader,
    focus_snapshot() .. " expected " .. reader)
end

-- A file name with a glob character in it, beside a file its name would expand to.
-- bufnr() matches its argument as a pattern, so the buffer lookup has to resolve
-- the name rather than trust the match: otherwise the observation reloads and
-- marks the wrong buffer and leaves the file it observed stale.
local appdir = tmp .. "/app"
vim.fn.mkdir(appdir, "p")
local bracketed_path = appdir .. "/[id].lua"
local sibling_path = appdir .. "/i.lua"
local function fill(path, text)
  local handle = assert(io.open(path, "wb"))
  handle:write(text)
  handle:close()
end
fill(bracketed_path, "alpha\n")
fill(sibling_path, "one\n")
local bracketed_buf = vim.fn.bufadd(bracketed_path)
vim.fn.bufload(bracketed_buf)
local sibling_buf = vim.fn.bufadd(sibling_path)
vim.fn.bufload(sibling_buf)
fill(bracketed_path, "BETA\n")
session:refresh_buffer("app/[id].lua", {
  path = "app/[id].lua",
  status = "changed",
  key = "k",
  revision = vim.fn.sha256("BETA\n"),
  hunks = { { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } },
})
check("a file whose name holds a glob character reloads its own buffer",
  buffer_text(bracketed_buf) == "BETA\n", buffer_text(bracketed_buf))
check("and its marks land in that buffer",
  #vim.api.nvim_buf_get_extmarks(bracketed_buf, require("pair.marks").namespace(), 0, -1, {}) > 0)
check("the sibling its name expands to is left alone",
  buffer_text(sibling_buf) == "one\n" and
    #vim.api.nvim_buf_get_extmarks(sibling_buf, require("pair.marks").namespace(), 0, -1, {}) == 0,
  buffer_text(sibling_buf) .. " marks: " ..
    #vim.api.nvim_buf_get_extmarks(sibling_buf, require("pair.marks").namespace(), 0, -1, {}))

-- Teardown: closing stdin must end the process rather than leave it running.
local backend = session.backend
backend:stop()
check("closing stdin stops the fake Pi process", vim.wait(5000, function() return backend.job == nil end, 20))

-- A sidebar whose Pi has exited cannot send, so :Pair opens a live session
-- instead of showing the dead one again.
ui:close()
pair.toggle()
check(":Pair discards a session whose Pi has exited", pair.session ~= nil and pair.session ~= session)
check(":Pair opens a sidebar whose backend is running",
  pair.session ~= nil and pair.session.backend.job ~= nil and pair.session.ui:is_open())

-- :PairAsk follows the same rule: a composer on a dead session cannot send.
local replacement = pair.session
replacement.backend:stop()
vim.wait(5000, function() return replacement.backend.job == nil end, 20)
pair.ask()
check(":PairAsk discards a session whose Pi has exited", pair.session ~= nil and pair.session ~= replacement)
check(":PairAsk opens a composer whose backend is running",
  pair.session ~= nil and pair.session.backend.job ~= nil and pair.session.ui:is_open())

local asked = pair.session
pair.stop()
check("the replacement sessions are stopped", vim.wait(5000, function() return asked.backend.job == nil end, 20))

os.remove(tmp)
vim.fn.delete(real, "rf")
os.remove(wire_log)
print(("\n%d passed, %d failed"):format(checks - failures, failures))
if failures > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
