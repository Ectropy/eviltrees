--[[
    core/sampledata.lua
    -------------------
    Made-up world records for trying out the world grid, since the beta
    server has only two worlds. A debug tool: main.lua shows this data in
    the grid instead of the real records while "Sample data" is on (a
    button in the dashboard's debug section). It is never saved, and the
    real records keep being captured underneath.

    sampledata.generate(worldList, now, random) returns a table shaped like
    store.worlds ({ [104] = record, ... }). Each world gets a random state:
    no intel, a hint only, a spawn timer (exact and "~"), a sapling, a full
    tree (lightning timed, or only "dies within"), or a dead tree with
    rewards. On top of that, what we know about it varies independently,
    as it does in real play:
      - where:   the exact tile (seen), the spirit tree's clue, two
                 different hints (fewer places), one hint, or nothing (an
                 activity tracker timer says only "when")
      - type:    known, or not (a sapling or a tree only heard about)
      - health:  examined (exact), "50% or less" from the tree's look, or unknown
    The records follow worldstate's record shape (see core/worldstate.lua),
    so worldstate.tick moves them along like real ones: timers run out,
    saplings grow, trees get struck and die.

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

-- Where the tree is, for each kind: the ways we could know it, one picked
-- at random. "tile" = seen there, "clue" = the spirit tree's sentence
-- (only once the tree has spawned), "twoHints" / "hint" = hints heard,
-- "nothing" = only a time (the activity tracker).
local PLACE_CHOICES = {
    hint = { "hint", "hint", "twoHints" },
    spawn = { "hint", "hint", "twoHints", "nothing" },
    roughSpawn = { "hint", "nothing" },
    sapling = { "tile", "clue", "hint", "twoHints" },
    alive = { "tile", "tile", "clue", "hint", "twoHints" },
    roughAlive = { "clue", "hint", "twoHints" },
    dead = { "tile", "clue", "hint" },
}

-- Chance (out of 100) that we know the tree's type, for each kind. A
-- sapling's type needs its inspect text (optional chat access); a tree
-- only heard about from the spirit tree often has no type either.
local TYPE_KNOWN = { sapling = 50, alive = 75, roughAlive = 50, dead = 75 }

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

-- Two different hints that share at least one place, so together they
-- narrow it down. Returns the first hint, the second, and a shared place
-- name; or just one hint if the first shares no place with any other.
local function twoHints(random)
    local first = pick(hints.list, random)
    local place = pick(first.locations, random)
    local others = {}
    for _, entry in ipairs(hints.list) do
        if entry ~= first then
            for _, name in ipairs(entry.locations) do
                if name == place then
                    others[#others + 1] = entry
                end
            end
        end
    end
    if #others == 0 then
        return first.hint, nil
    end
    return first.hint, pick(others, random).hint
end

-- Fills in where the tree is, one of the ways in PLACE_CHOICES[kind].
local function addPlace(record, kind, random)
    local how = pick(PLACE_CHOICES[kind], random)
    if how == "tile" then
        local place = pick(hints.locations, random)
        record.tileX, record.tileZ = place.x, place.z
    elseif how == "clue" then
        record.locationClue = pick(hints.locations, random).clue
    elseif how == "twoHints" then
        local older, newer = twoHints(random)
        if newer ~= nil then
            record.earlierHints = { older }     -- heard first
            record.hint = newer
        else
            record.hint = older
        end
    elseif how == "hint" then
        record.hint = pick(hints.list, random).hint
    end
    -- "nothing": no place at all.
    return how
end

-- Sets a random tree type, or leaves it unknown (nil), per TYPE_KNOWN.
local function addType(record, kind, random)
    if random(1, 100) <= TYPE_KNOWN[kind] then
        record.treeType = pick(TREE_TYPES, random)
    end
end

-- Health for a full tree that matured "age" ms ago, consistent with the
-- strikes so far (M + 10 takes it to 50%, M + 20 to 25%): examined
-- (exact), "N% or less" from the tree's look, or unknown. The game only
-- ever says health in steps of five ("approximately 45%"), so an examined
-- health is a random whole number times 5.
local function addHealth(record, age, random)
    local roll = random(1, 10)
    if roll <= 5 then
        if age < 10 * MINUTE then
            record.health = random(11, 20) * 5      -- 55 to 100
        elseif age < 20 * MINUTE then
            record.health = random(6, 10) * 5       -- 30 to 50
        else
            record.health = random(1, 5) * 5        -- 5 to 25
        end
        record.healthSource = "examine"
    elseif roll <= 8 and age >= 10 * MINUTE then
        -- The look only caps it once a strike has happened.
        record.health = (age < 20 * MINUTE) and 50 or 25
        record.healthSource = "stage"
    end
    -- Otherwise unknown: no health at all.
end

-- One made-up record of the given kind, or nil for "unknown".
local function makeRecord(kind, now, random)
    if kind == "unknown" then
        return nil
    end
    local record = { updatedAt = now }

    if kind == "hint" then
        record.status = "none"
        addPlace(record, kind, random)

    elseif kind == "spawn" or kind == "roughSpawn" then
        -- Spawns 1 to 90 minutes from now. An exact timer reading gives a
        -- 1 min window; a rough one a 3 min window (shown with "~").
        record.status = "none"
        record.spawnAt = now + random(1, 90) * MINUTE + random(0, 59) * SECOND
        local half = (kind == "spawn") and 30 * SECOND or 90 * SECOND
        record.spawnEarliest = record.spawnAt - half
        record.spawnLatest = record.spawnAt + half
        -- With no place, the time came from the activity tracker.
        local how = addPlace(record, kind, random)
        record.spawnSource = (how == "nothing") and "tracker" or "timer"

    elseif kind == "sapling" then
        -- Spawned up to 4:50 ago, so it grows up within the next 5 minutes.
        record.status = "sapling"
        record.spawnAt = now - random(0, 290) * SECOND
        record.spawnEarliest = record.spawnAt - 30 * SECOND
        record.spawnLatest = record.spawnAt + 30 * SECOND
        record.spawnSource = "sapling"
        addType(record, kind, random)
        addPlace(record, kind, random)

    elseif kind == "alive" then
        -- Matured 0 to 29 minutes ago and watched, so M is known to the
        -- second and lightning is timed.
        local age = random(0, 29 * 60 - 1) * SECOND
        record.status = "alive"
        record.matureAt = now - age
        record.matureEarliest = record.matureAt - SECOND
        record.matureLatest = record.matureAt + SECOND
        record.matureSource = "watched"
        addType(record, kind, random)
        addHealth(record, age, random)
        addPlace(record, kind, random)

    elseif kind == "roughAlive" then
        -- Only told it's a full tree: M could be any time in the last
        -- 30 minutes, so only "dies within" is shown.
        record.status = "alive"
        record.matureEarliest = now - 30 * MINUTE
        record.matureLatest = now - random(0, 20) * MINUTE
        record.matureAt = (record.matureEarliest + record.matureLatest) / 2
        record.matureSource = "alive"
        addType(record, kind, random)
        addPlace(record, kind, random)

    elseif kind == "dead" then
        -- Died up to 8 minutes ago: rewards for a little while yet.
        record.status = "dead"
        record.deadAt = now - random(0, 8 * 60) * SECOND
        addType(record, kind, random)
        addPlace(record, kind, random)
    end
    return record
end

-- Builds the whole made-up table. worldList is data/worlds.lua's list.
-- Beta worlds are left out: only real records put them on the grid.
-- random defaults to math.random ("a or b" is like a ?? b in JS).
function sampledata.generate(worldList, now, random)
    random = random or math.random
    local worlds = {}
    for _, entry in ipairs(worldList) do
        if not entry.beta then
            worlds[entry.number] = makeRecord(pickKind(random), now, random)
        end
    end
    return worlds
end

return sampledata
