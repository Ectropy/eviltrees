--[[
    capture/trees.lua
    -----------------
    Notices evil tree objects ("locs") near the player and reports what they are.

    The game tells plugins when locs appear (Event.LocAdded), disappear
    (Event.LocRemoved) or start an animation (Event.LocAnimation). We look each
    new loc's ID up in data/trees.lua; if it's an evil tree, we remember its
    tile and report it.

    What testing in the beta client showed:
      - Growing / taking damage: a new LocAdded at the same tile with the next
        ID (e.g. EVILTREE_OAK -> EVILTREE_OAK_LVL2).
      - Felled: LocRemoved, then LocAdded for the _DYING and then _DEAD loc.
      - Rewards over: the dead trunk plays EVILTREE_FADE_OUT, then LocRemoved.

    Reports go to the callback given to trees.setOnEvent(), as
        onEvent(kind, info, tileX, tileZ, previous)
    where kind is "seen", "fading" or "removed", info is the data/trees.lua
    entry (treeType, stage, healthCap, saplingLevel), and previous is the
    info of the loc this one just replaced (see below), or nil.

    Real change vs. "came into view": LocAdded most likely also fires when
    you walk up to a tree that was already there, and LocRemoved when you
    walk away or hop (not yet confirmed in the beta, so we play it safe).
    A real stage change is a LocRemoved followed straight away by a LocAdded
    at (nearly) the same tile - the tile can shift by one when the model gets
    bigger. So a removed tree is remembered for a couple of server ticks; if
    a new evil tree loc appears close by in that time, it's reported with
    previous = the removed one. A LocAdded straight onto the tile of a
    tracked tree (no LocRemoved) is a change too.
]]

local safe = require("core/safe")
local treeData = require("data/trees")

local trees = {}

local REPLACE_WINDOW_TICKS = 2  -- server ticks (~1.2 s) a removed tree is remembered
local REPLACE_MAX_TILES = 2     -- how far the replacement may be from the old tile

local onEvent = nil     -- function(kind, info, tileX, tileZ, previous), set by main.lua
local tracked = {}      -- [tile key] = { info, x, z } for each evil tree loc in view
local justRemoved = {}  -- list of { info, x, z, tick } for recently removed trees
local serverTick = 0

-- A text key for a tile, e.g. "2520,3102,0". LocRemoved only gives us the
-- tile, so this is how we know which tracked tree went away.
local function tileKey(coord)
    return coord.x .. "," .. coord.z .. "," .. coord.level
end

-- Starts tracking the evil tree loc on this tile (replacing any before it).
local function track(coord, info)
    tracked[tileKey(coord)] = { info = info, x = coord.x, z = coord.z }
end

-- True if a remembered tree (an entry of tracked or justRemoved) is at most
-- maxTiles away from tile x, z in both directions. math.abs is Math.abs.
local function isNear(entry, x, z, maxTiles)
    return math.abs(entry.x - x) <= maxTiles and math.abs(entry.z - z) <= maxTiles
end

local function report(kind, info, coord, previous)
    if onEvent ~= nil then
        onEvent(kind, info, coord.x, coord.z, previous)
    end
end

-- Finds (and forgets) a tree removed a moment ago close to this tile.
-- Returns its info, or nil.
local function takeJustRemoved(coord)
    for index, entry in ipairs(justRemoved) do
        if isNear(entry, coord.x, coord.z, REPLACE_MAX_TILES) then
            table.remove(justRemoved, index)
            return entry.info
        end
    end
    return nil
end

-- Registers the function to call for each evil tree event.
function trees.setOnEvent(callback)
    onEvent = callback
end

-- Forget everything we're tracking. Call when the world changes: trees from
-- the old world must not count as "replaced" by trees on the new one.
function trees.reset()
    tracked = {}
    justRemoved = {}
end

-- True if an evil tree loc is in view right now.
-- next(t) returns the first key of a table, or nil if it's empty.
function trees.isTreeInView()
    return next(tracked) ~= nil
end

-- True if an evil tree is within maxTiles of this tile: one in view now, or
-- one removed a moment ago. (A strike swaps the tree's loc in the same
-- second, so the strike can arrive between the old loc's LocRemoved and the
-- new one's LocAdded, while nothing is in "tracked".)
-- pairs() walks a table with any keys (here tile keys), ipairs() a list.
function trees.isNearTree(x, z, maxTiles)
    if x == nil or z == nil then
        return false
    end
    for _, entry in pairs(tracked) do
        if isNear(entry, x, z, maxTiles) then
            return true
        end
    end
    for _, entry in ipairs(justRemoved) do
        if isNear(entry, x, z, maxTiles) then
            return true
        end
    end
    return false
end

-- Event.ServerLogic handler: lets old "just removed" entries expire.
function trees.onServerTick()
    serverTick = serverTick + 1
    -- Walk the list backwards so removing an entry doesn't skip the next one.
    -- "for i = a, b, -1" counts down from a to b, like for (i = a; i >= b; i--).
    for index = #justRemoved, 1, -1 do
        if serverTick - justRemoved[index].tick > REPLACE_WINDOW_TICKS then
            table.remove(justRemoved, index)
        end
    end
end

-- Event.LocAdded handler.
function trees.onLocAdded(event)
    local configId = safe.try(function() return event.config.id end)
    local info = treeData.byId[configId]
    if info == nil then
        return      -- not an evil tree
    end
    local previous = takeJustRemoved(event.coordGrid)
    -- The game can also swap a loc in place: a LocAdded on the tile of a
    -- tree we're tracking, with no LocRemoved first (seen in the beta on a
    -- lightning strike, full tree -> _LVL2). That's a change too.
    local old = tracked[tileKey(event.coordGrid)]
    if previous == nil and old ~= nil and old.info ~= info then
        previous = old.info
    end
    track(event.coordGrid, info)
    report("seen", info, event.coordGrid, previous)
end

-- Event.LocRemoved handler.
function trees.onLocRemoved(event)
    local coord = event.coordGrid
    local key = tileKey(coord)
    local entry = tracked[key]
    if entry == nil then
        return
    end
    tracked[key] = nil
    justRemoved[#justRemoved + 1] = { info = entry.info, x = coord.x, z = coord.z, tick = serverTick }
    report("removed", entry.info, coord)
end

-- Event.LocAnimation handler. We only care about the dead trunk fading out.
function trees.onLocAnimation(event)
    local entry = tracked[tileKey(event.coordGrid)]
    if entry == nil or event.animation == nil then
        return
    end
    -- The animation prints like "config.Seq.EVILTREE_FADE_OUT(1715)".
    if string.find(tostring(event.animation), "EVILTREE_FADE_OUT", 1, true) then
        report("fading", entry.info, event.coordGrid)
    end
end

-- Looks for evil trees that are already nearby (e.g. right after start-up,
-- when no LocAdded events have arrived for them). These are first sightings,
-- so previous is nil.
function trees.scanNearby()
    for locId, info in pairs(treeData.byId) do
        local found = safe.try(function() return LocList.ByConfigID(locId) end) or {}
        for _, loc in ipairs(found) do
            if loc.isValid then
                track(loc.coordGrid, info)
                report("seen", info, loc.coordGrid)
            end
        end
    end
end

return trees
