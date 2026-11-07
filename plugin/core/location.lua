--[[
    core/location.lua
    -----------------
    Works out where a world's tree is (or will be), from what we know:
      1. the tile we saw the tree on       -> the nearest known location
      2. the spirit tree's clue sentence   -> the location it describes
      3. the hints                         -> one or more possible locations
    The first one available wins: a tree we saw beats anything we were told.

    Hints: each place has one to three hints, and the game picks one of them
    each time you ask. So two DIFFERENT hints for the same tree leave only
    the places they share. Seen on the W204 oak (2026-11-07): "on the
    southern coast of a tropical island" (Ape Atoll or Kharazi) and "on the
    island known as Karamja" (Kharazi or Shilo) -> Kharazi, where it was.
    Pure: no game API calls. The places themselves are in data/hints.lua.
]]

local hints = require("data/hints")

local location = {}

-- A tree's tile is a few tiles from its location's map pin (the W204 willow
-- was 10 tiles from the Rellekka pin). The closest two pins are about 40
-- tiles apart, so anything within 20 tiles can only belong to one pin.
-- Further than that, we'd rather say nothing than guess.
location.MAX_PIN_DISTANCE = 20

-- Makes two texts comparable: lower case, single spaces, no spaces or full
-- stop at either end. "  North as the crow  flies. " -> "north as the crow flies".
-- In Lua patterns, %s is any whitespace (like \s in regex), and "^%s*(.-)%s*$"
-- captures everything between leading and trailing spaces (like a trim()).
local function normalize(text)
    text = string.lower(text)
    text = string.gsub(text, "%s+", " ")
    text = string.match(text, "^%s*(.-)%s*$")
    text = string.gsub(text, "%.$", "")       -- a trailing full stop
    return text
end

-- The hints and clues normalized once at load, so lookups don't redo it.
-- hintIndex["north as the crow flies from seers' village"] = { "East of ...", ... }
-- clues = { { name = "West of Falador", clue = "to the west of falador, beside the mine" }, ... }
local hintIndex = {}
for _, entry in ipairs(hints.list) do
    hintIndex[normalize(entry.hint)] = entry.locations
end
local clues = {}
for _, place in ipairs(hints.locations) do
    clues[#clues + 1] = { name = place.name, clue = normalize(place.clue) }
end

-- The possible locations for a hint, as a list of names (empty if we don't
-- know the hint). The hint is the part after "It can be found", as the
-- parser captures it, e.g. "north as the crow flies from Seers' Village".
function location.forHint(hint)
    if hint == nil then
        return {}
    end
    return hintIndex[normalize(hint)] or {}
end

-- True if two hints are the same text, ignoring capitals and spacing.
function location.sameHint(a, b)
    return normalize(a) == normalize(b)
end

-- The items of list a that are also in list b, in a's order. Returns a new
-- list (like a.filter(x => b.includes(x)) in JS).
local function shared(a, b)
    local inB = {}
    for _, name in ipairs(b) do
        inB[name] = true
    end
    local result = {}
    for _, name in ipairs(a) do
        if inB[name] then
            result[#result + 1] = name
        end
    end
    return result
end

-- The places all of a record's hints agree on, as a list of names (empty if
-- we know none of its hints). Works from the newest hint back:
--   - a hint we don't know (not in data/hints.lua) is skipped, so it can't
--     wipe out what the known ones say;
--   - an older hint that shares no place with the newer ones must be about
--     an older tree (or our data has a gap), so it and anything older are
--     ignored: the newest hints win.
function location.forHints(record)
    -- Newest first: record.hint, then earlierHints from its end.
    local newestFirst = { record.hint }
    local earlier = record.earlierHints or {}
    -- "for i = #list, 1, -1" counts down, like for (i = len; i >= 1; i--).
    for i = #earlier, 1, -1 do
        newestFirst[#newestFirst + 1] = earlier[i]
    end

    local places = nil
    for _, hint in ipairs(newestFirst) do
        local candidates = location.forHint(hint)
        if #candidates > 0 then
            if places == nil then
                places = candidates
            else
                local both = shared(places, candidates)
                if #both == 0 then
                    break           -- like break in JS: stop the loop here
                end
                places = both
            end
        end
    end
    return places or {}
end

-- The location a spirit tree clue describes, or nil. The clue is the part
-- after "which has appeared", e.g. "beside the west gates of Yanille".
-- string.find(text, part, 1, true) looks for part as plain text (the "true"
-- turns patterns off), like text.includes(part) in JS.
function location.forClue(clue)
    if clue == nil then
        return nil
    end
    local text = normalize(clue)
    for _, entry in ipairs(clues) do
        if string.find(text, entry.clue, 1, true) then
            return entry.name
        end
    end
    return nil
end

-- The location whose pin is nearest to a tile, or nil if none is within
-- MAX_PIN_DISTANCE tiles.
function location.forTile(x, z)
    if x == nil or z == nil then
        return nil
    end
    local bestName, bestDistance = nil, location.MAX_PIN_DISTANCE
    for _, place in ipairs(hints.locations) do
        -- Straight-line distance, Pythagoras: sqrt(dx^2 + dz^2). ^ is "power" in Lua.
        local distance = math.sqrt((place.x - x) ^ 2 + (place.z - z) ^ 2)
        if distance <= bestDistance then
            bestName, bestDistance = place.name, distance
        end
    end
    return bestName
end

-- Where a world record's tree is, if we know exactly: the tile, else the
-- clue, else hints that leave only one place. nil if we don't know.
-- (For "one of these places", ask forHints.)
function location.forRecord(record)
    local name = location.forTile(record.tileX, record.tileZ)
        or location.forClue(record.locationClue)
    -- ("a or b" gives a unless it's nil, like a ?? b in JS.)
    if name ~= nil then
        return name
    end
    local candidates = location.forHints(record)
    if #candidates == 1 then            -- # is the length of a list, like .length
        return candidates[1]
    end
    return nil
end

return location
