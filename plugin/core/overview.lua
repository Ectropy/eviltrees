--[[
    core/overview.lua
    -----------------
    Decides what the world grid and the world card show: the words for each
    world. Pure: no game API calls, so it can be tested outside the game.
    ui/grid.lua and ui/worldcard.lua only put these texts on screen.

    Each world's words start as a "row" (see buildRow), like:
        {
            world = 204,
            heading = "w204 - Evil willow - 50% or less",
            place = "East of the house portal in Rellekka",   -- or nil
            places = { "East of the house portal in Rellekka" },  -- the same, one
                                     -- entry per place: two or three when the
                                     -- hints leave a choice (place then joins
                                     -- them with " or "); nil if place is nil
            noIntel = true,          -- only on the current world's row, when
                                     -- we know nothing about it yet
            eventLabel = "Lightning in", eventAt = <Unix ms>, approximate = false,
            eventSuffix = " or less",   -- after the time (saplings only), or nil
            eventDue = "Spawning",      -- shown once no time is left, or nil
        }
    The heading and place change rarely; the countdown changes every second,
    so it is made separately by overview.countdownText(row, now).

    overview.cells(...) gives one "cell" for EVERY world (with intel or
    not), in world order, and overview.currentCell(...) the cell for the
    world you're on. A cell is a row (above) plus a few short fields, see
    buildCell. Its countdown
    is overview.cellCountdown(cell, now): whole minutes ("29m", "1h 5m")
    until the last minute, then seconds ("45s"), so it changes once a
    minute. For an alive tree it counts to its DEATH, not the next strike.
]]

local worldstate = require("core/worldstate")
local location = require("core/location")

local overview = {}

-- worldstate.nextEvent's labels -> the words for the countdown:
--   label   in front of the time: "Spawns in 4m 5s"
--   suffix  after the time (optional): "Matures in 4m 5s or less". A
--           sapling can be nurtured by players, which makes it grow up
--           sooner, so its time is only the latest.
--   due     shown instead, once no time is left: "Spawning". Left out for
--           the rewards: that line just goes when they do.
-- (A table of tables, like { spawns: { label: "Spawns in", ... } } in JS.)
local EVENT_WORDS = {
    ["spawns"] = { label = "Spawns in", due = "Spawning" },
    ["matures by"] = { label = "Matures in", suffix = " or less", due = "Maturing" },
    ["lightning"] = { label = "Lightning in", due = "Lightning strike" },
    ["dies by"] = { label = "Dies in", due = "Dying" },
    ["dies within"] = { label = "Dies within", due = "Dying" },   -- only the latest it can die
    ["gone by"] = { label = "Rewards gone in" },
}

-- "willow" -> "Willow". "^%l" is a lower-case letter at the very start, and
-- gsub replaces it with string.upper of itself.
local function capitalize(text)
    return (string.gsub(text, "^%l", string.upper))
    -- (The extra brackets keep only gsub's first result, the text; it also
    -- returns how many replacements it made.)
end

-- The tree's type and state in a few words:
--
--                  type known         type "tree"        type unknown
--     sapling      "Elder sapling"    "Tree sapling"     "Strange sapling (unknown)"
--     alive        "Evil willow"      "Evil tree"        "Mature evil tree (unknown)"
--     dead         "Dead evil willow" "Dead evil tree"   "Dead evil tree (unknown)"
--
-- or "No tree". Every one of these is an evil tree; "tree" is also the
-- name of one TYPE of evil tree (the lowest, named after the ordinary
-- tree). So "Evil tree" alone always means that type, and a tree whose
-- type we don't know says "(unknown)". ("Strange sapling" is the game's
-- own name for a sapling.)
local function describeTree(record)
    local treeType = record.treeType    -- "tree", "oak", ... or nil
    if record.status == "sapling" then
        if treeType == nil then
            return "Strange sapling (unknown)"
        end
        return capitalize(treeType) .. " sapling"
    elseif record.status == "alive" then
        if treeType == nil then
            return "Mature evil tree (unknown)"
        end
        return "Evil " .. treeType
    elseif record.status == "dead" then
        if treeType == nil then
            return "Dead evil tree (unknown)"
        elseif treeType == "tree" then
            return "Dead evil tree"     -- not "Dead tree": that reads like any tree
        end
        return "Dead evil " .. treeType
    end
    return "No tree"
end

