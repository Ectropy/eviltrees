--[[
    ui/worldcard.lua
    ----------------
    The world card: one world in full, in a framed box. Used twice, so both
    look the same:
      - at the top of the world grid (ui/grid.lua): the clicked world, or
        the one you're on
      - in the ribbon page (ui/dashboard.lua): the world you're on

        w204                                   [P2P]   <- sky-blue outline: you're on it
        [icon] Evil willow - 45%               <- status, in the status colour
        East of the house portal in Rellekka   <- place
        or Northwest of Seers' Village bank    <- (when the hints leave two or
                                                   three places: one line each)
        Lightning in 4m 5s  -  Dies in 24m 5s  <- countdown

    The card is the FULL view of what a grid cell shortens, so nothing on it
    is cut off: the status, the place and the countdown each wrap onto as
    many lines as they need, and the card grows taller to fit. A card whose
    texts all fit on one line is 80 tall. worldcard.update returns the
    card's height, so whoever shows the card can move what is under it.

    It is a few plain game components, built once (worldcard.new) and then
    only changed in place (worldcard.update), like setting
    element.textContent in vanilla JS. core/overview.lua decides the words:
    update takes one of its cells.

    Two anchor tricks are used (as in PrettyUI's own widgets):
      SetSize(w, h, 1.0, 0)   width = the parent's full width + w, so a
                              negative w leaves a margin and it follows resizes
      SetPos(x, y, 1.0, 0)    x is measured from the parent's RIGHT edge
]]

local overview = require("core/overview")
local colours = require("ui/colours")
local icons = require("ui/icons")
local parts = require("ui/parts")

local worldcard = {}

local INNER = 8                 -- text margin inside the card
local BADGE_WIDTH, BADGE_HEIGHT = 32, 16
local ICON_SIZE = 18
local STATUS_Y = 25             -- where the status starts
local STATUS_FONT = "MUSEO_SANS_13PT_BOLD"  -- the world number and the status
local STATUS_LINE = 18          -- the height of one line of status text
local LINE = 16                 -- the height of one line of small text
local BOTTOM = 5                -- space under the countdown
local MAX_LINES = 6             -- the most lines one text may take (a safety limit)
local MAX_PLACES = 3            -- the most places the hints can leave (core/overview.lua)
local CARD_BG = 0x221F1BF5      -- a shade lighter than the grid's cells

-- A card whose texts each fit on one line: 80. Cards start at this height.
worldcard.MIN_HEIGHT = STATUS_Y + STATUS_LINE + LINE + LINE + BOTTOM

