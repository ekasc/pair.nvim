-- Change groups: the observed changes that belong to one stated decision, instead
-- of a flat list of files. A group is a view over evidence and not a record of its
-- own: the decision supplies the intent and the file list, the observation supplies
-- the reading, and the binding the decision recorded supplies whether that reading
-- still holds. A file is in a group because the decision named it, which is a
-- statement about names and never about authorship.

local Groups = {}

-- The evidence a group shows for one path: the last observation of it and the
-- state of the decision's binding for it. The observation is referred to rather
-- than copied, so the view cannot drift from the reading it points at.
function Groups.file(path, entry, binding)
  return {
    path = path,
    entry = entry,
    -- Whether a file moved is decided where the mark is set, where two readings
    -- are available to compare. This reports that mark.
    superseded = binding ~= nil and binding.revised == true,
    gone = binding ~= nil and binding.gone == true,
  }
end

-- One group per decision that names files, in the order the decisions were
-- stated, followed by the observed paths no decision names. The second return
-- value is that bucket, which is not a group: no decision holds it, and listing it
-- anyway is what keeps this view from quietly hiding changes it cannot place.
function Groups.build(decisions, file_log)
  local groups, claimed = {}, {}
  for _, decision in ipairs(decisions) do
    local named = decision.files or {}
    if #named > 0 then
      local group = { title = decision.title, files = {} }
      local named_once = {}
      for _, path in ipairs(named) do
        -- A decision that names one path twice names one file. Counting it twice
        -- would report a second file and a second copy of the same hunks.
        if not named_once[path] then
          named_once[path] = true
          group.files[#group.files + 1] = Groups.file(path, file_log[path], decision.bindings and decision.bindings[path])
        end
        claimed[path] = true
      end
      groups[#groups + 1] = group
    end
  end
  local unclaimed = {}
  for path, entry in pairs(file_log) do
    if not claimed[path] then unclaimed[#unclaimed + 1] = Groups.file(path, entry, nil) end
  end
  table.sort(unclaimed, function(a, b) return a.path < b.path end)
  return groups, unclaimed
end

return Groups
