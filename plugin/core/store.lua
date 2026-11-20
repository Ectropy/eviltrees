--[[
    core/store.lua
    --------------
    Saves and loads the plugin's data with PersistentDB, the plugin API's
    built-in storage (a small database on disk, kept per plugin).

    What is stored:
      "schemaVersion" - number saying which data format the save uses, so
                        future versions can upgrade old saves.
      "worlds"        - one record per world we have intel on (format in
                        core/worldstate.lua).
      "lastWorld"     - the last world we knew we were on, when we saw it, and
                        when we left the game (for the activity tracker's
                        login reading after a restart).
      "gridWindow"    - where the world grid window was and whether it was
                        open: { x, y, width, height, open = 1 or 0 }.
      "gridView"      - the grid's sort, filters and layout, as six strings:
                        { sort = "soonest", worlds = "all", info = "any",
                        trees = "yew,magic", lines = "two", card = "top" }
                        (trees joined by commas, "" for any tree; plain
                        strings avoid saving an empty table or a list).
                        ui/grid.lua checks them on load.

    Saving is "debounced": changes only mark the data as changed, and
    store.saveIfChanged() (called every few seconds by main.lua) writes it.
    That avoids writing to disk on every tiny change.

    Storage format notes:
      - In memory, store.worlds is keyed by world number
        (store.worlds[205] = {...}). On disk we save a plain list of records
        that each include their world number, which avoids relying on how
        numeric keys are serialised.
      - PersistentDB keeps numbers inside tables as 32-bit floats (found in
        the beta: a saved spawn time came back 24 s off). A 32-bit float
        holds whole numbers exactly only up to 16,777,216, and our Unix-ms
        timestamps are about 1.8 trillion, so they'd be rounded to steps of
        131 seconds. Big whole numbers are therefore saved as text like
        "int:1793945263552" and turned back into numbers on load.
]]

local safe = require("core/safe")
local devlog = require("core/devlog")

local store = {}

-- Bump this when a released version changes the saved format, and add an
-- upgrade step in load(). 1: the first release's format.
local SCHEMA_VERSION = 1

-- Largest whole number a 32-bit float holds exactly (2 to the power 24).
local FLOAT32_EXACT_LIMIT = 16777216
local INT_PREFIX = "int:"

store.worlds = {}           -- [worldNumber] = record table
store.lastWorld = nil       -- { number = 205, seenAt = <unix ms>, leftAt = <unix ms or nil> } or nil
store.gridWindow = nil      -- { x =, y =, width =, height =, open = 1 } or nil
store.gridView = nil        -- { sort =, worlds =, info =, trees =, lines =, card = } (all strings) or nil
store.lastSavedAt = nil     -- unix ms of the most recent save this session

local changed = false

