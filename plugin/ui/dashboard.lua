--[[
    ui/dashboard.lua
    ----------------
    The dashboard in the plugin's ribbon page, drawn with PrettyUI (a Plugin
    Hub UI library, declared in plugin.json's optionalDependencies; the
    client loads it first and gives us the global "prettyui").

    It only puts on screen what core/overview.lua decided:
      - the world you're on: tree, health, countdown, place, Clear world
      - other worlds with intel, soonest event first
      - optionally, a debug section (main.lua's SHOW_DEBUG)

    How updating works (React developers: there is no virtual DOM here).
    PrettyUI lays components out top to bottom when they're added, and
    measures each text's height then. Changing a text later doesn't move the
    components below it. So:
      - Countdowns (one line each) are updated in place every second, by
        setting the Text's .content (like element.textContent in JS).
      - When anything else changes (a world appears, a heading changes, the
        order changes), the whole view is rebuilt. That happens rarely: on a
        capture, or when an event passes.
    To tell the two apart, each build remembers a "signature": all the texts
    that aren't countdowns, joined into one string. A different signature
    means rebuild.

    If building fails on a page that was just opened, something is wrong
    with PrettyUI itself (e.g. a version without a call we use), so
    dashboard.failed becomes true and main.lua switches to the plain debug
    panel for the rest of the session.
]]

local safe = require("core/safe")
local overview = require("core/overview")

local dashboard = {}

-- True once the dashboard couldn't be built on a freshly opened page.
dashboard.failed = false

-- Colours are 0xRRGGBBAA. PrettyUI's default body text is 0xE7D7B0FF.
local MUTED = 0xAFA27FFF            -- secondary text: places, hints
local HEADING = 0xF2C66DFF          -- a world's heading line (PrettyUI's title gold)

local parent = nil          -- the ribbon page's component (from ContentLayerReady)
local view = nil            -- the PrettyUI SimpleView inside it, or nil
local signature = nil       -- the signature of what's on screen now
local countdowns = {}       -- { { text = <ui.Text>, world = 204 }, ... }
local debugClock = nil      -- the debug section's first line, updated in place
local onClear = nil         -- function(worldNumber), set by main.lua
local freshParent = false   -- true from opening the page until the first build works

-- Removes the view (if any). Destroy can fail if the page was already
-- closed and its components are gone; that's fine, we drop it either way.
local function destroyView()
    if view ~= nil then
        safe.try(function() view:Destroy() end)
    end
    view = nil
end

-- main.lua gives the function that clears a world's data.
function dashboard.setOnClear(fn)
    onClear = fn
end

-- Asks "are you sure?" before clearing, since it can't be undone.
-- If the confirm dialog can't be shown, clears directly (better than a
-- button that does nothing).
local function confirmClear(worldNumber)
    if onClear == nil then
        return
    end
    -- pcall runs a function and catches any error (like try/catch); it
    -- returns false and the error message if one was thrown.
    local ok, err = pcall(function()
        prettyui.Confirm.new(parent, {
            title = "CLEAR WORLD " .. worldNumber,
            body = "Forget everything known about world " .. worldNumber .. "?",
            confirmLabel = "CLEAR",
            confirmVariant = "negative",
            onConfirm = function() onClear(worldNumber) end,
        })
    end)
    if not ok then
        log("[error] dashboard confirm dialog: " .. tostring(err) .. " (clearing directly)")
        onClear(worldNumber)
    end
end

