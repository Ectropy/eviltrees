--[[
    Evil Trees - main.lua
    =====================
    Tracks Evil Trees (the Distraction & Diversion) across RS3 worlds,
    automatically, from normal play.

    This file only wires things together: it loads the modules, connects game
    events to them, and starts the UI. The real work lives in:
      data/worlds.lua           - list of worlds
      core/clock.lua            - wall clock (the sandbox has no os.time)
      core/store.lua            - saving / loading with PersistentDB
      data/trees.lua            - which game objects are evil trees
      core/parser.lua           - dialogue / examine text -> facts
      core/worldstate.lua       - facts + time -> one saved record per world
      capture/currentworld.lua  - which world we're on (friends list header)
      capture/dialogue.lua      - Spirit tree / Queen of Sunrise dialogue
      capture/examine.lua       - examine text
      capture/trees.lua         - evil tree objects near the player
      capture/lightning.lua     - lightning strikes (the "Thor" NPC)
      ui/debugpanel.lua         - temporary text panel

    Status (in development): dialogue, examine text and tree objects are
    merged into saved world records (core/worldstate.lua), and timed rules
    move them along. The debug panel shows the current world's record.

    Lua reminder: require("core/clock") loads core/clock.lua (path relative to
    this plugin's folder) and returns whatever that file returns, like an ES
    module import. Each file is only run once; later requires reuse it.
]]

local devlog = require("core/devlog")
devlog.enabled = false          -- set to true to see [clock]/[store]/[world] messages in the console

-- Where the debug panel goes: true = the plugin's page in the Plugins window
-- (ribbon icon), false = a small box floating over the game window.
-- The ribbon icon shows as "ET" (our initials, since we have no icon image)
-- in the Plugins floating window.
local USE_RIBBON = true

local safe = require("core/safe")
local worlds = require("data/worlds")
local clock = require("core/clock")
local store = require("core/store")
local parser = require("core/parser")
local worldstate = require("core/worldstate")
local capturelog = require("core/capturelog")
local currentWorld = require("capture/currentworld")
local dialogue = require("capture/dialogue")
local examine = require("capture/examine")
local trees = require("capture/trees")
local lightning = require("capture/lightning")
local debugPanel = require("ui/debugpanel")

local VERSION = "0.4.0-dev"
local MAX_RECENT = 3            -- how many recent captures the debug panel lists
local MAX_OTHER_WORLDS = 4      -- how many other worlds' records it lists
local MS_PER_MINUTE = 60000
local SAVE_EVERY_TICKS = 8      -- server ticks (~0.6 s each), so a save at most every ~5 s
local PANEL_EVERY_TICKS = 50    -- logic ticks (50 per second), so the panel updates once a second

local serverTicks = 0

-------------------------------------------------------------------------------
-- Start-up: load saved data
-------------------------------------------------------------------------------

store.load()

-- Keep what the previous session saved, so the panel can show it (proves saving works).
local previousWorld = store.lastWorld

-------------------------------------------------------------------------------
-- Debug panel content
-------------------------------------------------------------------------------

-- The newest captured facts, shown in the debug panel (newest first).
local recentCaptures = {}

-- Adds a line like "03:41:12 W204 spirit tree: spawn in 1h42m" to the panel
-- list. fullText (optional) is the complete original game text; it goes into
-- the saved capture log only, since it can be too long for the panel.
local function addCapture(text, fullText)
    local world = currentWorld.number and ("W" .. currentWorld.number) or "W?"
    local line = clock.formatUtc(clock.now()) .. " " .. world .. " " .. text
    table.insert(recentCaptures, 1, line)
    if #recentCaptures > MAX_RECENT then
        table.remove(recentCaptures)    -- with no position given, removes the last (oldest) one
    end
    if fullText ~= nil then
        line = line .. "  | text: " .. fullText
    end
    capturelog.add(line)
    devlog.print("[capture]", line)
end

-- Milliseconds -> "1h42m" or "42m".
local function formatDuration(ms)
    local totalMinutes = ms // MS_PER_MINUTE
    local hours = totalMinutes // 60
    local minutes = totalMinutes % 60
    if hours > 0 then
        return hours .. "h" .. minutes .. "m"
    end
    return minutes .. "m"
end

-- One line describing a world's record, e.g.
-- "sapling willow | next: matures 03:48:12 | hint 'north as the crow...'".
local function describeRecord(record)
    if record == nil then
        return "no intel"
    end
    local parts = { record.status }
    if record.treeType ~= nil then
        parts[#parts + 1] = record.treeType
    end
    if record.health ~= nil then
        parts[#parts + 1] = record.health .. "% (" .. tostring(record.healthSource) .. ")"
    end
    local text = table.concat(parts, " ")
    -- nextEvent returns two values; "local a, b = f()" receives both.
    -- nextEvent returns three values; "local a, b, c = f()" receives them.
    -- A "~" in front means "about" (up to a minute off: beat unknown).
    local label, at, approximate = worldstate.nextEvent(record, clock.now())
    if label ~= nil then
        text = text .. " | next: " .. label .. " " .. (approximate and "~" or "") .. clock.formatUtc(at)
    end
    if record.beatMs ~= nil then
        text = text .. " | beat :" .. string.format("%02d", record.beatMs // 1000)
    end
    if record.locationClue ~= nil then
        text = text .. " | at '" .. record.locationClue .. "'"
    elseif record.hint ~= nil then
        text = text .. " | hint '" .. record.hint .. "'"
    end
    if record.tileX ~= nil then
        text = text .. " | tile " .. record.tileX .. "," .. record.tileZ
    end
    return text
end

-- How many worlds we have intel on ("Scouted N / 137"). Worlds that aren't
-- in data/worlds.lua (the beta worlds 204 / 205) count too, so the number
-- means something on the beta.
local function scoutedCount()
    local count = 0
    for _ in pairs(store.worlds) do     -- "_" = a loop variable we don't use
        count = count + 1
    end
    return count
end

-- Lines for the other worlds we have intel on, soonest next event first,
-- e.g. "W204 none | next: spawns 06:07:43 | hint '...'". At most maxLines.
local function otherWorldLines(maxLines)
    local entries = {}
    for number, record in pairs(store.worlds) do
        if number ~= currentWorld.number then
            local _, at = worldstate.nextEvent(record, clock.now())  -- only the time is needed
            -- math.huge is Infinity: worlds with nothing due sort last.
            entries[#entries + 1] = { number = number, record = record, at = at or math.huge }
        end
    end
    -- table.sort with a comparison function, like array.sort((a, b) => ...)
    -- in JS, except it returns true when a should come first.
    table.sort(entries, function(a, b) return a.at < b.at end)
    local lines = {}
    for index, entry in ipairs(entries) do
        if index > maxLines then
            lines[#lines + 1] = "  (+" .. (#entries - maxLines) .. " more)"
            break
        end
        lines[#lines + 1] = "  W" .. entry.number .. " " .. describeRecord(entry.record)
    end
    return lines
end

-- Shortens long text so a panel line doesn't get too wide.
local function shorten(text, maxLength)
    if #text <= maxLength then
        return text
    end
    return string.sub(text, 1, maxLength - 3) .. "..."
end


local function refreshPanel()
    local worldText = "unknown"
    if currentWorld.number ~= nil then
        worldText = tostring(currentWorld.number)
        if worlds.byNumber[currentWorld.number] == nil then
            worldText = worldText .. " (not in list)"   -- e.g. the beta worlds
        end
    end

    local clockState = "minute only"
    if clock.isSynced() then
        -- // 1000 turns milliseconds into whole seconds.
        clockState = "synced, jumped " .. (clock.syncCorrectionMs // 1000) .. "s"
    end
    if clock.now() == nil then
        clockState = "waiting for game clock"
    end

    local previousText = "none"
    if previousWorld ~= nil then
        previousText = tostring(previousWorld.number) .. " at " .. clock.formatUtc(previousWorld.seenAt) .. " UTC"
    end

    local savedText = "not yet this session"
    if store.lastSavedAt ~= nil then
        savedText = clock.formatUtc(store.lastSavedAt) .. " UTC"
    end

    -- Kept short so the recent captures fit: the panel can't scroll.
    local lines = {
        "World " .. worldText .. "  |  " .. clock.formatUtc(clock.now()) .. " UTC (" .. clockState .. ")",
        "v" .. VERSION .. "  |  saved " .. savedText .. "  |  prev " .. previousText,
        "This world: " .. shorten(describeRecord(store.worlds[currentWorld.number or -1]), 110),
        "Scouted " .. scoutedCount() .. " / " .. #worlds.list .. " worlds. Other worlds:",
    }
    for _, line in ipairs(otherWorldLines(MAX_OTHER_WORLDS)) do
        lines[#lines + 1] = shorten(line, 110)
    end
    lines[#lines + 1] = "Recent (newest first, full log saved):"
    for _, line in ipairs(recentCaptures) do
        lines[#lines + 1] = line
    end
    debugPanel.show(lines)
end

-------------------------------------------------------------------------------
-- Reactions to changes
-------------------------------------------------------------------------------

-- Called with the result of a worldstate.apply... function. If the current
-- world's record changed, mark the data for saving and log the new record,
-- so the capture log shows how each fact was merged.
local function noteChange(changed)
    if not changed then
        return
    end
    store.markChanged()
    local line = "  -> record now: " .. describeRecord(store.worlds[currentWorld.number])
    capturelog.add(line)
    devlog.print("[state]", line)
end

-- Remember the latest world we were on. This is what makes the
-- "Previous session" line work after a reload or world hop.
-- The clock can still be unknown right after start-up (seen after a world
-- hop), so if it is, we hold on to the world and record it once the clock runs.
local pendingWorld = nil

local function rememberWorld(number)
    local now = clock.now()
    if now == nil then
        pendingWorld = number       -- try again from the Logic handler below
        return
    end
    pendingWorld = nil
    store.lastWorld = { number = number, seenAt = now }
    store.markChanged()
end

currentWorld.setOnChange(function(newNumber, oldNumber)
    -- Trees we were tracking belong to the old world.
    trees.reset()
    if newNumber ~= nil then
        rememberWorld(newNumber)
        -- Now that we know which world we're on (start-up, or after a hop),
        -- look for an evil tree that's already in view. Doing it earlier
        -- would report the tree before we know which world it belongs to.
        trees.scanNearby()
    end
    refreshPanel()
end)

-- A new page of Spirit tree / Queen of Sunrise dialogue.
dialogue.setOnPage(function(speaker, text)
    local facts = parser.parseDialogue(speaker, text)
    if facts == nil then
        -- Not a page we understand. Log Spirit tree / Queen of Sunrise pages
        -- anyway (e.g. sapling-stage wording we haven't seen yet).
        if speaker == "Spirit tree" or speaker == "Queen of Sunrise" then
            addCapture(speaker .. " (unrecognised)", text)
        end
        return
    end
    local parts = {}
    if facts.noTree then parts[#parts + 1] = "no tree" end
    if facts.rewardsWindow then parts[#parts + 1] = "dead, rewards window" end
    if facts.treeAlive then parts[#parts + 1] = "tree alive" end
    if facts.saplingExists then parts[#parts + 1] = "sapling" end
    if facts.timerMs then parts[#parts + 1] = "spawn in " .. formatDuration(facts.timerMs) end
    if facts.treeType then
        parts[#parts + 1] = "type " .. facts.treeType .. (facts.isSapling and " (sapling)" or " (mature)")
    end
    if facts.hint then parts[#parts + 1] = "hint '" .. shorten(facts.hint, 40) .. "'" end
    if facts.locationClue then parts[#parts + 1] = "at '" .. shorten(facts.locationClue, 40) .. "'" end
    addCapture(facts.source .. ": " .. table.concat(parts, ", "), text)
    noteChange(worldstate.applyDialogue(store.worlds, currentWorld.number, facts, clock.now()))
end)

-- Examine text. Unrecognised text is shown too (shortened), so we can learn
-- what new texts look like - e.g. examining a sapling.
examine.setOnText(function(text)
    local facts = parser.parseExamine(text)
    if facts ~= nil and facts.health ~= nil then
        addCapture("examine: health " .. facts.health .. "%", text)
    elseif facts ~= nil and facts.deadWithRewards then
        addCapture("examine: dead tree with rewards", text)
    else
        addCapture("examine (unrecognised): '" .. shorten(text, 40) .. "'", text)
    end
    if facts ~= nil then
        noteChange(worldstate.applyExamine(store.worlds, currentWorld.number, facts, clock.now()))
    end
end)

-- An evil tree object appeared, faded or was removed near the player.
-- previous is set when we watched this loc replace an older stage.
trees.setOnEvent(function(kind, info, tileX, tileZ, previous)
    local what = info.stage
    if info.treeType ~= nil then
        what = info.treeType .. " " .. what
    end
    if info.healthCap ~= nil then
        what = what .. " (<=" .. info.healthCap .. "%)"
    end
    if info.saplingLevel ~= nil then
        what = what .. " " .. info.saplingLevel .. "/5"
    end
    local from = ""
    if previous ~= nil then
        -- (x or "") gives "" when x is nil, like x ?? "" in JS.
        from = " (replaced " .. previous.stage .. (previous.saplingLevel or "") .. ")"
    end
    addCapture("tree " .. kind .. ": " .. what .. " at " .. tileX .. "," .. tileZ .. from)
    noteChange(worldstate.applyTreeLoc(store.worlds, currentWorld.number, kind, info,
        tileX, tileZ, previous, clock.now(), clock.isSynced()))
end)

-- A lightning strike at the tree (the "Thor" NPC appeared).
lightning.setOnStrike(function(tileX, tileZ)
    addCapture("lightning strike at " .. tostring(tileX) .. "," .. tostring(tileZ))
    noteChange(worldstate.applyStrike(store.worlds, currentWorld.number, clock.now(), clock.isSynced()))
end)

-------------------------------------------------------------------------------
-- Event wiring
-------------------------------------------------------------------------------
-- Each Subscribe takes a name (used to unsubscribe later) and a handler.
-- safe.handler logs any error instead of losing it.

-- 50 times a second: keep the clock ticking. Once a second: run the timed
-- rules (this also catches up after start-up) and refresh the panel.
Event.Logic.Subscribe("evilTrees", safe.handler("Logic", function(event)
    clock.onLogic(event)
    if pendingWorld ~= nil and clock.now() ~= nil then
        rememberWorld(pendingWorld)
    end
    if event.logicTick % PANEL_EVERY_TICKS == 0 then
        -- The world whose tree is in view pauses its timers: the game tells
        -- us when that tree changes. "x and y or nil" is Lua's x ? y : nil.
        local inViewWorld = trees.isTreeInView() and currentWorld.number or nil
        if worldstate.tick(store.worlds, clock.now(), inViewWorld) then
            store.markChanged()
        end
        refreshPanel()
    end
end))

-- About every 0.6 s: world polling, clock safety net, debounced saving.
Event.ServerLogic.Subscribe("evilTrees", safe.handler("ServerLogic", function()
    serverTicks = serverTicks + 1
    clock.onServerTick()
    currentWorld.onServerTick()
    dialogue.onServerTick()
    trees.onServerTick()
    lightning.onServerTick()
    if serverTicks % SAVE_EVERY_TICKS == 0 then
        store.saveIfChanged(clock.now())
        capturelog.saveIfChanged()
    end
end))

-- Game variables changing: the clock's minute variable and the examine text.
Event.VarTransmit.Subscribe("evilTrees", safe.handler("VarTransmit", function(event)
    clock.onVarTransmit(event)
    examine.onVarTransmit(event)
end))

-- Game objects (locs) appearing, disappearing and animating: evil trees.
Event.LocAdded.Subscribe("evilTrees", safe.handler("LocAdded", trees.onLocAdded))
Event.LocRemoved.Subscribe("evilTrees", safe.handler("LocRemoved", trees.onLocRemoved))
Event.LocAnimation.Subscribe("evilTrees", safe.handler("LocAnimation", trees.onLocAnimation))

-- NPCs appearing: the lightning strike ("Thor").
Event.NPCEntityAdded.Subscribe("evilTrees", safe.handler("NPCEntityAdded", lightning.onNpcAdded))

-- Logging in, hopping worlds, logging out.
Event.GameStateChanged.Subscribe("evilTrees", safe.handler("GameStateChanged", function(event)
    currentWorld.onGameStateChanged(event)
end))

-- The debug panel.
if USE_RIBBON then
    -- Fires each time the player opens this plugin's page in the Plugins window.
    Event.ContentLayerReady.Subscribe("evilTrees", safe.handler("ContentLayerReady", function(event)
        debugPanel.attachToRibbon(event)
        refreshPanel()
    end))
else
    if not debugPanel.attachFloating() then
        log("Evil Trees: game window not ready; log in, then reload with: prl evil-trees")
    end
end

-------------------------------------------------------------------------------
-- Go
-------------------------------------------------------------------------------

currentWorld.start()   -- the tree scan runs once the world is known (see setOnChange above)
refreshPanel()

-- Called by the client when the plugin is turned off or the client closes.
-- Must be a global function (no "local"), per the plugin docs.
function PluginShutdown()
    store.saveNow(clock.now())
    capturelog.saveIfChanged()
    debugPanel.destroy()
end
