--[[
    ui/gridtoolbar.lua
    ------------------
    The world grid's toolbar, pinned between the card and the cells:

        [Sort: World v] [Worlds: All v] [Info: Any v] [Tree: Any v]   40 / 137  [Reset]

    The count (gold) and Reset only show while something is filtered. The
    choices and their labels come from core/filters.lua; this file only
    draws the controls and tells ui/grid.lua when the player picks
    something (grid.lua keeps the choices, filters the cells and saves).

    How it is drawn (tried out in the grid lab, rounds 1 and 2):
      - Sort, Worlds and Info are PrettyUI ComboBoxes. Giving each entry an
        `order` makes PrettyUI use its OrderedComboBox: a text box you can
        type in to filter the list, and an arrow button. (The game's own
        combo sorts the labels and stayed open on a click elsewhere.) The
        group name is part of every label ("Sort: Soonest"), so there are
        no separate label texts.
      - Tree is ui/treepicker.lua: a button that opens tick boxes.
      - Everything sits straight on the window (window.root), next to the
        card. The open lists and the Tree popup are drawn on the game area
        instead, so they go over the cells and past the window's edge.
      - Flow layout: the controls go left to right and wrap onto as many
        rows as the window's width needs. When every control ends up on a
        row of its own, they all stretch to the full width.
      - Closing on a click elsewhere: while a list or the popup is open, an
        invisible Layer (a "scrim") covers the whole window and closes it
        when clicked. PrettyUI's ordered combo only closes itself when its
        text box loses the keyboard, or on Esc, so a list opened with the
        arrow used to stay open (lab round 2). Opening one control closes
        any other.
]]

local filters = require("core/filters")
local colours = require("ui/colours")
local treepicker = require("ui/treepicker")

local gridtoolbar = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

local ROW_HEIGHT = 20           -- one row of controls (the controls' height)
local ROW_GAP = 4               -- between two rows
local ITEM_GAP = 8              -- between two controls on a row
local MIN_CONTROL_WIDTH = 70    -- a control is never squeezed narrower than this
local COUNT_WIDTH = 60          -- the gold "40 / 137"
local RESET_WIDTH = 56
local COUNT_GAP = 4             -- between the count and Reset
local FONT = "MUSEO_SANS_11PT_REGULAR"

-- Each control's natural width (narrower only if the window is).
local WIDTHS = {
    sort = 175,                 -- fits "Sort: World (high first)" and the arrow
    worlds = 120,               -- "Worlds: All"
    info = 150,                 -- "Info: Needs place"
    trees = 140,                -- "Tree: Yew, Magic"
}

-- TEXT HEIGHT: where the text sits inside the controls. Tune these in the
-- beta so the dropdowns' text and the Tree button's text line up. A bigger
-- number moves that text DOWN, a smaller one UP.
--   COMBO_TEXT_TOP  the dropdowns' text inset from the top. PrettyUI's own
--                   default (3) is made for 30-high boxes in a 15pt font
--                   and looked too low here (lab round 2).
--   TREE_TEXT_Y     the Tree button's text, from centred in the row.
local COMBO_TEXT_TOP = 0
local TREE_TEXT_Y = 0
local TEXT_LEFT = 8             -- the dropdowns' text inset from the left (PrettyUI's default)

-- The three dropdowns, left to right. Each name is also the key in the
-- prefs table and in filters.TITLES.
local COMBO_NAMES = { "sort", "worlds", "info" }
local ENTRIES = { sort = filters.SORTS, worlds = filters.WORLDS, info = filters.INFOS }

local HOOK_ID = "evilTreesToolbar"  -- our name for the handlers we subscribe

-------------------------------------------------------------------------------
-- State (one toolbar at a time: the grid has one window)
-------------------------------------------------------------------------------

local window = nil          -- the grid's PrettyUI Window, while the toolbar exists
local handlers = nil        -- { onChange, onReset } from build
local combos = {}           -- combos.sort = the Sort ComboBox, ...
local wasOpen = {}          -- wasOpen.sort = true if the Sort list was open at the last check
local openCombo = nil       -- the name of the combo the scrim is showing for, or nil
local scrim = nil           -- the see-through Layer that closes things (see the header)
local count = nil           -- the gold count Text
local countText = nil       -- what it says now
local reset = nil           -- the Reset SimpleButton
local contextRegistered = false
local items = {}            -- what the flow layout places, see buildItems
local originX, originY = 0, 0   -- where the first row starts, on the window
local laidOutWidth = nil    -- the width at the last layout
local laidOutFiltering = nil
local height = 0            -- the rows' total height at the last layout

-------------------------------------------------------------------------------
-- Errors
-------------------------------------------------------------------------------

