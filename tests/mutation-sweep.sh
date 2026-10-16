#!/bin/bash
# Mutation checks: each patch disables one fixed behaviour and must make the
# checks that cover it fail. Files are restored from backup after each run.
#
# The sweep reports and exits non-zero on any patch that does not apply, does
# not change the file, or leaves the checks passing: a mutation tool that can
# only print is not evidence that the checks bite.
set -u

# The repository is found from this script, not from the caller's directory.
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

LOGIC="texlua tests/run.lua"
INTEG="nvim --headless -l tests/integration.lua"

for runner in "${LOGIC%% *}" "${INTEG%% *}"; do
  if ! command -v "$runner" >/dev/null 2>&1; then
    echo "missing test runner: $runner" >&2
    exit 2
  fi
done

bad=0
# The sweep copies files aside and puts them back. Comparing the repository state
# before and after proves the putting back worked, without failing when the
# caller had their own uncommitted work when they started.
state_before=""
if command -v git >/dev/null 2>&1; then state_before=$(git status --porcelain); fi

run_one() { # label, target file, perl expression, test command
  local label=$1 file=$2 expr=$3 cmd=$4
  cp "$file" "$work/backup"
  cp "$file" "$work/original"
  if ! perl -0pi -e "$expr" "$file" 2>"$work/err"; then
    printf '%-46s PATCH ERROR: %s\n' "$label" "$(cat "$work/err")"
    cp "$work/backup" "$file"
    bad=$((bad + 1))
    return
  fi
  if cmp -s "$work/backup" "$file"; then
    printf '%-46s PATCH DID NOT APPLY\n' "$label"
    cp "$work/backup" "$file"
    bad=$((bad + 1))
    return
  fi
  local out fails ran
  out=$(eval "$cmd" 2>&1)
  fails=$(printf '%s\n' "$out" | grep -c '^FAIL')
  # A patch that changes nothing observable may still make a runner die before it
  # reports, which is not the same as the checks catching the mutation.
  ran=$(printf '%s\n' "$out" | grep -c '^PASS')
  if [ "$fails" -eq 0 ] || [ "$ran" -eq 0 ]; then
    printf '%-46s NO BITE (%s checks failed, %s checks ran)\n' "$label" "$fails" "$ran"
    printf '%s\n' "$out" | grep -E '^(FAIL|.*error.*|E[0-9]+)' | head -5 | sed 's/^/      /'
    bad=$((bad + 1))
  else
    printf '%-46s %s checks failed\n' "$label" "$fails"
    printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'
  fi
  cp "$work/backup" "$file"
  if ! cmp -s "$work/backup" "$file"; then
    printf '%-46s RESTORE FAILED\n' "$label"
    cp "$work/original" "$file"
    bad=$((bad + 1))
  fi
}

run_one "marks gate on buffer content" lua/pair/marks.lua \
  's/return vim\.fn\.sha256\(text\) == revision/return true/' "$LOGIC"
run_one "key is not published as a revision" lua/pair/changes.lua \
  's/^        revision = entry\.revision,$/        revision = entry.revision or entry.key,/mg' "$LOGIC"
run_one "no sentinels in the change key" lua/pair/changes.lua \
  's/if not stat or stat\.type ~= "file" or stat\.size <= MAX_FILE_BYTES then return nil end/if not stat then return "<deleted>" end\n  if stat.type ~= "file" or stat.size <= MAX_FILE_BYTES then return nil end/' "$LOGIC"
run_one "rename keeps the reading comparable" lua/pair/changes.lua \
  's/local moved = renamed_to and after\[renamed_to\]/local moved = nil/' "$LOGIC"
run_one "rename publishes nothing for the old path" lua/pair/changes.lua \
  's/^          revision = nil$/          revision = entry.revision/m' "$LOGIC"
run_one "a copy is not a moved reading" lua/pair/changes.lua \
  's/    if after\[origin\] == nil then origin_of\[target\] = origin end/    origin_of[target] = origin/' "$LOGIC"
run_one "budget favours cheap files" lua/pair/changes.lua \
  's/    if left == right then return a\.path < b\.path end\n    return left < right/    return a.path < b.path/' "$LOGIC"
run_one "a dropped window is reported" lua/pair/changes.lua \
  's/self\.on_change\(\{\}, id, "no baseline was recorded before it ran"\)/self.on_change({}, id)/' "$LOGIC"
run_one "a commit is not a change" lua/pair/changes.lua \
  's/        elseif previous\.key == entry\.key then/        elseif false then/' "$LOGIC"
run_one "a commit is not a change (integration)" lua/pair/changes.lua \
  's/        elseif previous\.key == entry\.key then/        elseif false then/' "$INTEG"
run_one "a commit keeps the reading comparable" lua/pair/changes.lua \
  's/    local entry = \{ key = vim\.fn\.sha256\(content\), content = content \}/    local entry = { key = tostring(#content) .. ":" .. content:sub(1, 1), content = content }/' "$INTEG"
run_one "an absent file is marked absent" lua/pair/session.lua \
  's/    elseif entry\.status == "gone" then/    elseif false then/' "$LOGIC"
run_one "an absent file is marked absent (integration)" lua/pair/session.lua \
  's/    elseif entry\.status == "gone" then/    elseif false then/' "$INTEG"
run_one "marks leave a buffer holding another revision" lua/pair/session.lua \
  's/    Marks\.clear\(bufnr\)\n    return/    -- cleared\n    return/' "$INTEG"
