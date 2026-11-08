--[[
    Evil Trees - main.lua
    =====================
    Tracks Evil Trees (the Distraction & Diversion) across RS3 worlds,
    automatically, from normal play.

    This file only wires things together: it loads the modules, connects game
    events to them, and starts the UI. The real work lives in:
      data/worlds.lua           - list of worlds
      data/trees.lua            - which game objects are evil trees
      data/hints.lua            - spawn locations, hints and clues
      core/clock.lua            - wall clock (the sandbox has no os.time)
      core/store.lua            - saving / loading with PersistentDB
      core/parser.lua           - dialogue / examine text -> facts
      core/worldstate.lua       - facts + time -> one saved record per world
      core/location.lua         - tile / clue / hint -> where the tree is
      core/overview.lua         - records -> what the dashboard shows
      capture/currentworld.lua  - which world we're on (friends list header)
      capture/dialogue.lua      - Spirit tree / Queen of Sunrise dialogue
      capture/examine.lua       - examine text
      capture/trees.lua         - evil tree objects near the player
      capture/lightning.lua     - lightning strikes (the "Thor" NPC)
      capture/chat.lua          - sapling inspect text (optional chatAccess)
      ui/dashboard.lua          - the dashboard (drawn with PrettyUI)
      ui/grid.lua               - every world in a floating window (PrettyUI)
      ui/debugpanel.lua         - plain text panel, used if PrettyUI isn't loaded

    Status (in development): dialogue, examine text and tree objects are
    merged into saved world records (core/worldstate.lua), and timed rules
    move them along. The dashboard shows every world we know about.

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

-- Show the debug section under the dashboard (records, tiles, recent captures).
local SHOW_DEBUG = true

-- PrettyUI is an optional dependency (plugin.json): the client loads it first
-- and gives it to us as the global "prettyui". If it isn't there (not
-- installed or not enabled), reading the global just gives nil, and we fall
-- back to the plain debug panel so the plugin still works.
local USE_DASHBOARD = USE_RIBBON and prettyui ~= nil

local safe = require("core/safe")
local worlds = require("data/worlds")
local clock = require("core/clock")
local store = require("core/store")
local parser = require("core/parser")
local worldstate = require("core/worldstate")
local location = require("core/location")
local capturelog = require("core/capturelog")
local currentWorld = require("capture/currentworld")
local dialogue = require("capture/dialogue")
local examine = require("capture/examine")
local trees = require("capture/trees")
local lightning = require("capture/lightning")
local chat = require("capture/chat")
local overview = require("core/overview")
local dashboard = require("ui/dashboard")
local grid = require("ui/grid")
local debugPanel = require("ui/debugpanel")

local VERSION = "0.5.0-dev"
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
-- A "~" before the time means the clock didn't know the seconds yet (right
-- after start-up), so the time may be up to a minute early.
local function addCapture(text, fullText)
    local world = currentWorld.number and ("W" .. currentWorld.number) or "W?"
    local approx = clock.isSynced() and "" or "~"
    local line = approx .. clock.formatUtc(clock.now()) .. " " .. world .. " " .. text
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

