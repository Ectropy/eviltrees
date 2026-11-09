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
            heading = "w204 - Evil willow - max 50%",
            place = "East of the house portal in Rellekka",   -- or nil
            noIntel = true,          -- only on the current world's row, when
                                     -- we know nothing about it yet
            eventLabel = "Lightning in", eventAt = <Unix ms>, approximate = false,
        }
    The heading and place change rarely; the countdown changes every second,
    so it is made separately by overview.countdownText(row, now).

    overview.cells(...) is the same information for the world grid: one
    small "cell" for EVERY world (with intel or not), in world order. A cell
    is a row (above) plus a few short fields, see buildCell. Its countdown
    is overview.cellCountdown(cell, now): whole minutes ("29m", "1h 5m")
    until the last minute, then seconds ("45s"), so it changes once a
    minute. For an alive tree it counts to its DEATH, not the next strike.
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

-- Health as shown: "45%" (examined, exact), or "max 50%" (at most: from the
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
    -- Not "<=50%": game text reads "<...>" as a markup tag (like <br>),
    -- so a "<" hides the rest of the line.
    return "max " .. percent
end

-- Where the tree is (or will be): the exact place if we know it, else the
-- places the hints leave (see location.forHints), else the newest hint
-- itself. nil if we know nothing.
local function describePlace(record)
    local name = location.forRecord(record)
    if name ~= nil then
        return name
    end
    local candidates = location.forHints(record)
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
        row.heading = "w" .. number          -- "w204", like EctoTrees
        row.noIntel = true
        return row
    end

    local parts = { "w" .. number, describeTree(record) }
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

-------------------------------------------------------------------------------
-- The world grid
-------------------------------------------------------------------------------

-- Tree types in a word, for cells.
local SHORT_TYPES = {
    tree = "Tree", oak = "Oak", willow = "Willow", maple = "Maple",
    yew = "Yew", magic = "Magic", elder = "Elder",
}

-- What a cell is showing, which picks its colour:
--   "unknown"  no intel at all
--   "none"     intel (e.g. a hint) but no tree and no spawn time
--   "spawn"    no tree yet, spawn time known
--   "sapling" | "alive" | "dead"   the record's status
local function cellKind(record)
    if record == nil then
        return "unknown"
    end
    if record.status == "none" then
        return record.spawnAt ~= nil and "spawn" or "none"
    end
    return record.status
end

-- One world's cell: everything buildRow gives (heading, place, event),
-- plus:
--   members   true (P2P) | false (F2P) | nil (not in data/worlds.lua,
--             e.g. the beta worlds)
--   current   true for the world you're on
--   kind      see cellKind
--   treeType  "Willow" (or nil)
--   health    "95%" or "max 50%" (alive trees only, or nil)
--   status    "Evil willow - 45%", "Oak sapling", "No tree" (or nil: no intel)
--   deathAt, deathApproximate
--             when an alive tree dies (worldstate.deathTime), or nil
--   cellAt, cellApproximate
--             what the cell counts down to: the death for an alive tree,
--             else the same as eventAt (spawn, full tree, rewards gone)
--   icon      "timer" | "sapling" | "tree" | "dead", or nil (nothing known
--             but maybe a hint): see ui/icons.lua
--   logs      the tree type ("willow", "tree", ...) for an alive tree whose
--             type we know: its logs are shown instead of the tree icon; else nil
local CELL_ICONS = { spawn = "timer", sapling = "sapling", alive = "tree", dead = "dead" }

local function buildCell(number, members, record, currentNumber, now)
    local cell = buildRow(number, record, now)
    cell.members = members
    cell.current = (number == currentNumber)
    cell.kind = cellKind(record)
    cell.icon = CELL_ICONS[cell.kind]      -- nil for "unknown" and "none"
    if cell.kind == "alive" then
        cell.logs = record.treeType
    end
    cell.cellAt, cell.cellApproximate = cell.eventAt, cell.approximate
    if record ~= nil then
        cell.treeType = SHORT_TYPES[record.treeType]   -- nil if no type (SHORT_TYPES[nil] is nil)
        cell.status = describeTree(record)
        if record.status == "alive" then
            cell.health = describeHealth(record)
            if cell.health ~= nil then
                cell.status = cell.status .. " - " .. cell.health
            end
            -- Two results into two variables, like const [a, b] = f() in JS.
            cell.deathAt, cell.deathApproximate = worldstate.deathTime(record)
            if cell.deathAt ~= nil then
                cell.cellAt, cell.cellApproximate = cell.deathAt, cell.deathApproximate
            end
        end
    end
    return cell
end

-- Milliseconds -> "1h 42m", "1h 5m", "29m", or "45s" in the last minute. Like
-- EctoTrees, whole minutes until the final minute. Rounds down, like
-- formatDuration, so a cell never shows more time than the detail view.
function overview.shortDuration(ms)
    local totalSeconds = math.max(0, ms // 1000)
    if totalSeconds < 60 then
        -- string.format, not "..": a float (45.0) would join as "45.0s".
        return string.format("%ds", totalSeconds)
    end
    local hours = totalSeconds // 3600
    local minutes = (totalSeconds % 3600) // 60
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes)     -- %d: no leading zero
    end
    return string.format("%dm", minutes)
end

-- A cell's countdown (to cell.cellAt): "29m", or "~29m" when the time is
-- approximate. nil if nothing is due or the clock isn't running yet.
function overview.cellCountdown(cell, now)
    if cell.cellAt == nil or now == nil then
        return nil
    end
    return (cell.cellApproximate and "~" or "") .. overview.shortDuration(cell.cellAt - now)
end

-- "Dies in 14:05" (or "Dies in ~14:05"), for a cell whose next event is
-- a lightning strike, so the death time is shown too. nil otherwise (the
-- countdown already says when it dies, or it isn't alive).
function overview.deathText(cell, now)
    if cell.deathAt == nil or now == nil or cell.eventAt == cell.deathAt then
        return nil
    end
    return "Dies in " .. (cell.deathApproximate and "~" or "") .. overview.formatDuration(cell.deathAt - now)
end

-- Builds every cell, in world-number order. worldList is data/worlds.lua's
-- list. Worlds that aren't in it still get a cell when we're on them or
-- have a record for them (the beta worlds 204/205, or a world added to the
-- game after our list was written).
function overview.cells(worlds, worldList, currentNumber, now)
    local cells = {}
    local added = {}            -- added[204] = true once 204 has a cell (a Set in JS)

    for _, entry in ipairs(worldList) do
        cells[#cells + 1] = buildCell(entry.number, entry.members, worlds[entry.number], currentNumber, now)
        added[entry.number] = true
    end

    -- Worlds missing from the list. Members unknown, so nil.
    local function addUnlisted(number)
        if number ~= nil and not added[number] then
            cells[#cells + 1] = buildCell(number, nil, worlds[number], currentNumber, now)
            added[number] = true
        end
    end
    addUnlisted(currentNumber)
    for number in pairs(worlds) do      -- pairs with one variable: just the keys
        addUnlisted(number)
    end

    table.sort(cells, function(a, b) return a.world < b.world end)
    return cells
end

return overview
