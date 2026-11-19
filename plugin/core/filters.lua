--[[
    core/filters.lua
    ----------------
    The world grid's sort and filters. Pure: no game API calls, so it can be
    tested outside the game. ui/grid.lua shows the buttons (made from the
    entry lists below) and calls filters.apply to get the cells to draw.

    It works on CELLS (what overview.cells returns), never on saved records.
    The cell fields used: world, members, kind, cellAt, treeKey, hasHint,
    hasPlace, healthValue, saplingType (all described above buildCell in core/overview.lua).

    The user's choices ("prefs") are a table like:
        { sort = "soonest", worlds = "p2p", info = "any", trees = { "yew", "magic" },
          lines = "two" }
    sort / worlds / info / lines are one id from the lists below. lines is
    not a filter: it says how the cells are drawn (one or two lines each),
    and is kept here so it is saved and checked with the rest. trees is a list of
    tree keys; an empty list means any tree. Prefs get saved, so always run
    saved data through filters.normalize before using it.

    Words used in this file:
      "active"  a cell with kind "spawn", "sapling", "alive" or "dead"
                (we know something about its tree, or when it spawns)
      "tree up" kind "sapling", "alive" or "dead"
]]

local filters = {}

-- The group names, for the buttons ("Sort", "Worlds", ...).
filters.TITLES = { sort = "Sort", worlds = "Worlds", info = "Info", trees = "Tree" }

-- The choices for each group, in the order they are shown. Each entry is
-- { id = what we save and compare, label = what the button says }.
-- (A list of tables like [{ id: "world", label: "World" }, ...] in JS.)
filters.SORTS = {
    { id = "world", label = "World" },
    { id = "worldDesc", label = "World (high first)" },
    { id = "soonest", label = "Soonest" },
    { id = "latest", label = "Latest" },
    { id = "health", label = "Lowest health" },
}

filters.WORLDS = {
    { id = "all", label = "All" },
    { id = "p2p", label = "P2P" },
    { id = "f2p", label = "F2P" },
}

filters.INFOS = {
    { id = "any", label = "Any" },
    { id = "noIntel", label = "No intel" },
    { id = "hasIntel", label = "Has intel" },
    { id = "needsHint", label = "Needs hint" },
    { id = "needsPlace", label = "Needs place" },
}
-- (EctoTrees also had "Has hint", "Has place" and "Needs / Has health".
-- They help scouts who share intel; playing alone, the useful ones are
-- those that say which world is worth a visit. Left out on 2026-11-09.)

-- How the cells are drawn: "two" adds the health and the place on a
-- second line (see ui/grid.lua). Not a filter: it hides nothing. Chosen on
-- the grid's settings page (ui/gridsettings.lua).
filters.LINES = {
    { id = "two", label = "Two lines" },
    { id = "one", label = "One line" },
}

-- Tree keys are the cell's treeKey: see overview.lua.
filters.TREES = {
    { id = "unknown", label = "Unknown" },
    { id = "sapling", label = "Sapling" },
    { id = "tree", label = "Tree" },
    { id = "oak", label = "Oak" },
    { id = "willow", label = "Willow" },
    { id = "maple", label = "Maple" },
    { id = "yew", label = "Yew" },
    { id = "magic", label = "Magic" },
    { id = "elder", label = "Elder" },
}

-------------------------------------------------------------------------------
-- Prefs
-------------------------------------------------------------------------------

-- A NEW default prefs table every time. (If everyone shared one table, a
-- change made through one variable would show up in all of them, as with
-- a shared object in JS. So there is no shared DEFAULTS table.)
function filters.defaults()
    return { sort = "world", worlds = "all", info = "any", trees = {}, lines = "two" }
end

-- true if id is one of the entries' ids. ipairs walks an array in order,
-- like for...of; each step gives (index, entry), and "_" ignores the index.
local function hasId(entries, id)
    for _, entry in ipairs(entries) do
        if entry.id == id then
            return true
        end
    end
    return false
