--[[
    ui/gridsettings.lua
    -------------------
    The plugin's settings, in two places that show the same choices:

        Cells
        (o) Two lines
        ( ) One line
        World card
        (o) Above the grid
        ( ) Left of the grid
        ( ) Right of the grid

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
    once (gridsettings.showChoice, called by ui/grid.lua).

    Each setting is one entry in SETTINGS below: a heading and a radio,
    made from one of core/filters.lua's lists (LINES, CARD). Adding a
    setting is adding an entry there. This file only draws: ui/grid.lua
    keeps the choices and saves them. (The world card's place can also be
    changed with the arrows on the card itself: see ui/grid.lua.)

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
        (PrettyUI 1.3.0 internals): without them the gear is still
        drawn, but the title bar may take its clicks.
      - The page is a Layer on the window with a solid background, in front
        of the card, toolbar and cells, so it hides them and takes the
        mouse. Nothing under it is hidden or changed, so closing it just
        hides the page.
]]

local filters = require("core/filters")
local colours = require("ui/colours")
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
local RADIO_ROW = 22            -- one choice in a PrettyUI RadioButton (its ROW_HEIGHT)
local SECTION_GAP = 10          -- between one setting's radio and the next heading
local PAGE_BG = 0x1B1814FF      -- solid, close to the window's own background

-------------------------------------------------------------------------------
-- State (one grid window at a time)
-------------------------------------------------------------------------------

local window = nil          -- the grid's PrettyUI Window, while the gear exists
local gear = nil            -- the gear SpriteButton
local underline = nil       -- the gold line under the gear, shown while the page is open
local page = nil            -- the page's parts: { root, radios = { lines = radio, card = radio } }
local handlers = nil        -- { get, onPick, onOpen } from attach
local hubRadios = {}        -- the radios on the client's settings page, once it has been opened: hubRadios.card, ...

-------------------------------------------------------------------------------
-- Shared
-------------------------------------------------------------------------------

-- The settings, in the order they show. group is the prefs field it sets
-- (see core/filters.lua), title its heading, entries its choices.
local SETTINGS = {
    { group = "lines", title = "Cells", entries = filters.LINES },
    { group = "card", title = "World card", entries = filters.CARD },
}

-- A setting's choices in the form PrettyUI wants ({ value, text }), like
-- entries.map(e => ({ value: e.id, text: e.label })) in JS.
local function choicesOf(entries)
    local choices = {}
    for index, entry in ipairs(entries) do
        choices[index] = { value = entry.id, text = entry.label }
    end
    return choices
end

-- Calls onPick(group, value), logging an error instead of losing it (like
-- try/catch). For the radios' onChange, which the game calls directly.
local function pick(onPick, group, value)
    local ok, err = pcall(onPick, group, value)
    if not ok then
        log("[error] settings: " .. tostring(err))
    end
end

-- How tall the grid's settings page needs to be: each setting's heading
-- and radio, and the gaps (as buildPage stacks them). ui/grid.lua keeps
-- the window at least this tall inside.
function gridsettings.pageHeight()
    local height = PAD
    for _, setting in ipairs(SETTINGS) do
        height = height + HEADING_HEIGHT + 2 + #setting.entries * RADIO_ROW + SECTION_GAP
    end
    return height
end

-------------------------------------------------------------------------------
-- 1. The client's settings page
-------------------------------------------------------------------------------

-- Fills the client's settings layer. get(group) is the choice to show
-- for a setting (get("lines") is "two" or "one", get("card") is "top",
-- "left" or "right"); onPick(group, value) is called when the player
-- picks one.
function gridsettings.fillHub(layer, get, onPick)
    local view = prettyui.SimpleView.new(layer, {
        categoryID = "auto",    -- PrettyUI picks free component IDs (its "Component IDs" docs)
        x = MARGIN,
        y = MARGIN,
        width = (layer.width or 300) - 2 * MARGIN,
        height = (layer.height or 400) - 2 * MARGIN,
    })
    hubRadios = {}
    -- ipairs walks SETTINGS in order, like for...of; "_" ignores the index.
    for _, setting in ipairs(SETTINGS) do
        local group = setting.group     -- a fresh local per setting, so each onChange below keeps its own
        view:AddTitle(setting.title)
        -- onChange(radio, value) runs when the player picks a choice. Kept,
        -- so a choice made on the grid's page can show here too.
        hubRadios[group] = view:AddRadioButton(choicesOf(setting.entries), {
            selectedValue = get(group),
            onChange = function(_, value) pick(onPick, group, value) end,
        })
    end
    return view
