--[[
    core/capturelog.lua
    -------------------
    A development aid: keeps the most recent captured facts (dialogue, examine
    text, tree objects) as plain text lines and saves them to PersistentDB
    under the key "captureLog". The debug panel can only show a few lines, so
    this is where the full history lives. scripts/read_plugin_log.py reads it:
        python scripts/read_plugin_log.py

    Will be removed or turned off before the plugin is submitted.
]]

local capturelog = {}

local MAX_LINES = 300       -- oldest lines are dropped beyond this

local lines = {}            -- oldest first
local changed = false

-- Load what earlier sessions saved, so a reload or world hop doesn't wipe it.
local saved = nil
pcall(function() saved = PersistentDB:GetString("captureLog") end)
if type(saved) == "string" then
    -- string.gmatch loops over every match; "[^\n]+" = a run of non-newline characters.
    for line in string.gmatch(saved, "[^\n]+") do
        lines[#lines + 1] = line
    end
end

-- Adds one line.
function capturelog.add(line)
    lines[#lines + 1] = line
    if #lines > MAX_LINES then
        table.remove(lines, 1)      -- drop the oldest
    end
    changed = true
end

-- Writes the log to PersistentDB if anything was added since the last save.
function capturelog.saveIfChanged()
    if not changed then
        return
    end
    changed = false
    pcall(function() PersistentDB:SetString("captureLog", table.concat(lines, "\n")) end)
end

return capturelog
