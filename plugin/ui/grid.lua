--[[
    ui/grid.lua
    -----------
    The world grid: every world as a small one-line cell ("[icon] w104  29m")
    in a floating, resizable PrettyUI Window over the game. An icon AND a
    colour show what the world is doing (the icon for colour-blind
    players; see ui/icons.lua); the countdown is to the tree's death (or its spawn,
    full growth, or the rewards going); hovering shows everything we know.
    A card at the top of the window shows the clicked world (or the one
    you're on) in full. It stays put: only the cells under it scroll.
    core/overview.lua decides the words (overview.cells); this file only
    draws them.

    How it is drawn (tried out first in the local "grid lab"):
      - Each cell is a few plain game components: a Layer (takes the mouse)
        holding a background Rectangle, an outline Rectangle, two Sprites
        (one icon slot: a sprite and an item icon) and two Texts. 137
        cells is about 1000 components (the grid lab built 700 without a
        freeze).
      - Cells (and the card) are built ONCE, then only changed in place: a countdown
        text, a colour. Like setting element.textContent in vanilla JS,
        with no re-render. Countdowns show whole minutes, so most cells
        change once a minute. The cells are rebuilt only if the set of
        worlds changes (e.g. a world that isn't in data/worlds.lua appears).
      - Cells are placed by hand: columns = window width / cell width. When
        the window is resized, they are moved (not rebuilt). The height is
        the player's choice: a short window scrolls, a tall one has space.
      - The card stays visible while the cells scroll: see pinCard. The
        window's scroll area (viewport + scrollbar) is moved down by the
        card's height, and the card sits in the space left above it.

    Opening: main.lua calls grid.update once a second. While the player
    wants the grid open, update opens the window if it isn't there yet (so
    it comes back by itself after a reload or world hop) and refreshes it.
    Where the window was, and whether it was open, is passed back through
    grid.setOnLayoutChange so main.lua can save it.
]]

local overview = require("core/overview")
local icons = require("ui/icons")

local grid = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

-- A cell: [icon] w259  ~1h 18m   (the icon space is kept even when empty)
local CELL_WIDTH = 98           -- icon + "w259" + "~1h 18m" (72 overlapped "w259" and "1h18m")
local CELL_HEIGHT = 18
local ICON_SIZE = 14            -- a cell's icon
local NAME_X = 3 + ICON_SIZE + 3 -- the world number starts after the icon slot
local GAP = 3                   -- between cells
local PAD = 6                   -- around everything

