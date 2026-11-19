--[[
    ui/gridsettings.lua
    -------------------
    The plugin's settings, in two places that show the same choices:

        Cells
        (o) Two lines
        ( ) One line

      1. The client's settings page. "hasSettingsIcon": true in plugin.json
         makes the client draw a Settings icon (Plugin Hub > Manage). When
         the player clicks it, the client hands us an empty layer
         (Event.SettingsLayerReady, see main.lua) and gridsettings.fillHub
         fills it with a PrettyUI SimpleView, like the ribbon page. The
         client clears the layer itself before each event.
      2. A gear in the world grid's title bar, next to the close button
         (gridsettings.attach). It opens a page that covers the grid; the
         gear is underlined while it is open, and a second click closes it.

    Both pages stay in step: a choice made on one shows on the other at
    once (gridsettings.showLines, called by ui/grid.lua).

    Today there is one setting, the cells' lines (the choices are
    core/filters.lua's LINES); more can go here. This file only draws:
    ui/grid.lua keeps the choice and saves it.

    How the gear works (the same way as the Quest Helper plugin, which is
    BSD-licensed and allows AI use; no code copied):
      - The gear is a PrettyUI SpriteButton ON the window, anchored to its
        right edge, so it moves and resizes with the window by itself.
      - PrettyUI drags the window with an invisible Layer (window.titleDrag)
        that lies over the title bar, in front of the window, and would take
        the gear's clicks. So we keep that Layer short: it stops just left
        of the gear. PrettyUI sets its width again after every drag and
        resize, so gridsettings.onLogic (every frame) shortens it again
        whenever it has grown. While a drag is going on (window.dragFeedback
        is set) the Layer covers the whole screen on purpose, so it is left
        alone. window.titleDrag and window.dragFeedback are PrettyUI's own
        (PrettyUI 1.2.2 and 1.3.0 internals): without them the gear is still
        drawn, but the title bar may take its clicks.
      - The page is a Layer on the window with a solid background, in front
        of the card, toolbar and cells, so it hides them and takes the
        mouse. Nothing under it is hidden or changed, so closing it just
        hides the page.
]]

local filters = require("core/filters")
local parts = require("ui/parts")

local gridsettings = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

local MARGIN = 8                -- around the client's settings page, as the ribbon page
local GEAR_SIZE = 20            -- as big as PrettyUI's close button
local GEAR_X = -52              -- from the window's right edge: the close button (20 + 8 from the edge) and a gap of 4
local GEAR_Y = 7                -- from the window's top, as the close button
local UNDERLINE_Y = GEAR_Y + GEAR_SIZE + 2  -- just under the gear (near the title bar's bottom edge)
local DRAG_GAP = 2              -- between the end of the drag strip and the gear
local TITLE_HEIGHT = 32         -- PrettyUI's title bar
local TITLE_WIDTH = -80         -- the title text's width (window width - 80), so it doesn't run under the gear
local PAD = 10                  -- inside the page
local HEADING_HEIGHT = 20
local PAGE_BG = 0x1B1814FF      -- solid, close to the window's own background
local GOLD = 0xF2C66DFF         -- PrettyUI's title gold: the heading and the underline

-------------------------------------------------------------------------------
-- State (one grid window at a time)
-------------------------------------------------------------------------------

local window = nil          -- the grid's PrettyUI Window, while the gear exists
local gear = nil            -- the gear SpriteButton
local underline = nil       -- the gold line under the gear, shown while the page is open
local page = nil            -- the page's parts: { root, radio }
local handlers = nil        -- { lines, onLines, onOpen } from attach
local hubRadio = nil        -- the radio on the client's settings page, once it has been opened

-------------------------------------------------------------------------------
-- Shared
-------------------------------------------------------------------------------

-- The choices from filters.LINES, in the form PrettyUI wants ({ value,
-- text }), like LINES.map(e => ({ value: e.id, text: e.label })) in JS.
local function lineChoices()
    local choices = {}
    for index, entry in ipairs(filters.LINES) do
        choices[index] = { value = entry.id, text = entry.label }
    end
    return choices
end

-- Calls onLines(value), logging an error instead of losing it (like
-- try/catch). For the radios' onChange, which the game calls directly.
local function pickLines(onLines, value)
    local ok, err = pcall(onLines, value)
    if not ok then
        log("[error] settings: " .. tostring(err))
    end
end

-------------------------------------------------------------------------------
-- 1. The client's settings page
-------------------------------------------------------------------------------

-- Fills the client's settings layer. lines is the choice to show ("two"
-- or "one"); onLines(linesId) is called when the player picks one.
function gridsettings.fillHub(layer, lines, onLines)
    local view = prettyui.SimpleView.new(layer, {
        categoryID = "auto",    -- PrettyUI picks free component IDs (its "Component IDs" docs)
        x = MARGIN,
        y = MARGIN,
        width = (layer.width or 300) - 2 * MARGIN,
        height = (layer.height or 400) - 2 * MARGIN,
    })
    view:AddTitle("Cells")
    -- onChange(radio, value) runs when the player picks a choice. Kept, so
    -- a choice made on the grid's page can show here too.
    hubRadio = view:AddRadioButton(lineChoices(), {
        selectedValue = lines,
        onChange = function(_, value) pickLines(onLines, value) end,
    })
    return view