-- Health as shown: "45%" (examined, exact), or "50% or less" (from the
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
    return percent .. " or less"
end

-- Where the tree is (or will be): the exact place if we know it, else the
-- places the hints leave (see location.forHints), else the newest hint
-- itself. Returns three values: the text on one line ("A or B"), the
-- same as a list with one entry per place ({ "A", "B" }), for the card,
-- which shows each on its own line, a short form for a grid cell (the
-- same text, but a hint without "Hint: "), and a fourth value: true when
-- the place is exact (a tile, clue or one-place hint), false when it is
-- only a hint. The list has no "Hint: " in it: the card adds the label
-- ("Hint:" or "Exact Location:") itself. All nil if we know nothing.
local function describePlace(record)
    local name = location.forRecord(record)
    if name ~= nil then
        return name, { name }, name, true
    end
    local candidates = location.forHints(record)
    if #candidates == 2 or #candidates == 3 then
        local joined = table.concat(candidates, " or ")     -- like candidates.join(" or ")
        return joined, candidates, joined, false
    end
    if record.hint ~= nil then
        local hint = capitalize(record.hint)
        return "Hint: " .. hint, { hint }, hint, false
    end
    return nil, nil
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
    -- Two results into two fields, like [row.place, row.places] = f() in JS.
    row.place, row.places, row.cellPlace, row.placeExact = describePlace(record)

    -- nextEvent returns three values: label, time, approximate.
    local label, at, approximate = worldstate.nextEvent(record, now)
    if label ~= nil then
        -- "or {}": an event we have no words for uses its own name, with
        -- no suffix or due word (words.suffix is then nil).
        local words = EVENT_WORDS[label] or {}
        row.eventLabel = words.label or label
        row.eventSuffix = words.suffix
        row.eventDue = words.due
        row.eventAt = at
        row.approximate = approximate
    end
    return row
end

-- Milliseconds -> "1h 23m 30s", "4m 5s" or "45s": the same units as the
-- grid's cells ("1h 23m", see shortDuration), with the seconds as well.
-- A part that is zero is left out, so a countdown reads "3m", then
-- "2m 59s" (never "3m 0s"), and "1h", "1h 5s", "1h 23m". Only when
-- nothing is left (the event is due right now, or overdue) is it "0s".
function overview.formatDuration(ms)
    local totalSeconds = math.max(0, ms // 1000)    -- // = whole-number division
    local hours = totalSeconds // 3600
    local minutes = (totalSeconds % 3600) // 60
    local seconds = totalSeconds % 60
    -- Collect the parts that aren't zero, then join them with spaces
    -- (like parts.join(" ") in JS). string.format, not "..": a float
    -- (5.0) would join as "5.0s"; %d prints it as a whole number.
    local parts = {}
    if hours > 0 then
        parts[#parts + 1] = string.format("%dh", hours)     -- parts.push(...)
    end
    if minutes > 0 then
        parts[#parts + 1] = string.format("%dm", minutes)
    end
    if seconds > 0 or #parts == 0 then
        parts[#parts + 1] = string.format("%ds", seconds)
    end
    return table.concat(parts, " ")
end

-- The changing part of a row: "Lightning in 4m 5s", or "Dies in ~12m 40s"
-- when the time is approximate (could be up to a minute later), or
-- "Matures in 1m 14s or less" for a sapling. Once no time is left it is
-- one word, "Spawning" / "Maturing" / "Dying", never "0s"; for the
-- rewards it is nil (the line goes). Also nil if nothing is due or the
-- clock isn't running yet.
function overview.countdownText(row, now)
    if row.eventAt == nil or now == nil then
        return nil
    end
    local left = row.eventAt - now
    if left < 1000 then             -- under a second: formatDuration would say "0s"
        return row.eventDue         -- may be nil
    end
    return row.eventLabel .. " " .. (row.approximate and "~" or "") .. overview.formatDuration(left)
        .. (row.eventSuffix or "")
end

-------------------------------------------------------------------------------
-- The world grid
-------------------------------------------------------------------------------

-- Tree types in a word, for cells. Public so the grid can measure the
-- widest word a cell may have to show.
overview.TYPE_WORDS = {
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
--             e.g. a world newer than our list)
--   current   true for the world you're on
--   kind      see cellKind
--   treeType  the type as the cell shows it: "Willow", for a sapling, an
--             alive or a dead tree alike (the icon and the colour say which
--             it is); nil if we don't know the type. Capitalised, unlike the
--             record's treeType ("willow").
--   health    "95%" or "50% or less" (alive trees only, or nil)
--   cellPlace the place for a two-line cell: as place, but a hint without
--             "Hint: " (no room to spare); nil if place is nil
--   placeExact true if the place is exact, false if it is only a hint (the
--             card labels them; cells don't mark them yet); nil if place is nil
--   places    the place as a list, one per line on the card, with no "Hint: "
--             in it (the card adds "Hint:" or "Exact Location:")
--   status    "Evil willow - 45%", "Oak sapling", "No tree" (or nil: no intel)
--   deathAt, deathApproximate
--             when an alive tree dies (worldstate.deathTime), or nil
--   cellAt, cellApproximate
--             what the cell counts down to: the death for an alive tree,
--             else the same as eventAt (spawn, full tree, rewards gone).
--             Always approximate for a sapling (it may be nurtured).
--   icon      "timer" | "sapling" | "tree" | "dead", or nil (nothing known
--             but maybe a hint): see ui/icons.lua
--   logs      the tree type ("willow", "tree", ...) for an alive tree whose
--             type we know: its logs are shown instead of the tree icon; else nil
--   The next four are for the grid's filters and sort (core/filters.lua):
--   treeKey   only when a tree is up: "sapling" for any sapling, else the
--             type ("tree", "oak", ... "elder") of an alive or dead tree, or
--             "unknown" if we don't know its type. nil otherwise.
--   saplingType  a sapling's type ("elder"), if we know it (the crown and
--             the helm say); nil otherwise. A tree filter matches it too.
--   hasHint   true if the record has a hint or an exact place, else false
--   hasPlace  true if we know the exact place (tile, clue or one-place hint)
--   healthValue  the health as a number (45, or 50 for "50% or less"), alive
--             trees only, else nil
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
    if cell.kind == "sapling" then
        -- Players can nurture a sapling, which makes it grow up sooner, so
        -- its time is always an estimate: the cell always gets the "~".
        cell.cellApproximate = true
    end
    cell.hasHint = false
    cell.hasPlace = false
    if record ~= nil then
        -- An exact place counts as a hint too (we don't need to be told one).
        cell.hasPlace = (location.forRecord(record) ~= nil)
        cell.hasHint = (record.hint ~= nil) or cell.hasPlace
        if record.status == "sapling" then
            cell.treeKey = "sapling"
            cell.saplingType = record.treeType      -- may be nil
        elseif record.status == "alive" or record.status == "dead" then
            cell.treeKey = record.treeType or "unknown"     -- a ?? b in JS
        end
        if cell.treeKey ~= nil then     -- a tree is up
            cell.treeType = overview.TYPE_WORDS[record.treeType]  -- nil if no type (TYPE_WORDS[nil] is nil)
        end
        cell.status = describeTree(record)
        if record.status == "alive" then
            cell.health = describeHealth(record)
            cell.healthValue = record.health        -- a number, or nil
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

-- The cell for the world you're on, for the ribbon page's card: the same
-- cell overview.cells makes for it. members is that world's P2P flag
-- (true / false, or nil if it isn't in data/worlds.lua). nil while we
-- don't know which world we're on.
function overview.currentCell(worlds, currentNumber, members, now)
    if currentNumber == nil then
        return nil
    end
    return buildCell(currentNumber, members, worlds[currentNumber], currentNumber, now)
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

-- "Dies in 14m 5s" (or "Dies in ~14m 5s"), for a cell whose next event is
-- a lightning strike, so the death time is shown too. nil otherwise (the
-- countdown already says when it dies, or it isn't alive).
function overview.deathText(cell, now)
    if cell.deathAt == nil or now == nil or cell.eventAt == cell.deathAt then
        return nil
    end
    local left = cell.deathAt - now
    if left < 1000 then
        return "Dying"              -- no time left: never "Dies in 0s"
    end
    return "Dies in " .. (cell.deathApproximate and "~" or "") .. overview.formatDuration(left)
end

-- Builds every cell, in world-number order. worldList is data/worlds.lua's
-- list. A beta world in it only gets a cell when we have a record for it
-- or we're on it: it isn't on the live servers, so it would only be in the
-- way. Worlds that aren't in the list still get a cell when we're on them
-- or have a record for them (a world added to the game after our list was
-- written).
function overview.cells(worlds, worldList, currentNumber, now)
    local cells = {}
    local added = {}            -- added[204] = true once 204 has a cell (a Set in JS)

    for _, entry in ipairs(worldList) do
        if not entry.beta or worlds[entry.number] ~= nil or entry.number == currentNumber then
            cells[#cells + 1] = buildCell(entry.number, entry.members, worlds[entry.number], currentNumber, now)
        end
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
