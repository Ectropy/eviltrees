--[[
    capture/lightning.lua
    ---------------------
    Notices lightning strikes on the evil tree.

    The plugin API has no events for graphics or sounds, but testing in the
    beta client found that a strike is done by an invisible NPC, EVILTREE_THOR (NPC id
    416, empty display name). It appears next to the tree at the moment of
    the strike and disappears about a second later. So "Thor appeared" =
    "lightning struck just now", to the second. (Seen on a killing strike;
    assumed to be the same for the other strikes.)

    We match by NPC id, never by name (its name is empty). Reports go to the
    callback given to lightning.setOnStrike(), as onStrike(tileX, tileZ).

    Wiring: main.lua forwards NPCEntityAdded and ServerLogic events here.
]]

local safe = require("core/safe")

local lightning = {}

local THOR_NPC_ID = 416
-- Walking in and out of range while Thor is there could report it twice;
-- strikes are 10 minutes apart, so ignore any repeat within ~5 s.
local REPEAT_TICKS = 8          -- server ticks (~0.6 s each)

local onStrike = nil            -- function(tileX, tileZ), set by main.lua
local serverTick = 0
local lastStrikeTick = nil

-- Registers the function to call for each strike.
function lightning.setOnStrike(callback)
    onStrike = callback
end

-- Event.ServerLogic handler: counts time for the repeat check.
function lightning.onServerTick()
    serverTick = serverTick + 1
end

-- Event.NPCEntityAdded handler.
function lightning.onNpcAdded(event)
    local npcId = safe.try(function() return event.npcEntity.configID end)
    if npcId ~= THOR_NPC_ID then
        return
    end
    if lastStrikeTick ~= nil and serverTick - lastStrikeTick <= REPEAT_TICKS then
        return      -- the same strike again
    end
    lastStrikeTick = serverTick
    local coord = safe.try(function() return event.npcEntity.coordGrid end)
    if onStrike ~= nil then
        -- "coord and coord.x" gives nil if coord is nil (like coord?.x in JS).
        onStrike(coord and coord.x, coord and coord.z)
    end
end

return lightning