end

-------------------------------------------------------------------------------
-- 2. The grid window's gear and page
-------------------------------------------------------------------------------

-- Builds the page, hidden. left / top: where the window's inside starts
-- (its side border, and the title bar's height).
local function buildPage(left, top)
    local root = parts.new(ui.Layer, window.root)
    root.hidden = true
    root:SetPos(left, top)
    root:SetSize(-2 * left, -top - left, 1.0, 1.0)  -- (width, height, anchors): the window's inside
    root.clickthrough = false                       -- takes the mouse, so the cells under it don't
    parts.rectangle(root, true, PAGE_BG)

    local heading = parts.text(root, PAD, PAD, 0, HEADING_HEIGHT, nil, id.Font.MUSEO_SANS_13PT_BOLD)
    heading:SetSize(-2 * PAD, HEADING_HEIGHT, 1.0, 0)
    heading.content = "Cells"
    heading.rgba = GOLD

    local radio = prettyui.RadioButton.new(root, lineChoices(), {
        x = PAD, y = PAD + HEADING_HEIGHT + 2,
        width = -2 * PAD, widthAnchor = 1.0,        -- as wide as the page
        selectedValue = handlers.lines(),
        onChange = function(_, value) pickLines(handlers.onLines, value) end,
    })
    page = { root = root, radio = radio }
end

-- The gear and its underline, on the window, anchored to its right edge
-- (the last SetPos argument, 1.0, measures x from the right).
local function buildGear()
    gear = prettyui.SpriteButton.new(window.root, "SETTINGS", function()
        local ok, err = pcall(function()
            if gridsettings.isOpen() then
                gridsettings.close()
            else
                gridsettings.open()
            end
        end)
        if not ok then
            log("[error] settings: " .. tostring(err))
        end
    end, { size = GEAR_SIZE, x = GEAR_X, y = GEAR_Y, xAnchor = 1.0, tooltip = "Settings" })

    underline = parts.new(ui.Rectangle, window.root)
    underline:SetPos(GEAR_X, UNDERLINE_Y, 1.0)
    underline:SetSize(GEAR_SIZE, 2)
    underline.fill = true
    underline.rgba = GOLD
    underline.clickthrough = true
    underline.hidden = true

    -- Keep the window's title text clear of the gear.
    if window.titleText ~= nil then
        pcall(function() window.titleText:SetSize(TITLE_WIDTH, TITLE_HEIGHT - 4, 1.0, 0) end)
    end
end

-- Builds the gear and the (hidden) page on newWindow. left / top: where
-- the window's inside starts. newHandlers:
--   lines()           the choice to show ("two" or "one")
--   onLines(linesId)  the player picked one
--   onOpen()          the page is about to show (to close open lists)
-- Throws if something is missing; grid.lua then calls gridsettings.detach
-- and goes on without the gear.
function gridsettings.attach(newWindow, left, top, newHandlers)
    window, handlers = newWindow, newHandlers
    buildPage(left, top)
    buildGear()
    gridsettings.onLogic()
end

function gridsettings.isOpen()
    return page ~= nil and page.root.hidden == false
end

-- Shows the page in front of everything else on the window, with the
-- current choice (it may have changed on the client's settings page).
function gridsettings.open()
    if page == nil then
        return
    end
    handlers.onOpen()
    page.radio:SetSelectedValue(handlers.lines(), false)   -- false: don't call onChange
    page.root.hidden = false
    page.root:MoveToFront()
    gear.root:MoveToFront()     -- the page covers the window's inside, not the title bar, but to be sure
    underline.hidden = false
end

function gridsettings.close()
    if page ~= nil then
        page.root.hidden = true
        underline.hidden = true
    end
end

-- Shows a choice on both pages without calling onChange, after it was
-- picked on one of them. The client may have cleared its page since (its
-- radio is then gone), so each update is in a pcall.
function gridsettings.showLines(lines)
    if hubRadio ~= nil then
        pcall(function() hubRadio:SetSelectedValue(lines, false) end)   -- false: don't call onChange
    end
    if page ~= nil then
        pcall(function() page.radio:SetSelectedValue(lines, false) end)
    end
end

-- Called every frame (50 a second) by ui/grid.lua: keeps PrettyUI's drag
-- strip short of the gear (see the header). Only touches it when PrettyUI
-- has made it longer again, after a drag or a resize.
function gridsettings.onLogic()
    local strip = window and window.titleDrag
    if strip == nil or window.dragFeedback ~= nil then
        return          -- no strip, or a drag is going on (it covers the screen then)
    end
    local width = window.root.width + GEAR_X - DRAG_GAP     -- the gear's left edge, minus a gap
    if strip.width ~= width then
        strip:SetSize(width, TITLE_HEIGHT)
    end
end

-- Removes the gear and the page (they are on the window, but the window
-- can stay while they go, e.g. after an error). Each part may be missing
-- (after a half-finished attach), so each removal is in a pcall.
function gridsettings.detach()
    if gear ~= nil then
        pcall(function() gear:Destroy() end)
    end
    if underline ~= nil then
        pcall(function() underline:Destroy() end)
    end
    if page ~= nil then
        pcall(function() page.root:Destroy() end)
    end
    window, gear, underline, page, handlers = nil, nil, nil, nil, nil
end

return gridsettings
