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
  return a + state % (b - a + 1)
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
