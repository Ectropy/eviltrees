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

trees.onLocAdded(ev(14847, 5, 5))                       -- oak dead
trees.onLocAnimation({ coordGrid = { x = 5, z = 5, level = 0 }, animation = "config.Seq.EVILTREE_FADE_OUT(1715)" })
check("T8 fading", last().kind, "fading")
trees.reset()

---------------------------------------------------------------- main.lua smoke
local handlers = {}
local errors = {}
local saved = {}
local interfaces = {}   -- ["550:48"] = text

Event = setmetatable({}, { __index = function(_, name)
  return { Subscribe = function(_, fn) handlers[name] = fn end }
end })
log = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  if string.find(line, "[error]", 1, true) then errors[#errors + 1] = line end
end
PersistentDB = {
  GetInt = function(_, k) return saved[k] end,
  GetString = function(_, k) return saved[k] end,
  GetStructuredData = function(_, k) return saved[k] end,
  SetInt = function(_, k, v) saved[k] = v end,
  SetString = function(_, k, v) saved[k] = v end,
  SetStructuredData = function(_, k, v) saved[k] = v end,
  Delete = function(_, k) saved[k] = nil end,
}
Player = { IsAvailable = function() return true end }
GameState = { GAME = 1 }
-- A float on purpose: fengari has 32-bit integers, so minutes * 60000 would
-- overflow (the real client has 64-bit integers).
local MINUTE_NOW = 29898900.0
var = { VarPlayer = { CLOCK_TIME_DATE_MINUTES = { value = MINUTE_NOW } } }
LocList = { ByConfigID = function(locId)
  if locId == 11393 then return { { isValid = true, coordGrid = { x = 2703, z = 3641, level = 0 } } } end
  return {}
end }
id = { Font = {}, Component = {}, StyleSheet = {} }
ui = {
  Interfaces = { GetComponent = function(_, i, c)
    local text = interfaces[i .. ":" .. tostring(c)]
    if text == nil then return nil end
    return { content = text }
  end },
  AlignMode = {},
  Text = { new = function()
    lastText = setmetatable({}, { __index = function() return function() end end })
    return lastText
  end },
}

interfaces["550:48"] = "Friends List RuneScape 204"
require("main")

local tick = 0
local function logic(times)
  for _ = 1, times do tick = tick + 1; handlers.Logic({ logicTick = tick }) end
end
local function server(times)
  for _ = 1, times do handlers.ServerLogic({}) end
end

logic(1)
server(2)                -- reads the world, scans: finds sapling 3 at 2703,3641
local store = require("core/store")
check("M1 record from scan", store.worlds[204] and store.worlds[204].status, "sapling")

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
local panel = lastText and lastText.content or ""
check("M6 other worlds listed", string.find(panel, "W205 none | next: spawns", 1, true) ~= nil, true)
check("M6 scouted counts beta worlds", string.find(panel, "Scouted 2 /", 1, true) ~= nil, true)
check("M6 this world line", string.find(panel, "This world: sapling willow", 1, true) ~= nil, true)

-- lightning: Thor (NPC id 416) counts once; other NPCs are ignored.
-- First let the clock see a minute change, so it knows the seconds (the beat
-- is only recorded then).
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
check("M7 beat recorded", store.worlds[204].beatMs ~= nil, true)
logic(10)
server(2)
handlers.NPCEntityAdded(npc(416, 3))                -- the same strike seen again
check("M7 repeat ignored", store.worlds[204].strikeSeenAt, firstStrike)

PluginShutdown()
check("M4 saved worlds", type(saved.worlds), "table")
check("M4 log has merges", saved.captureLog ~= nil and string.find(saved.captureLog, "-> record now", 1, true) ~= nil, true)
check("M4 log shows replacement", saved.captureLog ~= nil and string.find(saved.captureLog, "(replaced sapling3)", 1, true) ~= nil, true)
check("M5 no errors", #errors, 0)
for _, e in ipairs(errors) do print(e) end

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
