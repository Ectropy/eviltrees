--[[
    ui/grid.lua
    -----------
    The world grid: every world as a small cell in a floating, resizable
    PrettyUI Window over the game. A cell has one line ("[icon] w104  29m")
    or, by default, two (switched in the settings, ui/gridsettings.lua:
    the gear in the title bar, or the client's Settings icon):
        [icon] w104 Elder 45%   29m      <- line 1, plus the health
        West of Falador                  <- the place, cut off with "..."
    The health is just the number, also for "50% or less". An icon AND a
    colour show what the world is doing (the icon for colour-blind
    players; see ui/icons.lua); the countdown is to the tree's death (or
    its spawn, full growth, or the rewards going); hovering shows
    everything we know.
    When a tree's type is known, the cell says it too: "w104 Elder 29m"
    (a sapling's as well: its icon and colour say it is a sapling).
    World numbers are coloured like the game's world list (gold P2P, white
    F2P), dimmed for worlds we know nothing about. The world you're on has
    a thick sky-blue outline; the clicked one a gold outline.
    A card at the top of the window shows the clicked world (or the one
    you're on) in full (ui/worldcard.lua). Its texts wrap, so the card
    grows taller for a long place; the toolbar and cells then move down.
    Under it, a toolbar sorts and filters the cells (ui/gridtoolbar.lua).
    The card and toolbar stay put: only the cells under them scroll.
    For a wide, short grid the card can instead be a sidebar, a fixed
    SIDEBAR_WIDTH wide, on the left or right of the cells, with the
    toolbar under it, so the cells get the window's whole height
    (prefs.card: "top", "left" or "right"). Chosen in the settings, or with
    the arrows on the card's first line, as in EctoTrees: above the grid
    the card has "dock left" and "dock right"; as a sidebar, "move to the
    other side" and "back to the top". Where everything goes for each
    choice is worked out in one place: geometry().
    core/overview.lua decides the words (overview.cells) and
    core/filters.lua which cells show, in which order; this file only
    draws them.

    How it is drawn:
      - Each cell is a few plain game components: a Layer (takes the mouse)
        holding a background Rectangle, an outline Rectangle, two Sprites
        (one icon slot: a sprite and an item icon) and three Texts (world
        number, tree type, countdown); two-line cells add two more (health,
        place). 137 cells is about 1100 components, or 1370 with two lines.
        Switching lines rebuilds the cells.
      - Cells (and the card) are built ONCE, then only changed in place: a
        countdown text, a colour. Like setting element.textContent in JS,
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
        and none is kept while no type is known, so the grid stays
        compact. When the window is resized, the cells are moved and
        stretched (not rebuilt). The height is the player's choice: a
        short window scrolls, a tall one has space.
      - The card and toolbar stay visible while the cells scroll: see
        pinScrollArea. The window's scroll area (viewport + scrollbar) is
        moved down by their height, and they sit in the space left above
        it. When the toolbar wraps onto more rows, the scroll area moves
        down again and the window's minimum height grows. With the card
        as a sidebar, the card and toolbar sit beside the scroll area
        instead: it starts under the title bar and is narrowed (and moved
        right, for a left sidebar) to leave room for them.

    Opening: main.lua calls grid.update once a second. While the player
    wants the grid open, update opens the window if it isn't there yet (so
    it comes back by itself after a reload or world hop) and refreshes it.
    Where the window was, and whether it was open, is passed back through
    grid.setOnLayoutChange so main.lua can save it; the sort and filters
    go through grid.setOnViewChange. main.lua also calls grid.onLogic every
    frame, so an open dropdown notices a click elsewhere at once.

    If the toolbar fails (it relies on PrettyUI internals, which a future
    PrettyUI may change), the grid shows every world without it, and logs
    one line.
]]

local overview = require("core/overview")
local filters = require("core/filters")
local worlds = require("data/worlds")
local colours = require("ui/colours")
local icons = require("ui/icons")
local parts = require("ui/parts")
local worldcard = require("ui/worldcard")
local gridtoolbar = require("ui/gridtoolbar")
local gridsettings = require("ui/gridsettings")

local grid = {}

-------------------------------------------------------------------------------
-- Look (sizes in interface units, colours 0xRRGGBBAA)
-------------------------------------------------------------------------------

