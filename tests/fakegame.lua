-- A fake game for tests that load main.lua: stubs every game global the
-- plugin uses (Event, log, PersistentDB, var, LocList, ui, ...) and records
-- what happens, so a test can drive events and read the results.
--
-- Usage:
--   local game = require("fakegame")
--   game.interfaces["550:48"] = "Friends List RuneScape 204"
--   require("main")
--   game.logic(50); game.server(2)        -- run ticks
--   game.handlers.LocAdded({ ... })       -- fire any event
--   game.errors, game.logged, game.saved  -- what the plugin did
local game = {
  handlers = {},      -- handlers.Logic = the function main.lua subscribed
  errors = {},        -- log lines containing "[error]"
  logged = {},        -- every log line
  saved = {},         -- PersistentDB contents
  interfaces = {},    -- ["550:48"] = text shown in interface 550, component 48
  locs = {},          -- locs[locId] = { { isValid = true, coordGrid = {...} } } for LocList.ByConfigID
  varbits = {},       -- varbits[-20747] = 52 for var.VarPlayer.FromID
  lastText = nil,     -- the most recent ui.Text created
  tick = 0,
}

-- A float on purpose: fengari has 32-bit integers, so minutes * 60000 would
-- overflow (the real client has 64-bit integers).
game.MINUTE_NOW = 29898900.0

Event = setmetatable({}, { __index = function(_, name)
  return { Subscribe = function(_, fn) game.handlers[name] = fn end }
end })

log = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  game.logged[#game.logged + 1] = line
  if string.find(line, "[error]", 1, true) then game.errors[#game.errors + 1] = line end
end

PersistentDB = {
  GetInt = function(_, k) return game.saved[k] end,
  GetString = function(_, k) return game.saved[k] end,
  GetStructuredData = function(_, k) return game.saved[k] end,
  SetInt = function(_, k, v) game.saved[k] = v end,
  SetString = function(_, k, v) game.saved[k] = v end,
  SetStructuredData = function(_, k, v) game.saved[k] = v end,
  Delete = function(_, k) game.saved[k] = nil end,
}

Player = { IsAvailable = function() return true end }
GameState = { GAME = 1 }
var = { VarPlayer = {
  CLOCK_TIME_DATE_MINUTES = { value = game.MINUTE_NOW },
  FromID = function(varId)
    local value = game.varbits[varId]
    if value == nil then return nil end
    return { value = value }
  end,
} }
LocList = { ByConfigID = function(locId) return game.locs[locId] or {} end }
id = { Font = {}, Component = {}, StyleSheet = {} }

ui = {
  Interfaces = { GetComponent = function(_, i, c)
    local text = game.interfaces[i .. ":" .. tostring(c)]
    if text == nil then return nil end
    return { content = text }
  end },
  AlignMode = {},
  -- Any method call on a Text does nothing; .content can be read back.
  Text = { new = function()
    game.lastText = setmetatable({}, { __index = function() return function() end end })
    return game.lastText
  end },
}

-- Runs logic ticks (50 a second) and server ticks (~0.6 s).
function game.logic(times)
  for _ = 1, times do
    game.tick = game.tick + 1
    game.handlers.Logic({ logicTick = game.tick })
  end
end
function game.server(times)
  for _ = 1, times do game.handlers.ServerLogic({}) end
end

return game