-- Milliseconds -> "1h42m" or "42m" (for the capture log; the dashboard
-- uses overview.formatDuration, which shows seconds).
local function formatMinutes(ms)
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
    -- nextEvent returns three values; "local a, b, c = f()" receives them.
    -- A "~" in front means "about" (a minute or more off).
    local label, at, approximate = worldstate.nextEvent(record, clock.now())
    if label ~= nil then
        text = text .. " | next: " .. label .. " " .. (approximate and "~" or "") .. clock.formatUtc(at)
    end
    -- Where the spawn (S) and maturing (M) times came from, e.g. "S timer, M strike".
    if record.spawnSource ~= nil or record.matureSource ~= nil then
        local from = {}
        if record.spawnSource ~= nil then from[#from + 1] = "S " .. record.spawnSource end
        if record.matureSource ~= nil then from[#from + 1] = "M " .. record.matureSource end
        text = text .. " | " .. table.concat(from, ", ")
    end
    if record.locationClue ~= nil then
        text = text .. " | at '" .. record.locationClue .. "'"
    elseif record.hint ~= nil then
        text = text .. " | hint '" .. record.hint .. "'"
        -- Earlier, different hints and where they all point, e.g.
        -- " (+ 'on the island known as Karamja') -> Kharazi Jungle, ...".
        -- table.concat(list, ", ") is list.join(", ").
        if record.earlierHints ~= nil then
            text = text .. " (+ '" .. table.concat(record.earlierHints, "', '") .. "')"
                .. " -> " .. table.concat(location.forHints(record), " or ")
        end
    end
    if record.tileX ~= nil then
        text = text .. " | tile " .. record.tileX .. "," .. record.tileZ
    end
    return text
end

-- Lines for the other worlds we have intel on, in the dashboard's order
-- (soonest next event first), e.g.
-- "W204 none | next: spawns 06:07:43 | hint '...'". At most maxLines.
-- otherRows is overview.build's "others" list.
local function otherWorldLines(otherRows, maxLines)
    local lines = {}
    for index, row in ipairs(otherRows) do
        if index > maxLines then
            lines[#lines + 1] = "  (+" .. (#otherRows - maxLines) .. " more)"
            break
        end
        lines[#lines + 1] = "  W" .. row.world .. " " .. describeRecord(store.worlds[row.world])
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

-- The debug text: clock, saving, this world's full record, other worlds,
-- recent captures. model is overview.build's result (for the scouted count
-- and the order of the other worlds).
local function debugLines(model)
    local worldText = "unknown"
    if currentWorld.number ~= nil then
        worldText = tostring(currentWorld.number)
        if worlds.byNumber[currentWorld.number] == nil then
            worldText = worldText .. " (not in list)"   -- e.g. the beta worlds
        end
    end

    local clockState
    if clock.now() == nil then
        clockState = "waiting for game clock"
    elseif clock.isSynced() then
        -- // 1000 turns milliseconds into whole seconds.
        clockState = "synced, jumped " .. (clock.syncCorrectionMs // 1000) .. "s"
    else
        clockState = "minute only"
    end

    local previousText = "none"
    if previousWorld ~= nil then
        previousText = tostring(previousWorld.number) .. " at " .. clock.formatUtc(previousWorld.seenAt) .. " UTC"
    end

    local savedText = "not yet this session"
    if store.lastSavedAt ~= nil then
        savedText = clock.formatUtc(store.lastSavedAt) .. " UTC"
    end

    -- Kept short so the recent captures fit: the plain panel can't scroll.
    -- Everything that changes every second is on line 1, which the
    -- dashboard updates in place (see ui/dashboard.lua).
    local lines = {
        "World " .. worldText .. "  |  " .. clock.formatUtc(clock.now()) .. " UTC (" .. clockState .. ")"
            .. "  |  saved " .. savedText,
        "v" .. VERSION .. "  |  prev " .. previousText .. "  |  chat " .. (chat.hasAccess() and "on" or "off"),
        "This world: " .. shorten(describeRecord(store.worlds[currentWorld.number or -1]), 110),
        "Scouted " .. model.scouted .. " / " .. model.total .. " worlds. Other worlds:",
    }
    for _, line in ipairs(otherWorldLines(model.others, MAX_OTHER_WORLDS)) do
        lines[#lines + 1] = shorten(line, 110)
    end
    lines[#lines + 1] = "Recent (newest first, full log saved):"
    for _, line in ipairs(recentCaptures) do
        lines[#lines + 1] = line
    end
    return lines
end

-- True when the dashboard is in use: PrettyUI is there, and it hasn't
-- failed to draw (then the plain panel takes over, see ContentLayerReady).
local function usingDashboard()
    return USE_DASHBOARD and not dashboard.failed
end

-- Redraws the world grid (if wanted), then the dashboard (or the plain
-- panel). Called once a second.
local function refreshPanel()
    local now = clock.now()
    if grid.wantsOpen() then
        grid.update(overview.cells(store.worlds, worlds.list, currentWorld.number, now), now, worlds.count)
    end
    if usingDashboard() and not dashboard.isOpen() then
        return      -- nobody can see it; it's redrawn when the page opens
    end
    local model = overview.build(store.worlds, currentWorld.number, now, worlds.count)
    if usingDashboard() then
        -- "SHOW_DEBUG and x or nil" is Lua's SHOW_DEBUG ? x : nil.
        dashboard.update(model, now, SHOW_DEBUG and debugLines(model) or nil)
    else
        debugPanel.show(debugLines(model))
    end
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

-- The world grid needs PrettyUI too. Reopen it if it was open last time
-- (e.g. before a world hop), and save where the player puts it.
if prettyui ~= nil then
    grid.restore(store.gridWindow)
end
grid.setOnLayoutChange(function(state)
    store.gridWindow = state
    store.markChanged()
end)

-- The dashboard's "All worlds" button.
dashboard.setOnToggleGrid(function()
    grid.toggle()
    refreshPanel()
end)

-- The dashboard's "Clear world" button (after the player confirms).
dashboard.setOnClear(function(number)
    if worldstate.clearWorld(store.worlds, number) then
        store.markChanged()
        addCapture("cleared W" .. number .. " (Clear world button)")
        refreshPanel()
    end
end)

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
        -- anyway (e.g. sapling-stage wording we haven't seen yet). Capitals
        -- don't matter, as in parser.lua.
        local who = string.lower(speaker)
        if who == "spirit tree" or who == "queen of sunrise" then
            addCapture(speaker .. " (unrecognised)", text)
        end
        return
    end
    local parts = {}
    if facts.noTree then parts[#parts + 1] = "no tree" end
    if facts.rewardsWindow then parts[#parts + 1] = "dead, rewards window" end
    if facts.treeAlive then parts[#parts + 1] = "tree alive" end
    if facts.saplingExists then parts[#parts + 1] = "sapling" end
    if facts.timerMs then parts[#parts + 1] = "spawn in " .. formatMinutes(facts.timerMs) end
    if facts.treeType then
        parts[#parts + 1] = "type " .. facts.treeType .. (facts.isSapling and " (sapling)" or " (mature)")
    end
    if facts.hint then parts[#parts + 1] = "hint '" .. shorten(facts.hint, 40) .. "'" end
    if facts.locationClue then parts[#parts + 1] = "at '" .. shorten(facts.locationClue, 40) .. "'" end
    addCapture(facts.source .. ": " .. table.concat(parts, ", "), text)
    noteChange(worldstate.applyDialogue(store.worlds, currentWorld.number, facts, clock.now(), clock.isSynced()))
end)

-- Examine text. Unrecognised text is shown too (shortened), so we can learn
-- what new texts look like - e.g. examining a sapling.
examine.setOnText(function(text)
    local facts = parser.parseExamine(text)
    if facts == nil then
        addCapture("examine (unrecognised): '" .. shorten(text, 40) .. "'", text)
        return
    end
    if facts.health ~= nil then
        addCapture("examine: health " .. facts.health .. "%", text)
    elseif facts.deadWithRewards then
        addCapture("examine: dead tree with rewards", text)
    elseif facts.deadNoRewards then
        addCapture("examine: dead tree, no rewards (left)", text)
    end
    noteChange(worldstate.applyExamine(store.worlds, currentWorld.number, facts, clock.now()))
end)

-- A game message in the chatbox (only with the optional chatAccess
-- permission). We only act on inspecting a sapling; every other message is
-- ignored and never logged.
chat.setOnText(function(text)
    local facts = parser.parseInspect(text)
    if facts == nil then
        return
    end
    -- You can only inspect a sapling standing next to it, so it's this
    -- world's tree. If none is in view, the message isn't about one.
    if not trees.isTreeInView() then
        addCapture("sapling inspect ignored (no evil tree in view)", text)
        return
    end
    addCapture("sapling inspect: type " .. facts.treeType, text)
    noteChange(worldstate.applyDialogue(store.worlds, currentWorld.number, facts, clock.now()))
end)

-- An evil tree object appeared, faded or was removed near the player, or
-- we left it ("unloaded": logged only, it says nothing about the tree).
-- previous is set when we watched this loc replace an older stage.
trees.setOnEvent(function(kind, info, tileX, tileZ, previous)
    local what = info.stage
    if info.treeType ~= nil then
        what = info.treeType .. " " .. what
    end
    if info.healthCap ~= nil then
        what = what .. " (max " .. info.healthCap .. "%)"     -- no "<": the game reads it as a tag
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
    if kind == "unloaded" then
        return
    end
    noteChange(worldstate.applyTreeLoc(store.worlds, currentWorld.number, kind, info,
        tileX, tileZ, previous, clock.now(), clock.isSynced()))
end)

-- How close the "Thor" NPC must be to an evil tree we can see for it to
-- count as a strike on that tree (seen 1 tile away in the beta).
local STRIKE_MAX_TILES = 3

-- A lightning strike at the tree (the "Thor" NPC appeared).
lightning.setOnStrike(function(tileX, tileZ)
    -- Only a strike next to an evil tree in view is about this world's tree.
    if not trees.isNearTree(tileX, tileZ, STRIKE_MAX_TILES) then
        addCapture("lightning ignored (no evil tree next to it) at " .. tostring(tileX) .. "," .. tostring(tileZ))
        return
    end
    addCapture("lightning strike at " .. tostring(tileX) .. "," .. tostring(tileZ))
    noteChange(worldstate.applyStrike(store.worlds, currentWorld.number, clock.now(), clock.isSynced()))
end)

-------------------------------------------------------------------------------
-- Event wiring
-------------------------------------------------------------------------------
-- Each Subscribe takes a name (used to unsubscribe later) and a handler.
-- safe.handler logs any error instead of losing it.

-- 50 times a second: keep the clock ticking, and read dialogue on the frame
-- after each server tick (see capture/dialogue.lua). Once a second: run the timed
-- rules (this also catches up after start-up) and refresh the panel.
Event.Logic.Subscribe("evilTrees", safe.handler("Logic", function(event)
    clock.onLogic(event)
    dialogue.onLogic()
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

-- Chatbox game messages: sapling inspect. Only fires with chatAccess.
Event.ChatMessage.Subscribe("evilTrees", safe.handler("ChatMessage", chat.onChatMessage))

-- Logging in, hopping worlds, logging out.
Event.GameStateChanged.Subscribe("evilTrees", safe.handler("GameStateChanged", currentWorld.onGameStateChanged))

-- The dashboard (or the plain debug panel).
if USE_RIBBON then
    -- Fires each time the player opens this plugin's page in the Plugins window.
    Event.ContentLayerReady.Subscribe("evilTrees", safe.handler("ContentLayerReady", function(event)
        if usingDashboard() then
            dashboard.attachToRibbon(event)
            refreshPanel()
            if not dashboard.failed then
                return
            end
            -- PrettyUI couldn't draw on a freshly opened page: use the plain
            -- panel for the rest of this session.
            log("Evil Trees: the dashboard failed to draw; showing the plain panel instead.")
        end
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
    dashboard.destroy()
    grid.destroy()
    debugPanel.destroy()
end
