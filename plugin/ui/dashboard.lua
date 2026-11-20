--[[
    ui/dashboard.lua
    ----------------
    The dashboard in the plugin's ribbon page: the world you're on. (Every
    other world is in the world grid, ui/grid.lua, opened from here.)

    From the top:
      - the world card (ui/worldcard.lua, the same card as at the top of
        the grid): world, status icon and text, place, countdown. The page
        is narrow, so its texts often wrap and the card grows taller.
      - under it, a PrettyUI SimpleView with the buttons, lined up with
        the card's left edge (as the grid's toolbar and cells line up with
        its card):
          "All worlds (3 / 137)"   opens or closes the grid; the numbers are
                                   how many worlds have intel
          "Clear world"            forgets this world (asks first)
        and, optionally, a debug section (main.lua's SHOW_DEBUG)

    PrettyUI is a Plugin Hub UI library, a required dependency in
    plugin.json; the client loads it first and gives us the global
    "prettyui".

    How updating works (React developers: there is no virtual DOM here).
      - The card is built once per page, then changed in place every second
        (like setting element.textContent in JS).
      - The SimpleView lays its components out top to bottom when they're
        added, and can't move them later. So when what it shows changes
        (the scouted count, whether there is a Clear button, a debug line)
        or the card above it changes height, it is destroyed and built again. That happens rarely. To notice,
        each build remembers a "signature": everything it shows, joined
        into one string. A different signature means rebuild.

    If building fails on a page that was just opened, something is wrong
    with PrettyUI itself (e.g. a version without a call we use), so
    dashboard.failed becomes true and, for the rest of the session, main.lua
    shows a one-line "needs PrettyUI" notice instead.
]]

local safe = require("core/safe")
local colours = require("ui/colours")
local worldcard = require("ui/worldcard")

local dashboard = {}

-- True once the dashboard couldn't be built on a freshly opened page.
dashboard.failed = false

local MARGIN = 8            -- around the card and the view
local GAP = 6               -- between the card and the view (as the grid's card and toolbar)
-- The view's own padding: none at the sides or the top, so the buttons
-- start right under the card's left edge. (PrettyUI's default is 14 at
-- the sides and 12 at the top, which put them in from the card.)
local VIEW_LAYOUT = { paddingLeft = 0, paddingRight = 0, startY = 0 }

local parent = nil          -- the ribbon page's component (from ContentLayerReady)
local card = nil            -- the world card's components, or nil
local cardHeight = 0        -- the card's height at the last update (its texts wrap)
local view = nil            -- the PrettyUI SimpleView under the card, or nil
local signature = nil       -- the signature of what the view shows now
local debugClock = nil      -- the debug section's first line, updated in place
local onClear = nil         -- function(worldNumber), set by main.lua
local onToggleGrid = nil    -- function(), set by main.lua
local onToggleSample = nil  -- function(), set by main.lua (debug only)
local freshParent = false   -- true from opening the page until the first build works

-- Removes the view (if any). Destroy can fail if the page was already
-- closed and its components are gone; that's fine, we drop it either way.
local function destroyView()
    if view ~= nil then
        safe.try(function() view:Destroy() end)
    end
    view = nil
end

-- Removes everything we drew: the card and the view.
local function destroyAll()
    destroyView()
    if card ~= nil then
        worldcard.destroy(card)
    end
    card = nil
end

-- main.lua gives the function that clears a world's data.
function dashboard.setOnClear(fn)
    onClear = fn
end

-- main.lua gives the function that opens or closes the world grid.
function dashboard.setOnToggleGrid(fn)
    onToggleGrid = fn
end

-- main.lua gives the function that switches the grid's sample data on or
-- off (a button in the debug section).
function dashboard.setOnToggleSample(fn)
    onToggleSample = fn
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

