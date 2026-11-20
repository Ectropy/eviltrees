--[[
    capture/tracker.lua
    -------------------
    Reads the activity tracker's evil tree timer for the world you log in to.

    The server sends two game variables (varbits) when you log in or hop,
    whether or not Evil Tree is tracked in the activity tracker (tested in
    the beta, 2026-11-08):
        DNDTRACKER_EVIL_TREE_TIME   (id -20747)  minutes until the next tree
                                                 (the tracker's "Available in 00:52")
        DNDTRACKER_EVIL_TREE_ALIVE  (id -20746)  1 while a tree is up (sapling
                                                 or grown); TIME is then 0
    They are NOT updated afterwards, so a reading tells us about the moment
    of login, and only counts once per login.

    When was that login? Two cases:
      - The plugin was running: we saw the GameStateChanged to GAME, so we
        know (to the second).
      - The plugin started while already logged in (in the beta, a world hop
        turns dev plugins off, so this is the usual case there): the login
        came after we last left the game (main.lua saves that moment as
        lastWorld.leftAt) and before now. If that window is too wide, or we
        never saw ourselves leave (e.g. the plugin was just reloaded), the
        reading is skipped.

    main.lua calls tracker.takeLoginReading() once the world is known and
    the clock runs; the result goes to worldstate.applyTracker.
]]

local safe = require("core/safe")

local tracker = {}

local TIME_VARBIT_ID = -20747       -- DNDTRACKER_EVIL_TREE_TIME (varbits have negative ids)
local ALIVE_VARBIT_ID = -20746      -- DNDTRACKER_EVIL_TREE_ALIVE
-- After a restart, use the reading only if we left the old world at most
-- this long ago. (In the beta: hop, then switch the plugin back on.)
local MAX_LOGIN_WINDOW_MS = 5 * 60000

-- The login we haven't used a reading for yet, or nil:
--   { at = <ms> }              we saw it happen
--   { after = <ms or nil> }    plugin started in game; it was after this
local pendingLogin = nil

-- Reads both variables. Returns { minutes = 52, alive = false }, or nil if
-- the game won't give them to us.
function tracker.read()
    local minutes = safe.try(function() return var.VarPlayer.FromID(TIME_VARBIT_ID).value end)
    local alive = safe.try(function() return var.VarPlayer.FromID(ALIVE_VARBIT_ID).value end)
    if type(minutes) ~= "number" or type(alive) ~= "number" then
        return nil
    end
    return { minutes = minutes, alive = alive == 1 }
end

-- Called once at start-up. inGame: are we already logged in? leftAt: when
-- the previous session saw us leave the game (lastWorld.leftAt), or nil.
function tracker.start(inGame, leftAt)
    if inGame then
        pendingLogin = { after = leftAt }
    end
end

-- Event.GameStateChanged handler. now is clock.now() (may be nil).
function tracker.onGameStateChanged(event, now)
    if event.newState == GameState.GAME then
        -- "now and {...} or nil": the table if we know the time, else nil.
        pendingLogin = now and { at = now } or nil
    else
        pendingLogin = nil          -- left the game; the next login brings new values
    end
end

-- True while a login is waiting for its reading.
function tracker.isPending()
    return pendingLogin ~= nil
end

-- Uses up the pending login. now must not be nil. Returns a table:
--   { reading = {...}, loginEarliest = <ms>, loginLatest = <ms> }
-- or, if the reading can't be used, { skipped = "the reason" }.
function tracker.takeLoginReading(now)
    local login = pendingLogin
    pendingLogin = nil
    if login == nil then
        return { skipped = "no login to read" }
    end
    local earliest, latest = login.at, login.at
    if login.at == nil then
        if login.after == nil then
            return { skipped = "login time unknown (reloaded without leaving the game)" }
        end
        if now - login.after > MAX_LOGIN_WINDOW_MS then
            -- // is whole-number division: ms -> whole minutes
            return { skipped = "login time unknown (left the game "
                .. ((now - login.after) // 60000) .. " min ago)" }
        end
        earliest, latest = login.after, now
    end
    local reading = tracker.read()
    if reading == nil then
        return { skipped = "variables not readable" }
    end
    return { reading = reading, loginEarliest = earliest, loginLatest = latest }
end

return tracker
