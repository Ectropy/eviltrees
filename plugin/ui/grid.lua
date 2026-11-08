--[[
    ui/grid.lua
    -----------
    The world grid: every world as a small one-line cell ("w104   29m") in a
    floating, resizable PrettyUI Window over the game. Colour shows what
    the world is doing; hovering shows everything we know; clicking a cell
    shows its details at the top of the window. core/overview.lua decides
    the words (overview.cells); this file only draws them.

    How it is drawn (tried out first in the local "grid lab"):
      - Each cell is a few plain game components: a Layer (takes the mouse)
        holding a background Rectangle, an outline Rectangle and two Texts.
        137 cells is about 700 components, which builds without a freeze.
      - Cells are built ONCE and then only changed in place: a countdown
        text, a colour. Like setting element.textContent in vanilla JS,
        with no re-render. Countdowns show whole minutes, so most cells
        change once a minute. The cells are rebuilt only if the set of
        worlds changes (e.g. a world that isn't in data/worlds.lua appears).
      - Cells are placed by hand: columns = window width / cell width. When
        the window is resized, they are moved (not rebuilt). The height is
        the player's choice: a short window scrolls, a tall one has space.

    Opening: main.lua calls grid.update once a second. While the player
    wants the grid open, update opens the window if it isn't there yet (so
    it comes back by itself after a reload or world hop) and refreshes it.
    Where the window was, and whether it was open, is passed back through
    grid.setOnLayoutChange so main.lua can save it.
]]

local overview = require("core/overview")

local grid = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

local CELL_WIDTH = 84           -- fits "w259" and "1h18m" side by side (72 overlapped)
local CELL_HEIGHT = 18
local GAP = 3                   -- between cells
local PAD = 6                   -- around everything
local LINE_HEIGHT = 16          -- one header line
local TOP = PAD + 2 * LINE_HEIGHT + 4   -- the grid starts under the two header lines

local DEFAULT_X, DEFAULT_Y = 60, 80
local DEFAULT_WIDTH = 808       -- 9 columns
local DEFAULT_HEIGHT = 380
local MIN_WIDTH, MIN_HEIGHT = 200, 120

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
local HEADER_COLOUR = 0xF2C66DFF        -- PrettyUI's title gold
local PLACE_COLOUR = 0xAFA27FFF
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
local headerTop, headerBottom = nil, nil    -- the two header Texts
local views = {}            -- one table per cell on screen, in world order
local viewsByWorld = {}     -- viewsByWorld[204] = that view
local worldsKey = nil       -- the world numbers the cells were built for, as text
local laidOutWidth = nil    -- content width at the last layout
local selectedWorld = nil   -- the clicked world, or nil
local lastCells, lastNow, lastTotal = nil, nil, nil   -- the latest update's data
local titleText = nil
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
    if cell.current then
        parts[1] = parts[1] .. " (you're here)"
    end
    local countdown = overview.countdownText(cell, now)
    if countdown ~= nil then
        parts[#parts + 1] = countdown
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
-- (the game's align modes are shared by both directions).
local function newText(parent, x, y, width, height, alignHorizontal)
    local text = prettyui.NewComponent(ui.Text, parent)
    text:SetPos(x, y)
    text:SetSize(width, height)
    text.font = id.Font.MUSEO_SANS_11PT_REGULAR
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
    view.name = newText(view.root, 3, 1, textWidth, CELL_HEIGHT - 2)
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
        view.root:SetPos(PAD + column * (CELL_WIDTH + GAP), TOP + row * (CELL_HEIGHT + GAP))
    end
    local rows = (#views + columns - 1) // columns  -- rounds up
    local contentHeight = TOP + rows * (CELL_HEIGHT + GAP) - GAP + PAD
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
    local border = borderColour(cell)
    if border ~= view.borderColour then
        view.border.rgba = border
        view.borderColour = border
    end
    refreshBackground(view)
end

-- The header: the clicked world, else the one you're on, else a hint.
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
    if title ~= titleText then
        window:SetTitle(title)
        titleText = title
    end

    if shown == nil then
        headerTop.content = "Click a world for details."
        headerBottom.content = ""
        return
    end
    local top = shown.heading .. (shown.current and " (you're here)" or "")
    local countdown = overview.countdownText(shown, now)
    if countdown ~= nil then
        top = top .. "  -  " .. countdown
    end
    headerTop.content = top
    headerBottom.content = shown.place or (shown.noIntel and "Nothing known yet." or "")
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
    headerTop, headerBottom = nil, nil
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
    headerTop = newText(window.content, PAD, PAD, 300, LINE_HEIGHT)
    headerTop:SetSize(-2 * PAD, LINE_HEIGHT, 1.0, 0)    -- the window's width minus the padding
    headerTop.rgba = HEADER_COLOUR
    headerBottom = newText(window.content, PAD, PAD + LINE_HEIGHT, 300, LINE_HEIGHT)
    headerBottom:SetSize(-2 * PAD, LINE_HEIGHT, 1.0, 0)
    headerBottom.rgba = PLACE_COLOUR
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