-- Everything the view shows, and where it starts (under the card), as one
-- string (see the header).
-- ".." joins strings; tostring turns nil/true into "nil"/"true".
local function signatureOf(counts, cell, debugLines)
    local parts = {
        tostring(cardHeight), tostring(counts.scouted), tostring(counts.total),
        -- "cell and cell.world" is nil when there is no cell (like cell?.world in JS).
        tostring(cell and cell.world), tostring(cell and cell.noIntel),
    }
    if debugLines ~= nil then
        -- Skip line 1 (the clock): it's updated in place.
        for index = 2, #debugLines do
            parts[#parts + 1] = debugLines[index]
        end
    end
    return table.concat(parts, "\n")
end

-- Adds the view's components, top to bottom.
local function build(counts, cell, debugLines)
    debugClock = nil

    view:AddSimpleButton("All worlds (" .. counts.scouted .. " / " .. counts.total .. ")", function()
        if onToggleGrid ~= nil then
            onToggleGrid()
        end
    end, { tooltip = "Show or hide the grid of every world. " .. counts.scouted .. " of " .. counts.total
            .. " worlds have intel." })

    if cell ~= nil and not cell.noIntel then
        view:AddSimpleButton("Clear world", function() confirmClear(cell.world) end,
            { tooltip = "Forget everything about world " .. cell.world })
    end

    -- Debug section (temporary, for testing in the beta).
    if debugLines ~= nil then
        view:AddDivider({ marginTop = 4, marginBottom = 4 })
        view:AddTitle("Debug")
        view:AddSimpleButton("Sample data", function()
            if onToggleSample ~= nil then
                onToggleSample()
            end
        end, { tooltip = "Fill the world grid with random made-up data (not saved). Click again for the real data." })
        for index, line in ipairs(debugLines) do
            local text = view:AddText({ text = line, colour = colours.PLACE, maxLines = (index == 1) and 1 or 0 })
            if index == 1 then
                debugClock = text
            end
        end
    end
end

-- Destroys the current view (if any) and builds a new one, keeping the
-- scroll position so a rebuild doesn't jump back to the top.
-- newSignature is signatureOf(counts, cell, debugLines), already worked out.
local function rebuild(counts, cell, debugLines, newSignature)
    local scrollY = view and view.scrollY or 0
    destroyView()
    local viewY = MARGIN + cardHeight + GAP     -- just under the card
    view = prettyui.SimpleView.new(parent, {
        categoryID = "auto",    -- PrettyUI picks free component IDs (its "Component IDs" docs)
        x = MARGIN,
        y = viewY,
        width = (parent.width or 300) - 2 * MARGIN,
        height = (parent.height or 400) - viewY - MARGIN,
        layout = VIEW_LAYOUT,
    })
    build(counts, cell, debugLines)
    if scrollY > 0 then
        safe.try(function() view:SetScrollPosition(scrollY) end)
    end
    signature = newSignature
end

-- Shows the latest data. main.lua calls this about once a second.
--   counts      { scouted, total }: worlds with a record, and all worlds (main.lua)
--   cell        from overview.currentCell: the world you're on, or nil
--   now         the time (Unix ms, or nil)
--   debugLines  list of strings for the debug section, or nil for none
function dashboard.update(counts, cell, now, debugLines)
    if parent == nil then
        return      -- the ribbon page isn't open
    end

    -- The card first: built once per page, then filled in place every
    -- second. It says how tall it is now (its texts wrap to the page's
    -- width). Then the view under it, if it isn't there yet or needs
    -- building again (also when the card's height changed).
    local ok, err = pcall(function()
        if card == nil then
            card = worldcard.new(parent, MARGIN, MARGIN)
        end
        cardHeight = worldcard.update(card, cell, now, "Finding which world you're on...",
            (parent.width or 300) - 2 * MARGIN)
        local newSignature = signatureOf(counts, cell, debugLines)
        if view == nil or newSignature ~= signature then
            rebuild(counts, cell, debugLines, newSignature)
        end
    end)
    if not ok then
        log("[error] dashboard build: " .. tostring(err))
        destroyAll()                    -- remove whatever was half built
        if freshParent then
            dashboard.failed = true     -- main.lua then shows "needs PrettyUI"
        end
        parent = nil                    -- else: wait for the page to be opened again
        return
    end
    freshParent = false

    -- Then change in place what ticks in the view: the debug clock line.
    ok, err = pcall(function()
        if debugClock ~= nil and debugLines ~= nil then
            debugClock.content = debugLines[1]
        end
    end)
    if not ok then
        -- Most likely the page was closed and its components are gone.
        -- Start fresh when it's opened again. Logged so we can tell if it
        -- was something else.
        log("[error] dashboard update: " .. tostring(err))
        destroyAll()
        parent = nil
    end
end

-- Call from Event.ContentLayerReady: the client gives a new, empty page
-- component each time the player opens our page in the Plugins window.
-- The caller then calls dashboard.update to draw into it.
function dashboard.attachToRibbon(event)
    destroyAll()
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
    destroyAll()
    parent = nil
end

return dashboard
