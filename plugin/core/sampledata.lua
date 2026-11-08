--[[
    core/sampledata.lua
    -------------------
    Made-up world records for trying out the world grid, since the beta
    server has only two worlds. A debug tool: main.lua shows this data in
    the grid instead of the real records while "Sample data" is on (a
    button in the dashboard's debug section). It is never saved, and the
    real records keep being captured underneath.

    sampledata.generate(worldList, now, random) returns a table shaped like
    store.worlds ({ [104] = record, ... }), with a random mix of every state
    a world can be in: no intel, a hint only, a spawn timer (exact and
    "~"), a sapling, a full tree (lightning timed, or only "dies within"),
    and a dead tree with rewards. The records follow worldstate's record
    shape (see core/worldstate.lua), so worldstate.tick moves them along
    like real ones: timers run out, saplings grow, trees get struck and die.

    Pure: no game API calls. random is a function like math.random
    (random(a, b) = a whole number from a to b); tests pass their own to
    get the same "random" data every run.
]]

local hints = require("data/hints")

local sampledata = {}

local SECOND = 1000
local MINUTE = 60 * SECOND

local TREE_TYPES = { "tree", "oak", "willow", "maple", "yew", "magic", "elder" }

-- How often each kind of world comes up, out of 100. The unknowns are
-- kept high so the grid looks like a real session: plenty not scouted yet.
local WEIGHTS = {
    { kind = "unknown", weight = 25 },
    { kind = "hint", weight = 10 },          -- a hint, no spawn time
    { kind = "spawn", weight = 20 },         -- exact spawn timer
    { kind = "roughSpawn", weight = 5 },     -- "~" spawn timer
    { kind = "sapling", weight = 10 },
    { kind = "alive", weight = 15 },         -- lightning timed
    { kind = "roughAlive", weight = 5 },     -- only "dies within"
    { kind = "dead", weight = 10 },
}

-- One random entry of a list. #list is the list's length, and lists
-- start at 1, so random(1, #list) picks any of them.
local function pick(list, random)
    return list[random(1, #list)]
end

-- A kind from WEIGHTS: roll 1..100 and walk the list until the weights
-- add up past the roll.
local function pickKind(random)
    local roll = random(1, 100)
    local total = 0
    for _, entry in ipairs(WEIGHTS) do
        total = total + entry.weight
        if roll <= total then
            return entry.kind
        end
    end
    return "unknown"
end

-- Health for a full tree that matured "age" ms ago: above 50% before the
-- first strike (M + 10), 26-50% before the second (M + 20), then 1-25%.
local function healthFor(age, random)
    if age < 10 * MINUTE then
        return random(51, 100)
    elseif age < 20 * MINUTE then
        return random(26, 50)
    end
    return random(1, 25)
end

-- Fills in a tree's place: its tile (from a real location) or just a hint.
local function addPlace(record, random, seen)
    if seen then
        local place = pick(hints.locations, random)
        record.tileX, record.tileZ = place.x, place.z
    else
        record.hint = pick(hints.list, random).hint
    end
end

-- One made-up record of the given kind, or nil for "unknown".
local function makeRecord(kind, now, random)
    if kind == "unknown" then
        return nil
    end
    local record = { updatedAt = now }

    if kind == "hint" then
        record.status = "none"
        addPlace(record, random, false)

    elseif kind == "spawn" or kind == "roughSpawn" then
        -- Spawns 1 to 90 minutes from now. An exact timer reading gives a
        -- 1 min window; a rough one a 3 min window (shown with "~").
        record.status = "none"
        record.spawnAt = now + random(1, 90) * MINUTE + random(0, 59) * SECOND
        local half = (kind == "spawn") and 30 * SECOND or 90 * SECOND
        record.spawnEarliest = record.spawnAt - half
        record.spawnLatest = record.spawnAt + half
        record.spawnSource = "timer"
        addPlace(record, random, false)

    elseif kind == "sapling" then
        -- Spawned up to 4:50 ago, so it grows up within the next 5 minutes.
        record.status = "sapling"
        record.spawnAt = now - random(0, 290) * SECOND
        record.spawnEarliest = record.spawnAt - 30 * SECOND
        record.spawnLatest = record.spawnAt + 30 * SECOND
        record.spawnSource = "sapling"
        record.treeType = pick(TREE_TYPES, random)
        addPlace(record, random, random(1, 2) == 1)

    elseif kind == "alive" then
        -- Matured 0 to 29 minutes ago and watched, so M is known to the
        -- second and lightning is timed.
        local age = random(0, 29 * 60 - 1) * SECOND
        record.status = "alive"
        record.matureAt = now - age
        record.matureEarliest = record.matureAt - SECOND
        record.matureLatest = record.matureAt + SECOND
        record.matureSource = "watched"
        record.treeType = pick(TREE_TYPES, random)
        record.health = healthFor(age, random)
        record.healthSource = "examine"
        addPlace(record, random, true)

    elseif kind == "roughAlive" then
        -- Only told it's a full tree: M could be any time in the last
        -- 30 minutes, so only "dies within" is shown.
        record.status = "alive"
        record.matureEarliest = now - 30 * MINUTE
        record.matureLatest = now - random(0, 20) * MINUTE
        record.matureAt = (record.matureEarliest + record.matureLatest) / 2
        record.matureSource = "alive"
        record.treeType = pick(TREE_TYPES, random)
        addPlace(record, random, false)

    elseif kind == "dead" then
        -- Died up to 8 minutes ago: rewards for a little while yet.
        record.status = "dead"
        record.deadAt = now - random(0, 8 * 60) * SECOND
        record.treeType = pick(TREE_TYPES, random)
        addPlace(record, random, true)
    end
    return record
end

-- Builds the whole made-up table. worldList is data/worlds.lua's list.
-- random defaults to math.random ("a or b" is like a ?? b in JS).
function sampledata.generate(worldList, now, random)
    random = random or math.random
    local worlds = {}
    for _, entry in ipairs(worldList) do
        worlds[entry.number] = makeRecord(pickKind(random), now, random)
    end
    return worlds
end

return sampledata
