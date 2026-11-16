--[[
    ui/grid.lua
    -----------
    The world grid: every world as a small one-line cell ("[icon] w104  29m")
    in a floating, resizable PrettyUI Window over the game. An icon AND a
    colour show what the world is doing (the icon for colour-blind
    players; see ui/icons.lua); the countdown is to the tree's death (or its spawn,
    full growth, or the rewards going); hovering shows everything we know.
    When a tree's type is known, the cell says it too: "w104 Elder 29m"
    (a sapling's as well: its icon and colour say it is a sapling).
    World numbers are coloured like the game's world list (gold P2P, white
    F2P), dimmed for worlds we know nothing about. The world you're on has
    a thick sky-blue outline; the clicked one a gold outline.
    A card at the top of the window shows the clicked world (or the one
    you're on) in full (ui/worldcard.lua). Its texts wrap, so the card
    grows taller for a long place; the toolbar and cells then move down. Under it, a toolbar sorts and filters the cells
    (ui/gridtoolbar.lua). The card and toolbar stay put: only the cells
    under them scroll.
    core/overview.lua decides the words (overview.cells) and
    core/filters.lua which cells show, in which order; this file only
    draws them.

    How it is drawn (tried out first in the local "grid lab"):
      - Each cell is a few plain game components: a Layer (takes the mouse)
        holding a background Rectangle, an outline Rectangle, two Sprites
        (one icon slot: a sprite and an item icon) and three Texts (world
        number, tree type, countdown). 137 cells is about 1100 components (the grid lab built 700 without a
        freeze).
      - Cells (and the card) are built ONCE, then only changed in place: a countdown
        text, a colour. Like setting element.textContent in vanilla JS,
        with no re-render. Countdowns show whole minutes, so most cells
        change once a minute. The cells are rebuilt only if the set of
        worlds changes (e.g. a world that isn't in data/worlds.lua appears).
      - Sorting and filtering only move and hide cells: every world has a
        cell, filters.apply says which show and in which order, and the
        others get hidden = true. While something is filtered, a line under
        the last cell says so, with a "remove filters." link.
      - Cells are placed by hand: as many columns as fit at the narrowest
        cell width, then the cells are stretched to share out the space
        left over. The narrowest width is measured from the game's font
        (see measureCells), so the longest world number, tree type and
        countdown never overlap. The space for the tree type is only as
        wide as the widest type on show ("Oak" needs less than "Willow"),
        and none is kept while no type is known, so the grid stays compact. When the window is resized, the cells are moved and
        stretched (not rebuilt). The height is the player's choice: a
        short window scrolls, a tall one has space.
      - The card and toolbar stay visible while the cells scroll: see
        pinScrollArea. The window's scroll area (viewport + scrollbar) is
        moved down by their height, and they sit in the space left above
        it. When the toolbar wraps onto more rows, the scroll area moves
        down again and the window's minimum height grows.

    Opening: main.lua calls grid.update once a second. While the player
    wants the grid open, update opens the window if it isn't there yet (so
    it comes back by itself after a reload or world hop) and refreshes it.
    Where the window was, and whether it was open, is passed back through
    grid.setOnLayoutChange so main.lua can save it; the sort and filters
    go through grid.setOnViewChange. main.lua also calls grid.onLogic every
    frame, so an open dropdown notices a click elsewhere at once.

    If the toolbar fails (e.g. a PrettyUI version without something it
    uses), the grid shows every world without it, and logs one line.
]]

local overview = require("core/overview")
local filters = require("core/filters")
local colours = require("ui/colours")
local icons = require("ui/icons")
local parts = require("ui/parts")
local worldcard = require("ui/worldcard")
local gridtoolbar = require("ui/gridtoolbar")

local grid = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

-- A cell: [icon] w259 Willow  ~1h 18m   (the icon space is kept even when empty)
-- Its width is measured (measureCells); these are used only if the game
-- can't measure text. 98 was too narrow for "w204 ~1h 49m".
local FALLBACK_CELL_WIDTH = 112     -- without a tree type
local FALLBACK_NAME_WIDTH = 30      -- "w259"
local FALLBACK_TYPE_WIDTH = 40      -- "Willow"
local CELL_HEIGHT = 18
local ICON_SIZE = 14            -- a cell's icon
local NAME_X = 3 + ICON_SIZE + 3 -- the world number starts after the icon slot
local TEXT_GAP = 6              -- at least this much space between the world number and the countdown
local CELL_FONT = parts.FONT     -- the cells' font (id.Font for drawing, config.Font for measuring)
local GAP = 3                   -- between cells
local PAD = 6                   -- around everything

