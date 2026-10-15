#!/bin/bash
# Mutation checks: each patch disables one fixed behaviour and must make the
# checks that cover it fail. Files are restored from backup after each run.
set -u
cd /Users/ekassinghchhabra/Projects/lua/pair.nvim
work=$(mktemp -d)

run_one() { # label, target file, perl expression, test command
  local label=$1 file=$2 expr=$3 cmd=$4
  cp "$file" "$work/backup"
  if ! perl -0pi -e "$expr" "$file" 2>"$work/err"; then
    printf '%-46s PATCH ERROR: %s\n' "$label" "$(cat "$work/err")"
    cp "$work/backup" "$file"
    return
  fi
  if cmp -s "$work/backup" "$file"; then
    printf '%-46s PATCH DID NOT APPLY\n' "$label"
    cp "$work/backup" "$file"
    return
  fi
  local out fails
  out=$(eval "$cmd" 2>&1)
  fails=$(printf '%s\n' "$out" | grep -c '^FAIL')
  printf '%-46s %s checks failed\n' "$label" "$fails"
  printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'
  cp "$work/backup" "$file"
}

LOGIC="texlua tests/run.lua"
INTEG="nvim --headless -l tests/integration.lua"

run_one "marks gate on buffer content" lua/pair/marks.lua \
  's/return vim\.fn\.sha256\(text\) == revision/return true/' "$LOGIC"
run_one "key is not published as a revision" lua/pair/changes.lua \
  's/^        revision = entry\.revision,$/        revision = entry.revision or entry.key,/mg' "$LOGIC"
run_one "no sentinels in the change key" lua/pair/changes.lua \
  's/if not stat or stat\.type ~= "file" or stat\.size <= MAX_FILE_BYTES then return nil end/if not stat then return "<deleted>" end\n  if stat.type ~= "file" or stat.size <= MAX_FILE_BYTES then return nil end/' "$LOGIC"
run_one "rename keeps the reading comparable" lua/pair/changes.lua \
  's/local moved = renamed_to and after\[renamed_to\]/local moved = nil/' "$LOGIC"
run_one "budget favours cheap files" lua/pair/changes.lua \
  's/    if left == right then return a\.path < b\.path end\n    return left < right/    return a.path < b.path/' "$LOGIC"
run_one "a dropped window is reported" lua/pair/changes.lua \
  's/self\.on_change\(\{\}, id, "no baseline was recorded before it ran"\)/self.on_change({}, id)/' "$LOGIC"
run_one "a commit is not a change" lua/pair/changes.lua \
  's/        elseif previous\.key == entry\.key then/        elseif false then/' "$LOGIC"
run_one "a commit is not a change (integration)" lua/pair/changes.lua \
  's/        elseif previous\.key == entry\.key then/        elseif false then/' "$INTEG"
run_one "an absent file is marked absent" lua/pair/session.lua \
  's/    elseif entry\.status == "gone" then/    elseif false then/' "$LOGIC"
run_one "an absent file is marked absent (integration)" lua/pair/session.lua \
  's/    elseif entry\.status == "gone" then/    elseif false then/' "$INTEG"
run_one "the revised mark clears" lua/pair/ui.lua \
  's/      binding\.revised = \(binding\.key ~= nil and key ~= nil and binding\.key ~= key\) or false/      binding.revised = binding.revised or (binding.key ~= nil and key ~= nil and binding.key ~= key) or false/' "$LOGIC"

rm -rf "$work"
echo "--- mutation sweep done"