-- A cell: [icon] w259 Willow  ~1h 18m   (the icon space is kept even when empty)
-- Two lines:  [icon] w259 Willow 45%  ~1h 18m
--             West of Falador
-- Its width is measured (measureCells); these are used only if the game
-- can't measure text. 98 was too narrow for "w204 ~1h 49m".
local FALLBACK_CELL_WIDTH = 112     -- without a tree type
local FALLBACK_NAME_WIDTH = 30      -- "w259"
local FALLBACK_TYPE_WIDTH = 40      -- "Willow"
local CELL_HEIGHT = 18             -- a one-line cell
local TWO_LINE_HEIGHT = 34         -- a two-line cell
local PLACE_Y = 17                 -- two lines: where the second line starts
local PLACE_HEIGHT = 15            -- two lines: the second line's height
-- Two lines: the narrowest cell still shows this much of a place on its
-- second line (a made-up short place name; real names are often longer
-- and are cut off with "...").
local PLACE_SAMPLE = "S. Tree Gnome Stronghold"
local FALLBACK_HEALTH_WIDTH = 26   -- "100%"
local FALLBACK_SAMPLE_WIDTH = 140
local ICON_SIZE = 14            -- a cell's icon
local NAME_X = 3 + ICON_SIZE + 3 -- the world number starts after the icon slot
local TEXT_GAP = 6              -- at least this much space between the world number and the countdown
local CELL_FONT = parts.FONT     -- the cells' font (id.Font for drawing, config.Font for measuring)
local GAP = 3                   -- between cells
local PAD = 6                   -- around everything