-- The card (the selected world, at the top): see ui/worldcard.lua. Its
-- height changes with its texts: see cardHeight in State.
local TOOLBAR_GAP = 6           -- between the card and the toolbar

-- The filter notice under the last cell: "Showing 40 of 137 worlds. To
-- see more, remove filters." ("remove filters." is a link).
local NOTICE_GAP = 4            -- between the last row of cells and the notice
local NOTICE_HEIGHT = 16        -- one line
local LINK_GAP = 4              -- between the notice's text and its link
local LINK_TEXT = "remove filters."

local DEFAULT_X, DEFAULT_Y = 60, 80
local DEFAULT_WIDTH = 934       -- about 9 columns (8 or 9, depending on the measured cell width)
local DEFAULT_HEIGHT = 430     -- 380 before the card, plus room for it
-- Minimum height: title bar (32) + the card (86) + a scroll area tall
-- enough for the scrollbar's two arrows and a row of cells (~64) + bottom
-- edge (8). It grows with the toolbar's rows (see setMinimumHeight).
local MIN_WIDTH, MIN_HEIGHT = 200, 190
local MIN_SCROLL_HEIGHT = 64

-- Colours are 0xRRGGBBAA. The ones shared with the card and the ribbon
-- page are in ui/colours.lua; these are only the grid's.
local MUTED = colours.MUTED
local CELL_BG = 0x171512E8              -- PrettyUI's list background
local CELL_BG_HOVER = 0x393530F2        -- PrettyUI's hover
local CELL_BG_SELECTED = 0x4A4640FF     -- PrettyUI's selected
local LINK_COLOUR = 0xF2C66DFF          -- PrettyUI's title gold: "remove filters."
local LINK_HOVER_COLOUR = 0xFFE9A8FF    -- the link, brighter while the mouse is on it

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
local visibleKey = nil      -- the shown cells' world numbers, in order, at the last layout
-- Text widths, measured once per set of worlds (measureCells): base is the
-- narrowest a cell can be without a tree type, name the widest world
-- number, type the widest tree type word there can be ("Willow").
local sizes = { base = FALLBACK_CELL_WIDTH, name = FALLBACK_NAME_WIDTH, type = FALLBACK_TYPE_WIDTH }
local typeWidth = 0         -- the widest tree type text on show now (0: none, cells are then narrower)
local wordWidths = {}       -- wordWidths["Elder"] = its measured width, worked out once per word
local minCellWidth = FALLBACK_CELL_WIDTH  -- the narrowest a cell can be now
local gridTop = PAD         -- y of the first row of cells in the scroll area (see buildCard)
local pin = nil             -- where PrettyUI put the scroll area, { left, top }, or nil if it can't be moved
local notice = nil          -- the filter notice's parts (buildNotice), while the window is open
local hasToolbar = false    -- true while the toolbar is on screen and working
local toolbarHeight = 0     -- its rows' height at the last refresh
local cardHeight = worldcard.MIN_HEIGHT     -- the card's height now (it grows when its texts wrap)
local selectedWorld = nil   -- the clicked world, or nil
local lastCells, lastNow, lastTotal = nil, nil, nil   -- the latest update's data
local titleText = nil
local sampleMode = false    -- showing made-up data (core/sampledata.lua): say so in the title
local onLayoutChange = nil  -- function(state), set by main.lua
local placement = { x = DEFAULT_X, y = DEFAULT_Y, width = DEFAULT_WIDTH, height = DEFAULT_HEIGHT }
local reported = nil        -- the last state passed to onLayoutChange, as text

-- The sort and filters (see core/filters.lua). They survive the window
-- closing, and are saved through onViewChange.
local prefs = filters.defaults()
local NO_FILTERS = filters.defaults()   -- used while there is no toolbar (never changed)
local onViewChange = nil    -- function(state), set by main.lua
local reportedView = nil    -- the last state passed to onViewChange, as text

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
-- The sort and filters
-------------------------------------------------------------------------------

-- The prefs as they are saved: four strings, with the trees joined by
-- commas ("yew,magic", or "" for any tree). Plain strings avoid saving an
-- empty table or a list through PersistentDB.
local function savedForm(chosen)
    return {
        sort = chosen.sort,
        worlds = chosen.worlds,
        info = chosen.info,
        trees = table.concat(chosen.trees, ","),    -- trees.join(",")
    }
end

local function viewKey(state)
    return state.sort .. "|" .. state.worlds .. "|" .. state.info .. "|" .. state.trees
end