-- Runs fn; if it fails, logs one line instead of losing the error (like
-- try/catch). Used in click handlers, which the game calls directly.
local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then
        log("[error] grid toolbar: " .. tostring(err))
    end
end

-------------------------------------------------------------------------------
-- Opening and closing
-------------------------------------------------------------------------------

local function showScrim()
    scrim.hidden = false
    scrim:MoveToFront()             -- over the window's controls and cells
end

-- Closes one combo's list. There is no public call for it: combo:_Close
-- is PrettyUI's own (PrettyUI v1.3.0 internal). Without it the list just
-- stays open, as it did before the scrim.
local function closeCombo(combo)
    if combo.open == true and type(combo._Close) == "function" then
        pcall(function() combo:_Close() end)
    end
end

-- Closes every open list and the Tree popup, except the combo named
-- `keep` (nil closes everything, and hides the scrim).
local function closeAll(keep)
    for _, name in ipairs(COMBO_NAMES) do
        if name ~= keep and combos[name] ~= nil then
            closeCombo(combos[name])
        end
    end
    treepicker.close()
    if keep == nil then
        openCombo = nil
        scrim.hidden = true
    end
end

-- The Tree button: opens the popup (closing anything else), or closes it.
local function onTreeButton()
    if treepicker.isOpen() then
        closeAll()
        return
    end
    closeAll()
    showScrim()
    treepicker.open()               -- after the scrim, so it is drawn above it
end

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------

-- Lets the dropdown lists be drawn on the game area. PrettyUI's combo looks
-- for a "context" on its parent that says where to draw its list and how
-- to work out screen positions; a Window registers one for its scrolling
-- content, and we register the same kind for window.root. ownerWindow
-- makes the combo register its list as a window overlay, so the list moves
-- with the window. prettyui.Tooltip.registerContext and context.ownerWindow
-- (PrettyUI v1.3.0 internal) are what the lab's "Overlay screen" used; if
-- they are missing the toolbar fails to build and the grid shows without it.
local function registerContext(host)
    local context = prettyui.Tooltip.registerContext(window.root, host, function(target)
        -- Where a component on window.root is on the game area.
        return (window.root.x or 0) + (target.x or 0), (window.root.y or 0) + (target.y or 0)
    end, nil)
    context.ownerWindow = window
    contextRegistered = true
end

-- The scrim: covers the whole window, hidden until a list or the popup opens.
local function buildScrim()
    scrim = prettyui.NewComponent(ui.Layer, window.root)
    scrim.hidden = true                     -- first: it covers the whole window
    scrim:SetPos(0, 0)
    scrim:SetSize(0, 0, 1.0, 1.0)           -- (width, height, widthAnchor, heightAnchor): fill the window
    scrim.clickthrough = false              -- it takes the click, so nothing under it gets it
    scrim:Subscribe(ui.Hook.ONCLICK, HOOK_ID, function()
        scrim.hidden = true                 -- first, so it can never get stuck
        guarded(closeAll)
        return false
    end)
end

-- One dropdown. selectedId is the entry to show (from the prefs).
local function buildCombo(name, selectedId)
    local entries = {}
    for index, entry in ipairs(ENTRIES[name]) do
        entries[index] = {
            id = entry.id,
            label = filters.TITLES[name] .. ": " .. entry.label,   -- "Sort: Soonest"
            order = index,          -- keeps our order (and makes it an OrderedComboBox)
        }
    end
    combos[name] = prettyui.ComboBox.new(window.root, {
        width = WIDTHS[name], height = ROW_HEIGHT,
        font = id.Font[FONT],
        entryHeight = ROW_HEIGHT,
        maxVisibleEntries = #entries,       -- show them all, no scrolling
        entries = entries,
        selectedID = selectedId,
        -- ui.Margin.new(left, top, right, bottom): where the text sits in the box.
        contentMargin = ui.Margin.new(TEXT_LEFT, COMBO_TEXT_TOP, 4, 0),
        -- Called when the player picks an entry (not when we call Select).
        onChange = function(_, entryId)
            guarded(function() handlers.onChange(name, entryId) end)
        end,
    })
end

-- A one-line Text on the window.
local function newText(alignHorizontal)
    local text = prettyui.NewComponent(ui.Text, window.root)
    text.font = id.Font[FONT]
    text.isShadowed = true
    text.alignHorizontal = alignHorizontal
    text.alignVertical = ui.AlignMode.CENTRE
    text.maxLines = 1
    text.clickthrough = true
    text.content = ""
    return text
end

