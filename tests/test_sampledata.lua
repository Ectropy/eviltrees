-- core/sampledata.lua: made-up records for the world grid. Checks that the
-- mix covers every kind of cell, that the records are ones worldstate can
-- move along, and that they really do move along with time.
-- Run with: node check.js <plugin dir> test_sampledata.lua
local sampledata = require("core/sampledata")
local overview = require("core/overview")
local worldstate = require("core/worldstate")
local worlds = require("data/worlds")

local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then passes = passes + 1
  else failures = failures + 1; print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)) end
end

local MINUTE = 60000
local NOW = 1793932200000.0     -- a float: fengari's integers are 32-bit

-- A repeatable "random": a simple counter-based generator, so every run
-- gets the same data. random(a, b) like math.random.
local state = 12345
local function random(a, b)
  state = (state * 1103515245 + 12345) % 2147483648
  -- Use the high bits (// 65536): this generator's low bits repeat in
  -- short cycles, so picking from a 4-item list never hit some items.
  return a + (state // 65536) % (b - a + 1)
end

local sample = sampledata.generate(worlds.list, NOW, random)

---------------------------------------------------------------- the mix
local cells = overview.cells(sample, worlds.list, nil, NOW)
check("A1 one cell per listed world", #cells, worlds.count)
local kinds = {}
local roughSpawn, diesWithin, lightning = false, false, false
for _, cell in ipairs(cells) do
  kinds[cell.kind] = (kinds[cell.kind] or 0) + 1
  if cell.kind == "spawn" and cell.approximate then roughSpawn = true end
  if cell.eventLabel == "Dies within" then diesWithin = true end
  if cell.eventLabel == "Lightning in" then lightning = true end
end
for _, kind in ipairs({ "unknown", "none", "spawn", "sapling", "alive", "dead" }) do
  check("A2 has some " .. kind, (kinds[kind] or 0) > 0, true)
end
check("A3 some rough spawn timers (~)", roughSpawn, true)
check("A4 some 'dies within'", diesWithin, true)
check("A5 some timed lightning", lightning, true)

-- What we know varies: place, type and health each come in every flavour.
local seen = {}
local function saw(what) seen[what] = (seen[what] or 0) + 1 end
for number, record in pairs(sample) do
  if record.tileX ~= nil then saw("tile") end
  if record.locationClue ~= nil then saw("clue") end
  if record.earlierHints ~= nil then saw("twoHints") end
  if record.hint ~= nil and record.earlierHints == nil then saw("oneHint") end
  if record.tileX == nil and record.locationClue == nil and record.hint == nil then saw("noPlace") end
  if record.status == "alive" and record.treeType ~= nil then saw("aliveTyped") end
  if record.status == "alive" and record.treeType == nil then saw("aliveUntyped") end
  if record.status == "sapling" and record.treeType == nil then saw("saplingUntyped") end
  if record.status == "dead" and record.treeType == nil then saw("deadUntyped") end
  if record.healthSource == "examine" then saw("healthExact") end
  if record.healthSource == "stage" then saw("healthMax") end
  if record.status == "alive" and record.health == nil then saw("healthUnknown") end
  if record.spawnSource == "tracker" then saw("trackerTimer") end
end
for _, what in ipairs({ "tile", "clue", "twoHints", "oneHint", "noPlace", "aliveTyped", "aliveUntyped",
                        "saplingUntyped", "deadUntyped", "healthExact", "healthMax", "healthUnknown",
                        "trackerTimer" }) do
  check("A8 some " .. what, (seen[what] or 0) > 0, true)
end

-- The game only says health in steps of five, so the made-up ones are too.
-- (% is the remainder, as in JS.)
local oddHealth = 0
for _, record in pairs(sample) do
  if record.health ~= nil and (record.health % 5 ~= 0 or record.health < 5 or record.health > 100) then
    oddHealth = oddHealth + 1
  end
end
check("A9 every health is a step of five, 5 to 100", oddHealth, 0)

-- Two hints share a place, so the cell shows fewer places than either hint alone.
local location = require("core/location")
local narrowed = 0
for _, record in pairs(sample) do
  if record.earlierHints ~= nil and #location.forHints(record) >= 1 then narrowed = narrowed + 1 end
end
check("A9 two hints always share a place", narrowed, seen.twoHints)

-- Icons: logs for typed trees, the woodcutting tree for untyped ones.
local logsCells, treeCells = 0, 0
for _, cell in ipairs(cells) do
  if cell.icon == "tree" and cell.logs ~= nil then logsCells = logsCells + 1 end
  if cell.icon == "tree" and cell.logs == nil then treeCells = treeCells + 1 end
end
check("A10 some logs icons and some plain tree icons", logsCells > 0 and treeCells > 0, true)

-- Every non-unknown cell has a countdown or a place (nothing blank and odd).
local blank = 0
for _, cell in ipairs(cells) do
  if cell.kind ~= "unknown" and cell.eventAt == nil and cell.place == nil and cell.kind ~= "none" then
    blank = blank + 1
  end
end
check("A6 no records with nothing to show", blank, 0)

-- Every event is in the future (nothing starts at 0:00).
local overdue = 0
for _, cell in ipairs(cells) do
  if cell.eventAt ~= nil and cell.eventAt <= NOW then overdue = overdue + 1 end
end
check("A7 no overdue countdowns", overdue, 0)

---------------------------------------------------------------- time passing
-- A tick right away changes nothing much; after 2 hours every tree and
-- timer has run its course.
worldstate.tick(sample, NOW + 1000, nil)
local later = NOW + 120 * MINUTE
worldstate.tick(sample, later, nil)
local stillTree = 0
for _, record in pairs(sample) do
  if record.status ~= "none" then stillTree = stillTree + 1 end
end
check("B1 after 2 hours only fresh spawns are trees", stillTree <= (kinds.spawn or 0), true)

---------------------------------------------------------------- default random
local real = sampledata.generate(worlds.list, NOW)
local count = 0
for _ in pairs(real) do count = count + 1 end
check("C1 math.random works too", count > 0, true)

print(passes .. " passed, " .. failures .. " failed")
if failures > 0 then error("tests failed") end