-- Builds an empty card at (x, y) in parent, as wide as the parent minus x
-- on both sides. Returns a table of its components; fill it with
-- worldcard.update.
function worldcard.new(parent, x, y)
    local card = { x = x, height = worldcard.MIN_HEIGHT }
    card.root = prettyui.NewComponent(ui.Layer, parent)
    card.root:SetPos(x, y)
    card.root:SetSize(-2 * x, card.height, 1.0, 0)  -- the same margin on both sides
    card.root.clickthrough = true       -- nothing on the card takes the mouse
    card.background = parts.rectangle(card.root, true, CARD_BG)
    card.border = parts.rectangle(card.root, false, colours.FRAME)

    -- A full-width text. The status, place and countdown are put in
    -- their places (and given their heights) by layout, below.
    local function line(lineY, height, font)
        local text = parts.text(card.root, INNER, lineY, 0, height, nil, font)
        text:SetSize(-2 * INNER, height, 1.0, 0)
        return text
    end

    card.world = line(5, 20, id.Font[STATUS_FONT])

    -- Right end of the first line: the P2P / F2P badge.
    local badgeX = -(INNER + BADGE_WIDTH)
    card.badgeBorder = prettyui.NewComponent(ui.Rectangle, card.root)
    card.badgeBorder:SetPos(badgeX, 7, 1.0, 0)
    card.badgeBorder:SetSize(BADGE_WIDTH, BADGE_HEIGHT)
    card.badgeBorder.fill = false
    card.badgeBorder.clickthrough = true
    card.badge = parts.text(card.root, 0, 7, BADGE_WIDTH, BADGE_HEIGHT, ui.AlignMode.CENTRE)
    card.badge:SetPos(badgeX, 7, 1.0, 0)

    -- Status: the icon, then the text (to the right of it when there is one).
    card.statusIcon = icons.new(card.root, INNER, STATUS_Y, ICON_SIZE)
    card.status = line(STATUS_Y, STATUS_LINE, id.Font[STATUS_FONT])
    card.place = line(STATUS_Y + STATUS_LINE, LINE)
    card.place.rgba = colours.PLACE
    card.countdown = line(STATUS_Y + STATUS_LINE + LINE, LINE)
    card.countdown.rgba = colours.COUNTDOWN

    -- One Text per place: card.places[1] is card.place, the others ("or
    -- ...") are hidden until the hints leave more than one place. Separate
    -- Texts, so each "or" starts a new line whatever the width.
    card.places = { card.place }
    for index = 2, MAX_PLACES do
        local text = line(0, LINE)
        text.rgba = colours.PLACE
        text.hidden = true
        card.places[index] = text
    end
    return card
end

-- How many lines a text needs when it wraps at width, in the font called
-- fontName. The game counts them for us (config.Font.<name>:
-- GetStringLineCount, as PrettyUI uses for its own texts). If that isn't
-- there, we estimate from the text's width, or from 7 units a letter.
-- pcall is try/catch: it returns false if the call threw.
local function lineCount(fontName, text, width)
    if text == "" or width == nil or width <= 0 then
        return 1
    end
    local ok, count = pcall(function()
        return config.Font[fontName]:GetStringLineCount(text, width, false, false, false)
    end)
    if not (ok and type(count) == "number") then
        local okWidth, textWidth = pcall(function()
            return config.Font[fontName]:GetStringWidth(text, false)
        end)
        if not (okWidth and type(textWidth) == "number") then
            textWidth = #text * 7           -- #text is the text's length
        end
        count = math.ceil(textWidth / width)    -- rounds up
    end
    -- At least 1, at most MAX_LINES (like Math.min / Math.max in JS).
    return math.max(1, math.min(MAX_LINES, math.floor(count)))
end

-- Stacks the status, place and countdown under each other, each as tall as
-- the lines it needs at this card width, and sets the card's height.
-- width is the card's width, or nil if unknown (then nothing wraps).
-- statusX is where the status text starts (after the icon, if any).
local function layout(card, width, statusX)
    local textWidth = width and (width - 2 * INNER)     -- nil stays nil
    local statusLines = lineCount(STATUS_FONT, card.status.content, width and (width - statusX - INNER))
    -- The first place always keeps one line (even when empty, so the card
    -- doesn't jump); the "or ..." places take none while they are empty.
    local placeLines = {}
    for index, text in ipairs(card.places) do
        if index > 1 and text.content == "" then
            placeLines[index] = 0
        else
            placeLines[index] = lineCount(parts.FONT, text.content, textWidth)
        end
    end
    local countdownLines = lineCount(parts.FONT, card.countdown.content, textWidth)

    -- Only touch the components when something moved: this runs every second.
    -- (table.concat joins a list, like placeLines.join(",") in JS.)
    local key = statusX .. "," .. statusLines .. "," .. table.concat(placeLines, ",") .. "," .. countdownLines
    if key == card.layoutKey then
        return
    end
    card.layoutKey = key

    -- Puts one text at height y with room for its lines; returns the y under it.
    local function place(text, x, y, lines, lineHeight)
        local height = lines * lineHeight
        text:SetPos(x, y)
        text:SetSize(-(x + INNER), height, 1.0, 0)  -- from x to the right margin
        text.maxLines = lines
        return y + height
    end
    local y = place(card.status, statusX, STATUS_Y, statusLines, STATUS_LINE)
    for index, text in ipairs(card.places) do
        text.hidden = (placeLines[index] == 0)
        if placeLines[index] > 0 then
            y = place(text, INNER, y, placeLines[index], LINE)
        end
    end
    y = place(card.countdown, INNER, y, countdownLines, LINE)

    card.height = y + BOTTOM
    card.root:SetSize(-2 * card.x, card.height, 1.0, 0)
end

-- Fills the card with one cell (from overview.cells or overview.currentCell).
-- If cell is nil, the card shows only emptyText, e.g. "Click a world for
-- details." now is the time (Unix ms, or nil). width is how wide the card
-- is on screen (its texts wrap to it), or nil if the caller can't tell.
-- Returns the card's height, which changes when a text needs more or
-- fewer lines.
function worldcard.update(card, cell, now, emptyText, width)
    -- "cell and cell.icon" is nil when there is no cell (like cell?.icon in JS).
    local hasIcon = icons.set(card.statusIcon, cell and cell.icon, cell and cell.logs)
    local statusX = hasIcon and (INNER + ICON_SIZE + 4) or INNER

    if cell == nil then
        card.world.content = ""
        card.badge.content = ""
        card.badgeBorder.hidden = true
        card.status.content = emptyText or ""
        card.status.rgba = colours.MUTED
        for _, text in ipairs(card.places) do
            text.content = ""
        end
        card.countdown.content = ""
        card.border.rgba = colours.FRAME
        layout(card, width, statusX)
        return card.height
    end

    -- The world number in the game's world-list colour (gold P2P, white
    -- F2P). On your own world the card has a sky-blue outline.
    local worldColour = colours.world(cell.members, false)
    card.world.content = "w" .. cell.world
    card.world.rgba = worldColour
    card.border.rgba = cell.current and colours.CURRENT or colours.FRAME

    -- members is nil for worlds not in data/worlds.lua: no badge.
    if cell.members == nil then
        card.badge.content = ""
        card.badgeBorder.hidden = true
    else
        card.badge.content = cell.members and "P2P" or "F2P"
        card.badge.rgba = worldColour
        card.badgeBorder.rgba = worldColour
        card.badgeBorder.hidden = false
    end

    card.status.content = cell.noIntel and "Nothing known yet." or (cell.status or "")
    card.status.rgba = colours.KIND[cell.kind] or colours.MUTED
    -- The places, one per Text: "A", "or B", "or C". "cell.places or {}"
    -- is an empty list when there are none (like cell.places ?? [] in JS).
    local places = cell.places or {}
    for index, text in ipairs(card.places) do
        local name = places[index] or ""
        if index > 1 and name ~= "" then
            name = "or " .. name
        end
        text.content = name
    end

    -- "Lightning in 4m 5s  -  Dies in 24m 5s": the death time as well, when
    -- the next event is a strike.
    -- (countdownText is nil when nothing is due, e.g. the rewards are gone.)
    local countdown = overview.countdownText(cell, now)
    local death = overview.deathText(cell, now)
    if countdown ~= nil and death ~= nil then
        countdown = countdown .. "  -  " .. death
    end
    card.countdown.content = countdown or death or ""

    layout(card, width, statusX)
    return card.height
end

-- Removes the card. pcall (like try/catch): its parent may already be gone.
function worldcard.destroy(card)
    pcall(function() card.root:Destroy() end)
end

return worldcard
