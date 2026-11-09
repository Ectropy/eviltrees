-- ui/grid.lua with a fake PrettyUI Window and fake game components: what
-- the cells and header say, layout, clicking, closing, and saving where
-- the window is.
-- Run with: node check.js <plugin dir> test_grid.lua
local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then passes = passes + 1
  else failures = failures + 1; print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)) end
end

---------------------------------------------------------------- fakes
local logged = {}
log = function(line) logged[#logged + 1] = line end

local components = {}       -- every native component created, in order
local function newComponent(kind, parent)
  local component = { kind = kind, parent = parent, hooks = {}, x = 0, y = 0 }
  function component:SetPos(x, y) self.x, self.y = x, y end
  function component:SetSize(w, h) self.w, self.h = w, h end
  function component:Subscribe(hook, _, fn) self.hooks[hook] = fn end
  function component:Destroy() self.destroyed = true end
  function component:SetAssociatedObject(objectID) self.object = objectID end
  components[#components + 1] = component
  return component
end

id = { Font = {}, Component = { TOPLEVEL_V2__GAME_AREA = 1 } }
local gameArea = newComponent("GameArea")
ui = {
  Interfaces = { GetComponent = function() return gameArea end },
  Layer = "Layer", Rectangle = "Rectangle", Text = "Text", Sprite = "Sprite",
  AlignMode = { TOPLEFT = 1, CENTRE = 2, BOTTOMRIGHT = 3 },
  Hook = { ONCLICK = "click", ONSCROLLWHEEL = "wheel" },
}

-- Measuring text: every letter 6 wide, but "8" 20 wide, so the widest
-- countdown is "~8h 88m" (4 * 6 + 3 * 20 = 84), and a cell is at least
-- 20 (icon slot) + 24 ("w204") + 6 (gap) + 84 + 3 = 137 wide.
config = { Font = { MUSEO_SANS_11PT_REGULAR = {
  GetStringWidth = function(_, text)
    local _, eights = string.gsub(text, "8", "8")     -- gsub's second result: how many it replaced
    return #text * 6 + eights * 14
  end,
} } }

local windows = {}          -- every Window created
local noScrollArea = false  -- true: a PrettyUI without window._scroll (the card can't be pinned)
local CHROME = 40           -- fake title bar + borders
prettyui = {
  NewComponent = newComponent,
  Tooltip = { attach = function(target, _, options, handlers)
    local tip = { text = options.text, handlers = handlers }
    function tip:SetText(text) self.text = text end
    function tip:Show() self.shown = true end
    function tip:Hide() self.shown = false end
    target.tip = tip
    return tip
  end },
  Window = { new = function(_, options)
    local window = { options = options, title = options.title }
    window.root = { width = options.width, height = options.height }
    window.content = newComponent("Content")
    window.content.width = options.width - 16
    window.viewport = { height = options.height - CHROME }
    window._onScrollWheel = function() end
    -- The scroll area: under the title bar (32), inside the 8-wide borders.
    if not noScrollArea then
      window._scroll = { root = newComponent("ScrollArea") }
      window._scroll.root:SetPos(8, 32)
      function window._scroll:Refresh() self.refreshed = true end
    end
    function window:SetContentHeight(h) self.contentHeight = h end
    function window:SetSize(w, h)
      self.root.width, self.root.height = w, h
      self.viewport.height = h - CHROME
      self.content.width = w - 16
    end
    function window:SetTitle(t) self.title = t end
    function window:Close() self.options.onClose(self); self.destroyed = true end
    function window:Destroy() self.destroyed = true end
    windows[#windows + 1] = window
    return window
  end },
}

-- Helpers to read the "screen".
-- Cells are the 18-tall Layers (the card is a taller one).
local function cellsOnScreen()
  local list = {}
  for _, c in ipairs(components) do
    if c.kind == "Layer" and c.h == 18 and not c.destroyed then list[#list + 1] = c end
  end
  return list
end
local function textsOf(layer)      -- name, timer
  local texts = {}
  for _, c in ipairs(components) do
    if c.kind == "Text" and c.parent == layer then texts[#texts + 1] = c end
  end
  return texts[1], texts[2]
end
local function spritesOf(layer)    -- the icon slot: game sprite, item icon
  local sprites = {}
  for _, c in ipairs(components) do
    if c.kind == "Sprite" and c.parent == layer then sprites[#sprites + 1] = c end
  end
  return sprites[1], sprites[2]
end
local function borderOf(layer)
  for _, c in ipairs(components) do
    if c.kind == "Rectangle" and c.parent == layer and c.fill == false then return c end
  end
end
local function backgroundOf(layer)
  for _, c in ipairs(components) do
    if c.kind == "Rectangle" and c.parent == layer and c.fill == true then return c end
  end
end
local function cellFor(world)
  for _, layer in ipairs(cellsOnScreen()) do
    local name = textsOf(layer)
    if name.content == "w" .. world then return layer end
  end
end
-- The card: the Layer straight on the window (or in its content) that isn't a cell. Its
-- Texts in the order grid.lua makes them, by name; its outline Rectangle
-- and the badge's.
local function cardParts()
  local layer
  for _, c in ipairs(components) do
    local w = windows[#windows]
    if c.kind == "Layer" and (c.parent == w.root or c.parent == w.content) and c.h ~= 18 then layer = c end
  end
  local names = { "world", "badge", "status", "place", "countdown" }
  local parts, texts, rectangles = {}, 0, {}
  for _, c in ipairs(components) do
    if c.parent == layer and c.kind == "Text" then
      texts = texts + 1
      parts[names[texts]] = c
    elseif c.parent == layer and c.kind == "Rectangle" then
      rectangles[#rectangles + 1] = c
    end
  end
  parts.border, parts.badgeBorder = rectangles[2], rectangles[3]
  parts.sprite, parts.item = spritesOf(layer)
  return parts
end

---------------------------------------------------------------- data
local overview = require("core/overview")
local grid = require("ui/grid")

local MINUTE = 60000
local NOW = 1793932200000
local worldList = {}
for n = 1, 6 do worldList[n] = { number = n, members = (n ~= 3) } end
local records = {
  [2] = { status = "none", spawnAt = NOW + 45 * MINUTE },
  [204] = { status = "alive", treeType = "willow", health = 45, healthSource = "examine",
            matureAt = NOW - 5 * MINUTE, matureEarliest = NOW - 5 * MINUTE, matureLatest = NOW - 5 * MINUTE,
            tileX = 2702, tileZ = 3640 },
}
local function cells(now) return overview.cells(records, worldList, 204, now) end

local states = {}
grid.setOnLayoutChange(function(state) states[#states + 1] = state end)

---------------------------------------------------------------- closed
grid.update(cells(NOW), NOW, 137)
check("A1 closed by default", #windows, 0)
check("A2 not wanted", grid.wantsOpen(), false)

---------------------------------------------------------------- restored open
grid.restore({ x = 10, y = 20, width = 500, height = 400, open = 1 })
check("B1 wanted after restore", grid.wantsOpen(), true)
grid.update(cells(NOW), NOW, 137)
local window = windows[1]
check("B2 window opened", window ~= nil, true)
check("B3 at the saved place", window.options.x .. "," .. window.options.y, "10,20")
check("B4 one cell per world (6 + 204)", #cellsOnScreen(), 7)
check("B5 title counts scouted", window.title, "Evil Trees - 2 / 137 scouted")

local name, timer = textsOf(cellFor(2))
check("C1 w prefix", name.content, "w2")
check("C2 countdown in minutes", timer.content, "45m")
check("C3 spawn colour", timer.rgba, 0x8FB8DEFF)
name, timer = textsOf(cellFor(1))
check("C4 no intel: blank countdown", timer.content, "")
check("C5 no intel: name still in body text", name.rgba, 0xE7D7B0FF)
check("C6 current world outlined white", borderOf(cellFor(204)).rgba, 0xFFFFFFFF)
check("C7 F2P outline", borderOf(cellFor(3)).rgba, 0x2A6A8AFF)

-- An alive tree's cell counts to its death (M + 30), not the next strike.
check("C8 alive: countdown to death", select(2, textsOf(cellFor(204))).content, "25m")

-- Icons (id.Sprite is missing in these fakes, so the dump's numbers are used).
local sprite, item = spritesOf(cellFor(204))
check("C9 alive willow: willow logs only", item.object .. "," .. tostring(item.hidden) .. "," .. tostring(sprite.hidden), "1519,false,true")
sprite, item = spritesOf(cellFor(2))
check("C10 spawn: timer sprite", sprite.sprite .. "," .. tostring(sprite.hidden) .. "," .. tostring(item.hidden), "10432,false,true")
sprite, item = spritesOf(cellFor(1))
check("C11 no intel: no icon", tostring(sprite.hidden) .. "," .. tostring(item.hidden), "true,true")

-- (45% means strike 1 is done, so the next one is strike 2 at M + 20.)
local card = cardParts()
check("D1 card: world", card.world.content, "w204")
check("D3 card: beta world has no badge", card.badge.content .. "," .. tostring(card.badgeBorder.hidden), ",true")
check("D4 card: status", card.status.content, "Evil willow - 45%")
check("D5 card: status in the alive colour", card.status.rgba, 0x7CC04AFF)
check("D6 card: place", card.place.content, "East of the house portal in Rellekka")
check("D7 card: strike, then death", card.countdown.content, "Lightning in 15:00  -  Dies in 25:00")
check("D8 card: white outline on your world", card.border.rgba, 0xFFFFFFFF)
check("D9 card: willow logs", card.item.object .. "," .. tostring(card.item.hidden), "1519,false")
check("D10 card: status after the icon", card.status.x, 8 + 18 + 4)

-- The card is pinned: the scroll area moves down by 6 + 80 = 86, and the
-- card sits on the window above it.
local area = window._scroll.root
check("P1 scroll area moved under the card", area.x .. "," .. area.y, "8,118")
check("P2 scroll area shrunk to fit", area.w .. "," .. area.h, "-16,-126")
check("P3 scrollbar laid out again", window._scroll.refreshed, true)
local cardLayer = card.world.parent
check("P4 card on the window, not in the scrolling content", cardLayer.parent, window.root)
check("P5 card under the title bar", cardLayer.x .. "," .. cardLayer.y .. "," .. cardLayer.w, "14,38,-28")

-- Layout: content 484 wide, a row of 472 -> (472 + 3) // (137 + 3) = 3 columns,
-- stretched to (472 - 2 * 3) // 3 = 155 wide. Cells 4 to 6 on row 2, 7 on row 3.
-- The card is outside the scroll area, so the grid starts at the top: 6.
check("E1 first cell", cellFor(1).x .. "," .. cellFor(1).y, "6,6")
check("E1b cells stretched to fill the row", cellFor(1).w, 155)
check("E1c second cell after the first + a gap", cellFor(2).x, 6 + 155 + 3)
check("E2 seventh cell on row 3, column 1", cellFor(204).x .. "," .. cellFor(204).y, "6,48")
-- The texts stretch with the cell (anchored: the cell's width + these numbers).
local cellName, cellTimer = textsOf(cellFor(1))
check("E2b name to 3 from the right", cellName.w, -23)
check("E2c countdown with 3 each side", cellTimer.w, -6)
-- Three rows: 6 + 3 * 21 - 3 + 6 = 72 tall. The window keeps its height.
check("E3 content height", window.contentHeight, 72)
check("E4 window height left alone", window.root.height, 400)
check("E5 size reported for saving", states[#states].width .. "x" .. states[#states].height, "500x400")
check("E6 still open in the saved state", states[#states].open, 1)

-- Wider: 884 content, a row of 872 -> 875 // 140 = 6 columns of
-- (872 - 5 * 3) // 6 = 142. (Measured from "0" instead of the widest
-- digit, cells would be 77 + 18 + 3 = 98 at least, and all 7 would fit on one row.)
window:SetSize(900, 400)
grid.update(cells(NOW), NOW, 137)
check("E7 reflowed: 6 columns", cellFor(6).y .. "," .. cellFor(204).x .. "," .. cellFor(204).y, "6,6,27")
check("E8 cells re-stretched", cellFor(1).w, 142)

---------------------------------------------------------------- ticking
local before = #components
grid.update(cells(NOW + 61000), NOW + 61000, 137)
check("F1 no new components on update", #components, before)
check("F2 countdown ticks down", select(2, textsOf(cellFor(2))).content, "43m")

---------------------------------------------------------------- clicking
cellFor(2).hooks.click()
check("G1 clicked: gold outline", borderOf(cellFor(2)).rgba, 0xF2C66DFF)
check("G1b clicked: selected background", backgroundOf(cellFor(2)).rgba, 0x4A4640FF)
card = cardParts()
check("G2 card shows the clicked world", card.world.content, "w2")
check("G2c P2P badge", card.badge.content .. "," .. tostring(card.badgeBorder.hidden), "P2P,false")
check("G2d status in the spawn colour", card.status.content .. "," .. string.format("%X", card.status.rgba), "No tree,8FB8DEFF")
check("G2e countdown", card.countdown.content, "Spawns in 43:59")
check("G2f P2P outline", card.border.rgba, 0x8A6A2AFF)
check("G2g timer sprite, item hidden", card.sprite.sprite .. "," .. tostring(card.sprite.hidden) .. "," .. tostring(card.item.hidden), "10432,false,true")
cellFor(2).hooks.click()
check("G3 click again: unselected", borderOf(cellFor(2)).rgba, 0x8A6A2AFF)
check("G4 unselected: plain background", backgroundOf(cellFor(2)).rgba, 0x171512E8)
check("G4b unselected: card back on your world", cardParts().world.content, "w204")
cellFor(1).hooks.click()
card = cardParts()
check("G5 no intel", card.status.content .. "|" .. card.countdown.content, "Nothing known yet.|")
check("G5b no intel: no icon, text at the edge", tostring(card.sprite.hidden) .. "," .. tostring(card.item.hidden) .. "," .. card.status.x, "true,true,8")
cellFor(1).hooks.click()

-- Hover text.
cellFor(204).tip.handlers.onMouseOver(cellFor(204).tip)
check("H1 tooltip", cellFor(204).tip.text,
  "w204 - Evil willow - 45% | Lightning in 13:59 | Dies in 23:59 | East of the house portal in Rellekka")
check("H2 wheel handed to the window", cellFor(204).hooks.wheel, window._onScrollWheel)
check("H3 hover background", backgroundOf(cellFor(204)).rgba, 0x393530F2)
cellFor(204).tip.handlers.onMouseLeave(cellFor(204).tip)
check("H4 leave: plain background", backgroundOf(cellFor(204)).rgba, 0x171512E8)

---------------------------------------------------------------- closing
grid.toggle()
check("I1 closed", grid.wantsOpen(), false)
check("I2 saved as closed", states[#states].open, 0)
grid.update(cells(NOW), NOW, 137)
check("I3 stays closed", #windows, 1)
grid.toggle()
grid.update(cells(NOW), NOW, 137)
check("I4 toggled open again", #windows, 2)

---------------------------------------------------------------- shutdown keeps it wanted
grid.destroy()
check("J1 still wanted after shutdown", grid.wantsOpen(), true)
check("J2 window destroyed", windows[2].destroyed, true)

---------------------------------------------------------------- PrettyUI without _scroll
-- The card can't be pinned: it goes back into the scrolling content, with
-- the cells under it (6 + 80 + 6 = 92). Text can't be measured either, so
-- cells are at least 112: 875 // 115 = 7 columns of (872 - 18) // 7 = 122.
noScrollArea = true
config = nil
grid.update(cells(NOW), NOW, 137)
check("M1 window opened anyway", #windows, 3)
card = cardParts()
check("M2 card in the content", card.world.parent.parent, windows[3].content)
check("M3 card still filled", card.world.content, "w204")
-- (The fake Window:Destroy leaves the old cells in the list, so find w1 in this window.)
local firstCell
for _, layer in ipairs(cellsOnScreen()) do
  if layer.parent == windows[3].content and textsOf(layer).content == "w1" then firstCell = layer end
end
check("M4 cells under the card", firstCell.y, 92)
check("M4b fallback cell width", firstCell.w, 122)
-- (7 columns, so one row.)
check("M5 content height includes the card", windows[3].contentHeight, 92 + 21 - 3 + 6)
grid.destroy()

---------------------------------------------------------------- broken PrettyUI
prettyui.Window.new = function() error("no Window in this PrettyUI") end
grid.update(cells(NOW), NOW, 137)
check("K1 error logged", string.find(logged[#logged] or "", "[error] grid", 1, true) ~= nil, true)
check("K2 stops trying", grid.wantsOpen(), false)

---------------------------------------------------------------- which picture (ui/icons.lua)
local icons = require("ui/icons")
local function picture(word, treeType)
  local kind, value = icons.picture(word, treeType)
  return tostring(kind) .. " " .. tostring(value)
end
check("L1 alive, type unknown: woodcutting", picture("tree", nil), "sprite 31215")
check("L2 alive willow: willow logs", picture("tree", "willow"), "item 1519")
check("L3 alive plain tree: logs", picture("tree", "tree"), "item 1511")
check("L4 sapling: oak sapling item", picture("sapling", nil), "item 5370")
check("L5 dead: skull", picture("dead", "willow"), "sprite 33098")
check("L6 spawn: timer", picture("timer", nil), "sprite 10432")
check("L7 nothing", picture(nil, nil), "nil nil")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