end

-- A valid choice: the saved id if the list still has it, else the default.
local function validId(entries, saved, default)
    if hasId(entries, saved) then
        return saved
    end
    return default
end

-- Makes a fresh, valid prefs table from anything (nil, a string, an old save
-- with ids that no longer exist...). Unknown choices fall back to the
-- default. Trees keep only valid keys, once each, in filters.TREES order.
-- Never returns (or changes) the table you give it.
function filters.normalize(saved)
    local prefs = filters.defaults()
    if type(saved) ~= "table" then
        return prefs
    end
    prefs.sort = validId(filters.SORTS, saved.sort, prefs.sort)
    prefs.worlds = validId(filters.WORLDS, saved.worlds, prefs.worlds)
    prefs.info = validId(filters.INFOS, saved.info, prefs.info)
    prefs.lines = validId(filters.LINES, saved.lines, prefs.lines)

    if type(saved.trees) == "table" then
        -- First a set of what was saved: chosen["yew"] = true. A set makes
        -- duplicates and the order of the saved list not matter.
        local chosen = {}
        for _, key in ipairs(saved.trees) do
            chosen[key] = true
        end
        -- Then walk the full list, so the result is in display order.
        for _, entry in ipairs(filters.TREES) do
            if chosen[entry.id] then
                prefs.trees[#prefs.trees + 1] = entry.id    -- push
            end
        end
    end
    return prefs
end

-- true when the worlds, info or tree choice is not the default, so some
-- worlds may be hidden. (The sort and lines never hide anything.)
function filters.isFiltering(prefs)
    return prefs.worlds ~= "all" or prefs.info ~= "any" or #prefs.trees > 0
end

-- The Tree button's text: "Tree: Any", "Tree: Elder", "Tree: Yew, Magic",
-- "Tree: 4 types".
function filters.treeSummary(trees)
    -- The labels of the chosen trees, in display order.
    local chosen = {}
    for _, key in ipairs(trees) do
        chosen[key] = true
    end
    local labels = {}
    for _, entry in ipairs(filters.TREES) do
        if chosen[entry.id] then
            labels[#labels + 1] = entry.label
        end
    end

    if #labels == 0 then
        return filters.TITLES.trees .. ": Any"
    elseif #labels <= 2 then
        return filters.TITLES.trees .. ": " .. table.concat(labels, ", ")   -- labels.join(", ")
    end
    return string.format("%s: %d types", filters.TITLES.trees, #labels)
end

-------------------------------------------------------------------------------
-- Filtering
-------------------------------------------------------------------------------

local function isActive(cell)
    return cell.kind == "spawn" or cell.kind == "sapling" or cell.kind == "alive" or cell.kind == "dead"
end

local function isTreeUp(cell)
    return cell.kind == "sapling" or cell.kind == "alive" or cell.kind == "dead"
end

-- One test per info choice: each takes a cell and returns true to show it.
-- (A table of functions, like { noIntel: cell => ... } in JS. "any" is
-- missing on purpose: no test means show everything.)
local INFO_TESTS = {
    noIntel = function(cell) return cell.kind == "unknown" or cell.kind == "none" end,
    hasIntel = function(cell) return isActive(cell) end,
    needsHint = function(cell) return isActive(cell) and not cell.hasHint end,
    needsPlace = function(cell) return isTreeUp(cell) and not cell.hasPlace end,
}

-- Does the cell's tree match one of the wanted trees (a set, like
-- wanted["yew"] = true)? A cell with no tree (treeKey nil) never matches.
-- A sapling whose type we know matches "sapling" AND its type, so ticking
-- "Elder" also shows the elder that is about to grow up.
local function matchesTrees(cell, wanted)
    if cell.treeKey ~= nil and wanted[cell.treeKey] == true then
        return true
    end
    return cell.saplingType ~= nil and wanted[cell.saplingType] == true
end

-- Does the cell pass the worlds choice? A world whose members flag we don't
-- know (nil) only shows under "all".
local function passesWorlds(cell, worlds)
    if worlds == "p2p" then
        return cell.members == true
    elseif worlds == "f2p" then
        return cell.members == false
    end
    return true
end

-------------------------------------------------------------------------------
-- Sorting
-------------------------------------------------------------------------------

-- "Soonest" groups: the lower the number, the sooner it is listed.
local KIND_GROUPS = { dead = 0, alive = 1, sapling = 2, spawn = 3 }
local NO_TIME_GROUP = 4     -- no time to count down to: always listed last

-- A cell's group for the soonest/latest sorts.
local function timeGroup(cell)
    local group = KIND_GROUPS[cell.kind]    -- nil for "unknown" and "none"
    if group == nil or cell.cellAt == nil then
        return NO_TIME_GROUP
    end
    return group
end

-- table.sort wants a function that returns true only when a must come BEFORE
-- b (JS's sort wants a number instead). It must never say "a before b" for
-- two equal cells, and table.sort is not stable (equal cells can swap), so
-- every comparer ends by comparing world numbers: no two cells tie.

local function byWorld(a, b)
    return a.world < b.world
end

local function byWorldDesc(a, b)
    return a.world > b.world
end

-- Makes the soonest or latest comparer. In "latest" the groups run the other
-- way (spawn first, dead last) and times from the largest down, but the
-- no-time group is still last.
local function timeSorter(latest)
    return function(a, b)
        local aGroup, bGroup = timeGroup(a), timeGroup(b)
        if latest and aGroup ~= NO_TIME_GROUP then
            aGroup = 3 - aGroup     -- 0..3 becomes 3..0
        end
        if latest and bGroup ~= NO_TIME_GROUP then
            bGroup = 3 - bGroup
        end
        if aGroup ~= bGroup then
            return aGroup < bGroup
        end
        if aGroup ~= NO_TIME_GROUP and a.cellAt ~= b.cellAt then
            if latest then
                return a.cellAt > b.cellAt
            end
            return a.cellAt < b.cellAt
        end
        return a.world < b.world
    end
end

-- 0: alive with a health number, 1: alive without one, 2: everything else.
local function healthGroup(cell)
    if cell.kind == "alive" then
        return cell.healthValue ~= nil and 0 or 1   -- ("x and a or b" is x ? a : b)
    end
    return 2
end

local function byHealth(a, b)
    local aGroup, bGroup = healthGroup(a), healthGroup(b)
    if aGroup ~= bGroup then
        return aGroup < bGroup
    end
    if aGroup == 0 and a.healthValue ~= b.healthValue then
        return a.healthValue < b.healthValue
    end
    return a.world < b.world
end

local SORTERS = {
    world = byWorld,
    worldDesc = byWorldDesc,
    soonest = timeSorter(false),
    latest = timeSorter(true),
    health = byHealth,
}

-------------------------------------------------------------------------------
-- Putting it together
-------------------------------------------------------------------------------

-- The cells to show, in display order, as a NEW array. Neither the array
-- you pass nor the cells in it are changed (the result holds the same cell
-- tables, like array.filter in JS).
function filters.apply(cells, prefs)
    local infoTest = INFO_TESTS[prefs.info]     -- nil for "any"

    -- A set of the chosen trees, or nil for "any tree".
    local wantedTrees = nil
    if #prefs.trees > 0 then
        wantedTrees = {}
        for _, key in ipairs(prefs.trees) do
            wantedTrees[key] = true
        end
    end

    local result = {}
    for _, cell in ipairs(cells) do
        local show = passesWorlds(cell, prefs.worlds)
        if show and infoTest ~= nil then
            show = infoTest(cell)
        end
        if show and wantedTrees ~= nil then
            show = matchesTrees(cell, wantedTrees)
        end
        if show then
            result[#result + 1] = cell
        end
    end

    table.sort(result, SORTERS[prefs.sort] or byWorld)
    return result
end

return filters
