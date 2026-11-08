-- core/overview.lua: what the dashboard shows, built from saved world records.
-- Run with: node check.js <plugin dir> test_overview.lua
local overview = require("core/overview")

local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then
    passes = passes + 1
  else
    failures = failures + 1
    print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
  end
end

local MINUTE = 60000
local NOW = 1793932200000

---------------------------------------------------------------- F: durations
check("F1 seconds", overview.formatDuration(5 * 1000), "0:05")
check("F2 minutes", overview.formatDuration(4 * MINUTE + 5000), "4:05")
check("F3 hours", overview.formatDuration(68 * MINUTE + 12000), "1:08:12")
check("F4 overdue", overview.formatDuration(-3000), "0:00")
check("F5 part seconds round down", overview.formatDuration(59999), "0:59")
-- Timestamps can be floats (fengari, or after loading): still whole numbers out.
check("F6 float input", overview.formatDuration(65000.0), "1:05")

---------------------------------------------------------------- B: building
local worlds = {
  -- Current world: alive willow, examined at 45%, seen at its tile.
  [204] = { status = "alive", treeType = "willow", health = 45, healthSource = "examine",
            matureAt = NOW - 5 * MINUTE, matureEarliest = NOW - 5 * MINUTE, matureLatest = NOW - 5 * MINUTE,
            tileX = 2702, tileZ = 3640 },
  -- Spawns in 30 min, two-place hint.
  [117] = { status = "none", spawnAt = NOW + 30 * MINUTE,
            hint = "north as the crow flies from Seers' Village" },
  -- Sapling (type unknown), full tree in 2 min, one-place hint.
  [86]  = { status = "sapling", spawnAt = NOW - 3 * MINUTE,
            hint = "due west of the town you call Lumbridge" },
  -- Dead oak, rewards for 6 more minutes, four-place hint.
  [12]  = { status = "dead", treeType = "oak", deadAt = NOW - 4 * MINUTE,
            hint = "close to a large collection of willow trees" },
  -- Only a hint, nothing due.
  [3]   = { status = "none", hint = "close to a Runecrafting altar" },
}

local view = overview.build(worlds, 204, NOW, 137)
check("B1 scouted", view.scouted, 5)
check("B2 total", view.total, 137)
check("B3 others count", #view.others, 4)

local current = view.current
check("B4 current world", current.world, 204)
check("B4 heading", current.heading, "w204 - Evil willow - 45%")
check("B4 place from tile", current.place, "East of the house portal in Rellekka")
check("B4 next event", current.eventLabel, "Lightning in")
check("B4 not approximate", current.approximate, false)

-- Soonest first: sapling (2 min), dead (6 min), spawn (30 min), then nothing due.
check("B5 order 1", view.others[1].world, 86)
check("B5 order 2", view.others[2].world, 12)
check("B5 order 3", view.others[3].world, 117)
check("B5 order 4", view.others[4].world, 3)

local sapling, dead, spawning, hintOnly = view.others[1], view.others[2], view.others[3], view.others[4]
check("B6 sapling heading", sapling.heading, "w86 - Sapling")
check("B6 sapling place", sapling.place, "South of Draynor Village, near the willow trees")
check("B6 sapling countdown", overview.countdownText(sapling, NOW), "Full tree in 2:00")

check("B7 dead heading", dead.heading, "w12 - Dead oak")
check("B7 dead place: hint", dead.place, "Hint: Close to a large collection of willow trees")
check("B7 dead countdown", overview.countdownText(dead, NOW), "Rewards gone in 5:06")

check("B8 spawn heading", spawning.heading, "w117 - No tree")
check("B8 spawn place: two options", spawning.place,
  "East of the house portal in Rellekka or Northwest of Seers' Village bank")
check("B8 spawn countdown", overview.countdownText(spawning, NOW), "Spawns in 30:00")
check("B8 spawn countdown later", overview.countdownText(spawning, NOW + 61000), "Spawns in 28:59")

check("B9 nothing due", overview.countdownText(hintOnly, NOW), nil)
check("B9 two-place hint", hintOnly.place,
  "Near the body altar, south of the Edgeville Monastery or Southwest of mining spot near the nature altar, northwest of Shilo Village")

---------------------------------------------------------------- C: the current world
-- No record yet: a row that says so.
view = overview.build(worlds, 205, NOW, 137)
check("C1 no intel", view.current.noIntel, true)
check("C1 heading", view.current.heading, "w205")
check("C1 all others listed", #view.others, 5)

-- World not known yet (start-up / mid-hop).
view = overview.build(worlds, nil, NOW, 137)
check("C2 no current", view.current, nil)

-- Clock not running yet: rows still build; no countdowns.
view = overview.build(worlds, 204, nil, 137)
check("C3 no clock: no countdown", overview.countdownText(view.current, nil), nil)

---------------------------------------------------------------- H: health and type words
local function heading(record)
  return overview.build({ [1] = record }, 1, NOW, 137).current.heading
end
local alive = { status = "alive", matureAt = NOW }
alive.treeType = "tree"
check("H1 plain tree", heading(alive), "w1 - Evil tree")
alive.health, alive.healthSource = 50, "stage"
check("H2 stage cap", heading(alive), "w1 - Evil tree - <=50%")
alive.healthSource = "strike"
check("H3 strike", heading(alive), "w1 - Evil tree - <=50%")
alive.health, alive.healthSource = 25.0, "timed"
check("H4 timed (float): at most", heading(alive), "w1 - Evil tree - <=25%")
check("H5 magic sapling", heading({ status = "sapling", treeType = "magic", spawnAt = NOW }), "w1 - Magic sapling")
check("H6 unknown type alive", heading({ status = "alive", matureAt = NOW }), "w1 - Evil tree")

-- M known to the second: exact (events are exactly M + 10/20/30). M only known within a few minutes: approximate, "~".
local M = NOW - MINUTE
local row = overview.build({ [1] = { status = "alive", treeType = "yew", matureAt = M, matureEarliest = M, matureLatest = M } }, 1, NOW, 137).current
check("H7 exact M", overview.countdownText(row, NOW), "Lightning in 9:00")
row = overview.build({ [1] = { status = "alive", treeType = "yew", matureAt = M, matureEarliest = M - 2 * MINUTE, matureLatest = M } }, 1, NOW, 137).current
check("H7b rough M is approximate", overview.countdownText(row, NOW), "Lightning in ~9:00")

-- Only told "it's alive" (M somewhere in the last 31 min): no lightning
-- time, no health, just the latest it can die. (Beta bug 2026-11-06.)
local guessed = { status = "alive", matureAt = NOW - 15 * MINUTE, matureEarliest = NOW - 31 * MINUTE, matureLatest = NOW }
row = overview.build({ [1] = guessed }, 1, NOW, 137).current
check("H8 rough M: heading", row.heading, "w1 - Evil tree")
check("H8 rough M: only an upper bound", overview.countdownText(row, NOW), "Dies within 30:00")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
