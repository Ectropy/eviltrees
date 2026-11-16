-- core/filters.lua: the world grid's sort and filters, on hand-made cells.
-- Run with: node check.js <plugin dir> test_filters.lua
local filters = require("core/filters")
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

-- A list of cells -> "10,7,6" (their world numbers), to compare orders.
local function worldsOf(cells)
  local numbers = {}
  for _, cell in ipairs(cells) do numbers[#numbers + 1] = cell.world end
  return table.concat(numbers, ",")
end

-- A list of strings -> "a,b" (so lists are easy to check).
local function joined(list)
  return table.concat(list, ",")
end

-- prefs with some fields changed.
local function prefs(changes)
  local p = filters.defaults()
  for key, value in pairs(changes) do p[key] = value end
  return p
end

-- A hand-made cell: only the fields the filters read.
local function cell(world, members, kind, fields)
  local c = { world = world, members = members, kind = kind, hasHint = false, hasPlace = false }
  for key, value in pairs(fields or {}) do c[key] = value end
  return c
end

-- w1  p2p  unknown
-- w2  f2p  none (hint only)
-- w3  p2p  spawn, 300
-- w4  p2p  elder sapling, 100, hint + place
-- w5  f2p  alive willow, 200, health 50, hint
-- w6  p2p  alive type unknown, 150, no health
-- w7  p2p  dead oak, 400
-- w8  ?    alive yew, 200, health 25, hint + place (members unknown)
-- w9  p2p  alive magic, no time, no health
-- w10 p2p  dead elder, 50, hint + place
local cells = {
  cell(1, true, "unknown"),
  cell(2, false, "none", { hasHint = true }),
  cell(3, true, "spawn", { cellAt = 300 }),
  cell(4, true, "sapling", { cellAt = 100, treeKey = "sapling", saplingType = "elder", hasHint = true, hasPlace = true }),
  cell(5, false, "alive", { cellAt = 200, treeKey = "willow", healthValue = 50, hasHint = true }),
  cell(6, true, "alive", { cellAt = 150, treeKey = "unknown" }),
  cell(7, true, "dead", { cellAt = 400, treeKey = "oak" }),
  cell(8, nil, "alive", { cellAt = 200, treeKey = "yew", healthValue = 25, hasHint = true, hasPlace = true }),
  cell(9, true, "alive", { treeKey = "magic" }),
  cell(10, true, "dead", { cellAt = 50, treeKey = "elder", hasHint = true, hasPlace = true }),
}

---------------------------------------------------------------- D: defaults
check("D1 default sort", filters.defaults().sort, "world")
check("D1 default worlds", filters.defaults().worlds, "all")
check("D1 default info", filters.defaults().info, "any")
check("D1 default trees empty", #filters.defaults().trees, 0)
local d1, d2 = filters.defaults(), filters.defaults()
d1.trees[1] = "oak"
d1.sort = "latest"
check("D2 fresh table each time", d1 ~= d2, true)
check("D2 fresh trees list", #d2.trees, 0)
check("D2 other copy unchanged", d2.sort, "world")

-- The entry lists: ids and labels, in display order.
local function ids(entries)
  local list = {}
  for _, entry in ipairs(entries) do list[#list + 1] = entry.id end
  return joined(list)
end
local function labels(entries)
  local list = {}
  for _, entry in ipairs(entries) do list[#list + 1] = entry.label end
  return joined(list)
end
check("D3 sort ids", ids(filters.SORTS), "world,worldDesc,soonest,latest,health")
check("D3 sort labels", labels(filters.SORTS), "World,World (high first),Soonest,Latest,Lowest health")
check("D3 worlds ids", ids(filters.WORLDS), "all,p2p,f2p")
check("D3 worlds labels", labels(filters.WORLDS), "All,P2P,F2P")
check("D3 info ids", ids(filters.INFOS),
  "any,noIntel,hasIntel,needsHint,needsPlace")
check("D3 info labels", labels(filters.INFOS),
  "Any,No intel,Has intel,Needs hint,Needs place")
check("D3 tree ids", ids(filters.TREES), "unknown,sapling,tree,oak,willow,maple,yew,magic,elder")
check("D3 tree labels", labels(filters.TREES), "Unknown,Sapling,Tree,Oak,Willow,Maple,Yew,Magic,Elder")
check("D3 titles", filters.TITLES.sort .. filters.TITLES.worlds .. filters.TITLES.info .. filters.TITLES.trees,
  "SortWorldsInfoTree")

---------------------------------------------------------------- N: normalize
local function summary(p)
  return p.sort .. "|" .. p.worlds .. "|" .. p.info .. "|" .. joined(p.trees)
end
check("N1 nil", summary(filters.normalize(nil)), "world|all|any|")
check("N1 string", summary(filters.normalize("junk")), "world|all|any|")
check("N1 number", summary(filters.normalize(7)), "world|all|any|")
check("N1 empty table", summary(filters.normalize({})), "world|all|any|")
check("N2 valid values kept",
  summary(filters.normalize({ sort = "health", worlds = "f2p", info = "needsHint", trees = { "yew" } })),
  "health|f2p|needsHint|yew")
check("N3 old ids reset only their field",
  summary(filters.normalize({ sort = "oldSort", worlds = "p2p", info = "gone", trees = { "oak" } })),
  "world|p2p|any|oak")
check("N3 wrong types", summary(filters.normalize({ sort = 5, worlds = true, info = {}, trees = {} })),
  "world|all|any|")
check("N4 trees: invalid dropped, duplicates removed, display order",
  summary(filters.normalize({ trees = { "elder", "bogus", "oak", "elder", 5, "oak", "unknown" } })),
  "world|all|any|unknown,oak,elder")
check("N5 trees not a table", summary(filters.normalize({ trees = "oak" })), "world|all|any|")
check("N5 trees nil", summary(filters.normalize({ sort = "latest" })), "latest|all|any|")
local saved = { sort = "latest", trees = { "oak", "oak" } }
local normalized = filters.normalize(saved)
check("N6 returns a new table", normalized ~= saved, true)
check("N6 new trees list", normalized.trees ~= saved.trees, true)
check("N6 input not changed", #saved.trees .. saved.sort .. tostring(saved.worlds), "2latestnil")
normalized.trees[1] = "elder"
check("N6 changing the result leaves the input", saved.trees[1], "oak")

---------------------------------------------------------------- T: tree button text
check("T1 none", filters.treeSummary({}), "Tree: Any")
check("T2 one", filters.treeSummary({ "elder" }), "Tree: Elder")
check("T3 two, display order", filters.treeSummary({ "magic", "yew" }), "Tree: Yew, Magic")
check("T4 three", filters.treeSummary({ "oak", "yew", "magic" }), "Tree: 3 types")
check("T4 four", filters.treeSummary({ "oak", "willow", "yew", "magic" }), "Tree: 4 types")
check("T4 all nine", filters.treeSummary({ "unknown", "sapling", "tree", "oak", "willow", "maple", "yew", "magic", "elder" }),
  "Tree: 9 types")

---------------------------------------------------------------- I: isFiltering
check("I1 defaults", filters.isFiltering(filters.defaults()), false)
check("I2 sort is not a filter", filters.isFiltering(prefs({ sort = "health" })), false)
check("I3 worlds", filters.isFiltering(prefs({ worlds = "p2p" })), true)
check("I4 info", filters.isFiltering(prefs({ info = "needsHint" })), true)
check("I5 trees", filters.isFiltering(prefs({ trees = { "oak" } })), true)

---------------------------------------------------------------- S: sorts
check("S1 world", worldsOf(filters.apply(cells, prefs({ sort = "world" }))), "1,2,3,4,5,6,7,8,9,10")
check("S2 world, high first", worldsOf(filters.apply(cells, prefs({ sort = "worldDesc" }))), "10,9,8,7,6,5,4,3,2,1")
-- dead (10, 7), alive (6, 5 and 8 tie: world order), sapling 4, spawn 3, no time (1, 2, 9).
check("S3 soonest", worldsOf(filters.apply(cells, prefs({ sort = "soonest" }))), "10,7,6,5,8,4,3,1,2,9")
-- spawn 3, sapling 4, alive (5 and 8 tie, then 6), dead (7 then 10), no time.
check("S4 latest", worldsOf(filters.apply(cells, prefs({ sort = "latest" }))), "3,4,5,8,6,7,10,1,2,9")
-- alive with health low first (8, 5), alive without (6, 9), the rest by world.
check("S5 health", worldsOf(filters.apply(cells, prefs({ sort = "health" }))), "8,5,6,9,1,2,3,4,7,10")
check("S6 unknown sort id falls back to world", worldsOf(filters.apply(cells, prefs({ sort = "nope" }))),
  "1,2,3,4,5,6,7,8,9,10")

-- Cells given in a shuffled order come out the same (the sort is deterministic).
local shuffled = { cells[9], cells[3], cells[10], cells[1], cells[7], cells[5], cells[2], cells[8], cells[4], cells[6] }
check("S7 soonest from shuffled input", worldsOf(filters.apply(shuffled, prefs({ sort = "soonest" }))), "10,7,6,5,8,4,3,1,2,9")
check("S7 latest from shuffled input", worldsOf(filters.apply(shuffled, prefs({ sort = "latest" }))), "3,4,5,8,6,7,10,1,2,9")
check("S7 health from shuffled input", worldsOf(filters.apply(shuffled, prefs({ sort = "health" }))), "8,5,6,9,1,2,3,4,7,10")

-- Float timestamps, and equal times everywhere: world order decides.
local sameTime = {
  cell(30, true, "alive", { cellAt = 1793932200000.0 }),
  cell(20, true, "alive", { cellAt = 1793932200000.0 }),
  cell(10, true, "alive", { cellAt = 1793932200000.0 + 60000.0 }),
}
check("S8 float times, ties by world", worldsOf(filters.apply(sameTime, prefs({ sort = "soonest" }))), "20,30,10")
check("S8 latest", worldsOf(filters.apply(sameTime, prefs({ sort = "latest" }))), "10,20,30")

-- A kind that has no time (cellAt nil) goes last even if its kind is "dead".
local noTimeDead = { cell(1, true, "dead"), cell(2, true, "spawn", { cellAt = 5 }) }
check("S9 dead with no time goes last (soonest)", worldsOf(filters.apply(noTimeDead, prefs({ sort = "soonest" }))), "2,1")
check("S9 dead with no time goes last (latest)", worldsOf(filters.apply(noTimeDead, prefs({ sort = "latest" }))), "2,1")

---------------------------------------------------------------- W: worlds filter
check("W1 all (nil members too)", #filters.apply(cells, prefs({ worlds = "all" })), 10)
check("W2 p2p", worldsOf(filters.apply(cells, prefs({ worlds = "p2p" }))), "1,3,4,6,7,9,10")
check("W3 f2p", worldsOf(filters.apply(cells, prefs({ worlds = "f2p" }))), "2,5")

---------------------------------------------------------------- F: info filter
local function withInfo(id) return worldsOf(filters.apply(cells, prefs({ info = id }))) end
check("F1 any", withInfo("any"), "1,2,3,4,5,6,7,8,9,10")
check("F2 noIntel", withInfo("noIntel"), "1,2")
check("F3 hasIntel", withInfo("hasIntel"), "3,4,5,6,7,8,9,10")
check("F4 needsHint (active, no hint)", withInfo("needsHint"), "3,6,7,9")
check("F6 needsPlace (tree up, no place)", withInfo("needsPlace"), "5,6,7,9")
-- Ids that were dropped (old saves) are reset by normalize.
check("F7 dropped id normalizes to any", filters.normalize({ info = "hasHealth" }).info, "any")
check("F10 unknown info id shows everything", withInfo("bogus"), "1,2,3,4,5,6,7,8,9,10")

---------------------------------------------------------------- R: tree filter
local function withTrees(list) return worldsOf(filters.apply(cells, prefs({ trees = list }))) end
check("R1 none chosen = any", withTrees({}), "1,2,3,4,5,6,7,8,9,10")
check("R2 one type", withTrees({ "sapling" }), "4")
check("R3 unknown type", withTrees({ "unknown" }), "6")
check("R4 two types", withTrees({ "yew", "magic" }), "8,9")
check("R5 type nobody has", withTrees({ "maple" }), "")
check("R6 dead, alive and a typed sapling all match", withTrees({ "oak", "elder", "willow" }), "4,5,7,10")
check("R7 typed sapling matches its type alone", withTrees({ "elder" }), "4,10")

---------------------------------------------------------------- X: combinations
check("X1 p2p + needsHint", worldsOf(filters.apply(cells, prefs({ worlds = "p2p", info = "needsHint" }))), "3,6,7,9")
check("X2 p2p + trees + soonest", worldsOf(filters.apply(cells,
  prefs({ worlds = "p2p", trees = { "oak", "elder" }, sort = "soonest" }))), "10,7,4")
check("X3 f2p + needsPlace", worldsOf(filters.apply(cells, prefs({ worlds = "f2p", info = "needsPlace" }))), "5")
check("X4 members unknown hidden by p2p and f2p",
  worldsOf(filters.apply(cells, prefs({ worlds = "p2p", info = "hasIntel" }))), "3,4,6,7,9,10")
check("X5 hasIntel + health sort", worldsOf(filters.apply(cells, prefs({ info = "hasIntel", sort = "health" }))), "8,5,6,9,3,4,7,10")
check("X6 nothing matches", worldsOf(filters.apply(cells, prefs({ worlds = "f2p", info = "needsHint" }))), "")
check("X7 trees + noIntel (no tree ever matches)", worldsOf(filters.apply(cells,
  prefs({ info = "noIntel", trees = { "oak" } }))), "")
check("X8 no cells", #filters.apply({}, filters.defaults()), 0)

---------------------------------------------------------------- M: nothing is changed
local before = worldsOf(cells)
local firstCell = cells[1]
local snapshot = {}
for _, c in ipairs(cells) do
  snapshot[c.world] = c.world .. tostring(c.members) .. c.kind .. tostring(c.cellAt) .. tostring(c.treeKey)
    .. tostring(c.hasHint) .. tostring(c.hasPlace) .. tostring(c.healthValue)
end
local result = filters.apply(cells, prefs({ sort = "latest", worlds = "p2p" }))
check("M1 input list not reordered", worldsOf(cells), before)
check("M1 input list not shortened", #cells, 10)
check("M2 result is a new list", result ~= cells, true)
check("M2 same cell tables inside", result[#result] == cells[10] or result[1] == cells[3], true)
local unchanged = true
for _, c in ipairs(cells) do
  local now = c.world .. tostring(c.members) .. c.kind .. tostring(c.cellAt) .. tostring(c.treeKey)
    .. tostring(c.hasHint) .. tostring(c.hasPlace) .. tostring(c.healthValue)
  if now ~= snapshot[c.world] then unchanged = false end
end
check("M3 cell fields not changed", unchanged, true)
check("M3 first cell still first", cells[1] == firstCell, true)
local sameList = filters.apply(cells, filters.defaults())
check("M4 unfiltered result is a new list too", sameList ~= cells, true)
local p = prefs({ trees = { "oak" }, sort = "health" })
filters.apply(cells, p)
check("M5 prefs not changed", summary(p), "health|all|any|oak")

---------------------------------------------------------------- E: with real overview cells
local MINUTE = 60000
local NOW = 1793932200000
local worldList = {
  { number = 3, members = false },
  { number = 12, members = true },
  { number = 86, members = true },
  { number = 117, members = true },
  { number = 118, members = true },
}
local worlds = {
  [204] = { status = "alive", treeType = "willow", health = 45, healthSource = "examine",
            matureAt = NOW - 5 * MINUTE, matureEarliest = NOW - 5 * MINUTE, matureLatest = NOW - 5 * MINUTE,
            tileX = 2702, tileZ = 3640 },
  [117] = { status = "none", spawnAt = NOW + 30 * MINUTE, hint = "north as the crow flies from Seers' Village" },
  [86]  = { status = "sapling", spawnAt = NOW - 3 * MINUTE, hint = "due west of the town you call Lumbridge" },
  [12]  = { status = "dead", treeType = "oak", deadAt = NOW - 4 * MINUTE, hint = "close to a large collection of willow trees" },
  [3]   = { status = "none", hint = "close to a Runecrafting altar" },
}
local real = overview.cells(worlds, worldList, 204, NOW)    -- 3, 12, 86, 117, 118, 204
check("E1 defaults keep everything", worldsOf(filters.apply(real, filters.defaults())), "3,12,86,117,118,204")
check("E2 soonest", worldsOf(filters.apply(real, prefs({ sort = "soonest" }))), "12,204,86,117,3,118")
check("E3 latest", worldsOf(filters.apply(real, prefs({ sort = "latest" }))), "117,86,204,12,3,118")
check("E4 no intel", worldsOf(filters.apply(real, prefs({ info = "noIntel" }))), "3,118")
check("E5 has intel, soonest", worldsOf(filters.apply(real, prefs({ info = "hasIntel", sort = "soonest" }))), "12,204,86,117")
check("E5 has intel, p2p only (204 has unknown members)",
  worldsOf(filters.apply(real, prefs({ info = "hasIntel", worlds = "p2p", sort = "soonest" }))), "12,86,117")
check("E6 needs place", worldsOf(filters.apply(real, prefs({ info = "needsPlace" }))), "12")
check("E7 needs hint (none: all four have one)", worldsOf(filters.apply(real, prefs({ info = "needsHint" }))), "")
check("E8 oak or willow", worldsOf(filters.apply(real, prefs({ trees = { "oak", "willow" }, sort = "soonest" }))), "12,204")
check("E9 sapling", worldsOf(filters.apply(real, prefs({ trees = { "sapling" } }))), "86")
worlds[86].treeType = "yew"     -- the crown named the sapling's type
check("E10 typed sapling matches its type",
  worldsOf(filters.apply(overview.cells(worlds, worldList, 204, NOW), prefs({ trees = { "yew" } }))), "86")
check("E11 f2p", worldsOf(filters.apply(real, prefs({ worlds = "f2p" }))), "3")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
