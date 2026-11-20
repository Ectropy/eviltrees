--[[
    core/clock.lua
    --------------
    A wall clock for the plugin. The Lua sandbox has no os.time(), so we build
    "now" (Unix time in milliseconds) from two things the game does give us:

      1. CLOCK_TIME_DATE_MINUTES - a player variable holding the real time as
         whole minutes since 1970 (Unix minutes). It changes once a minute.
      2. Logic ticks - the client runs exactly 50 logic ticks per second,
         so one tick is 20 ms.

    When we see the minute variable change, we note "minute M started at tick T".
    After that:  now = M * 60000 + (currentTick - T) * 20

    Before the first change is seen (up to a minute after start-up) we only know
    the minute, not where inside it we are, so "now" may be up to 59 seconds
    behind. clock.isSynced() tells you which situation you are in.

    Wiring: main.lua forwards Logic, VarTransmit and ServerLogic events here.
]]

local safe = require("core/safe")
local devlog = require("core/devlog")

local clock = {}

local MS_PER_MINUTE = 60000
local MS_PER_TICK = 20          -- 1000 ms / 50 logic ticks per second

-- ID of the CLOCK_TIME_DATE_MINUTES player variable (found by testing in the beta client).
local MINUTE_VAR_ID = 11489

local latestTick = nil          -- most recent logic tick number
local anchorMinute = nil        -- the minute value we are counting from
local anchorTick = nil          -- the logic tick at which we started counting
local synced = false            -- true once we've seen the minute change

-- How much "now" jumped when the clock synced (ms), or nil before syncing.
-- Expected: 0 to 60 seconds. Much more means the minute value we read at
-- start-up was out of date.
clock.syncCorrectionMs = nil

-- Reads the minute variable directly. Returns a number, or nil if unavailable
-- (e.g. on the login screen).
local function readMinuteVar()
    local value = safe.try(function() return var.VarPlayer.CLOCK_TIME_DATE_MINUTES.value end)
    if type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

-- Called whenever we learn the current minute value, from any source.
-- If it's a new minute, it becomes our anchor.
local function handleMinute(minute)
    if minute == nil or latestTick == nil then
        return
    end
    if anchorMinute == nil then
        -- First time we learn the minute: we don't know how far into it we are.
        anchorMinute = minute
        anchorTick = latestTick
        devlog.print("[clock] minute known (not yet synced):", minute)
    elseif minute ~= anchorMinute then
        -- The minute just changed, so this tick is (very close to) second 0.
        if not synced then
            -- Diagnostic: how far off was our "minute only" guess? A positive
            -- number means the clock was running behind before it synced.
            clock.syncCorrectionMs = minute * MS_PER_MINUTE - clock.now()
            synced = true
            devlog.print("[clock] synced at minute", minute, "correction ms", clock.syncCorrectionMs)
        end
        anchorMinute = minute
        anchorTick = latestTick
    end
end

-- Event.Logic handler: remember the latest tick (50 per second).
function clock.onLogic(event)
    latestTick = event.logicTick
    if anchorMinute == nil then
        handleMinute(readMinuteVar())  -- try to learn the minute as soon as possible
    end
end

-- Event.VarTransmit handler: the server tells us the minute variable changed.
function clock.onVarTransmit(event)
    if event.var.id == MINUTE_VAR_ID then
        handleMinute(event.newValue)
    end
end

-- Event.ServerLogic handler: re-reads the minute each server tick, so the
-- clock doesn't rely on VarTransmit alone. One read every 0.6 s is cheap.
function clock.onServerTick()
    handleMinute(readMinuteVar())
end

-- True once "now" is accurate to the second (we've seen a minute change).
function clock.isSynced()
    return synced
end

-- Current Unix time in milliseconds, or nil if we don't know the time yet.
function clock.now()
    if anchorMinute == nil or latestTick == nil then
        return nil
    end
    return anchorMinute * MS_PER_MINUTE + (latestTick - anchorTick) * MS_PER_TICK
end

-- Formats a Unix-ms time as "hh:mm:ss" in UTC, e.g. "02:17:43".
-- "//" is integer (floor) division, "%" is remainder - same as Math.floor(a / b) and a % b in JS.
function clock.formatUtc(ms)
    if ms == nil then
        return "--:--:--"
    end
    local secondsToday = (ms // 1000) % 86400
    local hours = secondsToday // 3600
    local minutes = (secondsToday % 3600) // 60
    local seconds = secondsToday % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

return clock
