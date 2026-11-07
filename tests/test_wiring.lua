-- capture/trees.lua tests with stub loc events, then a smoke run of main.lua
-- with every game global stubbed. Fails on any "[error]" log line.
local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then passes = passes + 1
  else failures = failures + 1; print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)) end
end

---------------------------------------------------------------- trees.lua
local trees = require("capture/trees")
local events = {}
trees.setOnEvent(function(kind, info, x, z, previous)
  events[#events + 1] = { kind = kind, info = info, x = x, z = z, previous = previous }
end)
local function ev(locId, x, z) return { config = { id = locId }, coordGrid = { x = x, z = z, level = 0 } } end
local function last() return events[#events] end

trees.onLocAdded(ev(11392, 2703, 3641))                 -- sapling 2, first sight
check("T1 seen", last().kind, "seen")
check("T1 no previous", last().previous, nil)
check("T1 in view", trees.isTreeInView(), true)

trees.onLocRemoved(ev(0, 2703, 3641))
check("T2 removed", last().kind, "removed")
check("T2 not in view", trees.isTreeInView(), false)
trees.onLocAdded(ev(11393, 2703, 3641))                 -- sapling 3, same tick
check("T2 previous", last().previous and last().previous.saplingLevel, 2)

trees.onServerTick()
trees.onLocRemoved(ev(0, 2703, 3641))
trees.onLocAdded(ev(11394, 2702, 3640))                 -- sapling 4, tile shifted by one
check("T3 shifted previous", last().previous and last().previous.saplingLevel, 3)

trees.onLocRemoved(ev(0, 2702, 3640))
trees.onServerTick(); trees.onServerTick(); trees.onServerTick()
trees.onLocAdded(ev(11395, 2702, 3640))                 -- too late: first sight
check("T4 expired", last().previous, nil)

trees.onLocRemoved(ev(0, 2702, 3640))
trees.onLocAdded(ev(11437, 2900, 3000))                 -- far away: not a replacement
check("T5 far", last().previous, nil)

trees.onLocRemoved(ev(0, 2900, 3000))
trees.reset()
trees.onLocAdded(ev(11437, 2900, 3000))
check("T6 reset clears just-removed", last().previous, nil)
trees.reset()
check("T6 reset clears tracked", trees.isTreeInView(), false)

local n = #events
trees.onLocAdded(ev(12345, 1, 1))                       -- not an evil tree
check("T7 ignored", #events, n)

-- swapped in place (no LocRemoved), as on the W204 strike at 02:33:37
trees.onLocAdded(ev(11440, 2602, 3117))                 -- willow, full
trees.onLocAdded(ev(11441, 2602, 3117))                 -- willow _LVL2, same tile
check("T7b in-place swap is a change", last().previous and last().previous.healthCap, 100)
trees.onLocAdded(ev(11441, 2602, 3117))                 -- same loc again (rescan)
check("T7c same loc again is not", last().previous, nil)
trees.reset()

trees.onLocAdded(ev(14847, 5, 5))                       -- oak dead
trees.onLocAnimation({ coordGrid = { x = 5, z = 5, level = 0 }, animation = "config.Seq.EVILTREE_FADE_OUT(1715)" })
check("T8 fading", last().kind, "fading")
trees.reset()

-- isNearTree: a tree in view, or one removed a moment ago (a strike can land
-- between the old loc's LocRemoved and the new one's LocAdded).
trees.onLocAdded(ev(11440, 2602, 3117))                 -- willow, full
check("T9 near tree in view", trees.isNearTree(2603, 3116, 3), true)
check("T9 negative offset", trees.isNearTree(2599, 3120, 3), true)
check("T9 too far", trees.isNearTree(2606, 3117, 3), false)
check("T9 nil tile", trees.isNearTree(nil, 3117, 3), false)
trees.onLocRemoved(ev(0, 2602, 3117))
check("T9 near just-removed", trees.isNearTree(2602, 3118, 3), true)
trees.onServerTick(); trees.onServerTick(); trees.onServerTick()
check("T9 just-removed expired", trees.isNearTree(2602, 3118, 3), false)
trees.reset()

---------------------------------------------------------------- main.lua smoke
local game = require("fakegame")   -- stubs every game global (tests/fakegame.lua)
local handlers, errors, saved, interfaces = game.handlers, game.errors, game.saved, game.interfaces
local logic, server, MINUTE_NOW = game.logic, game.server, game.MINUTE_NOW
game.locs[11393] = { { isValid = true, coordGrid = { x = 2703, z = 3641, level = 0 } } }  -- sapling 3

interfaces["550:48"] = "Friends List RuneScape 204"
require("main")

logic(1)
server(2)                -- reads the world, scans: finds sapling 3 at 2703,3641
local store = require("core/store")
check("M1 record from scan", store.worlds[204] and store.worlds[204].status, "sapling")

-- chat (optional chatAccess): a player typing the text is ignored; the game's
-- inspect message gives the sapling's type
local INSPECT = "<col=ffffff>This sapling will grow into an evil willow tree.</col>"
handlers.ChatMessage({ senderNameUnfiltered = "Someone", chatMessage = INSPECT })
check("M1b player chat ignored", store.worlds[204].treeType, nil)
handlers.ChatMessage({ senderNameUnfiltered = "", chatMessage = "Some other game message." })
check("M1b other game text ignored", store.worlds[204].treeType, nil)
handlers.ChatMessage({ senderNameUnfiltered = "", chatMessage = INSPECT })
check("M1c inspect gives type", store.worlds[204].treeType, "willow")
check("M1c still a sapling", store.worlds[204].status, "sapling")

interfaces["1184:4"] = "Queen of Sunrise"
interfaces["1184:10"] = "Nasty spirits have got at a willow tree sapling. It can be found north as the crow flies from Seers' Village."
server(1)
check("M2 crown type", store.worlds[204].treeType, "willow")
check("M2 hint", store.worlds[204].hint, "north as the crow flies from Seers' Village")
interfaces["1184:4"] = nil; interfaces["1184:10"] = nil

handlers.VarTransmit({ var = { id = 2251, typeName = "VarClient" }, newValue = "A strange sapling emerging from the ground." })
logic(60)                -- passes logicTick 50: tick + panel refresh
handlers.LocRemoved({ coordGrid = { x = 2703, z = 3641, level = 0 } })
handlers.LocAdded({ config = { id = 11394 }, coordGrid = { x = 2702, z = 3640, level = 0 } })
check("M3 tile", store.worlds[204].tileX, 2702)

-- the debug panel: open the ribbon page, then check its text
store.worlds[205] = { status = "none", spawnAt = 1793945263552, spawnEarliest = 1793945232000, spawnLatest = 1793945283000, hint = "close to Seers" }
handlers.ContentLayerReady({ component = {} })
logic(50)
local panel = game.lastText and game.lastText.content or ""
check("M6 other worlds listed", string.find(panel, "W205 none | next: spawns", 1, true) ~= nil, true)
check("M6 scouted counts beta worlds", string.find(panel, "Scouted 2 /", 1, true) ~= nil, true)
check("M6 this world line", string.find(panel, "This world: sapling willow", 1, true) ~= nil, true)

-- lightning: Thor (NPC id 416) counts once; other NPCs are ignored.
-- First let the clock see a minute change, so it knows the seconds.
var.VarPlayer.CLOCK_TIME_DATE_MINUTES.value = MINUTE_NOW + 1
server(1)
logic(1)
store.worlds[204] = { status = "alive", treeType = "willow", spawnAt = 1 }   -- make it alive
local function npc(id, uid) return { npcEntity = { configID = id, uid = uid, coordGrid = { x = 2703, z = 3642, level = 0 } } } end
handlers.NPCEntityAdded(npc(327, 1))                -- a fishing spot
check("M7 other NPC ignored", store.worlds[204].strikeSeenAt, nil)
handlers.NPCEntityAdded(npc(416, 2))
local firstStrike = store.worlds[204].strikeSeenAt
check("M7 Thor = strike", firstStrike ~= nil, true)
logic(10)
server(2)
handlers.NPCEntityAdded(npc(416, 3))                -- the same strike seen again
check("M7 repeat ignored", store.worlds[204].strikeSeenAt, firstStrike)
-- a Thor that isn't next to an evil tree we can see is not our tree's strike
logic(10)
server(20)
handlers.NPCEntityAdded({ npcEntity = { configID = 416, uid = 4, coordGrid = { x = 2750, z = 3700, level = 0 } } })
check("M7b far Thor ignored", store.worlds[204].strikeSeenAt, firstStrike)

PluginShutdown()
check("M4 saved worlds", type(saved.worlds), "table")
check("M4 log has merges", saved.captureLog ~= nil and string.find(saved.captureLog, "-> record now", 1, true) ~= nil, true)
check("M4 log shows replacement", saved.captureLog ~= nil and string.find(saved.captureLog, "(replaced sapling3)", 1, true) ~= nil, true)
check("M5 no errors", #errors, 0)
for _, e in ipairs(errors) do print(e) end

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