-- The count and Reset, hidden until something is filtered.
local function buildCountAndReset()
    -- BOTTOMRIGHT puts the text on the right, next to Reset (the game's
    -- align modes are shared by both directions).
    count = newText(ui.AlignMode.BOTTOMRIGHT)
    count.rgba = colours.GOLD
    count.hidden = true
    countText = ""
    reset = prettyui.SimpleButton.new(window.root, "Reset", function()
        guarded(function()
            closeAll()
            handlers.onReset()
        end)
    end, { width = RESET_WIDTH, height = ROW_HEIGHT })
    reset.root.hidden = true
end

-- Moves and sizes a component (only touching the size when it changes).
local function placeComponent(component, x, y, width)
    component:SetPos(x, y)
    if component.width ~= width then
        component:SetSize(width, ROW_HEIGHT)
    end
end

-- What the flow layout places, in order. Each item has the width it would
-- like and a function that puts it at (x, y) with a given width (like an
-- array of { width, place } objects in JS). filterOnly: shown only while
-- filtering.
local function buildItems()
    items = {}
    for _, name in ipairs(COMBO_NAMES) do
        items[#items + 1] = {
            width = WIDTHS[name],
            place = function(x, y, width)
                placeComponent(combos[name].root, x, y, width)
            end,
        }
    end
    items[#items + 1] = {
        width = WIDTHS.trees,
        place = function(x, y, width)
            treepicker.place(x, y, width, ROW_HEIGHT)
        end,
    }
    items[#items + 1] = {
        width = COUNT_WIDTH + COUNT_GAP + RESET_WIDTH,
        filterOnly = true,
        -- The count takes what Reset leaves, so a stretched item keeps
        -- Reset at the right end.
        place = function(x, y, width)
            placeComponent(count, x, y, width - COUNT_GAP - RESET_WIDTH)
            reset.root:SetPos(x + width - RESET_WIDTH, y)
        end,
    }
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

