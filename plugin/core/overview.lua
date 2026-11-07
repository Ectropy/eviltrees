--[[
    core/overview.lua
    -----------------
    Decides what the dashboard shows: which worlds, in which order, and the
    words for each. Pure: no game API calls, so it can be tested outside the
    game. ui/dashboard.lua only puts these texts on screen.

    overview.build(...) returns a table like:
        {
            scouted = 3,            -- worlds we have intel on
            total = 137,            -- worlds in data/worlds.lua
            current = row or nil,   -- the world you're on (nil = not known yet)
            others = { row, ... },  -- other worlds with intel, soonest event first
        }
    and each row looks like:
        {
            world = 204,
            heading = "W204 - Evil willow - <=50%",
            place = "East of the house portal in Rellekka",   -- or nil
            noIntel = true,          -- only on the current world's row, when
                                     -- we know nothing about it yet
            eventLabel = "Lightning in", eventAt = <Unix ms>, approximate = false,
        }
    The heading and place change rarely; the countdown changes every second,
    so it is made separately by overview.countdownText(row, now).
]]

local worldstate = require("core/worldstate")
local location = require("core/location")

local overview = {}

-- worldstate.nextEvent's labels -> the words in front of the countdown.
local EVENT_WORDS = {
    ["spawns"] = "Spawns in",
    ["matures by"] = "Full tree in",
    ["lightning"] = "Lightning in",
    ["dies by"] = "Dies in",
    ["dies within"] = "Dies within",    -- only the latest it can die
    ["gone by"] = "Rewards gone in",
}

-- "willow" -> "Willow". "^%l" is a lower-case letter at the very start, and
-- gsub replaces it with string.upper of itself.
local function capitalize(text)
    return (string.gsub(text, "^%l", string.upper))
    -- (The extra brackets keep only gsub's first result, the text; it also
    -- returns how many replacements it made.)
end

-- The tree's type and state in a few words: "Evil willow", "Oak sapling",
-- "Dead maple", "No tree". "tree" is the plain (normal) evil tree.
local function describeTree(record)
    local treeType = record.treeType
    if treeType == "tree" then
        treeType = nil              -- "Evil tree", not "Evil tree tree"
    end
    if record.status == "sapling" then
        return treeType and (capitalize(treeType) .. " sapling") or "Sapling"
        -- ("x and a or b" is Lua's x ? a : b.)
    elseif record.status == "alive" then
        return "Evil " .. (treeType or "tree")
    elseif record.status == "dead" then
        return "Dead " .. (treeType or "tree")
    end
    return "No tree"
end

-- Health as shown: "45%" (examined, exact), or "<=50%" (at most: from the
-- tree's look, a strike we saw, or a strike that has certainly happened by
-- now). nil if unknown.
local function describeHealth(record)
    if record.health == nil then
        return nil
    end
    -- %d prints a whole number; health may be stored as 50.0 (see store.lua).
    local percent = string.format("%d%%", math.floor(record.health))
    if record.healthSource == "examine" then
        return percent
    end
    return "<=" .. percent
end

-- Where the tree is (or will be): the exact place if we know it, else the
-- places the hint can mean, else the hint itself. nil if we know nothing.
local function describePlace(record)
    local name = location.forRecord(record)
    if name ~= nil then
        return name
    end
    local candidates = location.forHint(record.hint)
    if #candidates == 2 or #candidates == 3 then
        return table.concat(candidates, " or ")     -- like candidates.join(" or ")
    end
    if record.hint ~= nil then
        return "Hint: " .. capitalize(record.hint)
    end
    return nil
end

-- One world's row. record may be nil (current world, nothing known yet).
local function buildRow(number, record, now)
    local row = { world = number }
    if record == nil then
        row.heading = "W" .. number
        row.noIntel = true
        return row
    end

    local parts = { "W" .. number, describeTree(record) }
    local health = describeHealth(record)
    if health ~= nil and record.status == "alive" then
        parts[#parts + 1] = health
    end
    row.heading = table.concat(parts, " - ")
    row.place = describePlace(record)

    -- nextEvent returns three values: label, time, approximate.
    local label, at, approximate = worldstate.nextEvent(record, now)
    if label ~= nil then
        row.eventLabel = EVENT_WORDS[label] or label
        row.eventAt = at
        row.approximate = approximate
    end
    return row
end

-- Milliseconds -> "4:05" (minutes:seconds) or "1:08:12" (hours too).
-- Negative times (the event is due right now) show as "0:00".
function overview.formatDuration(ms)
    local totalSeconds = math.max(0, ms // 1000)    -- // = whole-number division
    local hours = totalSeconds // 3600
    local minutes = (totalSeconds % 3600) // 60
    local seconds = totalSeconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end
    return string.format("%d:%02d", minutes, seconds)
end

-- The changing part of a row: "Lightning in 4:05", or "Dies in ~12:40"
-- when the time is approximate (could be up to a minute later). nil if
-- nothing is due or the clock isn't running yet.
function overview.countdownText(row, now)
    if row.eventAt == nil or now == nil then
        return nil
    end
    return row.eventLabel .. " " .. (row.approximate and "~" or "") .. overview.formatDuration(row.eventAt - now)
end

-- Builds the whole overview. worlds is store.worlds, currentNumber the
-- world you're on (or nil), now the time (Unix ms, or nil), totalWorlds
-- the number of worlds tracked.
function overview.build(worlds, currentNumber, now, totalWorlds)
    local result = { scouted = 0, total = totalWorlds, others = {} }

    for number, record in pairs(worlds) do
        result.scouted = result.scouted + 1
        if number ~= currentNumber then
            result.others[#result.others + 1] = buildRow(number, record, now)
        end
    end

    -- Soonest event first; worlds with nothing due last; ties by world number.
    -- table.sort's function returns true when a should come before b
    -- (JS's sort wants a number instead). math.huge is Infinity.
    table.sort(result.others, function(a, b)
        local aAt, bAt = a.eventAt or math.huge, b.eventAt or math.huge
        if aAt ~= bAt then
            return aAt < bAt
        end
        return a.world < b.world
    end)

    if currentNumber ~= nil then
        result.current = buildRow(currentNumber, worlds[currentNumber], now)
    end
    return result
end

return overview