-- Passes the prefs to main.lua (to save), but only when they changed.
local function reportView()
    local state = savedForm(prefs)
    local key = viewKey(state)
    if key ~= reportedView then
        reportedView = key
        if onViewChange ~= nil then
            onViewChange(state)
        end
    end
end

-- The prefs to draw with. Without a toolbar, nothing may be hidden: the
-- player would have no way to see those worlds again.
local function activePrefs()
    if hasToolbar then
        return prefs
    end
    return NO_FILTERS
end

-------------------------------------------------------------------------------
-- Text for a cell
-------------------------------------------------------------------------------

-- Hover text: everything, unabbreviated, e.g.
-- "w204 - Evil willow - 45% | Lightning in 4m 5s | West of Falador".
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

-- A cell's outline: gold if clicked, sky blue on your world, else plain.
-- (P2P / F2P is the world number's colour, as in the game's world list.)
local function borderColour(cell)
    if cell.world == selectedWorld then return colours.SELECTED end
    if cell.current then return colours.CURRENT end
    return colours.FRAME
end

-- Shows or hides a cell's "you're here" mark: a second outline just inside
-- the first, so your world's outline is twice as thick. The thickness can
-- be seen without telling colours apart, and it stays when the cell is
-- also the clicked one (gold outside, sky blue inside). Made the first
-- time a cell needs it: only one world is ever yours.
local function setCurrentMark(view, isCurrent)
    if isCurrent and view.currentMark == nil then
        view.currentMark = parts.rectangle(view.root, false, colours.CURRENT)
        view.currentMark:SetPos(1, 1)
        view.currentMark:SetSize(-2, -2, 1.0, 1.0)  -- the cell's size minus 1 on every side
    end
    if view.currentMark ~= nil then
        local hidden = not isCurrent
        if view.currentMark.hidden ~= hidden then
            view.currentMark.hidden = hidden
        end
    end
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

local render     -- defined below; declared here so the click handlers can call it

-- Draws the latest data again straight away (after a click), instead of
-- waiting for the next update. what names the click for the error log.
local function redraw(what)
    if window == nil or lastCells == nil then
        return
    end
    local ok, err = pcall(render, lastCells, lastNow, lastTotal)
    if not ok then
        log("[error] grid " .. what .. ": " .. tostring(err))
    end
end

-- Clicking a cell selects it (its details go in the header); clicking it
-- again unselects it.
local function onCellClick(world)
    if selectedWorld == world then
        selectedWorld = nil
    else
        selectedWorld = world
    end
    redraw("click")
end

-- One cell's components. view.cell is updated every second with the
-- latest data from overview.cells, so the hover text is always fresh.
local function buildView(cell)
    local view = { world = cell.world, cell = cell }

    -- The width is set by layout (cells stretch to fill the row).
    -- Everything inside follows it: the rectangles fill the cell, and the
    -- texts use the anchor trick from buildCard (width = the cell's
    -- width + a negative number), so a wider cell needs no changes here.
    view.root = prettyui.NewComponent(ui.Layer, window.content)
    view.root:SetSize(minCellWidth, CELL_HEIGHT)
    view.root.clickthrough = false
    view.background = parts.rectangle(view.root, true, CELL_BG)
    view.border = parts.rectangle(view.root, false, colours.FRAME)
    -- The icon slot comes first and is always kept, so the world numbers line up down the grid.
    view.icon = icons.new(view.root, 3, 2, ICON_SIZE)
    view.name = parts.text(view.root, NAME_X, 1, 0, CELL_HEIGHT - 2)
    view.name:SetSize(-(NAME_X + 3), CELL_HEIGHT - 2, 1.0, 0)  -- to 3 units from the right edge
    view.name.content = "w" .. cell.world     -- its colour is set by updateView
    -- The countdown, on the right (3 units of margin each side).
    view.timer = parts.text(view.root, 3, 1, 0, CELL_HEIGHT - 2, ui.AlignMode.BOTTOMRIGHT)
    view.timer:SetSize(-6, CELL_HEIGHT - 2, 1.0, 0)
    -- The tree type ("Elder"), after the widest world number, so the types
    -- line up down the grid like a table column. Its box fits the widest
    -- type there can be. Empty until a type is known.
    view.type = parts.text(view.root, NAME_X + sizes.name + TEXT_GAP, 1, sizes.type + 2, CELL_HEIGHT - 2)

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
    -- window._onScrollWheel is PrettyUI's handler
    -- (PrettyUI v1.3.0 internal); without it, the wheel only works over
    -- the scrollbar.
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