-- PersistentDB saves numbers inside tables as decimals, so 204 comes back as
-- 204.0. Lua treats 204.0 == 204 as true, but it would display as "204.0".
-- This walks a loaded table and turns whole-number decimals back into integers.
-- math.type(x) is "integer" or "float"; math.tointeger(204.0) gives 204.
-- It also turns "int:..." text (see the header) back into a number.
local function restoreIntegers(value)
    if type(value) == "table" then
        for key, inner in pairs(value) do
            value[key] = restoreIntegers(inner)
        end
        return value
    end
    if math.type(value) == "float" then
        return math.tointeger(value) or value  -- keep real decimals like 0.5 as they are
    end
    -- string.sub(s, 1, n) is s.slice(0, n). tonumber("123") gives 123, or
    -- nil if the text isn't a number; math.tointeger then makes it a whole
    -- number if possible.
    if type(value) == "string" and string.sub(value, 1, #INT_PREFIX) == INT_PREFIX then
        local number = tonumber(string.sub(value, #INT_PREFIX + 1))
        if number ~= nil then
            return math.tointeger(number) or number
        end
    end
    return value
end

-- Makes a copy of a table that's safe to save: whole numbers too big for a
-- 32-bit float become "int:..." text. The in-memory table is left alone.
local function prepareForSave(value)
    if type(value) == "table" then
        local result = {}
        for key, inner in pairs(value) do
            result[key] = prepareForSave(inner)
        end
        return result
    end
    -- A whole number may be held as an integer or as a float (e.g. 1.79e12
    -- that came from a calculation), so test the value, not the type.
    -- "%.0f" prints a number with no decimals, like n.toFixed(0) in JS.
    if type(value) == "number" and math.abs(value) > FLOAT32_EXACT_LIMIT
        and value == math.floor(value) then
        return INT_PREFIX .. string.format("%.0f", value)
    end
    return value
end

-- Call after changing store.worlds, store.lastWorld, store.gridWindow or store.gridView.
function store.markChanged()
    changed = true
end

-- Reads everything from PersistentDB.
function store.load()
    local savedVersion = safe.try(function() return PersistentDB:GetInt("schemaVersion") end)
    if savedVersion == nil then
        devlog.print("[store] no saved data yet")
        return
    end
    if savedVersion > SCHEMA_VERSION then
        -- Saved by a newer version of the plugin; don't guess at its format.
        log("[store] saved data is from a newer plugin version; starting empty")
        return
    end

    local savedList = restoreIntegers(safe.try(function() return PersistentDB:GetStructuredData("worlds") end) or {})
    store.worlds = {}
    local count = 0
    for _, record in ipairs(savedList) do
        if type(record) == "table" and type(record.world) == "number" then
            store.worlds[record.world] = record
            count = count + 1
        end
    end

    store.lastWorld = restoreIntegers(safe.try(function() return PersistentDB:GetStructuredData("lastWorld") end))
    store.gridWindow = restoreIntegers(safe.try(function() return PersistentDB:GetStructuredData("gridWindow") end))
    store.gridView = safe.try(function() return PersistentDB:GetStructuredData("gridView") end)   -- strings only

    devlog.print("[store] loaded", count, "world records")
end

-- Writes everything to PersistentDB right away. nowMs is the current time
-- (from clock.now()), recorded so the debug section can show when we last saved.
function store.saveNow(nowMs)
    local list = {}
    for worldNumber, record in pairs(store.worlds) do
        record.world = worldNumber      -- make sure each record knows its world
        list[#list + 1] = record        -- list[#list + 1] = x is Lua's list.push(x)
    end

    -- Each table is deleted before it's written. The docs say Set replaces
    -- the old value, but in the beta a field from an older save seemed to
    -- survive. Deleting first guarantees the save is exactly this table
    -- (so a cleared world, or a field set to nil, really goes).
    local ok, err = pcall(function()
        PersistentDB:SetInt("schemaVersion", SCHEMA_VERSION)
        PersistentDB:Delete("worlds")
        PersistentDB:SetStructuredData("worlds", prepareForSave(list))
        if store.lastWorld ~= nil then
            PersistentDB:Delete("lastWorld")
            PersistentDB:SetStructuredData("lastWorld", prepareForSave(store.lastWorld))
        end
        if store.gridWindow ~= nil then
            PersistentDB:Delete("gridWindow")
            PersistentDB:SetStructuredData("gridWindow", prepareForSave(store.gridWindow))
        end
        -- Last, so a problem with it can't stop the world records being saved.
        if store.gridView ~= nil then
            PersistentDB:Delete("gridView")
            PersistentDB:SetStructuredData("gridView", store.gridView)
        end
    end)
    if not ok then
        log("[error] saving data failed: " .. tostring(err))
        return
    end

    changed = false
    store.lastSavedAt = nowMs
    devlog.print("[store] saved", #list, "world records")
end

-- Saves only if something changed since the last save.
function store.saveIfChanged(nowMs)
    if changed then
        store.saveNow(nowMs)
    end
end

return store
