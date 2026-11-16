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
check("F1 seconds", overview.formatDuration(5 * 1000), "5s")
check("F2 minutes", overview.formatDuration(4 * MINUTE + 5000), "4m 5s")
check("F3 hours", overview.formatDuration(68 * MINUTE + 12000), "1h 8m 12s")
check("F4 overdue", overview.formatDuration(-3000), "0s")
check("F5 part seconds round down", overview.formatDuration(59999), "59s")
-- Timestamps can be floats (fengari, or after loading): still whole numbers out.
check("F6 float input", overview.formatDuration(65000.0), "1m 5s")
check("F7 zero parts are left out", overview.formatDuration(60 * MINUTE + 5000) .. "|" .. overview.formatDuration(60 * MINUTE)
  .. "|" .. overview.formatDuration(83 * MINUTE), "1h 5s|1h|1h 23m")
check("F8 3m, then 2m 59s", overview.formatDuration(3 * MINUTE) .. "|" .. overview.formatDuration(3 * MINUTE - 1000), "3m|2m 59s")

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
  -- Dead evil oak, rewards for 6 more minutes, four-place hint.
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
check("B6 sapling heading", sapling.heading, "w86 - Strange sapling (unknown)")
check("B6 sapling place", sapling.place, "South of Draynor Village, near the willow trees")
check("B6 sapling countdown: the latest it matures", overview.countdownText(sapling, NOW), "Matures in 2m or less")
-- No time left: a word, never "0s". The rewards' line just goes.
local function dueText(record, at) return tostring(overview.countdownText(overview.build({ [3] = record }, nil, at, 137).others[1], at)) end
check("B6b due: maturing", overview.countdownText(sapling, NOW + 2 * MINUTE), "Maturing")
check("B6c due: spawning (also when overdue)",
  dueText({ status = "none", spawnAt = NOW }, NOW) .. "|" .. dueText({ status = "none", spawnAt = NOW }, NOW + 5000), "Spawning|Spawning")
check("B6d the last second still counts", dueText({ status = "none", spawnAt = NOW + 1000 }, NOW), "Spawns in 1s")

check("B7 dead heading", dead.heading, "w12 - Dead evil oak")
check("B7 dead place: hint", dead.place, "Hint: Close to a large collection of willow trees")
check("B7 dead countdown", overview.countdownText(dead, NOW), "Rewards gone in 5m 6s")
check("B7b rewards gone: the line goes", overview.countdownText(dead, NOW + 6 * MINUTE), nil)

check("B8 spawn heading", spawning.heading, "w117 - No tree")
check("B8 spawn place: two options", spawning.place,
  "East of the house portal in Rellekka or Northwest of Seers' Village bank")
check("B8 spawn countdown", overview.countdownText(spawning, NOW), "Spawns in 30m")
check("B8 spawn countdown later", overview.countdownText(spawning, NOW + 61000), "Spawns in 28m 59s")

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
check("H2 stage cap", heading(alive), "w1 - Evil tree - 50% or less")
alive.healthSource = "strike"
check("H3 strike", heading(alive), "w1 - Evil tree - 50% or less")
alive.health, alive.healthSource = 25.0, "timed"
check("H4 timed (float): at most", heading(alive), "w1 - Evil tree - 25% or less")
check("H5 magic sapling", heading({ status = "sapling", treeType = "magic", spawnAt = NOW }), "w1 - Magic sapling")
-- "Evil tree" alone is the TYPE "tree"; a tree of unknown type says so.
check("H6 unknown type alive", heading({ status = "alive", matureAt = NOW }), "w1 - Mature evil tree (unknown)")
check("H6b type tree, alive", heading({ status = "alive", treeType = "tree", matureAt = NOW }), "w1 - Evil tree")
check("H6c type tree, sapling", heading({ status = "sapling", treeType = "tree", spawnAt = NOW }), "w1 - Tree sapling")
check("H6d dead: known, tree, unknown",
  heading({ status = "dead", treeType = "maple", deadAt = NOW }) .. "|" ..
  heading({ status = "dead", treeType = "tree", deadAt = NOW }) .. "|" ..
  heading({ status = "dead", deadAt = NOW }),
  "w1 - Dead evil maple|w1 - Dead evil tree|w1 - Dead evil tree (unknown)")

