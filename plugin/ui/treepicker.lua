--[[
    ui/treepicker.lua
    -----------------
    The grid toolbar's "Tree" control: a button that looks like the other
    dropdowns ("Tree: Yew, Magic") and opens a small popup of tick boxes,
    one per tree type (PrettyUI's CheckboxButton). Several can be ticked;
    none ticked means any tree. The types come from core/filters.lua.

    ui/gridtoolbar.lua builds it, places the button and decides when the
    popup opens and closes (it also owns the see-through "scrim" that
    closes it on a click elsewhere). This file only draws the two parts
    and reports clicks and ticks through the callbacks given to build.

    How it is drawn:
      - The button is a Layer on the window holding the game's native
        dropdown frame (a ComboField, the same frame PrettyUI's own
        dropdowns use) with our own text on top.
      - The popup is drawn on the game area, not on the window, so it is
        drawn over the cells and can hang below the window's bottom edge.
        Not being part of the window, it is registered as one of the
        window's "overlays", so it follows when the window is dragged.
]]

local filters = require("core/filters")
local colours = require("ui/colours")
local parts = require("ui/parts")

local treepicker = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

local TEXT_X = 8                -- the text's left margin, as the dropdowns' (their contentMargin)
local ARROW_SPACE = 24          -- the frame's arrow on the right (PrettyUI's combo button width)
local POPUP_PAD = 6             -- inside the popup, around the tick boxes
local POPUP_GAP = 2             -- between the button and the popup
local TEXT_COLOUR = 0xE9E5DDFF  -- PrettyUI's control text: the dropdowns' text colour
local POPUP_BG = 0x171512F8     -- PrettyUI's list background, less see-through

local HOOK_ID = "evilTreesTreePicker"   -- our name for the handlers we subscribe

-- The tick boxes, in CheckboxButton's format: { text = what it says,
-- value = what we get back }. Made once from core/filters.lua's list.
local CHOICES = {}
for index, entry in ipairs(filters.TREES) do
    CHOICES[index] = { text = entry.label, value = entry.id }
end

-------------------------------------------------------------------------------
-- State (one picker at a time: the grid has one window)
-------------------------------------------------------------------------------

local window = nil          -- the grid's PrettyUI Window
local host = nil            -- what the popup is drawn on (the game area)
local button = nil          -- the button's Layer, on window.root
local label = nil           -- the button's Text
local labelText = nil       -- what the label says now
local popup = nil           -- { root, checks, width, height }
local overlayRegistered = false
local popupOpen = false
local buttonX, buttonY, buttonHeight = 0, 0, 0  -- where place put the button

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------

-- The button: the native dropdown frame, and our text over it.
local function buildButton(options)
    button = prettyui.NewComponent(ui.Layer, window.root)
    button:SetSize(1, options.height)       -- the real size comes from treepicker.place
    button.clickthrough = false             -- it takes the mouse

    local frame = prettyui.NewComponent(ui.ComboField, button)
    -- Size it first: a frame left at the game's default size shows up as
    -- a stray empty box.
    frame:SetSize(0, 0, 1.0, 1.0)
    frame.clickthrough = true
    frame.stylesheetID = id.StyleSheet.COMBO_DEFAULT

    -- A one-line Text in the dropdowns' font (ui/parts.lua). The anchor
    -- trick: SetSize(w, h, 1.0, 0) makes the width "the button's width +
    -- w", so the text follows when the button stretches.
    label = parts.text(button, TEXT_X, options.textY, 0, options.height)
    label:SetSize(-(TEXT_X + ARROW_SPACE), options.height, 1.0, 0)
    label.rgba = TEXT_COLOUR
    labelText = ""

    -- Subscribe(hook, id, fn): the id lets several handlers share one hook.
    -- Returning false is what PrettyUI's buttons do.
    button:Subscribe(ui.Hook.ONCLICK, HOOK_ID, function()
        options.onClick()
        return false
    end)
end

-- Puts the popup under the button, or above it if it would go past the
-- bottom of the game area. The popup is on the game area, so the window's
-- own place is added to the button's.
local function placePopup()
    local x = window.root.x + buttonX
    local below = window.root.y + buttonY + buttonHeight + POPUP_GAP
    local above = window.root.y + buttonY - POPUP_GAP - popup.height
    local y = below
    local hostHeight = host.height or 0     -- "or 0": if the game can't say, never flip
    if hostHeight > 0 and below + popup.height > hostHeight and above >= 0 then
        y = above
    end
    popup.root:SetPos(x, y)
end