-- The card (the selected world, at the top): see ui/worldcard.lua. Its
-- height changes with its texts: see cardHeight in State.
local TOOLBAR_GAP = 6           -- between the card and the toolbar
-- The card as a sidebar (prefs.card "left" or "right"): always this wide,
-- about as wide as the ribbon page's card, so its texts wrap the same way.
local SIDEBAR_WIDTH = 240
local SIDEBAR_GAP = 6           -- between the sidebar and the scroll area
local SCROLLBAR_SPACE = 18      -- the scrollbar and its gap (PrettyUI's BAR_WIDTH 16 + BAR_GAP 2)
-- The arrows on the card's first line that move it (see buildDock).
local DOCK_SIZE = 16
local DOCK_GAP = 2              -- between two arrows

-- The filter notice under the last cell: "Showing 40 of 137 worlds. To
-- see more, remove filters." ("remove filters." is a link).
local NOTICE_GAP = 4            -- between the last row of cells and the notice
local NOTICE_HEIGHT = 16        -- one line
local LINK_GAP = 4              -- between the notice's text and its link
local LINK_TEXT = "remove filters."

local DEFAULT_X, DEFAULT_Y = 60, 80
local DEFAULT_WIDTH = 934       -- about 9 one-line columns, or 4 two-line ones (depends on the measured widths)
local DEFAULT_HEIGHT = 430
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
local LINK_COLOUR = colours.GOLD        -- "remove filters."
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
-- Two lines also need health (the widest health, "100%") and sample (PLACE_SAMPLE).
local sizes = { base = FALLBACK_CELL_WIDTH, name = FALLBACK_NAME_WIDTH, type = FALLBACK_TYPE_WIDTH,
    health = FALLBACK_HEALTH_WIDTH, sample = FALLBACK_SAMPLE_WIDTH }
local twoLines = true       -- the cells on screen have two lines (set when they are built)
local cellHeight = TWO_LINE_HEIGHT  -- and so are this tall
local typeWidth = 0         -- the widest tree type text on show now (0: none, cells are then narrower)
local wordWidths = {}       -- wordWidths["Elder"] = its measured width, worked out once per word
local minCellWidth = FALLBACK_CELL_WIDTH  -- the narrowest a cell can be now
local gridTop = PAD         -- y of the first row of cells in the scroll area (see buildCard)
local pin = nil             -- where PrettyUI put the scroll area, { left, top }, or nil if it can't be moved
local notice = nil          -- the filter notice's parts (buildNotice), while the window is open
local hasToolbar = false    -- true while the toolbar is on screen and working
local hasSettings = false   -- true while the settings gear and page are on the window
local dock = nil            -- the card's arrows (buildDock): dock.left, dock.right, dock.top
local dockSettle = 0        -- frames left to keep the arrows' tooltips hidden after the card moved
local toolbarWindowWidth = nil  -- the window's width when the toolbar was last placed
local lastShown, lastTotal = nil, nil   -- the toolbar's counts at the last update
local toolbarHeight = 0     -- its rows' height at the last refresh
local cardHeight = worldcard.MIN_HEIGHT     -- the card's height now (it grows when its texts wrap)
local selectedWorld = nil   -- the clicked world, or nil
local lastCells, lastNow = nil, nil   -- the latest update's data
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

-- The prefs as they are saved: six strings, with the trees joined by
-- commas ("yew,magic", or "" for any tree). Plain strings avoid saving an
-- empty table or a list through PersistentDB.
local function savedForm(chosen)
    return {
        sort = chosen.sort,
        worlds = chosen.worlds,
        info = chosen.info,
        trees = table.concat(chosen.trees, ","),    -- trees.join(",")
        lines = chosen.lines,
        card = chosen.card,
    }
end

local function viewKey(state)
    return state.sort .. "|" .. state.worlds .. "|" .. state.info .. "|" .. state.trees .. "|" .. state.lines
        .. "|" .. state.card
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
    local pieces = { cell.heading }
    local countdown = overview.countdownText(cell, now)
    if countdown ~= nil then
        pieces[#pieces + 1] = countdown
    end
    -- The cell counts to the death, so say when that is too.
    local death = overview.deathText(cell, now)
    if death ~= nil then
        pieces[#pieces + 1] = death
    end
    if cell.place ~= nil then
        pieces[#pieces + 1] = cell.place
    end
    if cell.noIntel then
        pieces[#pieces + 1] = "No intel"
    end
    return table.concat(pieces, " | ")
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
    local ok, err = pcall(render, lastCells, lastNow)
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

-- Two lines: where the health starts. After the widest world number, and
-- after the tree type column while one is shown (typeWidth > 0).
local function healthX()
    local x = NAME_X + sizes.name + TEXT_GAP
    if typeWidth > 0 then
        x = x + typeWidth + TEXT_GAP
    end
    return x
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
    view.root:SetSize(minCellWidth, cellHeight)
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
    if twoLines then
        -- The health ("45%"), after the tree type, so healths line up down
        -- the grid too. setTypeWidth moves it when the type column changes.
        view.health = parts.text(view.root, healthX(), 1, sizes.health + 2, CELL_HEIGHT - 2)
        view.health.rgba = colours.PLACE
        -- The second line: the place, across the whole cell (from under
        -- the icon, for more room).
        view.place = parts.text(view.root, 3, PLACE_Y, 0, PLACE_HEIGHT)
        view.place:SetSize(-6, PLACE_HEIGHT, 1.0, 0)
        view.place.rgba = colours.PLACE
    end

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
-- Each cell's tooltip goes too: once shown, PrettyUI keeps its parts on
-- window.content and a reference in the window's list of tooltips, so
-- removing only the cell would leave them behind (switching lines rebuilds
-- every cell).
local function destroyViews()
    for _, view in ipairs(views) do
        pcall(function() view.tooltip:Destroy() end)
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
-- Two-line cells also need the widest health and the sample place (see
-- setTypeWidth).
local function measureCells(cells)
    local fallback = { base = FALLBACK_CELL_WIDTH, name = FALLBACK_NAME_WIDTH, type = FALLBACK_TYPE_WIDTH,
        health = FALLBACK_HEALTH_WIDTH, sample = FALLBACK_SAMPLE_WIDTH }

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
    -- Two lines: the widest health ("100%"), and the sample place.
    local healthWidth = textWidth("100%")
    local sampleWidth = textWidth(PLACE_SAMPLE)
    if timerWidth == nil or nameWidth == 0 or widestType == 0 or healthWidth == nil or sampleWidth == nil then
        return fallback
    end
    -- math.ceil rounds up to a whole number (widths may have fractions).
    return {
        base = math.ceil(NAME_X + nameWidth + TEXT_GAP + timerWidth + 3),
        name = math.ceil(nameWidth),
        type = math.ceil(widestType),
        health = math.ceil(healthWidth),
        sample = math.ceil(sampleWidth),
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
-- type is shown). A type needs its text and one more gap. Two-line cells
-- also fit the health on line 1 and the sample place on line 2: the
-- wider line sets the width. The health moves with the type column.
local function setTypeWidth(width)
    typeWidth = width
    minCellWidth = sizes.base + (width > 0 and (width + TEXT_GAP) or 0)
    if twoLines then
        local line1 = minCellWidth + sizes.health + TEXT_GAP
        local line2 = 3 + sizes.sample + 3      -- 3 units of margin each side
        minCellWidth = math.max(line1, line2)
        local x = healthX()
        for _, view in ipairs(views) do
            view.health:SetPos(x, 1)
        end
    end
    laidOutWidth = nil          -- place the cells again on the next layout
end

local function buildViews(cells)
    destroyViews()
    twoLines = (prefs.lines == "two")
    cellHeight = twoLines and TWO_LINE_HEIGHT or CELL_HEIGHT
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

-- Where the card goes: prefs.card ("top", "left" or "right"), but always
-- "top" when the card can't be pinned (it is then in the scrolling
-- content, above the cells).
local function cardSide()
    if pin == nil then
        return "top"
    end
    return prefs.card
end

-- Where everything goes on the window, for the card's side. Only used
-- while the card is pinned (pin ~= nil). x values are from the window's
-- left edge, y values from its top. Returns a table:
--   side             "top", "left" or "right"
--   cardX, cardY     the card's top-left corner; for "right", cardX is
--                    from the window's RIGHT edge (cardFromRight = true)
--   cardWidth        a fixed width, or nil: as wide as the window allows
--   areaLeft         the scroll area's left edge
--   areaRight        the space kept right of the scroll area
--   toolbarX, toolbarY  where the toolbar's first row starts (from the
--                    left edge, also for a right sidebar)
--   toolbarWidth     how wide the toolbar's rows are
--
--   top:    [ card              ]     left:  [ card    ] [ cells    ]
--           [ toolbar           ]            [ toolbar ] [          ]
--           [ cells             ]                        [          ]
local function geometry()
    local side = cardSide()
    local g = { side = side, cardY = pin.top + PAD, areaLeft = pin.left, areaRight = pin.left }
    -- The sidebar, plus the window margin before it and the gap after it.
    local sidebarSpace = PAD + SIDEBAR_WIDTH + SIDEBAR_GAP
    if side == "left" then
        g.cardX, g.cardWidth = pin.left + PAD, SIDEBAR_WIDTH
        g.areaLeft = pin.left + sidebarSpace
    elseif side == "right" then
        -- A negative x measured from the right edge (see cardFromRight),
        -- so the card follows the window's right edge when it is resized.
        g.cardX, g.cardWidth, g.cardFromRight = -(pin.left + PAD + SIDEBAR_WIDTH), SIDEBAR_WIDTH, true
        g.areaRight = pin.left + sidebarSpace
    else
        g.cardX = pin.left + PAD
    end
    -- The toolbar is always under the card, as wide as it. Above the
    -- grid, that also lines it up with the cells (which start PAD inside
    -- the scroll area).
    g.toolbarY = pin.top + PAD + cardHeight + TOOLBAR_GAP
    if side == "left" then
        g.toolbarX, g.toolbarWidth = g.cardX, SIDEBAR_WIDTH
    elseif side == "right" then
        -- The toolbar is placed from the left edge, so it is worked out
        -- from the window's width (and follows a resize: see followResize).
        g.toolbarX, g.toolbarWidth = window.root.width + g.cardX, SIDEBAR_WIDTH
    else
        g.toolbarX = g.areaLeft + PAD
        g.toolbarWidth = window.root.width - g.areaLeft - g.areaRight - 2 * PAD
    end
    return g
end

-- The window space above the scroll area: the card and the toolbar's
-- rows, above the grid only. Beside a sidebar the scroll area starts right
-- under the title bar, and the cells level with the card's top.
local function pinnedSpace()
    if cardSide() ~= "top" then
        return 0
    end
    local space = PAD + cardHeight
    if hasToolbar then
        space = space + TOOLBAR_GAP + toolbarHeight
    end
    return space
end

-- Sets the window's minimum size, and makes the window bigger if it is
-- now smaller. window.minWidth / minHeight (used by SetSize) and
-- window.resize.minWidth / minHeight (used while the player drags an edge)
-- are PrettyUI's own fields (PrettyUI v1.3.0 internal); if they are
-- missing, the minimum stays MIN_WIDTH x MIN_HEIGHT and only the bigger
-- window remains.
local function setMinimumSize(width, height)
    if window.minWidth ~= nil then
        window.minWidth = width
    end
    if window.minHeight ~= nil then
        window.minHeight = height
    end
    if window.resize ~= nil then
        if window.resize.minWidth ~= nil then
            window.resize.minWidth = width
        end
        if window.resize.minHeight ~= nil then
            window.resize.minHeight = height
        end
    end
    if window.root.width < width or window.root.height < height then
        window:SetSize(math.max(window.root.width, width), math.max(window.root.height, height))
    end
end

-- Moves the scroll area to just under the card and toolbar (and beside a
-- sidebar card). Called when the window opens and whenever the card's
-- height, its side or the toolbar's height changes.
local function pinScrollArea()
    local g = geometry()
    local space = pinnedSpace()
    local area = window._scroll.root
    -- The anchors (1.0, 1.0) make the size "the window's size + these
    -- numbers", so it still follows resizes. The bottom border is as thick
    -- as the side ones (8), as in PrettyUI's window.lua.
    area:SetPos(g.areaLeft, pin.top + space)
    area:SetSize(-(g.areaLeft + g.areaRight), -(pin.top + space) - pin.left, 1.0, 1.0)
    window._scroll:Refresh()                -- lay the scrollbar out for the new size

    -- Tall enough for a row of cells (and the scrollbar's arrows), and for
    -- the settings page (it covers the window's inside). Beside a sidebar,
    -- also for the whole card, and wide enough for one column of cells
    -- next to it.
    local width = MIN_WIDTH
    local height = math.max(MIN_HEIGHT, pin.top + space + MIN_SCROLL_HEIGHT + pin.left,
        pin.top + gridsettings.pageHeight() + pin.left)
    if g.side ~= "top" then
        -- The sidebar: the card, then the toolbar under it.
        local sidebarHeight = PAD + cardHeight + PAD
        if hasToolbar then
            sidebarHeight = sidebarHeight + TOOLBAR_GAP + toolbarHeight
        end
        height = math.max(height, pin.top + sidebarHeight + pin.left)
        width = math.max(width, g.areaLeft + g.areaRight + 2 * PAD + minCellWidth + SCROLLBAR_SPACE)
    end
    setMinimumSize(width, height)
end

-- The card (ui/worldcard.lua): built once when the window opens, then
-- filled in by updateHeader. A pinned card is put in its place by
-- arrange, below.
local function buildCard()
    -- Pinned: straight on the window, in the space above (or beside) the
    -- scroll area, and the cells start at the top of the scroll area. Not
    -- pinned: at the top of the scrolling content, with the cells under it.
    local parent, x, y = window.content, PAD, PAD
    cardHeight = worldcard.MIN_HEIGHT       -- a new card starts at its smallest
    gridTop = PAD + cardHeight + PAD
    if pin ~= nil then
        parent, x, y = window.root, pin.left + PAD, pin.top + PAD
        gridTop = PAD
    end
    card = worldcard.new(parent, x, y)
end

local pickSide      -- defined with the toolbar below; declared here so the arrows can call it

-- The arrows that move the card, as in EctoTrees' sidebar: PrettyUI
-- SpriteButtons on the window (like the settings gear), in front of the
-- card's first line, left of its P2P badge. Only for a pinned card. All
-- three are built; placeDock shows the two that fit the card's side.
local DOCK_BUTTONS = {
    left = { sprite = "ARROW_LEFT", tooltip = "Show the card on the left" },
    right = { sprite = "ARROW_RIGHT", tooltip = "Show the card on the right" },
    top = { sprite = "ARROW_UP", tooltip = "Show the card above the grid" },
}
-- Which arrows show for each side, left to right.
local DOCK_ORDER = {
    top = { "left", "right" },
    left = { "right", "top" },
    right = { "left", "top" },
}

local function buildDock()
    dock = {}
    for side, look in pairs(DOCK_BUTTONS) do
        dock[side] = prettyui.SpriteButton.new(window.root, look.sprite, function()
            pickSide(side)
        end, { size = DOCK_SIZE, tooltip = look.tooltip })
        dock[side].root.hidden = true
    end
end

-- Shows the arrows for the card's side (g from geometry), on the right
-- end of the card's first line, and hides the third.
local function placeDock(g)
    if dock == nil then
        return
    end
    for _, button in pairs(dock) do
        button.root.hidden = true
        -- Disabled as well as hidden, so a hidden arrow takes no mouse
        -- events at all (PrettyUI makes a disabled SpriteButton
        -- clickthrough). The arrow just clicked hides, so it never gets
        -- its "mouse leave": hide its tooltip ourselves. pcall: if either
        -- call is missing, the arrow keeps its look a moment.
        pcall(function() button:SetDisabled(true) end)
        pcall(function() button.tooltip:Hide() end)
    end
    -- Keep hiding the tooltips for a few frames (see grid.onLogic), in
    -- case the game sends a late "mouse over" to the arrow just clicked.
    dockSettle = 10
    local shown = DOCK_ORDER[g.side]
    -- The card's right edge: from the window's right edge (xAnchor 1.0)
    -- for "top" and "right", from its left edge for "left".
    local right, xAnchor = -(pin.left + PAD), 1.0
    if g.side == "left" then
        right, xAnchor = g.cardX + g.cardWidth, 0
    end
    local y = g.cardY + worldcard.BADGE_Y
    for index, side in ipairs(shown) do
        -- How many arrows from the right this one is (1 = the rightmost).
        local fromRight = #shown - index + 1
        local x = right - worldcard.CONTROLS_RIGHT - fromRight * DOCK_SIZE - (fromRight - 1) * DOCK_GAP
        dock[side].root:SetPos(x, y, xAnchor, 0)
        dock[side].root.hidden = false
        pcall(function() dock[side]:SetDisabled(false) end)    -- takes clicks again
    end
end

-- Hides the arrows' tooltips (called for a few frames after the card moved).
local function hideDockTooltips()
    for _, button in pairs(dock) do
        pcall(function() button.tooltip:Hide() end)
    end
end

local function destroyDock()
    if dock ~= nil then
        for _, button in pairs(dock) do
            pcall(function() button:Destroy() end)
        end
    end
    dock = nil
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

-- How wide the card is on screen: the sidebar's width, or its parent's
-- width minus its margins. (The card needs it to wrap its texts.)
local function cardWidth()
    if cardSide() ~= "top" then
        return SIDEBAR_WIDTH
    end
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
    local rowWidth = width - 2 * PAD            -- the space for one row of cells
    -- As many columns as fit at the narrowest width (n cells have n - 1 gaps)...
    -- math.floor also turns 10.0 into the integer 10 (Lua 5.4).
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
        view.root:SetPos(PAD + column * (cellWidth + GAP), gridTop + row * (cellHeight + GAP))
        view.root:SetSize(cellWidth, cellHeight)
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
        bottom = gridTop + rows * (cellHeight + GAP) - GAP
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

-- Puts the card, its arrows, the toolbar and the scroll area in their
-- places for the card's side (see geometry). Called when the window
-- opens, when the card's side changes, and when its height changes (above
-- the grid, the toolbar and cells move with it). Does nothing while the
-- card can't be pinned.
local function arrange()
    if pin == nil then
        return
    end
    local g = geometry()
    worldcard.place(card, g.cardX, g.cardY, g.cardWidth, g.cardFromRight)
    placeDock(g)
    if hasToolbar then
        local ok, err = pcall(gridtoolbar.setOrigin, g.toolbarX, g.toolbarY)
        if not ok then
            dropToolbar(err)    -- also moves the scroll area
            return
        end
    end
    pinScrollArea()
end

-- The toolbar's onChange, and the settings pages' (ui/gridsettings.lua):
-- group is "sort", "worlds", "info", "trees", "lines" or "card".
local function setPref(group, value)
    -- A copy with one field changed (like { ...prefs, [group]: value } in
    -- JS), made valid by filters.normalize (unknown values fall back).
    local changed = { sort = prefs.sort, worlds = prefs.worlds, info = prefs.info, trees = prefs.trees,
        lines = prefs.lines, card = prefs.card }
    changed[group] = value
    prefs = filters.normalize(changed)
    if group == "lines" or group == "card" then
        -- Both settings pages show the new choice (it may have come from
        -- the other page, or from the card's arrows).
        pcall(gridsettings.showChoice, group, prefs[group])
    end
    if group == "lines" then
        worldsKey = nil         -- one line or two: the cells are built again
    end
    if group == "card" and window ~= nil then
        arrange()               -- the card moves; the toolbar and cells make room
        laidOutWidth = nil      -- place the cells again for their new width
    end
    viewChanged()
end

-- The card's arrows (assigned to the local declared above buildDock).
pickSide = function(side)
    local ok, err = pcall(setPref, "card", side)
    if not ok then
        log("[error] grid card side: " .. tostring(err))
    end
end

-- Reset, and the notice's "remove filters." link: clears Worlds, Info and
-- Tree. The sort, the lines and the card's side are never reset.
-- (Assigned to the local declared above buildNotice.)
resetFilters = function()
    local cleared = filters.defaults()
    cleared.sort = prefs.sort
    cleared.lines = prefs.lines
    cleared.card = prefs.card
    prefs = cleared
    if hasToolbar then
        local ok, err = pcall(gridtoolbar.showPrefs, prefs)
        if not ok then
            dropToolbar(err)
        end
    end
    viewChanged()
end

-- Builds the toolbar under the card (or beside it). host is what the
-- window is on (the game area): the toolbar draws its lists and popup
-- there. Only when the card is pinned: without that, the toolbar would
-- have no fixed place.
local function buildToolbar(host)
    if pin == nil then
        return
    end
    local g = geometry()
    local ok, err = pcall(gridtoolbar.build, window, host, g.toolbarX, g.toolbarY, prefs,
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
    lastShown, lastTotal = shown, total
    -- Under the card, as wide as it. setOrigin does nothing unless the
    -- place changed (a right sidebar moves when the window is resized).
    local g = geometry()
    toolbarWindowWidth = window.root.width
    local ok, result = pcall(function()
        gridtoolbar.setOrigin(g.toolbarX, g.toolbarY)
        return gridtoolbar.refresh(g.toolbarWidth, prefs, shown, total)
    end)
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

-- The settings gear in the title bar and its page (ui/gridsettings.lua).
-- If they fail, the grid goes on without them (the client's Settings icon
-- still has the same choices).
local function attachSettings()
    -- Where the window's inside starts: found with the scroll area, else
    -- PrettyUI's border (8) and title bar (32).
    local left, top = 8, 32
    if pin ~= nil then
        left, top = pin.left, pin.top
    end
    local ok, err = pcall(gridsettings.attach, window, left, top, {
        get = function(group) return prefs[group] end,
        onPick = setPref,
        onOpen = function()
            if hasToolbar then
                pcall(gridtoolbar.closeLists)   -- an open list or popup would sit over the page
            end
        end,
    })
    hasSettings = ok
    if not ok then
        log("[error] grid settings: " .. tostring(err) .. " (showing the grid without the gear)")
        pcall(gridsettings.detach)
    end
end

local function detachSettings()
    if hasSettings then
        pcall(gridsettings.detach)
    end
    hasSettings = false
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
    local word = cell.treeType or ""
    if word ~= view.typeText then
        view.type.content = word
        view.typeText = word
    end
    if view.health ~= nil then
        -- Just the number, even for "50% or less" (healthValue 50): the
        -- card and the hover text say "or less". %d needs a whole number.
        local health = cell.healthValue and string.format("%d%%", math.floor(cell.healthValue)) or ""
        if health ~= view.healthText then
            view.health.content = health
            view.healthText = health
        end
        local place = cell.cellPlace or ""      -- a hint without "Hint: "
        if place ~= view.placeText then
            view.place.content = place
            view.placeText = place
        end
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
local function updateHeader(cells, now)
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

    -- Out of the live worlds only: beta worlds are on the grid for testing.
    local title = "Evil Trees - " .. scouted .. " / " .. worlds.count .. " scouted"
    if sampleMode then
        title = title .. " (sample)"     -- short: the title bar cuts off long titles
    end
    if title ~= titleText then
        window:SetTitle(title)
        titleText = title
    end

    -- The card says how tall it is now. When that changes (a text wrapped
    -- onto more or fewer lines), move what is under it (or, beside a
    -- sidebar, make sure the window is still tall enough for it).
    local height = worldcard.update(card, shown, now, "Click a world for details.", cardWidth())
    if height ~= cardHeight then
        cardHeight = height
        if pin ~= nil then
            arrange()
        else
            gridTop = PAD + cardHeight + PAD    -- the card is in the scrolling content
            laidOutWidth = nil                  -- place the cells again, lower or higher
        end
    end
end

-- Draws the latest data. cells from overview.cells, now the time (or nil).
render = function(cells, now)
    lastCells, lastNow = cells, now
    if keyOf(cells) ~= worldsKey then
        buildViews(cells)
    end
    local widest = 0            -- the widest tree type text on show
    for _, cell in ipairs(cells) do
        updateView(viewsByWorld[cell.world], cell, now)
        if cell.treeType ~= nil then
            widest = math.max(widest, wordWidth(cell.treeType))
        end
    end
    -- Cells get wider when a wider type word appears (the first type, or
    -- "Willow" after only "Oak"), and narrower again when it goes. Rare:
    -- the cells are then placed again.
    if widest ~= typeWidth then
        setTypeWidth(widest)
        if pin ~= nil then
            pinScrollArea()     -- beside a sidebar, the window's minimum width follows the cells' width
        end
    end
    updateHeader(cells, now)

    -- Which cells show, in which order. The toolbar's count ("40 / 137")
    -- is out of every cell, so it can be more than the title's 137 (a
    -- beta world, or a world not in our list).
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
    card, notice, pin, dock = nil, nil, nil, nil
    dockSettle, toolbarWindowWidth, lastShown, lastTotal = 0, nil, nil, nil
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
        destroyOnClose = true,          -- free the cells' components while closed
        onClose = function()
            -- The player closed it with the X. (PrettyUI destroys the
            -- window right after this.)
            wantOpen = false
            reportLayout()
            destroyToolbar()
            detachSettings()
            destroyDock()
            forgetWindow()
        end,
        onPositionChange = function(_, x, y)
            placement.x, placement.y = x, y
            reportLayout()
        end,
    })
    findScrollArea()
    buildCard()
    if pin ~= nil then
        buildDock()
    end
    buildNotice()
    buildToolbar(parent)
    arrange()                   -- the card, arrows, toolbar and scroll area in their places
    attachSettings()
    return true
end

-- Removes the window without counting it as "closed by the player" (so it
-- reopens after a reload).
local function destroyWindow()
    destroyToolbar()
    detachSettings()
    destroyDock()
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
-- info = "any", trees = "yew,magic", lines = "two", card = "top" }.
-- Anything odd or out of date falls back to the default
-- (filters.normalize). Call before the window opens.
function grid.restoreView(state)
    local saved = {}
    if type(state) == "table" then
        saved.sort, saved.worlds, saved.info = state.sort, state.worlds, state.info
        saved.lines, saved.card = state.lines, state.card
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

-- A setting's choice, for the client's settings page (ui/gridsettings.lua,
-- fillHub): grid.choice("lines") is "two" or "one", grid.choice("card")
-- is "top", "left" or "right" (see core/filters.lua, LINES and CARD).
function grid.choice(group)
    return prefs[group]
end

-- Sets a setting from the client's settings page: saved, and an open grid
-- is drawn again with it (new cells, or the card moved).
function grid.setChoice(group, value)
    setPref(group, value)
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
function grid.update(cells, now)
    if not wantOpen then
        return
    end
    local ok, err = pcall(function()
        if window == nil and not createWindow() then
            return              -- no game area yet; try again next second
        end
        render(cells, now)
    end)
    if not ok then
        -- Something is wrong. Stop trying, so the console isn't flooded
        -- every second.
        log("[error] grid: " .. tostring(err) .. " (grid closed)")
        destroyWindow()
        wantOpen = false
        reportLayout()
    end
end

-- Called every frame (50 a second) by main.lua, so the title bar's drag
-- strip stays short of the settings gear (see gridsettings.onLogic) and
-- the toolbar notices a dropdown opening straight away (see
-- gridtoolbar.onLogic). The toolbar part does nothing while there is no
-- toolbar. If it fails, the toolbar is removed, so the
-- error is logged once, not 50 times a second.
function grid.onLogic()
    if hasSettings then
        local ok, err = pcall(gridsettings.onLogic)
        if not ok then
            log("[error] grid settings: " .. tostring(err) .. " (gear removed)")
            detachSettings()
        end
    end
    if dockSettle > 0 and dock ~= nil then
        dockSettle = dockSettle - 1
        hideDockTooltips()
    end
    -- A right sidebar follows the window's right edge by itself (anchored),
    -- but the toolbar under it is placed from the left: move it with the
    -- window while the player resizes, not a second later.
    if hasToolbar and window ~= nil and cardSide() == "right" and lastShown ~= nil
        and window.root.width ~= toolbarWindowWidth then
        refreshToolbar(lastShown, lastTotal)
    end
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