-- The card (the selected world, at the top). Four lines:
--   w204                                   [P2P]   (white outline: you're on it)
--   [icon] Evil willow - 45%               <- status, in the cell's colour
--   East of the house portal in Rellekka   <- place
--   Lightning in 4:05  -  Dies in 24:05    <- countdown
local CARD_HEIGHT = 80
local CARD_INNER = 8            -- text margin inside the card
local BADGE_WIDTH, BADGE_HEIGHT = 32, 16
local CARD_ICON_SIZE = 18
local STATUS_Y = 25             -- the status line
local CARD_SPACE = PAD + CARD_HEIGHT    -- the window space the card takes, above the scroll area

local DEFAULT_X, DEFAULT_Y = 60, 80
local DEFAULT_WIDTH = 934       -- 9 columns: 16 (window edges) + 2 * PAD + 9 * CELL_WIDTH + 8 * GAP
local DEFAULT_HEIGHT = 430     -- 380 before the card, plus room for it
-- Minimum height: title bar (32) + the card (86) + a scroll area tall
-- enough for the scrollbar's two arrows and a row of cells (~60) + bottom edge (8).
local MIN_WIDTH, MIN_HEIGHT = 200, 190

-- Where a colour is "PrettyUI's", it is copied from PrettyUI v1.3.0's own
-- widgets (it has no public palette), so the grid matches its look: warm
-- browns and golds rather than cool greys.

-- Text colour of a cell's countdown, by overview's cell.kind. Softer than
-- pure hues so they sit well on the brown cells.
local MUTED = 0x8B8882FF                -- PrettyUI's disabled text
local KIND_COLOURS = {
    unknown = MUTED,            -- no intel
    none = MUTED,               -- intel (a hint) but nothing due
    spawn = 0x8FB8DEFF,         -- soft blue: spawn timer
    sapling = 0xF0DC5AFF,       -- yellow
    alive = 0x7CC04AFF,         -- green (PrettyUI's buff green, brightened for text)
    dead = 0xD9786FFF,          -- red: rewards left (PrettyUI's chart red, brightened)
}
local NAME_COLOUR = 0xE7D7B0FF          -- PrettyUI's body text: every world number
local CARD_WORLD_COLOUR = 0xFFFFFFFF    -- the card's big world number
local BADGE_COLOUR = 0xF2C66DFF         -- PrettyUI's title gold: "P2P" / "F2P"
local COUNTDOWN_COLOUR = 0xF0A050FF     -- the card's countdown: warm orange
local PLACE_COLOUR = 0xAFA27FFF
local CARD_BG = 0x221F1BF5              -- a shade lighter than the cells
local CELL_BG = 0x171512E8              -- PrettyUI's list background
local CELL_BG_HOVER = 0x393530F2        -- PrettyUI's hover
local CELL_BG_SELECTED = 0x4A4640FF     -- PrettyUI's selected
local BORDER_P2P = 0x8A6A2AFF
local BORDER_F2P = 0x2A6A8AFF
local BORDER_OTHER = 0x716B61FF         -- PrettyUI's frame; not in our world list (beta worlds)
local BORDER_CURRENT = 0xFFFFFFFF       -- the world you're on
local BORDER_SELECTED = 0xF2C66DFF      -- the world you clicked

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local wantOpen = false      -- the player wants the grid (survives the window closing)
local window = nil          -- the PrettyUI Window, while it's on screen
local card = nil            -- the card's components (see buildCard), while the window is open
local views = {}            -- one table per cell on screen, in world order
local viewsByWorld = {}     -- viewsByWorld[204] = that view
local worldsKey = nil       -- the world numbers the cells were built for, as text
local laidOutWidth = nil    -- content width at the last layout
local gridTop = PAD         -- y of the first row of cells in the scroll area (see pinCard)
local selectedWorld = nil   -- the clicked world, or nil
local lastCells, lastNow, lastTotal = nil, nil, nil   -- the latest update's data
local titleText = nil
local sampleMode = false    -- showing made-up data (core/sampledata.lua): say so in the title
local onLayoutChange = nil  -- function(state), set by main.lua
local placement = { x = DEFAULT_X, y = DEFAULT_Y, width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT }
local reported = nil        -- the last state passed to onLayoutChange, as text

-------------------------------------------------------------------------------
-- Saving where the window is
-------------------------------------------------------------------------------

-- Passes the window's place, size and open state to main.lua (to save),
-- but only when something changed.
local function reportLayout()
    if window ~= nil and window.root ~= nil then
        placement.width = window.root.width
        placement.height = window.root.height
    end
    local state = {
        x = placement.x, y = placement.y,
        width = placement.width, height = placement.height,
        open = wantOpen and 1 or 0,
    }
    -- %d needs whole numbers; sizes can be floats like 776.0.
    local key = string.format("%d,%d,%d,%d,%d", math.floor(state.x), math.floor(state.y),
        math.floor(state.width), math.floor(state.height), state.open)
    if key ~= reported then
        reported = key
        if onLayoutChange ~= nil then
            onLayoutChange(state)
        end
    end
end

-------------------------------------------------------------------------------
-- Text for a cell
-------------------------------------------------------------------------------

-- Hover text: everything, unabbreviated, e.g.
-- "w204 - Evil willow - 45% | Lightning in 4:05 | West of Falador".
local function tooltipText(cell, now)
    local parts = { cell.heading }
    local countdown = overview.countdownText(cell, now)
    if countdown ~= nil then
        parts[#parts + 1] = countdown
    end
    -- The cell counts to the death, so say when that is too.
    local death = overview.deathText(cell, now)
    if death ~= nil then
        parts[#parts + 1] = death
    end
    if cell.place ~= nil then
        parts[#parts + 1] = cell.place
    end
    if cell.noIntel then
        parts[#parts + 1] = "No intel"
    end
    return table.concat(parts, " | ")
end

local function borderColour(cell)
    if cell.world == selectedWorld then return BORDER_SELECTED end
    if cell.current then return BORDER_CURRENT end
    if cell.members == true then return BORDER_P2P end
    if cell.members == false then return BORDER_F2P end
    return BORDER_OTHER
end

-- Sets a cell's background: selected beats hovered beats plain. Only
-- touches the game component when the colour actually changes.
local function refreshBackground(view)
    local colour = CELL_BG
    if view.world == selectedWorld then
        colour = CELL_BG_SELECTED
    elseif view.hovered then
        colour = CELL_BG_HOVER
    end
    if colour ~= view.backgroundColour then
        view.background.rgba = colour
        view.backgroundColour = colour
    end
end

-------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------

-- prettyui.NewComponent(type, parent) is ui.<Type>.new(parent) plus a free
-- component ID (PrettyUI tracks IDs; see its "Component IDs" docs).
local function newRectangle(parent, fill, colour)
    local rectangle = prettyui.NewComponent(ui.Rectangle, parent)
    rectangle:SetSize(0, 0, 1.0, 1.0)       -- (width, height, widthAnchor, heightAnchor): fill the parent
    rectangle.fill = fill                   -- false: just the outline
    rectangle.rgba = colour
    rectangle.clickthrough = true           -- let the mouse reach the cell underneath
    return rectangle
end

-- A one-line Text. alignHorizontal BOTTOMRIGHT puts the text on the right
-- (the game's align modes are shared by both directions). font is
-- optional: the small 11pt font if left out.
local function newText(parent, x, y, width, height, alignHorizontal, font)
    local text = prettyui.NewComponent(ui.Text, parent)
    text:SetPos(x, y)
    text:SetSize(width, height)
    text.font = font or id.Font.MUSEO_SANS_11PT_REGULAR
    text.isShadowed = true
    text.alignHorizontal = alignHorizontal or ui.AlignMode.TOPLEFT
    text.alignVertical = ui.AlignMode.CENTRE
    text.maxLines = 1                       -- too long: cut off with "..."
    text.clickthrough = true
    text.content = ""
    return text
end

local render     -- defined below; declared here so the click handler can call it

-- Clicking a cell selects it (its details go in the header); clicking it
-- again unselects it.
local function onCellClick(world)
    if selectedWorld == world then
        selectedWorld = nil
    else
        selectedWorld = world
    end
    if lastCells ~= nil then
        local ok, err = pcall(render, lastCells, lastNow, lastTotal)
        if not ok then
            log("[error] grid click: " .. tostring(err))
        end
    end
end

-- One cell's components. view.cell is updated every second with the
-- latest data from overview.cells, so the hover text is always fresh.
local function buildView(cell)
    local view = { world = cell.world, cell = cell }
    local textWidth = CELL_WIDTH - 6            -- 3 units of margin each side

    view.root = prettyui.NewComponent(ui.Layer, window.content)
    view.root:SetSize(CELL_WIDTH, CELL_HEIGHT)
    view.root.clickthrough = false
    view.background = newRectangle(view.root, true, CELL_BG)
    view.border = newRectangle(view.root, false, BORDER_OTHER)
    -- The icon slot comes first and is always kept, so the world numbers line up down the grid.
    view.icon = icons.new(view.root, 3, 2, ICON_SIZE)
    view.name = newText(view.root, NAME_X, 1, CELL_WIDTH - NAME_X - 3, CELL_HEIGHT - 2)
    view.name.content = "w" .. cell.world
    view.name.rgba = NAME_COLOUR
    view.timer = newText(view.root, 3, 1, textWidth, CELL_HEIGHT - 2, ui.AlignMode.BOTTOMRIGHT)

    -- Tooltip. Giving our own hover handlers lets us also highlight the
    -- cell; then we Show/Hide the tooltip ourselves.
    view.tooltip = prettyui.Tooltip.attach(view.root, window.content, { text = "", maxWidth = 300 }, {
        onMouseOver = function(tip)
            pcall(function()
                view.hovered = true
                refreshBackground(view)
                tip:SetText(tooltipText(view.cell, lastNow))
                tip:Show()
            end)
        end,
        onMouseLeave = function(tip)
            pcall(function()
                view.hovered = false
                refreshBackground(view)
                tip:Hide()
            end)
        end,
    })

    -- Subscribe(hook, id, fn): the id lets several handlers share one hook
    -- (the tooltip has its own). Returning false is what PrettyUI's buttons do.
    view.root:Subscribe(ui.Hook.ONCLICK, "evilTreesGrid", function()
        onCellClick(view.world)
        return false
    end)

    -- Mouse wheel: a cell that takes the mouse also takes the wheel, so we
    -- hand it on to the window, as PrettyUI does for its own children.
    -- _onScrollWheel is PrettyUI's internal handler (checked in v1.3.0);
    -- without it, the wheel only works over the scrollbar.
    if window._onScrollWheel ~= nil then
        view.root:Subscribe(ui.Hook.ONSCROLLWHEEL, "evilTreesGrid", window._onScrollWheel)
    end
    return view
end

-- The world numbers as one text, e.g. "1,2,4,5,...,204". If it changes,
-- the cells must be rebuilt.
local function keyOf(cells)
    local numbers = {}
    for index, cell in ipairs(cells) do
        numbers[index] = cell.world
    end
    return table.concat(numbers, ",")
end

-- Removes all cells (when the set of worlds changes).
local function destroyViews()
    for _, view in ipairs(views) do
        pcall(function() view.root:Destroy() end)
    end
    views = {}
    viewsByWorld = {}
end

local function buildViews(cells)
    destroyViews()
    for index, cell in ipairs(cells) do
        local view = buildView(cell)
        views[index] = view
        viewsByWorld[cell.world] = view
    end
    worldsKey = keyOf(cells)
    laidOutWidth = nil          -- place them on the next layout
end

-- Makes room for the card ABOVE the window's scroll area, so the card
-- doesn't scroll away with the cells. Returns the parent for the card and
-- the card's x, y in it.
--
-- A PrettyUI Window keeps everything that scrolls (the viewport, the
-- content and the scrollbar) in one Layer, window._scroll.root, placed
-- just under the title bar and stretched to the window's edges. We move
-- that Layer down by CARD_SPACE and shrink it by the same amount. PrettyUI
-- reads the Layer's place and size whenever it lays out the scrollbar
-- (also on every resize), so the scrollbar, the mouse wheel and the hover
-- tooltips all follow. _scroll is PrettyUI's internal field (checked in
-- v1.3.0, like _onScrollWheel below): if a future PrettyUI doesn't have
-- it, the card goes back into the scrolling content (and scrolls).
local function pinCard()
    local scroll = window._scroll
    local area = scroll and scroll.root     -- like window._scroll?.root in JS
    if area == nil or area.x == nil or area.y == nil or scroll.Refresh == nil then
        gridTop = CARD_SPACE + PAD          -- the cells start under the card
        return window.content, PAD, PAD
    end

    local left, top = area.x, area.y        -- the window's side border, title bar height
    -- The anchors (1.0, 1.0) make the size "the window's size + these
    -- numbers", so it still follows resizes. The bottom border is as thick
    -- as the side ones (8), as in PrettyUI's window.lua.
    area:SetPos(left, top + CARD_SPACE)
    area:SetSize(-2 * left, -(top + CARD_SPACE) - left, 1.0, 1.0)
    scroll:Refresh()                        -- lay the scrollbar out for the new height
    gridTop = PAD
    -- The card goes straight on the window, in the space left above.
    return window.root, left + PAD, top + PAD
end

-- The card: built once when the window opens, then filled in by
-- updateCard. Two anchor tricks (as in PrettyUI's own widgets):
--   SetSize(w, h, 1.0, 0)   width = the parent's full width + w, so a
--                           negative w leaves a margin and it follows resizes
--   SetPos(x, y, 1.0, 0)    x is measured from the parent's RIGHT edge
local function buildCard()
    local parent, x, y = pinCard()          -- a function can return several values
    card = {}
    card.root = prettyui.NewComponent(ui.Layer, parent)
    card.root:SetPos(x, y)
    card.root:SetSize(-2 * x, CARD_HEIGHT, 1.0, 0)  -- the same margin on both sides
    card.root.clickthrough = true       -- nothing on the card takes the mouse
    card.background = newRectangle(card.root, true, CARD_BG)
    card.border = newRectangle(card.root, false, BORDER_OTHER)

    -- A full-width line of text at height y.
    local function line(y, height, font)
        local text = newText(card.root, CARD_INNER, y, 0, height, nil, font)
        text:SetSize(-2 * CARD_INNER, height, 1.0, 0)
        return text
    end

    card.world = line(5, 20, id.Font.MUSEO_SANS_13PT_BOLD)
    card.world.rgba = CARD_WORLD_COLOUR

    -- Right end of the first line: the P2P badge.
    local badgeX = -(CARD_INNER + BADGE_WIDTH)
    card.badgeBorder = prettyui.NewComponent(ui.Rectangle, card.root)
    card.badgeBorder:SetPos(badgeX, 7, 1.0, 0)
    card.badgeBorder:SetSize(BADGE_WIDTH, BADGE_HEIGHT)
    card.badgeBorder.fill = false
    card.badgeBorder.rgba = BADGE_COLOUR
    card.badgeBorder.clickthrough = true
    card.badge = newText(card.root, 0, 7, BADGE_WIDTH, BADGE_HEIGHT, ui.AlignMode.CENTRE)
    card.badge:SetPos(badgeX, 7, 1.0, 0)
    card.badge.rgba = BADGE_COLOUR

    -- Status line: the icon, then the text (moved right by updateCard
    -- when there is an icon).
    card.statusIcon = icons.new(card.root, CARD_INNER, STATUS_Y, CARD_ICON_SIZE)
    card.status = line(STATUS_Y, 18, id.Font.MUSEO_SANS_13PT_BOLD)
    card.place = line(43, 16)
    card.place.rgba = PLACE_COLOUR
    card.countdown = line(59, 16)
    card.countdown.rgba = COUNTDOWN_COLOUR
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

local function contentWidth()
    local width = window.content and window.content.width
    if width == nil or width <= 0 then
        width = window.root.width - 16
    end
    return width
end

-- Places every cell for the window's width (moving, not rebuilding). The
-- window's height is left alone.
local function layout()
    local width = contentWidth()
    -- math.floor also turns 10.0 into the integer 10 (Lua 5.4).
    local columns = math.max(1, math.floor((width - 2 * PAD + GAP) / (CELL_WIDTH + GAP)))
    for index, view in ipairs(views) do
        local column = (index - 1) % columns    -- % is the remainder, like JS
        local row = (index - 1) // columns      -- // divides and rounds down
        view.root:SetPos(PAD + column * (CELL_WIDTH + GAP), gridTop + row * (CELL_HEIGHT + GAP))
    end
    local rows = (#views + columns - 1) // columns  -- rounds up
    local contentHeight = gridTop + rows * (CELL_HEIGHT + GAP) - GAP + PAD
    window:SetContentHeight(contentHeight)     -- how far it scrolls
    laidOutWidth = width
end

-------------------------------------------------------------------------------
-- Updating
-------------------------------------------------------------------------------

-- Changes only what differs from what's on screen.
local function updateView(view, cell, now)
    view.cell = cell
    local timer = overview.cellCountdown(cell, now) or ""
    if timer ~= view.timerText then
        view.timer.content = timer
        view.timerText = timer
    end
    if cell.kind ~= view.kind then
        view.kind = cell.kind
        view.timer.rgba = KIND_COLOURS[cell.kind] or MUTED
    end
    icons.set(view.icon, cell.icon, cell.logs)     -- only redraws if it changed
    local border = borderColour(cell)
    if border ~= view.borderColour then
        view.border.rgba = border
        view.borderColour = border
    end
    refreshBackground(view)
end

-- The card's outline: white on the world you're on, else P2P gold / F2P
-- blue, like the cells.
local function cardBorderColour(cell)
    if cell.current then return BORDER_CURRENT end
    if cell.members == true then return BORDER_P2P end
    if cell.members == false then return BORDER_F2P end
    return BORDER_OTHER
end

-- Shows the card's status icon for a cell (nil: none) and moves the
-- status text to just after it.
local function setCardIcons(shown)
    -- "shown and shown.icon" is nil when no world is shown (like shown?.icon in JS).
    local hasIcon = icons.set(card.statusIcon, shown and shown.icon, shown and shown.logs)
    local x = CARD_INNER
    if hasIcon then
        x = x + CARD_ICON_SIZE + 4
    end
    if x ~= card.statusX then
        card.status:SetPos(x, STATUS_Y)
        card.status:SetSize(-(x + CARD_INNER), 18, 1.0, 0)  -- the rest of the width
        card.statusX = x
    end
end

-- Fills the card with one cell, or a hint to click one if shown is nil.
local function updateCard(shown, now)
    setCardIcons(shown)
    if shown == nil then
        card.world.content = ""
        card.badge.content = ""
        card.badgeBorder.hidden = true
        card.status.content = "Click a world for details."
        card.status.rgba = MUTED
        card.place.content = ""
        card.countdown.content = ""
        card.border.rgba = BORDER_OTHER
        return
    end

    card.world.content = "w" .. shown.world
    -- members is nil for worlds not in data/worlds.lua: no badge.
    if shown.members == nil then
        card.badge.content = ""
        card.badgeBorder.hidden = true
    else
        card.badge.content = shown.members and "P2P" or "F2P"
        card.badgeBorder.hidden = false
    end
    card.border.rgba = cardBorderColour(shown)

    card.status.content = shown.noIntel and "Nothing known yet." or (shown.status or "")
    card.status.rgba = KIND_COLOURS[shown.kind] or MUTED
    card.place.content = shown.place or ""

    -- "Lightning in 4:05  -  Dies in 24:05": the death time as well, when
    -- the next event is a strike.
    local countdown = overview.countdownText(shown, now) or ""
    local death = overview.deathText(shown, now)
    if death ~= nil then
        countdown = countdown .. "  -  " .. death
    end
    card.countdown.content = countdown
end

-- The title, and the card: the clicked world, else the one you're on.
local function updateHeader(cells, now, total)
    local scouted = 0
    local shown = nil
    for _, cell in ipairs(cells) do
        if cell.kind ~= "unknown" then
            scouted = scouted + 1
        end
        if cell.world == selectedWorld or (selectedWorld == nil and cell.current) then
            shown = cell
        end
    end

    local title = "Evil Trees - " .. scouted .. " / " .. total .. " scouted"
    if sampleMode then
        title = title .. " (sample)"     -- short: the title bar cuts off long titles
    end
    if title ~= titleText then
        window:SetTitle(title)
        titleText = title
    end

    updateCard(shown, now)
end

-- Draws the latest data. cells from overview.cells, now the time (or nil),
-- total the number of worlds tracked.
render = function(cells, now, total)
    lastCells, lastNow, lastTotal = cells, now, total
    if keyOf(cells) ~= worldsKey then
        buildViews(cells)
    end
    for _, cell in ipairs(cells) do
        updateView(viewsByWorld[cell.world], cell, now)
    end
    updateHeader(cells, now, total)
    if contentWidth() ~= laidOutWidth then
        layout()
    end
    reportLayout()      -- saves a new size if the player resized it
end

-------------------------------------------------------------------------------
-- Opening and closing
-------------------------------------------------------------------------------

-- Forgets the window (after it was closed or destroyed).
local function forgetWindow()
    window = nil
    card = nil
    views, viewsByWorld = {}, {}
    worldsKey, laidOutWidth, titleText = nil, nil, nil
end

-- Creates the window. Returns false if the game area isn't there yet
-- (e.g. on the login screen); update tries again a second later.
local function createWindow()
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if parent == nil then
        return false
    end
    window = prettyui.Window.new(parent, {
        categoryID = "auto",
        title = "Evil Trees",
        x = placement.x, y = placement.y,
        width = placement.width, height = placement.height,
        resizable = true,
        minWidth = MIN_WIDTH, minHeight = MIN_HEIGHT,
        destroyOnClose = true,          -- free the ~700 components while closed
        onClose = function()
            -- The player closed it with the X.
            wantOpen = false
            reportLayout()
            forgetWindow()
        end,
        onPositionChange = function(_, x, y)
            placement.x, placement.y = x, y
            reportLayout()
        end,
    })
    buildCard()
    return true
end

-- Removes the window without counting it as "closed by the player" (so it
-- reopens after a reload).
local function destroyWindow()
    if window ~= nil then
        pcall(function() window:Destroy() end)
    end
    forgetWindow()
end

-------------------------------------------------------------------------------
-- For main.lua
-------------------------------------------------------------------------------

-- The saved state from store.gridWindow (or nil): where the window was,
-- and whether to open it.
function grid.restore(state)
    if type(state) ~= "table" then
        return
    end
    -- "a or b": use b when a is nil (like a ?? b in JS).
    placement.x = state.x or DEFAULT_X
    placement.y = state.y or DEFAULT_Y
    placement.width = state.width or DEFAULT_WIDTH
    placement.height = state.height or DEFAULT_HEIGHT
    wantOpen = (state.open == 1)
end

-- fn(state) is called with { x, y, width, height, open = 1 or 0 } when any
-- of them changes.
function grid.setOnLayoutChange(fn)
    onLayoutChange = fn
end

-- True while the player wants the grid open (main.lua then builds the data).
function grid.wantsOpen()
    return wantOpen
end

-- Opens or closes the grid (the dashboard's "All worlds" button).
function grid.toggle()
    if window ~= nil then
        pcall(function() window:Close() end)    -- runs onClose above
        if window ~= nil then                   -- Close failed
            wantOpen = false
            destroyWindow()
            reportLayout()
        end
        return
    end
    wantOpen = true
    reportLayout()
end

-- True while main.lua passes made-up data (the debug "Sample data" button),
-- so the title can say so.
function grid.setSampleMode(on)
    sampleMode = on
end

-- Called about once a second by main.lua. cells from overview.cells.
function grid.update(cells, now, total)
    if not wantOpen then
        return
    end
    local ok, err = pcall(function()
        if window == nil and not createWindow() then
            return              -- no game area yet; try again next second
        end
        render(cells, now, total)
    end)
    if not ok then
        -- Something is wrong (e.g. a PrettyUI version without a call we
        -- use). Stop trying, so the console isn't flooded every second.
        log("[error] grid: " .. tostring(err) .. " (grid closed)")
        destroyWindow()
        wantOpen = false
        reportLayout()
    end
end

-- Called when the plugin shuts down. Keeps wantOpen, so the grid comes
-- back after a reload or world hop.
function grid.destroy()
    destroyWindow()
end

return grid