run_one "the revised mark clears" lua/pair/ui.lua \
  's/      binding\.revised = \(binding\.key ~= nil and key ~= nil and binding\.key ~= key\) or false/      binding.revised = binding.revised or (binding.key ~= nil and key ~= nil and binding.key ~= key) or false/' "$LOGIC"
run_one "a group shows the reading it points at" lua/pair/groups.lua \
  's/        group\.files\[#group\.files \+ 1\] = Groups\.file\(path, file_log\[path\], decision\.bindings and decision\.bindings\[path\]\)/        group.files[#group.files + 1] = Groups.file(path, nil, decision.bindings and decision.bindings[path])/' "$LOGIC"
run_one "a group lists paths no decision names" lua/pair/groups.lua \
  's/    if not claimed\[path\] then unclaimed\[#unclaimed \+ 1\] = Groups\.file\(path, entry, nil\) end/    if false then unclaimed[#unclaimed + 1] = Groups.file(path, entry, nil) end/' "$INTEG"
run_one "a group reports superseded evidence" lua/pair/groups.lua \
  's/    superseded = binding ~= nil and binding\.revised == true/    superseded = false/' "$INTEG"
run_one "a reported path that is not readable ends its absence" lua/pair/session.lua \
  's/      self\.ui:mark_revised\(file, nil\)/      self.ui:mark_gone(file)/' "$LOGIC"
run_one "a decision names each path as the editor would" lua/pair/session.lua \
  's/            file = vim\.fs\.normalize\(vim\.trim\(file\)\)/            file = vim.trim(file)/' "$LOGIC"
run_one "a decision names one path once" lua/pair/session.lua \
  's/            if file ~= "" and not seen\[file\] then/            if file ~= "" then/' "$LOGIC"
run_one "an absence already told is not told again" lua/pair/changes.lua \
  's/  if reported == nil or reported\.status ~= state or reported\.reason ~= read_reason\(entry\) then/  if true then/' "$LOGIC"
run_one "a window reports nothing it cannot name" lua/pair/changes.lua \
  's/      if status then\n        local hunks, hunks_reason, revision/      if true then\n        local hunks, hunks_reason, revision/' "$LOGIC"
run_one "a dead backend is not reopened" lua/pair/init.lua \
  's/  elseif M\.session\.backend\.job then/  elseif true then/' "$INTEG"
run_one "a dead backend is not asked" lua/pair/init.lua \
  's/  if M\.session and M\.session\.backend\.job then/  if M.session then/' "$INTEG"
run_one "a failed turn is reported with its reason" lua/pair/session.lua \
  's/    if event\.message\.stopReason == "error" then/    if false then/' "$LOGIC"
run_one "an answer section opens with its first text" lua/pair/session.lua \
  's/    self\.active_message = nil\n  elseif event\.type == "message_update" then/    self.active_message = self.ui:add("agent", "")\n  elseif event.type == "message_update" then/' "$LOGIC"
run_one "a window compares against the previous observation" lua/pair/changes.lua \
  's/  if type\(baseline\) ~= "table" or held\(self, baseline\) then/  if true then/' "$LOGIC"
run_one "a window compares against the previous observation (integration)" lua/pair/changes.lua \
  's/  if type\(baseline\) ~= "table" or held\(self, baseline\) then/  if true then/' "$INTEG"
run_one "the root is one canonical name" lua/pair/init.lua \
  's/  return vim\.uv\.fs_realpath\(path\) or vim\.fs\.normalize\(path\)/  return vim.fs.normalize(path)/' "$INTEG"
run_one "a question keeps the decision that named its file" lua/pair/session.lua \
  's/  if decision then\n    -- Referred to rather than copied/  if false then\n    -- Referred to rather than copied/' "$LOGIC"
run_one "a send leaves the user where they were" lua/pair/ui.lua \
  's/  if focused and self\.input_win and vim\.api\.nvim_win_is_valid\(self\.input_win\) then/  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then/' "$INTEG"
run_one "a growing transcript does not move a reader" lua/pair/ui.lua \
  's/  local should_follow = cursor\[1\] >= old_count - 2/  local should_follow = true/' "$INTEG"
run_one "a question while the agent works is queued" lua/pair/pi.lua \
  's/  if self\.busy then/  if false then/' "$INTEG"
run_one "a redirect is sent as a steer" lua/pair/pi.lua \
  's/    command = behavior == "steer" and "steer" or "follow_up"/    command = "follow_up"/' "$INTEG"
run_one "an interruption is reported as one" lua/pair/session.lua \
  's/    self\.ui:add\("status", event\.aborted and "Agent interrupted" or "Agent idle"\)/    self.ui:add("status", "Agent idle")/' "$INTEG"
run_one "a rename after the work was accepted is still a rename" lua/pair/changes.lua \
  's/    if before\[origin\] == nil and after\[origin\] == nil and after\[target\] ~= nil then/    if false then/' "$LOGIC"
run_one "a buffer is resolved by name, not by pattern" lua/pair/session.lua \
  's/    if vim\.api\.nvim_buf_get_name\(candidate\) == path then return candidate end/    return vim.fn.bufnr(path)/' "$INTEG"

rm -rf "$work"
if command -v git >/dev/null 2>&1 && [ "$(git status --porcelain)" != "$state_before" ]; then
  echo "--- mutation sweep FAILED: the repository was not restored" >&2
  git status --porcelain >&2
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  echo "--- mutation sweep FAILED: $bad patch(es) did not bite"
  exit 1
fi
echo "--- mutation sweep done: every patch bit"