-- M known to the second: exact (events are exactly M + 10/20/30). M only known within a few minutes: approximate, "~".
local M = NOW - MINUTE
local row = overview.build({ [1] = { status = "alive", treeType = "yew", matureAt = M, matureEarliest = M, matureLatest = M } }, 1, NOW, 137).current
check("H7 exact M", overview.countdownText(row, NOW), "Lightning in 9m")
row = overview.build({ [1] = { status = "alive", treeType = "yew", matureAt = M, matureEarliest = M - 2 * MINUTE, matureLatest = M } }, 1, NOW, 137).current
check("H7b rough M is approximate", overview.countdownText(row, NOW), "Lightning in ~9m")

-- Only told "it's alive" (M somewhere in the last 31 min): no lightning
-- time, no health, just the latest it can die. (Beta bug 2026-11-06.)
local guessed = { status = "alive", matureAt = NOW - 15 * MINUTE, matureEarliest = NOW - 31 * MINUTE, matureLatest = NOW }
row = overview.build({ [1] = guessed }, 1, NOW, 137).current
check("H8 rough M: heading", row.heading, "w1 - Mature evil tree (unknown)")
check("H8 rough M: only an upper bound", overview.countdownText(row, NOW), "Dies within 30m")

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
check("G6 sapling countdown (last 2 min)", overview.cellCountdown(byWorld[86], NOW + 61000), "~59s")   -- a sapling always gets the "~"
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
check("G8 next event is still the strike", overview.countdownText(here, NOW), "Lightning in 15m")
check("G8 death text", overview.deathText(here, NOW), "Dies in 25m")
check("G7 dead status", byWorld[12].status, "Dead evil oak")
check("G7 dead: no death text", overview.deathText(byWorld[12], NOW), nil)
check("G3 no intel: no status", byWorld[118].status, nil)

-- After the last strike the next event IS the death: no separate death text.
local struck = overview.cells({ [3] = { status = "alive", health = 20, healthSource = "strike",
    matureAt = NOW - 25 * MINUTE, matureEarliest = NOW - 25 * MINUTE, matureLatest = NOW - 25 * MINUTE } },
    worldList, nil, NOW)[1]
check("G12 last strike done: countdown", overview.countdownText(struck, NOW), "Dies in 5m")
check("G12 cell", overview.cellCountdown(struck, NOW), "5m")
check("G12 no extra death text", overview.deathText(struck, NOW), nil)

-- M only roughly known: the cell shows the latest it can die.
local rough = overview.cells({ [3] = { status = "alive", matureAt = NOW - 15 * MINUTE,
    matureEarliest = NOW - 31 * MINUTE, matureLatest = NOW } }, worldList, nil, NOW)[1]
check("G13 rough M: cell shows latest death", overview.cellCountdown(rough, NOW), "30m")

-- Fields for the filters and sort (core/filters.lua).
check("G14 treeKey alive", here.treeKey, "willow")
check("G14 treeKey dead", byWorld[12].treeKey, "oak")
check("G14 treeKey sapling (type unknown)", byWorld[86].treeKey, "sapling")
check("G14 treeKey spawn timer", byWorld[117].treeKey, nil)
check("G14 treeKey hint only", byWorld[3].treeKey, nil)
check("G14 treeKey no intel", byWorld[118].treeKey, nil)
check("G14 treeKey alive, type unknown", rough.treeKey, "unknown")
check("G14 treeKey sapling with a type", overview.cells({ [3] = { status = "sapling", treeType = "magic", spawnAt = NOW } },
    worldList, nil, NOW)[1].treeKey, "sapling")
check("G14 treeKey dead, type unknown", overview.cells({ [3] = { status = "dead", deadAt = NOW } },
    worldList, nil, NOW)[1].treeKey, "unknown")
check("G15 hasHint: tile only", here.hasHint, true)
check("G15 hasHint: hint", byWorld[117].hasHint, true)
check("G15 hasHint: none", byWorld[118].hasHint, false)
check("G15 hasHint: record without hint or place", overview.cells({ [3] = { status = "none", spawnAt = NOW } },
    worldList, nil, NOW)[1].hasHint, false)