-- Splits the items into rows for a given width: a new row starts when the
-- next item doesn't fit. Returns a list of rows; each row is a list of
-- { item, width }. An item wider than the whole row is squeezed to fit.
local function flow(shownItems, available)
    local rows = { {} }
    local x = 0
    for _, item in ipairs(shownItems) do
        local width = math.max(MIN_CONTROL_WIDTH, math.min(item.width, available))
        local row = rows[#rows]             -- the last row (#t is the length)
        if #row > 0 and x + width > available then
            row = {}
            rows[#rows + 1] = row           -- push a new row
            x = 0
        end
        row[#row + 1] = { item = item, width = width }
        x = x + width + ITEM_GAP
    end
    return rows
end

-- Places everything for a width and sets `height`.
local function layout(available, filtering)
    local shownItems = {}
    for _, item in ipairs(items) do
        if filtering or not item.filterOnly then
            shownItems[#shownItems + 1] = item
        end
    end
    count.hidden = not filtering
    reset.root.hidden = not filtering

    local rows = flow(shownItems, available)
    -- One control per row (a narrow window): stretch them all to the full
    -- width, so they don't look ragged.
    local stretch = (#rows == #shownItems)
    for rowIndex, row in ipairs(rows) do
        local x = originX
        local y = originY + (rowIndex - 1) * (ROW_HEIGHT + ROW_GAP)
        for _, slot in ipairs(row) do
            local width = stretch and available or slot.width   -- ("c and a or b" is c ? a : b)
            slot.item.place(x, y, width)
            x = x + width + ITEM_GAP
        end
    end
    height = #rows * ROW_HEIGHT + (#rows - 1) * ROW_GAP
    laidOutWidth, laidOutFiltering = available, filtering
end

-------------------------------------------------------------------------------
-- For ui/grid.lua
-------------------------------------------------------------------------------

-- Builds the toolbar on newWindow (a PrettyUI Window). host is what the
-- window was created on (the game area): the lists and the Tree popup are
-- drawn there. x, y is where the first row starts, on the window. prefs
-- are the choices to show (see core/filters.lua). newHandlers:
--   onChange(group, value)  the player picked something: group is "sort",
--                           "worlds", "info" or "trees" (value: a list of keys)
--   onReset()               Reset was clicked
-- Throws if something is missing (e.g. a different PrettyUI version);
-- grid.lua then calls gridtoolbar.destroy and shows the grid without it.
-- Nothing is placed until the first gridtoolbar.refresh.
function gridtoolbar.build(newWindow, host, x, y, prefs, newHandlers)
    window, handlers = newWindow, newHandlers
    originX, originY = x, y
    laidOutWidth, laidOutFiltering, height = nil, nil, 0
    wasOpen, openCombo = {}, nil
    registerContext(host)
    buildScrim()                    -- first, so it starts under the controls
    for _, name in ipairs(COMBO_NAMES) do
        buildCombo(name, prefs[name])   -- prefs[name] is prefs.sort, prefs.worlds, ...
    end
    treepicker.build(window, host, {
        trees = prefs.trees,
        height = ROW_HEIGHT,
        textY = TREE_TEXT_Y,
        onClick = function() guarded(onTreeButton) end,
        onChange = function(values)
            guarded(function() handlers.onChange("trees", values) end)
        end,
    })
    buildCountAndReset()
    buildItems()
end

-- Updates the toolbar for the latest choices and counts, and lays it out
-- again if the width (the space for the rows) or the filtering changed.
-- shown / total: how many worlds are shown, out of how many. Returns the
-- toolbar's height (it grows when the controls wrap onto more rows).
function gridtoolbar.refresh(available, prefs, shown, total)
    local filtering = filters.isFiltering(prefs)
    local text = shown .. " / " .. total
    if text ~= countText then
        count.content = text
        countText = text
    end
    treepicker.setLabel(filters.treeSummary(prefs.trees))
    if available ~= laidOutWidth or filtering ~= laidOutFiltering then
        if available ~= laidOutWidth then
            -- The controls move: close any open list rather than leave it
            -- hanging where its control used to be.
            closeAll()
        end
        layout(available, filtering)
    end
    return height
end

-- Moves the toolbar to start at (x, y) on the window: the card above it
-- grew or shrank, or moved to a side of the grid. The controls are placed
-- again on the next refresh.
function gridtoolbar.setOrigin(x, y)
    if x == originX and y == originY then
        return
    end
    originX, originY = x, y
    closeAll()              -- an open list would be left where its control was
    laidOutWidth = nil      -- makes the next refresh lay everything out again
end

-- Closes an open list or the Tree popup (when the settings page opens).
function gridtoolbar.closeLists()
    closeAll()
end

-- Shows these choices without calling onChange (after Reset).
function gridtoolbar.showPrefs(prefs)
    for _, name in ipairs(COMBO_NAMES) do
        -- Select(id, triggerEvents): false = don't call onChange.
        combos[name]:Select(prefs[name], false)
    end
    treepicker.setTrees(prefs.trees)
end

-- Called every frame (50 a second) by grid.lua: notices a dropdown list
-- opening or closing (by comparing with the last frame), to show or hide
-- the scrim. combo.open is PrettyUI's own flag (PrettyUI v1.3.0 internal);
-- without it (nil) lists just don't close on a click elsewhere, as before.
-- The scrim only shows when a list OPENS, so if _Close is missing and a
-- scrim click can't close the list, the scrim still goes away.
function gridtoolbar.onLogic()
    if window == nil then
        return
    end
    for _, name in ipairs(COMBO_NAMES) do
        local isOpen = (combos[name].open == true)
        if isOpen and not wasOpen[name] then
            -- This list just opened: close anything else, and cover the
            -- window so a click elsewhere closes it.
            closeAll(name)
            openCombo = name
            showScrim()
        elseif not isOpen and wasOpen[name] and openCombo == name then
            -- It closed by itself (an entry picked, Enter or Esc).
            openCombo = nil
            if not treepicker.isOpen() then
                scrim.hidden = true
            end
        end
        wasOpen[name] = isOpen
    end
end

-- Removes the toolbar. Things on the game area (the lists, the popup) and
-- our context would outlive the window, so this must run before the
-- window goes. Also used after a half-finished build, so every part may
-- be missing; each removal is in a pcall so one failure can't stop the rest.
function gridtoolbar.destroy()
    if window == nil then
        return
    end
    treepicker.destroy()
    for _, name in ipairs(COMBO_NAMES) do
        local combo = combos[name]
        if combo ~= nil then
            pcall(function() combo:Destroy() end)   -- also removes its list from the game area
        end
    end
    if reset ~= nil then
        pcall(function() reset:Destroy() end)
    end
    -- On the window: they go with it, but the toolbar can also be removed
    -- while the window stays (if it fails).
    if scrim ~= nil then
        pcall(function() scrim:Destroy() end)
    end
    if count ~= nil then
        pcall(function() count:Destroy() end)
    end
    if contextRegistered then
        -- prettyui.Tooltip.unregisterContext (PrettyUI v1.3.0 internal), see registerContext.
        pcall(function() prettyui.Tooltip.unregisterContext(window.root) end)
    end
    window, handlers = nil, nil
    combos, items, wasOpen = {}, {}, {}
    openCombo, scrim, count, countText, reset = nil, nil, nil, nil, nil
    contextRegistered = false
end

return gridtoolbar