-- How wide text is in the cells' font, or nil if the game can't say
-- (config.Font.<name>:GetStringWidth, as PrettyUI uses for its own
-- buttons; pcall in case it's missing, e.g. in the tests).
local function textWidth(text)
    local ok, width = pcall(function()
        return config.Font[CELL_FONT]:GetStringWidth(text, false)
    end)
    if ok and type(width) == "number" then
        return width
    end
    return nil
end

-- Measures the cells' texts, for the widths in "sizes" (see State).
-- base is the narrowest a cell can be without its texts overlapping: the
-- icon slot, the widest world number, a gap, and the widest countdown there
-- can be. Countdowns look like "~1h 49m", "~29m" or "45s"
-- (overview.cellCountdown); the longest is "~Xh XXm". Digits aren't all
-- the same width in this font, so we build that countdown from the
-- widest digit: no real countdown can be wider. Returns the fallbacks if
-- the game can't measure. Called once per set of worlds (in buildViews).
local function measureCells(cells)
    local fallback = { base = FALLBACK_CELL_WIDTH, name = FALLBACK_NAME_WIDTH, type = FALLBACK_TYPE_WIDTH }

    local widestDigit, digitWidth = nil, -1
    for digit = 0, 9 do
        local width = textWidth(tostring(digit))
        if width == nil then
            return fallback                 -- can't measure: use safe guesses
        end
        if width > digitWidth then
            widestDigit, digitWidth = tostring(digit), width
        end
    end
    local d = widestDigit
    local timerWidth = textWidth("~" .. d .. "h " .. d .. d .. "m")

    local nameWidth = 0
    for _, cell in ipairs(cells) do
        nameWidth = math.max(nameWidth, textWidth("w" .. cell.world) or 0)
    end
    -- The widest tree type word. pairs walks a table's keys and values in
    -- no fixed order (like Object.entries in JS); "_" ignores the key.
    local widestType = 0
    for _, word in pairs(overview.TYPE_WORDS) do
        widestType = math.max(widestType, textWidth(word) or 0)
    end
    if timerWidth == nil or nameWidth == 0 or widestType == 0 then
        return fallback
    end
    -- math.ceil rounds up to a whole number (widths may have fractions).
    return {
        base = math.ceil(NAME_X + nameWidth + TEXT_GAP + timerWidth + 3),
        name = math.ceil(nameWidth),
        type = math.ceil(widestType),
    }
end

-- How wide one tree type word is ("Elder"), remembered so each word
-- is measured once. If the game can't measure, the widest there can be.
local function wordWidth(word)
    if wordWidths[word] == nil then
        local width = textWidth(word)
        wordWidths[word] = width and math.ceil(width) or sizes.type
    end
    return wordWidths[word]
end

-- Sets the narrowest cell width for the widest tree type on show (0: no
-- type is shown). A type needs its text and one more gap.
local function setTypeWidth(width)
    typeWidth = width
    minCellWidth = sizes.base + (width > 0 and (width + TEXT_GAP) or 0)
    laidOutWidth = nil          -- place the cells again on the next layout
end

local function buildViews(cells)
    destroyViews()
    sizes = measureCells(cells)
    wordWidths = {}             -- measured again with the new sizes
    setTypeWidth(typeWidth)
    for index, cell in ipairs(cells) do
        local view = buildView(cell)
        views[index] = view
        viewsByWorld[cell.world] = view
    end
    worldsKey = keyOf(cells)
end

-- Pinning: the card and the toolbar sit ABOVE the window's scroll area,
-- so they don't scroll away with the cells.
--
-- A PrettyUI Window keeps everything that scrolls (the viewport, the
-- content and the scrollbar) in one Layer, window._scroll.root, placed
-- just under the title bar and stretched to the window's edges. We move
-- that Layer down and shrink it by the same amount. PrettyUI reads the
-- Layer's place and size whenever it lays out the scrollbar (also on every
-- resize), so the scrollbar, the mouse wheel and the hover tooltips all
-- follow. window._scroll (PrettyUI v1.3.0 internal, like _onScrollWheel
-- below): if a future PrettyUI doesn't have it, the card goes back into
-- the scrolling content (and scrolls), with no toolbar.