-- The texts that decide the layout (everything except countdown numbers).
-- ".." joins strings; tostring turns nil/true into "nil"/"true".
local function signatureOf(model, now, debugLines)
    local parts = { tostring(model.scouted) }
    local function addRowSignature(row)
        -- Whether a countdown line is shown (see overview.countdownText).
        local hasCountdown = row.eventAt ~= nil and now ~= nil
        parts[#parts + 1] = row.heading .. "|" .. tostring(row.place) .. "|" .. tostring(row.eventLabel)
            .. "|" .. tostring(hasCountdown)
    end
    if model.current ~= nil then
        addRowSignature(model.current)
    end
    for _, row in ipairs(model.others) do
        addRowSignature(row)
    end
    if debugLines ~= nil then
        -- Skip line 1 (the clock): it's updated in place.
        for index = 2, #debugLines do
            parts[#parts + 1] = debugLines[index]
        end
    end
    return table.concat(parts, "\n")
end

-- Adds one world's lines: heading, countdown, place.
local function addRow(row, now)
    view:AddText({ text = row.heading, colour = HEADING, maxLines = 1 })
    local countdown = overview.countdownText(row, now)
    if countdown ~= nil then
        local text = view:AddText({ text = countdown, maxLines = 1 })
        countdowns[#countdowns + 1] = { text = text, world = row.world }
    end
    if row.place ~= nil then
        view:AddText({ text = row.place, colour = MUTED })
    end
end

-- Creates every component from scratch.
local function build(model, now, debugLines)
    countdowns = {}
    debugClock = nil

    view:AddTitle("Evil Trees")
    view:AddText({ text = "Scouted " .. model.scouted .. " / " .. model.total .. " worlds", colour = MUTED })

    -- The world you're on.
    local current = model.current
    if current == nil then
        view:AddText("Finding which world you're on...")
    elseif current.noIntel then
        view:AddText({ text = current.heading .. " (you're here)", colour = HEADING })
        view:AddText({ text = "Nothing known yet. Talk to a spirit tree, use the Sunbeam crown, or find the tree.",
                       colour = MUTED })
    else
        addRow(current, now)
        view:AddSimpleButton("Clear world", function() confirmClear(current.world) end,
            { tooltip = "Forget everything about world " .. current.world })
    end

    -- Other worlds.
    view:AddDivider({ marginTop = 4, marginBottom = 4 })
    view:AddTitle("Other worlds")
    if #model.others == 0 then
        view:AddText({ text = "None yet. Hop and scout to fill this list.", colour = MUTED })
    end
    for _, row in ipairs(model.others) do
        addRow(row, now)
    end

    -- Debug section (temporary, for testing in the beta).
    if debugLines ~= nil then
        view:AddDivider({ marginTop = 4, marginBottom = 4 })
        view:AddTitle("Debug")
        for index, line in ipairs(debugLines) do
            local text = view:AddText({ text = line, colour = MUTED, maxLines = (index == 1) and 1 or 0 })
            if index == 1 then
                debugClock = text
            end
        end
    end
end

-- Destroys the current view (if any) and builds a new one, keeping the
-- scroll position so a rebuild doesn't jump back to the top.
-- newSignature is signatureOf(model, now, debugLines), already worked out.
local function rebuild(model, now, debugLines, newSignature)
    local scrollY = view and view.scrollY or 0
    destroyView()
    view = prettyui.SimpleView.new(parent, {
        x = 8,
        y = 8,
        width = (parent.width or 300) - 16,
        height = (parent.height or 400) - 16,
    })
    build(model, now, debugLines)
    if scrollY > 0 then
        safe.try(function() view:SetScrollPosition(scrollY) end)
    end
    signature = newSignature
end

-- Shows the latest data. main.lua calls this about once a second.
--   model       from overview.build
--   now         the time (Unix ms, or nil)
--   debugLines  list of strings for the debug section, or nil for none
function dashboard.update(model, now, debugLines)
    if parent == nil then
        return      -- the ribbon page isn't open
    end
    local newSignature = signatureOf(model, now, debugLines)
    if view == nil or newSignature ~= signature then
        -- pcall(f, a, b) calls f(a, b), catching any error.
        local ok, err = pcall(rebuild, model, now, debugLines, newSignature)
        if ok then
            freshParent = false
            return
        end
        log("[error] dashboard build: " .. tostring(err))
        destroyView()                   -- remove whatever was half built
        if freshParent then
            dashboard.failed = true     -- main.lua falls back to the plain panel
        end
        parent = nil                    -- else: wait for the page to be opened again
        return
    end

    local ok, err = pcall(function()
        -- Same layout: just tick the countdowns and the debug clock line.
        -- Use this model's rows (a new sighting can move a time by a few
        -- seconds without changing the layout), found by world number.
        local rowsByWorld = {}
        if model.current ~= nil then
            rowsByWorld[model.current.world] = model.current
        end
        for _, row in ipairs(model.others) do
            rowsByWorld[row.world] = row
        end
        for _, entry in ipairs(countdowns) do
            local row = rowsByWorld[entry.world]
            entry.text.content = row and overview.countdownText(row, now) or ""
        end
        if debugClock ~= nil and debugLines ~= nil then
            debugClock.content = debugLines[1]
        end
    end)
    if not ok then
        -- Most likely the page was closed and its components are gone.
        -- Start fresh when it's opened again. Logged so we can tell if it
        -- was something else.
        log("[error] dashboard update: " .. tostring(err))
        destroyView()
        parent = nil
    end
end

-- Call from Event.ContentLayerReady: the client gives a new, empty page
-- component each time the player opens our page in the Plugins window.
-- The caller then calls dashboard.update to draw into it.
function dashboard.attachToRibbon(event)
    destroyView()
    parent = event.component
    freshParent = true
end

-- True while there's a page to draw into (so main.lua can skip the work
-- of building the data when nobody can see it).
function dashboard.isOpen()
    return parent ~= nil
end

-- Called when the plugin shuts down.
function dashboard.destroy()
    destroyView()
    parent = nil
end

return dashboard