check("G16 hasPlace: tile", here.hasPlace, true)
check("G16 hasPlace: one-place hint", byWorld[86].hasPlace, true)
check("G16 hasPlace: two-place hint", byWorld[117].hasPlace, false)
check("G16 hasPlace: four-place hint", byWorld[12].hasPlace, false)
check("G16 hasPlace: no intel", byWorld[118].hasPlace, false)
check("G17 healthValue: examined", here.healthValue, 45)
check("G17 healthValue: strike", struck.healthValue, 20)
check("G17 healthValue: unknown", rough.healthValue, nil)
check("G17 healthValue: dead tree", byWorld[12].healthValue, nil)
check("G17 healthValue: dead tree that kept a health", overview.cells({ [3] = { status = "dead", treeType = "oak",
    health = 10, healthSource = "strike", deadAt = NOW } }, worldList, nil, NOW)[1].healthValue, nil)

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

-- The place as a list too, one entry per place, for the card's lines.
local function placesOf(record)
  local cell = overview.cells({ [3] = record }, worldList, nil, NOW)[1]
  return tostring(cell.place) .. " / " .. (cell.places and table.concat(cell.places, " + ") or "nil")
end
check("P1 two places: joined, and listed", placesOf({ status = "none", spawnAt = NOW, hint = "north as the crow flies from Seers' Village" }),
  "East of the house portal in Rellekka or Northwest of Seers' Village bank / East of the house portal in Rellekka + Northwest of Seers' Village bank")
check("P2 exact place: a list of one", placesOf({ status = "none", spawnAt = NOW, tileX = 2702, tileZ = 3640 }),
  "East of the house portal in Rellekka / East of the house portal in Rellekka")
check("P3 nothing known: no list", placesOf({ status = "none", spawnAt = NOW }), "nil / nil")

-- A sapling may be nurtured (it then grows up sooner), so its cell always
-- has the "~", even when we saw it spawn to the second.
local seenSapling = overview.cells({ [3] = { status = "sapling", spawnAt = NOW - 3 * MINUTE } }, worldList, nil, NOW)[1]
check("N1 sapling cell: always ~", overview.cellCountdown(seenSapling, NOW), "~2m")
check("N2 sapling card: the latest, in words", overview.countdownText(seenSapling, NOW), "Matures in 2m or less")
-- The death time next to a strike: "Dying" once no time is left.
check("N3 death due: a word, not 0s", overview.deathText({ deathAt = NOW, eventAt = NOW - 1 }, NOW), "Dying")

-- The ribbon page's card: the cell for the world you're on.
local mine = overview.currentCell({ [3] = { status = "sapling", treeType = "elder", spawnAt = NOW } }, 3, false, NOW)
check("H1 current cell", mine.world .. "," .. tostring(mine.current) .. "," .. tostring(mine.members) .. "," .. mine.kind, "3,true,false,sapling")
check("H2 current cell: the same words as the grid's", mine.status .. "," .. mine.treeType, "Elder sapling,Elder")
check("H3 current cell: nothing known", overview.currentCell({}, 7, true, NOW).noIntel, true)
check("H4 current cell: world not known yet", overview.currentCell({}, nil, nil, NOW), nil)
check("H5 the type words are public (the grid measures them)", overview.TYPE_WORDS.elder, "Elder")
-- What a cell says about the type: the word (a sapling's too), nothing
-- when the type isn't known.
local function typeWord(record) return overview.cells({ [3] = record }, worldList, nil, NOW)[1].typeWord end
check("K6 type word: typed sapling", mine.typeWord, "Elder")
check("K7 type word: alive", typeWord({ status = "alive", treeType = "yew", matureAt = NOW }), "Yew")
check("K8 type word: dead", typeWord({ status = "dead", treeType = "oak", deadAt = NOW }), "Oak")
check("K9 type word: the type tree", typeWord({ status = "alive", treeType = "tree", matureAt = NOW }), "Tree")
check("K10 type word: none for unknown types",
  tostring(typeWord({ status = "sapling", spawnAt = NOW })) .. "," .. tostring(typeWord({ status = "alive", matureAt = NOW })), "nil,nil")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