-- The popup: a background, an outline and the tick boxes, hidden until opened.
local function buildPopup(options)
    -- getSize returns two values (width, height), like returning [w, h] in JS.
    local checksWidth, checksHeight = prettyui.CheckboxButton.getSize(CHOICES, {})
    popup = {
        width = checksWidth + 2 * POPUP_PAD,
        height = checksHeight + 2 * POPUP_PAD,
    }
    -- categoryID "auto": PrettyUI picks free component IDs on the game area
    -- (see its "Component IDs" docs), as for the window itself.
    popup.root = prettyui.NewComponent(ui.Layer, host, { categoryID = "auto" })
    popup.root.hidden = true                -- first: it sits at 0,0 until placePopup runs
    popup.root:SetSize(popup.width, popup.height)
    popup.root.clickthrough = false         -- clicks on it don't reach the window behind
    parts.rectangle(popup.root, true, POPUP_BG)
    parts.rectangle(popup.root, false, colours.FRAME)
    popup.checks = prettyui.CheckboxButton.new(popup.root, CHOICES, {
        x = POPUP_PAD, y = POPUP_PAD,
        selectedValues = options.trees,
        -- values: every ticked value, e.g. { "yew", "magic" }.
        onChange = function(_, values)
            options.onChange(values)
        end,
    })

    -- Register it as a window overlay: PrettyUI then moves it with the
    -- window (placePopup) and hides it with the window, as it does for its
    -- own dropdown lists. window:_RegisterOverlay
    -- (PrettyUI v1.3.0 internal): without it the popup just doesn't follow
    -- a dragged window.
    overlayRegistered = pcall(function()
        window:_RegisterOverlay(popup.root,
            function() return popupOpen end,                        -- should it show?
            function() if popupOpen then placePopup() end end)      -- place it again
    end)
end

-------------------------------------------------------------------------------
-- For ui/gridtoolbar.lua
-------------------------------------------------------------------------------

-- Builds the button (on newWindow.root) and the popup (on newHost, the
-- game area). options:
--   trees    the ticked tree keys to start with, e.g. { "yew" }
--   height   the button's height
--   textY    moves the button's text down (see gridtoolbar.lua's TREE_TEXT_Y)
--   onClick  function(): the button was clicked
--   onChange function(values): the ticks changed; values lists the ticked keys
-- May throw (e.g. a PrettyUI without CheckboxButton): gridtoolbar.lua
-- then calls treepicker.destroy to remove what was made.
function treepicker.build(newWindow, newHost, options)
    window, host = newWindow, newHost
    popupOpen = false
    buildButton(options)
    buildPopup(options)
end

-- Puts the button at x, y (on the window) with this width and height.
function treepicker.place(x, y, width, height)
    button:SetPos(x, y)
    button:SetSize(width, height)
    buttonX, buttonY, buttonHeight = x, y, height
    if popupOpen then
        placePopup()
    end
end

-- The button's text, e.g. "Tree: Yew, Magic" (filters.treeSummary).
function treepicker.setLabel(text)
    if text ~= labelText then
        label.content = text
        labelText = text
    end
end

-- Ticks exactly these tree keys, without calling onChange (for Reset).
function treepicker.setTrees(trees)
    local wanted = {}               -- a set: wanted["yew"] = true
    for _, key in ipairs(trees) do
        wanted[key] = true
    end
    for _, choice in ipairs(CHOICES) do
        -- SetSelected(value, ticked, notify): notify false = no onChange.
        popup.checks:SetSelected(choice.value, wanted[choice.value] == true, false)
    end
end

function treepicker.isOpen()
    return popupOpen
end

function treepicker.open()
    popupOpen = true
    placePopup()
    popup.root.hidden = false
    popup.root:MoveToFront()        -- over everything else on the game area
end

function treepicker.close()
    popupOpen = false
    if popup ~= nil and popup.root ~= nil then
        popup.root.hidden = true
    end
end

-- Removes everything. The popup is on the game area, so it would outlive
-- the window if we didn't. Safe to call after a half-finished build.
function treepicker.destroy()
    if popup ~= nil then
        if overlayRegistered then
            -- window:_UnregisterOverlay (PrettyUI v1.3.0 internal), see buildPopup.
            pcall(function() window:_UnregisterOverlay(popup.root) end)
        end
        if popup.checks ~= nil then
            pcall(function() popup.checks:Destroy() end)
        end
        if popup.root ~= nil then
            pcall(function() popup.root:Destroy() end)
        end
    end
    if button ~= nil then
        -- On the window: it goes with the window, but the toolbar can also
        -- be removed while the window stays (if it fails).
        pcall(function() button:Destroy() end)
    end
    window, host, button, label, labelText, popup = nil, nil, nil, nil, nil, nil
    overlayRegistered = false
    popupOpen = false
end

return treepicker
