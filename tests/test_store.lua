-- core/store.lua round trip through a fake PersistentDB that stores numbers
-- inside tables as 32-bit floats, like the real one does (seen in the beta:
-- 1793945263552 came back as 1793945239552.0).
local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then passes = passes + 1
  else failures = failures + 1; print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)) end
end

-- Rounds a number the way a 32-bit float would, and returns it as a float.
local function float32(n)
  return (string.unpack("f", string.pack("f", n)))
end
check("sanity: float32 rounds big timestamps", float32(1793945263552), 1793945239552.0)

-- Deep copy that turns every number into a 32-bit float (strings unchanged).
local function throughDb(value)
  if type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do out[k] = throughDb(v) end
    return out
  end
  if type(value) == "number" then return float32(value) end
  return value
end

local disk = {}
PersistentDB = {
  GetInt = function(_, k) return disk[k] end,
  SetInt = function(_, k, v) disk[k] = v end,
  GetStructuredData = function(_, k) return disk[k] and throughDb(disk[k]) end,
  SetStructuredData = function(_, k, v) disk[k] = throughDb(v) end,
  Delete = function(_, k) disk[k] = nil end,
}
log = function() end

local store = require("core/store")
store.worlds[204] = {
  status = "none", spawnAt = 1793945263552, spawnEarliest = 1793945232000, spawnLatest = 1793945283000,
  hint = "close to the village you call 'Seers'", earlierHints = { "on the island known as Karamja" }, health = 50, tileX = 2702,
}
store.lastWorld = { number = 205, seenAt = 1793940389123 }
store.gridWindow = { x = 60, y = 80, width = 762, height = 330, open = 1 }
store.gridView = { sort = "soonest", worlds = "p2p", info = "needsHint", trees = "yew,magic" }
store.saveNow(1793940389123)
check("in-memory record untouched by saving", store.worlds[204].spawnAt, 1793945263552)

store.worlds = {}
store.lastWorld = nil
store.gridWindow = nil
store.gridView = nil
store.load()
check("record loaded", store.worlds[204] ~= nil, true)
check("grid window kept", store.gridWindow and store.gridWindow.width, 762)
check("grid window open flag", store.gridWindow and store.gridWindow.open, 1)
local view = store.gridView or {}
check("grid view kept", tostring(view.sort) .. "|" .. tostring(view.worlds) .. "|" .. tostring(view.info) .. "|" .. tostring(view.trees),
  "soonest|p2p|needsHint|yew,magic")

-- Saving again replaces the view (deleted first), and "" (any tree) survives.
store.gridView = { sort = "world", worlds = "all", info = "any", trees = "" }
store.saveNow(1793940389123)
store.gridView = nil
store.load()
view = store.gridView or {}
check("grid view replaced", tostring(view.sort) .. "|" .. tostring(view.trees), "world|")
local r = store.worlds[204]
check("spawnAt exact", r.spawnAt, 1793945263552)
check("spawnEarliest exact", r.spawnEarliest, 1793945232000)
check("spawnLatest exact", r.spawnLatest, 1793945283000)
-- (fengari, used for these tests, only has 32-bit integers, so the type of
-- a big timestamp is not checked here; real Lua 5.4 in the client has 64-bit.)
check("small numbers stay numbers", r.health, 50)
check("small number type", math.type(r.health), "integer")
check("tile", r.tileX, 2702)
check("world", r.world, 204)
check("hint text kept", r.hint, "close to the village you call 'Seers'")
check("earlier hints kept", r.earlierHints and r.earlierHints[1], "on the island known as Karamja")
check("lastWorld seenAt exact", store.lastWorld.seenAt, 1793940389123)
check("lastWorld number", store.lastWorld.number, 205)

-- A save from a newer format is left alone: the plugin starts empty.
disk.schemaVersion = 2
disk.worlds = throughDb({ { world = 9, status = "none", spawnAt = 1793945263552 } })
store.worlds = {}
store.load()
check("newer format not loaded", store.worlds[9], nil)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
