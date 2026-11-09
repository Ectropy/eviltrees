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
check("H2 stage cap", heading(alive), "w1 - Evil tree - max 50%")
alive.healthSource = "strike"
check("H3 strike", heading(alive), "w1 - Evil tree - max 50%")
alive.health, alive.healthSource = 25.0, "timed"
check("H4 timed (float): at most", heading(alive), "w1 - Evil tree - max 25%")
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

---------------------------------------------------------------- S: short durations (grid cells)
check("S1 seconds in the last minute", overview.shortDuration(45 * 1000), "45s")
check("S2 just under a minute", overview.shortDuration(59999), "59s")
check("S3 exactly a minute", overview.shortDuration(MINUTE), "1m")
check("S4 minutes round down", overview.shortDuration(29 * MINUTE + 59000), "29m")
check("S5 hours", overview.shortDuration(102 * MINUTE), "1h 42m")
check("S6 hours, few minutes: no leading zero", overview.shortDuration(65 * MINUTE), "1h 5m")
check("S6b whole hour", overview.shortDuration(120 * MINUTE), "2h 0m")
check("S7 overdue", overview.shortDuration(-3000), "0s")
check("S8 float input", overview.shortDuration(45000.0), "45s")

---------------------------------------------------------------- G: grid cells
local worldList = {
  { number = 3, members = false },
  { number = 12, members = true },
  { number = 86, members = true },
  { number = 117, members = true },
  { number = 118, members = true },
}
-- On 204 (a beta world, not in the list); "worlds" (above) has a record for it.
local cells = overview.cells(worlds, worldList, 204, NOW)
check("G1 one cell per listed world, plus 204", #cells, 6)
check("G2 world order", cells[1].world .. "," .. cells[5].world .. "," .. cells[6].world, "3,118,204")

local byWorld = {}
for _, cell in ipairs(cells) do byWorld[cell.world] = cell end

check("G3 no intel", byWorld[118].kind, "unknown")
check("G3 no intel: no countdown", overview.cellCountdown(byWorld[118], NOW), nil)
check("G3 members", byWorld[118].members, true)
check("G4 hint only", byWorld[3].kind, "none")
check("G4 F2P", byWorld[3].members, false)
check("G5 spawn", byWorld[117].kind, "spawn")
check("G5 spawn countdown", overview.cellCountdown(byWorld[117], NOW), "30m")
check("G6 sapling", byWorld[86].kind, "sapling")
check("G6 sapling countdown (last 2 min)", overview.cellCountdown(byWorld[86], NOW + 61000), "59s")
check("G7 dead", byWorld[12].kind, "dead")
check("G7 dead type", byWorld[12].treeType, "Oak")
check("G7 dead: no health", byWorld[12].health, nil)

local here = byWorld[204]
check("G8 current", here.current, true)
check("G8 others not current", byWorld[3].current, false)
check("G8 unlisted: members unknown", here.members, nil)
check("G8 alive", here.kind, "alive")
check("G8 type", here.treeType, "Willow")
check("G8 health", here.health, "45%")
check("G8 tooltip heading", here.heading, "w204 - Evil willow - 45%")
check("G8 place", here.place, "East of the house portal in Rellekka")
check("G8 status", here.status, "Evil willow - 45%")
check("G8 icon and logs", here.icon .. "," .. here.logs, "tree,willow")
check("G3 no intel: no icon", byWorld[118].icon, nil)
check("G4 hint only: no icon", byWorld[3].icon, nil)
check("G5 spawn: timer", byWorld[117].icon, "timer")
check("G6 sapling icon, no logs", byWorld[86].icon .. "," .. tostring(byWorld[86].logs), "sapling,nil")
check("G7 dead: skull, no logs", byWorld[12].icon .. "," .. tostring(byWorld[12].logs), "dead,nil")
-- An alive tree's cell counts to its death (M + 30), not the next strike (M + 20).
check("G8 cell counts to death", overview.cellCountdown(here, NOW), "25m")
check("G8 next event is still the strike", overview.countdownText(here, NOW), "Lightning in 15:00")
check("G8 death text", overview.deathText(here, NOW), "Dies in 25:00")
check("G7 dead status", byWorld[12].status, "Dead oak")
check("G7 dead: no death text", overview.deathText(byWorld[12], NOW), nil)
check("G3 no intel: no status", byWorld[118].status, nil)

-- After the last strike the next event IS the death: no separate death text.
local struck = overview.cells({ [3] = { status = "alive", health = 20, healthSource = "strike",
    matureAt = NOW - 25 * MINUTE, matureEarliest = NOW - 25 * MINUTE, matureLatest = NOW - 25 * MINUTE } },
    worldList, nil, NOW)[1]
check("G12 last strike done: countdown", overview.countdownText(struck, NOW), "Dies in 5:00")
check("G12 cell", overview.cellCountdown(struck, NOW), "5m")
check("G12 no extra death text", overview.deathText(struck, NOW), nil)

-- M only roughly known: the cell shows the latest it can die.
local rough = overview.cells({ [3] = { status = "alive", matureAt = NOW - 15 * MINUTE,
    matureEarliest = NOW - 31 * MINUTE, matureLatest = NOW } }, worldList, nil, NOW)[1]
check("G13 rough M: cell shows latest death", overview.cellCountdown(rough, NOW), "30m")

-- A record for an unlisted world we're not on still gets a cell; the
-- current world gets one even with no record.
cells = overview.cells({ [205] = { status = "none", spawnAt = NOW + MINUTE } }, worldList, 204, NOW)
check("G9 count", #cells, 7)
check("G9 order", cells[6].world .. "," .. cells[7].world, "204,205")
check("G9 current, no record", cells[6].kind .. "," .. tostring(cells[6].current), "unknown,true")
-- Approximate times get "~".
cells = overview.cells({ [3] = { status = "none", spawnAt = NOW + 5 * MINUTE,
                                 spawnEarliest = NOW, spawnLatest = NOW + 5 * MINUTE } }, worldList, nil, NOW)
check("G10 approximate", overview.cellCountdown(cells[1], NOW), "~5m")
check("G11 no clock", overview.cellCountdown(cells[1], nil), nil)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