end

-------------------------------------------------------------------------------
-- 2. The grid window's gear and page
-------------------------------------------------------------------------------

-- Builds the page, hidden. left / top: where the window's inside starts
-- (its side border, and the title bar's height).
local function buildPage(left, top)
    local root = prettyui.NewComponent(ui.Layer, window.root)
    root.hidden = true
    root:SetPos(left, top)
    root:SetSize(-2 * left, -top - left, 1.0, 1.0)  -- (width, height, anchors): the window's inside
    root.clickthrough = false                       -- takes the mouse, so the cells under it don't
    parts.rectangle(root, true, PAGE_BG)

    -- Each setting: a gold heading, then its radio, stacked downwards.
    local radios = {}
    local y = PAD
    for _, setting in ipairs(SETTINGS) do
        local group = setting.group
        local heading = parts.text(root, PAD, y, 0, HEADING_HEIGHT, nil, id.Font.MUSEO_SANS_13PT_BOLD)
        heading:SetSize(-2 * PAD, HEADING_HEIGHT, 1.0, 0)
        heading.content = setting.title
        heading.rgba = colours.GOLD
        y = y + HEADING_HEIGHT + 2

        radios[group] = prettyui.RadioButton.new(root, choicesOf(setting.entries), {
            x = PAD, y = y,
            width = -2 * PAD, widthAnchor = 1.0,        -- as wide as the page
            selectedValue = handlers.get(group),
            onChange = function(_, value) pick(handlers.onPick, group, value) end,
        })
        -- #setting.entries is the number of choices (# is a list's length).
        y = y + #setting.entries * RADIO_ROW + SECTION_GAP
    end
    page = { root = root, radios = radios }
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

    underline = prettyui.NewComponent(ui.Rectangle, window.root)
    underline:SetPos(GEAR_X, UNDERLINE_Y, 1.0)
    underline:SetSize(GEAR_SIZE, 2)
    underline.fill = true
    underline.rgba = colours.GOLD
    underline.clickthrough = true
    underline.hidden = true

    -- Keep the window's title text clear of the gear.
    if window.titleText ~= nil then
        pcall(function() window.titleText:SetSize(TITLE_WIDTH, TITLE_HEIGHT - 4, 1.0, 0) end)
    end
end

-- Builds the gear and the (hidden) page on newWindow. left / top: where
-- the window's inside starts. newHandlers:
--   get(group)            the choice to show for a setting (see fillHub)
--   onPick(group, value)  the player picked one
--   onOpen()              the page is about to show (to close open lists)
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
-- current choices (they may have changed on the client's settings page,
-- or with the card's arrows).
function gridsettings.open()
    if page == nil then
        return
    end
    handlers.onOpen()
    -- pairs walks a table's keys and values (like Object.entries in JS).
    for group, radio in pairs(page.radios) do
        radio:SetSelectedValue(handlers.get(group), false)  -- false: don't call onChange
    end
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

-- Shows a setting's choice on both pages without calling onChange, after
-- it was picked somewhere (one of the pages, or the card's arrows). group
-- is "lines" or "card". The client may have cleared its page since (its
-- radios are then gone), so each update is in a pcall.
function gridsettings.showChoice(group, value)
    if hubRadios[group] ~= nil then
        pcall(function() hubRadios[group]:SetSelectedValue(value, false) end)   -- false: don't call onChange
    end
    if page ~= nil and page.radios[group] ~= nil then
        pcall(function() page.radios[group]:SetSelectedValue(value, false) end)
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
