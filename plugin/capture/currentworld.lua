--[[
    capture/currentworld.lua
    ------------------------
    Works out which world the player is on.

    The game shows it in the friends list header, e.g.
        "Friends List RuneScape 205"
    (interface 550, component 48). Testing in the beta client showed this text can be
    read even when the friends tab is closed. There is no API call or game
    variable for the current world, so we read that label.

    When we re-read it:
      - at start-up,
      - a few server ticks after logging in or hopping (the label needs a
        moment to update),
      - every few seconds as a safety net.

    Other modules hear about changes through the callback given to
    currentWorld.setOnChange(). The world is nil while unknown, e.g. mid-hop.

    Wiring: main.lua forwards GameStateChanged and ServerLogic events here.
]]

local safe = require("core/safe")
local devlog = require("core/devlog")

local currentWorld = {}

local FRIENDS_INTERFACE_ID = 550
local FRIENDS_HEADER_COMPONENT_ID = 48

local READ_DELAY_TICKS = 5      -- wait ~3 s after logging in / hopping
local POLL_EVERY_TICKS = 10     -- re-check every ~6 s

currentWorld.number = nil       -- e.g. 205, or nil if unknown

local onChange = nil            -- function(newNumber, oldNumber), set by main.lua
local ticksUntilRead = nil      -- countdown to a scheduled read, or nil
local ticksSincePoll = 0
local inGame = false

-- Reads the friends list header. Returns the world number, or nil.
local function readWorldNumber()
    local text = safe.try(function()
        local label = ui.Interfaces:GetComponent(FRIENDS_INTERFACE_ID, FRIENDS_HEADER_COMPONENT_ID)
        if label == nil then
            return nil
        end
        return label.content
    end)
    if type(text) ~= "string" then
        return nil
    end
    -- "%d+" means "one or more digits"; the brackets capture just the number.
    -- tonumber turns the captured text "205" into the number 205.
    -- Matched on a lower-case copy, so capitals don't matter.
    return tonumber(string.match(string.lower(text), "runescape (%d+)"))
end

-- Stores the new world and tells the listener if it changed.
local function setWorld(newNumber)
    if newNumber == currentWorld.number then
        return
    end
    local oldNumber = currentWorld.number
    currentWorld.number = newNumber
    devlog.print("[world] now", tostring(newNumber), "(was " .. tostring(oldNumber) .. ")")
    if onChange ~= nil then
        onChange(newNumber, oldNumber)
    end
end

-- Registers the function to call when the world changes.
function currentWorld.setOnChange(callback)
    onChange = callback
end

-- Called once at start-up. The first read happens on the next server tick
-- rather than right now, so the clock has had a chance to start (otherwise
-- the "when did we see this world" time would be unknown).
function currentWorld.start()
    inGame = Player.IsAvailable()
    if inGame then
        ticksUntilRead = 1
    end
end

-- Event.GameStateChanged handler.
function currentWorld.onGameStateChanged(event)
    if event.newState == GameState.GAME then
        inGame = true
        ticksUntilRead = READ_DELAY_TICKS
    else
        -- Logging out, hopping, loading: the old world no longer applies.
        inGame = false
        ticksUntilRead = nil
        setWorld(nil)
    end
end

-- Event.ServerLogic handler (about every 0.6 s).
function currentWorld.onServerTick()
    if not inGame then
        return
    end

    if ticksUntilRead ~= nil then
        ticksUntilRead = ticksUntilRead - 1
        if ticksUntilRead <= 0 then
            ticksUntilRead = nil
            setWorld(readWorldNumber())
        end
        return
    end

    ticksSincePoll = ticksSincePoll + 1
    if ticksSincePoll >= POLL_EVERY_TICKS then
        ticksSincePoll = 0
        local number = readWorldNumber()
        if number ~= nil then       -- don't forget the world just because one read failed
            setWorld(number)
        end
    end
end

return currentWorld