-- Remembers where PrettyUI put the scroll area (left = the window's side
-- border, top = the title bar's height). Done once per window, so moving
-- it again later starts from the same place instead of adding up.
local function findScrollArea()
    local scroll = window._scroll
    local area = scroll and scroll.root     -- like window._scroll?.root in JS
    if area == nil or area.x == nil or area.y == nil or scroll.Refresh == nil then
        pin = nil
    else
        pin = { left = area.x, top = area.y }
    end
end

-- The window space above the scroll area: the card, and the toolbar's rows.
local function pinnedSpace()
    local space = PAD + cardHeight
    if hasToolbar then
        space = space + TOOLBAR_GAP + toolbarHeight
    end
    return space
end

-- Sets the window's minimum height, and makes the window taller if it is
-- now below it. window.minHeight (used by SetSize) and
-- window.resize.minHeight (used while the player drags an edge) are
-- PrettyUI's own fields (PrettyUI v1.3.0 internal); if they are missing,
-- the minimum stays MIN_HEIGHT and only the taller window remains.
local function setMinimumHeight(height)
    if window.minHeight ~= nil then
        window.minHeight = height
    end
    if window.resize ~= nil and window.resize.minHeight ~= nil then
        window.resize.minHeight = height
    end
    if window.root.height < height then
        window:SetSize(window.root.width, height)
    end
end

-- Moves the scroll area down to just under the card and toolbar. Called
-- when the window opens and whenever the toolbar's height changes.
local function pinScrollArea()
    local space = pinnedSpace()
    local area = window._scroll.root
    -- The anchors (1.0, 1.0) make the size "the window's size + these
    -- numbers", so it still follows resizes. The bottom border is as thick
    -- as the side ones (8), as in PrettyUI's window.lua.
    area:SetPos(pin.left, pin.top + space)
    area:SetSize(-2 * pin.left, -(pin.top + space) - pin.left, 1.0, 1.0)
    window._scroll:Refresh()                -- lay the scrollbar out for the new height
    setMinimumHeight(pin.top + space + MIN_SCROLL_HEIGHT + pin.left)
end

-- The card (ui/worldcard.lua): built once when the window opens, then
-- filled in by updateHeader.
local function buildCard()
    -- Pinned: straight on the window, in the space above the scroll area,
    -- and the cells start at the top of the scroll area. Not pinned: at
    -- the top of the scrolling content, with the cells under it.
    local parent, x, y = window.content, PAD, PAD
    cardHeight = worldcard.MIN_HEIGHT       -- a new card starts at its smallest
    gridTop = PAD + cardHeight + PAD
    if pin ~= nil then
        parent, x, y = window.root, pin.left + PAD, pin.top + PAD
        gridTop = PAD
    end
    card = worldcard.new(parent, x, y)
end

local resetFilters      -- defined with the toolbar below; declared here so the link can call it

-- Shows the link brighter while the mouse is on it.
local function setLinkHover(hovered)
    notice.linkHovered = hovered
    notice.linkText.rgba = hovered and LINK_HOVER_COLOUR or LINK_COLOUR
end

-- The filter notice under the cells (placed by showNotice): a muted Text,
-- then the link, a small Layer that takes the mouse holding a gold Text.
-- Hidden until something is filtered.
local function buildNotice()
    notice = {}
    notice.text = parts.text(window.content, PAD, 0, 1, NOTICE_HEIGHT)
    notice.text.rgba = MUTED
    notice.text.hidden = true

    -- "or": if the game can't measure text, guess 6 per letter.
    notice.linkWidth = math.ceil(textWidth(LINK_TEXT) or #LINK_TEXT * 6) + 2
    notice.link = prettyui.NewComponent(ui.Layer, window.content)
    notice.link:SetSize(notice.linkWidth, NOTICE_HEIGHT)
    notice.link.clickthrough = false
    notice.link.hidden = true
    notice.linkText = parts.text(notice.link, 0, 0, notice.linkWidth, NOTICE_HEIGHT)
    notice.linkText.content = LINK_TEXT
    setLinkHover(false)

    notice.link:Subscribe(ui.Hook.ONMOUSEOVER, "evilTreesGrid", function()
        setLinkHover(true)
        return false
    end)
    notice.link:Subscribe(ui.Hook.ONMOUSELEAVE, "evilTreesGrid", function()
        setLinkHover(false)
        return false
    end)
    notice.link:Subscribe(ui.Hook.ONCLICK, "evilTreesGrid", function()
        local ok, err = pcall(resetFilters)
        if not ok then
            log("[error] grid remove filters: " .. tostring(err))
        end
        return false
    end)
    -- The wheel, handed to the window as for the cells (see buildView).
    if window._onScrollWheel ~= nil then
        notice.link:Subscribe(ui.Hook.ONSCROLLWHEEL, "evilTreesGrid", window._onScrollWheel)
    end
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

-- How wide the card is on screen: its parent's width minus the margins
-- buildCard gave it. (The card needs it to wrap its texts.)
local function cardWidth()
    if pin ~= nil then
        return window.root.width - 2 * (pin.left + PAD)
    end
    return contentWidth() - 2 * PAD
end

-- Forgets every hovered cell: hides its tooltip and its hover colour. A
-- cell that moves or hides may never get its "mouse leave", so this runs
-- before cells are moved.
local function clearHover()
    for _, view in ipairs(views) do
        if view.hovered then
            view.hovered = false
            refreshBackground(view)
            if view.tooltip ~= nil then
                view.tooltip:Hide()
            end
        end
    end
end

local function hideNotice()
    notice.text.hidden = true
    notice.link.hidden = true
    if notice.linkHovered then
        setLinkHover(false)     -- a hidden link may never get its "mouse leave"
    end
end

-- Shows the filter notice at y = top. "remove filters." goes right after
-- the text, or on the next line if the row is too narrow. shown / total:
-- how many worlds are shown, out of how many. Returns the y just under it.
local function showNotice(top, rowWidth, shown, total)
    notice.text.hidden = false
    notice.link.hidden = false
    local prefix = "No worlds match. To see more,"
    if shown > 0 then
        prefix = string.format("Showing %d of %d worlds. To see more,", shown, total)
    end
    if prefix ~= notice.prefix then
        notice.prefix = prefix
        notice.text.content = prefix
        notice.prefixWidth = math.ceil(textWidth(prefix) or #prefix * 6)
    end
    -- The text box is never wider than the row: a very narrow window cuts
    -- the text off ("...") rather than spilling over.
    notice.text:SetPos(PAD, top)
    notice.text:SetSize(math.min(notice.prefixWidth + 2, rowWidth), NOTICE_HEIGHT)
    if notice.prefixWidth + LINK_GAP + notice.linkWidth > rowWidth then
        notice.link:SetPos(PAD, top + NOTICE_HEIGHT)    -- on the next line
        return top + 2 * NOTICE_HEIGHT
    end
    notice.link:SetPos(PAD + notice.prefixWidth + LINK_GAP, top)
    return top + NOTICE_HEIGHT
end

-- Places the visible cells (from filters.apply, in that order) for the
-- window's width, and hides the others. Only moves and hides: nothing is
-- rebuilt. The window's height is left alone.
local function layout(visible)
    local width = contentWidth()
    -- math.floor also turns 10.0 into the integer 10 (Lua 5.4).
    local rowWidth = width - 2 * PAD            -- the space for one row of cells
    -- As many columns as fit at the narrowest width (n cells have n - 1 gaps)...
    local columns = math.max(1, math.floor((rowWidth + GAP) / (minCellWidth + GAP)))
    -- ...then share out the whole row between them, so they stretch to
    -- fill it. (A few units can be left over on the right, from rounding.)
    local cellWidth = math.max(minCellWidth, math.floor((rowWidth - (columns - 1) * GAP) / columns))

    clearHover()
    local shown = {}            -- a set of the views placed: shown[view] = true
    for index, cell in ipairs(visible) do
        local view = viewsByWorld[cell.world]
        shown[view] = true      -- a table can be a key, like a Map in JS
        local column = (index - 1) % columns    -- % is the remainder, like JS
        local row = (index - 1) // columns      -- // divides and rounds down
        view.root:SetPos(PAD + column * (cellWidth + GAP), gridTop + row * (CELL_HEIGHT + GAP))
        view.root:SetSize(cellWidth, CELL_HEIGHT)
        if view.root.hidden then
            view.root.hidden = false
        end
    end
    for _, view in ipairs(views) do
        if not shown[view] and not view.root.hidden then
            view.root.hidden = true
        end
    end

    -- bottom: the y just under the last thing drawn.
    local rows = (#visible + columns - 1) // columns    -- rounds up
    local bottom = gridTop
    if rows > 0 then
        bottom = gridTop + rows * (CELL_HEIGHT + GAP) - GAP
    end
    -- While filtering, say so under the cells (in the scrolling content).
    if filters.isFiltering(activePrefs()) then
        local top = bottom
        if rows > 0 then
            top = bottom + NOTICE_GAP
        end
        bottom = showNotice(top, rowWidth, #visible, #views)
    else
        hideNotice()
    end
    window:SetContentHeight(bottom + PAD)     -- how far it scrolls
    laidOutWidth = width
    visibleKey = keyOf(visible)
end

-------------------------------------------------------------------------------
-- The toolbar (drawn by ui/gridtoolbar.lua)
-------------------------------------------------------------------------------

-- Removes a toolbar that failed and shows every world without it, with no
-- filters, so no world is hidden with no way to show it again. The
-- player's saved choices are kept for next time.
local function dropToolbar(err)
    log("[error] grid toolbar: " .. tostring(err) .. " (showing the grid without it)")
    pcall(gridtoolbar.destroy)
    hasToolbar = false
    toolbarHeight = 0
    visibleKey = nil            -- lay the cells out again, now unfiltered
    pinScrollArea()             -- the scroll area moves back up under the card
end

-- After the player changes the sort or a filter: save, and draw again.
local function viewChanged()
    reportView()
    -- Lay the cells out again even if the same ones show: the notice may
    -- need to come or go.
    visibleKey = nil
    redraw("toolbar")
end

-- The toolbar's onChange: group is "sort", "worlds", "info" or "trees".
local function setPref(group, value)
    -- A copy with one field changed (like { ...prefs, [group]: value } in
    -- JS), made valid by filters.normalize (unknown values fall back).
    local changed = { sort = prefs.sort, worlds = prefs.worlds, info = prefs.info, trees = prefs.trees }
    changed[group] = value
    prefs = filters.normalize(changed)
    viewChanged()
end

-- Reset, and the notice's "remove filters." link: clears Worlds, Info and
-- Tree. The sort is never reset. (Assigned to the local declared above
-- buildNotice.)
resetFilters = function()
    local cleared = filters.defaults()
    cleared.sort = prefs.sort
    prefs = cleared
    if hasToolbar then
        local ok, err = pcall(gridtoolbar.showPrefs, prefs)
        if not ok then
            dropToolbar(err)
        end
    end
    viewChanged()
end

-- Builds the toolbar under the card. host is what the window is on (the
-- game area): the toolbar draws its lists and popup there. Only when the
-- card is pinned: without that, the toolbar would have no fixed place.
local function buildToolbar(host)
    if pin == nil then
        return
    end
    local x, y = pin.left + PAD, pin.top + PAD + cardHeight + TOOLBAR_GAP
    local ok, err = pcall(gridtoolbar.build, window, host, x, y, prefs,
        { onChange = setPref, onReset = resetFilters })
    toolbarHeight = 0           -- known after the first refresh
    hasToolbar = ok
    if not ok then
        dropToolbar(err)
    end
end

-- Updates the toolbar's count and Tree text, and moves the scroll area
-- when the toolbar's height changes (it wraps onto more or fewer rows).
-- shown / total: how many worlds are shown, out of how many. Returns
-- false if the toolbar just failed (and was removed), else true.
local function refreshToolbar(shown, total)
    if not hasToolbar then
        return true
    end
    -- The rows are as wide as the card.
    local width = window.root.width - 2 * pin.left - 2 * PAD
    local ok, result = pcall(gridtoolbar.refresh, width, prefs, shown, total)
    if not ok then
        dropToolbar(result)
        return false
    end
    if result ~= toolbarHeight then
        toolbarHeight = result
        pinScrollArea()
    end
    return true
end

-- Removes the toolbar before its window goes: its lists and popup are on
-- the game area, so they would outlive the window.
local function destroyToolbar()
    if hasToolbar then
        pcall(gridtoolbar.destroy)
    end
    hasToolbar = false
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
    -- The tree type, when we know it ("" otherwise).
    local word = cell.typeWord or ""
    if word ~= view.typeText then
        view.type.content = word
        view.typeText = word
    end
    if cell.kind ~= view.kind then
        view.kind = cell.kind
        local colour = colours.KIND[cell.kind] or MUTED
        view.timer.rgba = colour
        view.type.rgba = colour
    end
    -- The world number: gold P2P / white F2P, dim while we know nothing.
    local nameColour = colours.world(cell.members, cell.kind == "unknown")
    if nameColour ~= view.nameColour then
        view.name.rgba = nameColour
        view.nameColour = nameColour
    end
    setCurrentMark(view, cell.current)
    icons.set(view.icon, cell.icon, cell.logs)     -- only redraws if it changed
    local border = borderColour(cell)
    if border ~= view.borderColour then
        view.border.rgba = border
        view.borderColour = border
    end
    refreshBackground(view)
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

    -- The card says how tall it is now. When that changes (a text wrapped
    -- onto more or fewer lines), move what is under it.
    local height = worldcard.update(card, shown, now, "Click a world for details.", cardWidth())
    if height ~= cardHeight then
        cardHeight = height
        if pin ~= nil then
            if hasToolbar then
                local ok, err = pcall(gridtoolbar.setTop, pin.top + PAD + cardHeight + TOOLBAR_GAP)
                if not ok then
                    dropToolbar(err)
                end
            end
            pinScrollArea()
        else
            gridTop = PAD + cardHeight + PAD    -- the card is in the scrolling content
            laidOutWidth = nil                  -- place the cells again, lower or higher
        end
    end
end

-- Draws the latest data. cells from overview.cells, now the time (or nil),
-- total the number of worlds tracked.
render = function(cells, now, total)
    lastCells, lastNow, lastTotal = cells, now, total
    if keyOf(cells) ~= worldsKey then
        buildViews(cells)
    end
    local widest = 0            -- the widest tree type text on show
    for _, cell in ipairs(cells) do
        updateView(viewsByWorld[cell.world], cell, now)
        if cell.typeWord ~= nil then
            widest = math.max(widest, wordWidth(cell.typeWord))
        end
    end
    -- Cells get wider when a wider type word appears (the first type, or
    -- "Willow" after only "Oak"), and narrower again when it goes. Rare:
    -- the cells are then placed again.
    if widest ~= typeWidth then
        setTypeWidth(widest)
    end
    updateHeader(cells, now, total)

    -- Which cells show, in which order. The toolbar's count ("40 / 137")
    -- is out of every cell, beta worlds included, so it can be more than
    -- the title's total.
    local visible = filters.apply(cells, activePrefs())
    if not refreshToolbar(#visible, #cells) then
        visible = filters.apply(cells, activePrefs())   -- the toolbar just failed: show every world
    end
    -- Lay out again when the order changes (e.g. Soonest, as timers pass)
    -- or the width does.
    if keyOf(visible) ~= visibleKey or contentWidth() ~= laidOutWidth then
        layout(visible)
    end
    reportLayout()      -- saves a new size if the player resized it
end

-------------------------------------------------------------------------------
-- Opening and closing
-------------------------------------------------------------------------------

-- Forgets the window (after it was closed or destroyed).
local function forgetWindow()
    window = nil
    card, notice, pin = nil, nil, nil
    views, viewsByWorld = {}, {}
    worldsKey, laidOutWidth, visibleKey, titleText = nil, nil, nil, nil
    hasToolbar, toolbarHeight = false, 0
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
            -- The player closed it with the X. (PrettyUI destroys the
            -- window right after this.)
            wantOpen = false
            reportLayout()
            destroyToolbar()
            forgetWindow()
        end,
        onPositionChange = function(_, x, y)
            placement.x, placement.y = x, y
            reportLayout()
        end,
    })
    findScrollArea()
    if pin ~= nil then
        pinScrollArea()
    end
    buildCard()
    buildNotice()
    buildToolbar(parent)
    return true
end

-- Removes the window without counting it as "closed by the player" (so it
-- reopens after a reload).
local function destroyWindow()
    destroyToolbar()
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

-- The saved sort and filters from store.gridView (or nil), in the form
-- onViewChange gives them: { sort = "soonest", worlds = "all",
-- info = "any", trees = "yew,magic" }. Anything odd or out of date falls
-- back to the default (filters.normalize). Call before the window opens.
function grid.restoreView(state)
    local saved = {}
    if type(state) == "table" then
        saved.sort, saved.worlds, saved.info = state.sort, state.worlds, state.info
        saved.trees = {}
        if type(state.trees) == "string" then
            -- "[^,]+" matches each run of characters that aren't commas, so
            -- this is like state.trees.split(",") in JS (skipping empty parts).
            for key in string.gmatch(state.trees, "[^,]+") do
                saved.trees[#saved.trees + 1] = key
            end
        end
    end
    prefs = filters.normalize(saved)
    reportedView = viewKey(savedForm(prefs))    -- nothing new to save yet
end

-- fn(state) is called with the sort and filters (see grid.restoreView for
-- the form) when the player changes them.
function grid.setOnViewChange(fn)
    onViewChange = fn
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

-- Called every frame (50 a second) by main.lua, so the toolbar notices a
-- dropdown opening straight away (see gridtoolbar.onLogic). Does nothing
-- while there is no toolbar. If it fails, the toolbar is removed, so the
-- error is logged once, not 50 times a second.
function grid.onLogic()
    if not hasToolbar then
        return
    end
    local ok, err = pcall(gridtoolbar.onLogic)
    if not ok then
        dropToolbar(err)
    end
end

-- Called when the plugin shuts down. Keeps wantOpen, so the grid comes
-- back after a reload or world hop.
function grid.destroy()
    destroyWindow()
end

return grid
