-- ui/grid.lua (and ui/gridtoolbar.lua, ui/treepicker.lua) with a fake
-- PrettyUI and fake game components: what the cells and header say,
-- layout, clicking, closing, saving where the window is, and the toolbar:
-- sort, filters, the notice, Reset, wrapping, and saving the choices.
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
  function component:MoveToFront() self.raised = (self.raised or 0) + 1 end
  function component:SetAssociatedObject(objectID) self.object = objectID end
  components[#components + 1] = component
  return component
end

id = { Font = {}, Component = { TOPLEVEL_V2__GAME_AREA = 1 }, StyleSheet = { COMBO_DEFAULT = 1 } }
local gameArea = newComponent("GameArea")
gameArea.height = 1000
ui = {
  Interfaces = { GetComponent = function() return gameArea end },
  Layer = "Layer", Rectangle = "Rectangle", Text = "Text", Sprite = "Sprite", ComboField = "ComboField",
  AlignMode = { TOPLEFT = 1, CENTRE = 2, BOTTOMRIGHT = 3 },
  Hook = { ONCLICK = "click", ONSCROLLWHEEL = "wheel", ONMOUSEOVER = "over", ONMOUSELEAVE = "leave" },
  Margin = { new = function(left, top, right, bottom) return { left = left, top = top, right = right, bottom = bottom } end },
}

-- Measuring text: every letter 6 wide, but "8" 20 wide, so the widest
-- countdown is "~8h 88m" (4 * 6 + 3 * 20 = 84), and a cell is at least
-- 20 (icon slot) + 24 ("w204") + 6 (gap) + 84 + 3 = 137 wide. While a tree
-- type is known, the widest one on show needs room too: "Willow" (36) + a
-- gap (6) = 179, or only "Oak" (18) + 6 = 161.
config = { Font = { MUSEO_SANS_11PT_REGULAR = {
  GetStringWidth = function(_, text)
    local _, eights = string.gsub(text, "8", "8")     -- gsub's second result: how many it replaced
    return #text * 6 + eights * 14
  end,
} } }

local windows = {}          -- every Window created
local noScrollArea = false  -- true: a PrettyUI without window._scroll (the card can't be pinned)
local CHROME = 40           -- fake title bar + borders

-- The toolbar's PrettyUI widgets, recorded so the tests can "click" them.
local combos = {}           -- every ComboBox, in order (each toolbar makes Sort, Worlds, Info)
local checkboxes = nil      -- the newest CheckboxButton (the Tree popup's ticks)
local resetButton = nil     -- the newest SimpleButton (Reset)
local contexts = {}         -- every Tooltip.registerContext call
local brokenToolbar = false -- true: a PrettyUI without ComboBox (the toolbar fails to build)

prettyui = {
  NewComponent = newComponent,
  Tooltip = {
    attach = function(target, _, options, handlers)
      local tip = { text = options.text, handlers = handlers }
      function tip:SetText(text) self.text = text end
      function tip:Show() self.shown = true end
      function tip:Hide() self.shown = false end
      target.tip = tip
      return tip
    end,
    registerContext = function(collection, parent, position)
      local context = { collection = collection, parent = parent, position = position }
      contexts[#contexts + 1] = context
      return context
    end,
    unregisterContext = function(collection)
      for _, context in ipairs(contexts) do
        if context.collection == collection then context.unregistered = true end
      end
    end,
  },
  -- An ordered ComboBox: Select(id, true) is the player picking an entry;
  -- .open is PrettyUI's flag for an open list.
  ComboBox = { new = function(parent, options)
    if brokenToolbar then error("no ComboBox in this PrettyUI") end
    local combo = { options = options, open = false, selectedID = options.selectedID }
    combo.root = newComponent("Combo", parent)
    combo.root:SetSize(options.width, options.height)
    function combo:Select(entryID, trigger)
      self.selectedID = entryID
      if trigger then self.options.onChange(self, entryID) end
    end
    function combo:_Close() self.open = false end
    function combo:Destroy() self.destroyed = true end
    combos[#combos + 1] = combo
    return combo
  end },
  CheckboxButton = {
    getSize = function(choices) return 100, #choices * 22 end,
    new = function(parent, choices, options)
      local box = { choices = choices, options = options, ticked = {} }
      box.root = newComponent("Checks", parent)
      for _, value in ipairs(options.selectedValues or {}) do box.ticked[value] = true end
      function box:SetSelected(value, on) self.ticked[value] = on or nil end
      function box:values()
        local list = {}
        for _, choice in ipairs(self.choices) do
          if self.ticked[choice.value] then list[#list + 1] = choice.value end
        end
        return table.concat(list, ",")
      end
      -- The player clicks one tick box.
      function box:click(value)
        self.ticked[value] = (not self.ticked[value]) or nil
        local list = {}
        for _, choice in ipairs(self.choices) do
          if self.ticked[choice.value] then list[#list + 1] = choice.value end
        end
        self.options.onChange(self, list, value, self.ticked[value] == true)
      end
      function box:Destroy() self.destroyed = true end
      checkboxes = box
      return box
    end,
  },
  SimpleButton = { new = function(parent, text, action, options)
    local button = { text = text, action = action }
    button.root = newComponent("Button", parent)
    button.root:SetSize(options.width, options.height)
    function button:Destroy() self.destroyed = true end
    resetButton = button
    return button
  end },
  Window = { new = function(_, options)
    local window = { options = options, title = options.title, overlays = {} }
    window.root = { width = options.width, height = options.height, x = options.x, y = options.y }
    window.minHeight = options.minHeight
    window.resize = { minHeight = options.minHeight }
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
      h = math.max(h, self.minHeight)             -- as PrettyUI's clamp
      self.root.width, self.root.height = w, h
      self.viewport.height = h - CHROME
      self.content.width = w - 16
    end
    function window:SetTitle(t) self.title = t end
    function window:Close() self.options.onClose(self); self.destroyed = true end
    function window:Destroy() self.destroyed = true end
    function window:_RegisterOverlay(component, isVisible, layout)
      self.overlays[component] = { isVisible = isVisible, layout = layout }
    end
    function window:_UnregisterOverlay(component) self.overlays[component] = nil end
    windows[#windows + 1] = window
    return window
  end },
}

-- Helpers to read the "screen".
-- Cells are the 18-tall Layers in the newest window's content (the fake
-- Window:Destroy leaves an old window's cells in the list).
local function cellsOnScreen()
  local list = {}
  local content = windows[#windows].content
  for _, c in ipairs(components) do
    if c.kind == "Layer" and c.h == 18 and c.parent == content and not c.destroyed then list[#list + 1] = c end
  end
  return list
end
local function textsOf(layer)      -- name, timer, tree type
  local texts = {}
  for _, c in ipairs(components) do
    if c.kind == "Text" and c.parent == layer then texts[#texts + 1] = c end
  end
  return texts[1], texts[2], texts[3]
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
-- The "you're here" mark: a second outline, 1 inside the first (or nil).
local function currentMarkOf(layer)
  local outlines = {}
  for _, c in ipairs(components) do
    if c.kind == "Rectangle" and c.parent == layer and c.fill == false then outlines[#outlines + 1] = c end
  end
  return outlines[2]
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
-- The card: the 80-tall Layer straight on the window (or in its content). Its
-- Texts in the order grid.lua makes them, by name; its outline Rectangle
-- and the badge's.
local function cardParts()
  local layer
  for _, c in ipairs(components) do
    local w = windows[#windows]
    if c.kind == "Layer" and (c.parent == w.root or c.parent == w.content) and c.h == 80 then layer = c end
  end
  local names = { "world", "badge", "status", "place", "countdown", "place2", "place3" }
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

-- The visible cells' world numbers, in reading order (rows, then columns).
local function shownWorlds()
  local list = {}
  for _, layer in ipairs(cellsOnScreen()) do
    if not layer.hidden then list[#list + 1] = layer end
  end
  table.sort(list, function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end)
  local numbers = {}
  for index, layer in ipairs(list) do numbers[index] = string.sub(textsOf(layer).content, 2) end
  return table.concat(numbers, ",")
end

-- The newest toolbar's parts.
local function toolbarCombos()        -- Sort, Worlds, Info
  return combos[#combos - 2], combos[#combos - 1], combos[#combos]
end
local function lastComponent(test)    -- the newest component that passes test
  for index = #components, 1, -1 do
    if test(components[index]) then return components[index] end
  end
end
local function treeButton()           -- the Layer holding the native combo frame
  return lastComponent(function(c) return c.kind == "ComboField" end).parent
end
local function treeLabel()
  local button = treeButton()
  return lastComponent(function(c) return c.kind == "Text" and c.parent == button end)
end
local function popupRoot() return checkboxes.root.parent end
local function scrim()                -- the Layer on the window that fills it
  local root = windows[#windows].root
  return lastComponent(function(c) return c.kind == "Layer" and c.parent == root and c.w == 0 and c.h == 0 end)
end
local function countText()            -- the gold "5 / 7"
  local root = windows[#windows].root
  return lastComponent(function(c) return c.kind == "Text" and c.parent == root and c.rgba == 0xF2C66DFF end)
end
-- The notice: its muted Text and the link (a 16-tall Layer), in the content.
local function noticeParts()
  local content = windows[#windows].content
  local text = lastComponent(function(c) return c.kind == "Text" and c.parent == content end)
  local link = lastComponent(function(c) return c.kind == "Layer" and c.parent == content and c.h == 16 end)
  return text, link
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
-- The toolbar was built (if it had failed, every toolbar test below would
-- run on the fallback path).
local sortCombo, worldsCombo, infoCombo = toolbarCombos()
check("B6 toolbar built: three dropdowns", #combos, 3)
check("B7 no toolbar error", #logged, 0)
check("B8 labels with the group baked in", sortCombo.options.entries[3].label .. "|" .. sortCombo.options.entries[3].order,
  "Sort: Soonest|3")
check("B9 starts on the defaults", sortCombo.selectedID .. "," .. worldsCombo.selectedID .. "," .. infoCombo.selectedID, "world,all,any")
check("B10 dropdown text inset from the top", sortCombo.options.contentMargin.top, 0)
check("B11 Tree button text", treeLabel().content, "Tree: Any")
check("B12 lists drawn on the game area", contexts[#contexts].collection == window.root and contexts[#contexts].parent == gameArea, true)
check("B13 the context knows its window", contexts[#contexts].ownerWindow, window)
check("B14 popup on the game area, hidden", popupRoot().parent == gameArea and popupRoot().hidden, true)
check("B15 popup registered as a window overlay", window.overlays[popupRoot()] ~= nil, true)
check("B16 no count or Reset while not filtering", tostring(countText().hidden) .. "," .. tostring(resetButton.root.hidden), "true,true")

local name, timer = textsOf(cellFor(2))
check("C1 w prefix", name.content, "w2")
check("C2 countdown in minutes", timer.content, "45m")
check("C3 spawn colour", timer.rgba, 0x8FB8DEFF)
name, timer = textsOf(cellFor(1))
check("C4 no intel: blank countdown", timer.content, "")
-- World numbers in the game's world-list colours (gold P2P, white F2P),
-- dimmed while we know nothing about the world.
check("C5 no intel, P2P: dim gold name", name.rgba, 0x8A7645FF)
check("C5b intel, P2P: gold name", (textsOf(cellFor(2))).rgba, 0xE2BD68FF)
check("C5c no intel, F2P: dim white name", (textsOf(cellFor(3))).rgba, 0x8F8F8FFF)
check("C5d intel, not in the world list: body text", (textsOf(cellFor(204))).rgba, 0xE7D7B0FF)
-- Your world: a sky-blue outline, twice as thick (a second one inside it).
check("C6 current world outlined sky blue", borderOf(cellFor(204)).rgba, 0x4FC3F7FF)
local mark = currentMarkOf(cellFor(204))
check("C6b current world: second outline inside the first",
  mark.x .. "," .. mark.y .. "," .. mark.w .. "," .. mark.h .. "," .. tostring(mark.hidden), "1,1,-2,-2,false")
check("C6c other worlds have no second outline", currentMarkOf(cellFor(2)), nil)
check("C7 P2P / F2P no longer in the outline", borderOf(cellFor(3)).rgba, 0x716B61FF)
-- The tree type, after the widest world number (20 + 24 + 6), in the status
-- colour. Its box fits the widest there can be: "Willow" (36) + 2.
local _, _, treeWord = textsOf(cellFor(204))
check("C7b tree type in the cell", treeWord.content .. "," .. treeWord.x .. "," .. treeWord.w, "Willow,50,38")
check("C7c tree type in the alive colour", treeWord.rgba, 0x7CC04AFF)
check("C7d no type known: empty", select(3, textsOf(cellFor(2))).content, "")

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
check("D1b card: world not in the list in body text", card.world.rgba, 0xE7D7B0FF)
check("D3 card: beta world has no badge", card.badge.content .. "," .. tostring(card.badgeBorder.hidden), ",true")
check("D4 card: status", card.status.content, "Evil willow - 45%")
check("D5 card: status in the alive colour", card.status.rgba, 0x7CC04AFF)
check("D6 card: place", card.place.content, "East of the house portal in Rellekka")
check("D7 card: strike, then death", card.countdown.content, "Lightning in 15m  -  Dies in 25m")
check("D8 card: sky-blue outline on your world", card.border.rgba, 0x4FC3F7FF)
check("D9 card: willow logs", card.item.object .. "," .. tostring(card.item.hidden), "1519,false")
check("D10 card: status after the icon", card.status.x, 8 + 18 + 4)

-- The card and toolbar are pinned. The toolbar's rows are 500 - 16 - 12
-- = 472 wide: Sort (175), Worlds (120) and Info (150) fit on row 1 with
-- 8-wide gaps (461), Tree goes on row 2. Two rows of 20 with a 4 gap = 44,
-- so the scroll area moves down by 6 + 80 + 6 + 44 = 136.
local area = window._scroll.root
check("P1 scroll area moved under the card and toolbar", area.x .. "," .. area.y, "8,168")
check("P2 scroll area shrunk to fit", area.w .. "," .. area.h, "-16,-176")
check("P2b toolbar row 1 under the card", sortCombo.root.x .. "," .. sortCombo.root.y, "14,124")
check("P2c Info at the end of row 1", infoCombo.root.x .. "," .. infoCombo.root.w, (14 + 175 + 8 + 120 + 8) .. ",150")
check("P2d Tree on row 2", treeButton().x .. "," .. treeButton().y .. "," .. treeButton().w, "14,148,140")
check("P2e minimum height grows with the toolbar", window.minHeight .. "," .. window.resize.minHeight, "240,240")
check("P3 scrollbar laid out again", window._scroll.refreshed, true)
local cardLayer = card.world.parent
check("P4 card on the window, not in the scrolling content", cardLayer.parent, window.root)
check("P5 card under the title bar", cardLayer.x .. "," .. cardLayer.y .. "," .. cardLayer.w, "14,38,-28")

-- Layout: content 484 wide, a row of 472. A tree type is known (the
-- willow), so cells are at least 179: (472 + 3) // (179 + 3) = 2 columns,
-- stretched to (472 - 3) // 2 = 234 wide. Two cells a row, the 7th on row 4.
-- The card is outside the scroll area, so the grid starts at the top: 6.
check("E1 first cell", cellFor(1).x .. "," .. cellFor(1).y, "6,6")
check("E1b cells stretched to fill the row", cellFor(1).w, 234)
check("E1c second cell after the first + a gap", cellFor(2).x, 6 + 234 + 3)
check("E2 seventh cell on row 4, column 1", cellFor(204).x .. "," .. cellFor(204).y, "6,69")
-- The texts stretch with the cell (anchored: the cell's width + these numbers).
local cellName, cellTimer = textsOf(cellFor(1))
check("E2b name to 3 from the right", cellName.w, -23)
check("E2c countdown with 3 each side", cellTimer.w, -6)
-- Four rows: 6 + 4 * 21 - 3 + 6 = 93 tall. The window keeps its height.
check("E3 content height", window.contentHeight, 93)
check("E4 window height left alone", window.root.height, 400)
check("E5 size reported for saving", states[#states].width .. "x" .. states[#states].height, "500x400")
check("E6 still open in the saved state", states[#states].open, 1)

-- Wider: 884 content, a row of 872 -> 875 // 182 = 4 columns of
-- (872 - 3 * 3) // 4 = 215. (Measured from "0" instead of the widest
-- digit, cells would be narrower, and all 7 would fit on one row.)
window:SetSize(900, 400)
grid.update(cells(NOW), NOW, 137)
check("E7 reflowed: 4 columns", cellFor(6).y .. "," .. cellFor(204).x .. "," .. cellFor(204).y, "27,442,27")
check("E8 cells re-stretched", cellFor(1).w, 215)

-- No tree type known any more: the cells give the space back
-- (875 // 140 = 6 columns of (872 - 5 * 3) // 6 = 142). Then it comes back.
local willow = records[204].treeType
records[204].treeType = nil
grid.update(cells(NOW), NOW, 137)
check("E8b no types: narrower cells, 6 columns", cellFor(1).w .. "," .. cellFor(6).y, "142,6")
check("E8c no types: the word is gone", select(3, textsOf(cellFor(204))).content, "")
records[204].treeType = willow
grid.update(cells(NOW), NOW, 137)
check("E8d types again: wider cells", cellFor(1).w, 215)

-- A hint that leaves two places: the card shows them on a line each, the
-- second after "or", and grows by that line (80 -> 96). The scroll area
-- moves down with it; the hover text keeps them on one line.
records[6] = { status = "none", spawnAt = NOW + 50 * MINUTE, hint = "north as the crow flies from Seers' Village" }
grid.update(cells(NOW), NOW, 137)
local areaBefore = area.y
cellFor(6).hooks.click()
local twoPlaces = lastComponent(function(c) return c.kind == "Layer" and c.parent == window.root and c.h == 96 end)
local placeTexts = {}
for _, c in ipairs(components) do
  if c.kind == "Text" and c.parent == twoPlaces then placeTexts[#placeTexts + 1] = c end
end
-- (world, badge, status, place, countdown, place 2, place 3: in the order the card makes them)
check("E8k two places: a line each", placeTexts[4].content .. "|" .. placeTexts[6].content,
  "East of the house portal in Rellekka|or Northwest of Seers' Village bank")
check("E8l second under the first, countdown under both, third hidden",
  placeTexts[4].y .. "," .. placeTexts[6].y .. "," .. tostring(placeTexts[6].hidden) .. "," .. placeTexts[5].y .. "," .. tostring(placeTexts[7].hidden),
  "43,59,false,75,true")
check("E8m scroll area moved down a line", area.y, areaBefore + 16)
cellFor(6).tip.handlers.onMouseOver(cellFor(6).tip)
check("E8n hover text keeps them on one line",
  string.find(cellFor(6).tip.text, "East of the house portal in Rellekka or Northwest of Seers' Village bank", 1, true) ~= nil, true)
cellFor(6).tip.handlers.onMouseLeave(cellFor(6).tip)
cellFor(6).hooks.click()
check("E8o unselected: card and scroll area back", cardParts().place.content .. "," .. area.y,
  "East of the house portal in Rellekka," .. areaBefore)
records[6] = nil

-- A typed sapling says just "Elder" in its cell (the icon and colour say
-- it is a sapling) and "Elder sapling" on the card. An untyped sapling
-- says nothing in its cell.
records[5] = { status = "sapling", treeType = "elder", spawnAt = NOW - 3 * MINUTE }
records[6] = { status = "sapling", spawnAt = NOW - 3 * MINUTE }
grid.update(cells(NOW), NOW, 137)
local _, _, saplingWord = textsOf(cellFor(5))
check("E8e typed sapling: its type, in the sapling colour", saplingWord.content .. "," .. string.format("%X", saplingWord.rgba), "Elder,F0DC5AFF")
check("E8f untyped sapling: no type text", select(3, textsOf(cellFor(6))).content, "")
cellFor(5).hooks.click()
check("E8g card: typed sapling spelled out", cardParts().status.content, "Elder sapling")
cellFor(5).hooks.click()
cellFor(6).hooks.click()
check("E8h card: untyped sapling", cardParts().status.content, "Strange sapling (unknown)")
cellFor(6).hooks.click()
records[5], records[6] = nil, nil
-- The space kept is for the widest word ON SHOW. With only an oak up, cells
-- are at least 137 + 18 + 6 = 161: 875 // 164 = 5 columns of
-- (872 - 12) // 5 = 172. With the willow back, 4 columns of 215 again.
records[204].treeType = "oak"
grid.update(cells(NOW), NOW, 137)
check("E8i a shorter word on show: narrower cells", cellFor(1).w .. "," .. cellFor(5).y .. "," .. cellFor(6).y, "172,6,27")
records[204].treeType = willow
grid.update(cells(NOW), NOW, 137)
check("E8j the wider word again", cellFor(1).w, 215)
-- The toolbar now fits on one row (609 of 872): the scroll area moves up.
check("E9 toolbar on one row, scroll area moved up", area.y .. "," .. treeButton().y, (32 + 86 + 6 + 20) .. ",124")

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
check("G2e countdown", card.countdown.content, "Spawns in 43m 59s")
check("G2f not your world: plain outline", card.border.rgba, 0x716B61FF)
check("G2h P2P: world and badge in the list's gold", string.format("%X,%X,%X", card.world.rgba, card.badge.rgba, card.badgeBorder.rgba), "E2BD68FF,E2BD68FF,E2BD68FF")
check("G2g timer sprite, item hidden", card.sprite.sprite .. "," .. tostring(card.sprite.hidden) .. "," .. tostring(card.item.hidden), "10432,false,true")
cellFor(2).hooks.click()
check("G3 click again: unselected", borderOf(cellFor(2)).rgba, 0x716B61FF)
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
  "w204 - Evil willow - 45% | Lightning in 13m 59s | Dies in 23m 59s | East of the house portal in Rellekka")
check("H2 wheel handed to the window", cellFor(204).hooks.wheel, window._onScrollWheel)
check("H3 hover background", backgroundOf(cellFor(204)).rgba, 0x393530F2)
cellFor(204).tip.handlers.onMouseLeave(cellFor(204).tip)
check("H4 leave: plain background", backgroundOf(cellFor(204)).rgba, 0x171512E8)

---------------------------------------------------------------- closing
grid.toggle()
check("I1 closed", grid.wantsOpen(), false)
check("I2 saved as closed", states[#states].open, 0)
-- The toolbar's parts on the game area don't go with the window: removed by hand.
check("I2b dropdowns (and their lists) removed", combos[1].destroyed and combos[2].destroyed and combos[3].destroyed, true)
check("I2c tree popup removed", popupRoot().destroyed and checkboxes.destroyed, true)
check("I2d popup overlay unregistered", next(windows[1].overlays), nil)
check("I2e context unregistered", contexts[1].unregistered, true)
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
-- cells are at least 112 + 40 (the widest tree type) + 6 = 158:
-- 875 // 161 = 5 columns of (872 - 12) // 5 = 172.
noScrollArea = true
local realConfig = config
config = nil
local combosBefore = #combos
grid.update(cells(NOW), NOW, 137)
check("M1 window opened anyway", #windows, 3)
check("M1b no toolbar without a pinned card (and no error)", #combos .. "," .. #logged, combosBefore .. ",0")
card = cardParts()
check("M2 card in the content", card.world.parent.parent, windows[3].content)
check("M3 card still filled", card.world.content, "w204")
-- (The fake Window:Destroy leaves the old cells in the list, so find w1 in this window.)
local firstCell
for _, layer in ipairs(cellsOnScreen()) do
  if layer.parent == windows[3].content and textsOf(layer).content == "w1" then firstCell = layer end
end
check("M4 cells under the card", firstCell.y, 92)
check("M4b fallback cell width", firstCell.w, 172)
-- (5 columns, so two rows.)
check("M5 content height includes the card", windows[3].contentHeight, 92 + 2 * 21 - 3 + 6)
grid.destroy()

---------------------------------------------------------------- broken PrettyUI
local realWindowNew = prettyui.Window.new
prettyui.Window.new = function() error("no Window in this PrettyUI") end
grid.update(cells(NOW), NOW, 137)
check("K1 error logged", string.find(logged[#logged] or "", "[error] grid", 1, true) ~= nil, true)
check("K2 stops trying", grid.wantsOpen(), false)
prettyui.Window.new = realWindowNew
noScrollArea = false
config = realConfig

---------------------------------------------------------------- toolbar: sort and filters
-- More worlds, so the filters have something to do:
--   1, 6  no intel        2  spawn timer, no hint      3  F2P, dead oak, a hint
--   4  elder sapling, no hint   5  a hint only ("none")   204  beta world, alive willow (yours)
records = {
  [2] = { status = "none", spawnAt = NOW + 45 * MINUTE },
  [3] = { status = "dead", treeType = "oak", deadAt = NOW - 4 * MINUTE,
          hint = "close to a large collection of willow trees" },
  [4] = { status = "sapling", treeType = "elder", spawnAt = NOW - 3 * MINUTE },
  [5] = { status = "none", hint = "close to a Runecrafting altar" },
  [204] = records[204],
}
local views = {}
grid.setOnViewChange(function(state) views[#views + 1] = state end)
grid.restore({ x = 10, y = 20, width = 500, height = 400, open = 1 })
logged = {}
grid.update(cells(NOW), NOW, 137)
window = windows[#windows]
area = window._scroll.root
sortCombo, worldsCombo, infoCombo = toolbarCombos()
local function update() grid.update(cells(NOW), NOW, 137) end

check("T0 no errors", #logged, 0)
check("T1 all worlds by number", shownWorlds(), "1,2,3,4,5,6,204")
check("T2 nothing hidden, no notice", tostring(cellFor(3).hidden) .. "," .. tostring((noticeParts()).hidden), "nil,true")
-- Content 484 wide: 2 columns, 4 rows: 6 + 4 * 21 - 3 + 6 = 93.
check("T3 content height without a notice", window.contentHeight, 93)

-- Sort: Soonest groups dead -> alive -> sapling -> spawn, then no timer by number.
sortCombo:Select("soonest", true)
check("T4 soonest reorders the cells", shownWorlds(), "3,204,4,2,1,5,6")
check("T5 first in the soonest order is top left", cellFor(3).x .. "," .. cellFor(3).y, "6,6")
check("T6 sort saved", views[#views].sort .. "|" .. views[#views].trees, "soonest|")
check("T7 sorting is not filtering: no count", countText().hidden, true)
sortCombo:Select("worldDesc", true)
check("T8 world (high first)", shownWorlds(), "204,6,5,4,3,2,1")

-- A hovered cell that gets hidden loses its tooltip and hover colour.
cellFor(3).tip.handlers.onMouseOver(cellFor(3).tip)
-- Worlds: P2P hides F2P world 3 and beta world 204 (not in the world list).
worldsCombo:Select("p2p", true)
check("T9 P2P only", shownWorlds(), "6,5,4,2,1")
check("T10 F2P cell hidden", cellFor(3).hidden, true)
check("T11 hidden cell's tooltip hidden", cellFor(3).tip.shown, false)
check("T12 hidden cell's hover colour gone", backgroundOf(cellFor(3)).rgba, 0x171512E8)
check("T13 count shown, out of every cell", countText().content .. "," .. tostring(countText().hidden), "5 / 7,false")
check("T14 Reset shown", resetButton.root.hidden, false)
-- 5 cells, 2 columns: 3 rows, bottom at 6 + 3 * 21 - 3 = 66; the notice 4
-- below. "Showing 5 of 7 worlds. To see more," is 35 letters (210 wide),
-- so the link fits after it: 6 + 210 + 4 = 220.
local noticeText, noticeLink = noticeParts()
check("T15 notice text", noticeText.content .. "|" .. tostring(noticeText.hidden), "Showing 5 of 7 worlds. To see more,|false")
check("T16 notice under the last row", noticeText.y, 70)
check("T17 link right after the text", noticeLink.x .. "," .. noticeLink.y .. "," .. tostring(noticeLink.hidden), "220,70,false")
check("T18 content height counts the notice", window.contentHeight, 70 + 16 + 6)
check("T19 worlds saved", views[#views].worlds, "p2p")
-- Count + Reset (60 + 4 + 56 = 120) still fit after Tree on row 2: still 2 rows.
check("T20 count and Reset on row 2", countText().y .. "," .. resetButton.root.x, "148," .. (14 + 140 + 8 + 120 - 56))
check("T20b still two rows", area.y, 168)
worldsCombo:Select("f2p", true)
check("T21 F2P only", shownWorlds(), "3")
worldsCombo:Select("all", true)

-- Info.
infoCombo:Select("noIntel", true)
check("T22 no intel: unknown and hint-only worlds", shownWorlds(), "6,5,1")
infoCombo:Select("needsHint", true)
check("T23 needs hint: active worlds with no hint or place", shownWorlds(), "4,2")
infoCombo:Select("any", true)
check("T24 back to everything", shownWorlds(), "204,6,5,4,3,2,1")
check("T25 not filtering: notice and count gone", tostring((noticeParts()).hidden) .. "," .. tostring(countText().hidden), "true,true")

-- Tree: the button opens the popup under it (window at 10,20; button at 14,148, 20 high).
treeButton().hooks.click()
check("T26 popup opened", popupRoot().hidden, false)
check("T27 popup under the button, on the game area", popupRoot().x .. "," .. popupRoot().y, (10 + 14) .. "," .. (20 + 148 + 20 + 2))
check("T28 scrim covers the window", scrim().hidden, false)
checkboxes:click("elder")
check("T29 elder: the elder sapling", shownWorlds(), "4")
check("T30 Tree button sums it up", treeLabel().content, "Tree: Elder")
check("T31 popup stays open while ticking", popupRoot().hidden, false)
checkboxes:click("oak")
checkboxes:click("willow")
check("T32 three types", shownWorlds() .. "|" .. treeLabel().content, "204,4,3|Tree: 3 types")
check("T33 trees saved as text", views[#views].trees, "oak,willow,elder")
-- A click anywhere else in the window lands on the scrim and closes the popup.
scrim().hooks.click()
check("T34 scrim click closes the popup", tostring(popupRoot().hidden) .. "," .. tostring(scrim().hidden), "true,true")
checkboxes:click("elder")
checkboxes:click("oak")

-- Nothing matches: say so at the top.
infoCombo:Select("noIntel", true)
noticeText, noticeLink = noticeParts()
check("T35 no worlds", shownWorlds(), "")
check("T36 no-match notice at the top", noticeText.content .. "|" .. noticeText.y, "No worlds match. To see more,|6")
check("T37 content height: just the notice", window.contentHeight, 6 + 16 + 6)
check("T38 count", countText().content, "0 / 7")

-- "remove filters." resets Worlds, Info and Tree, never Sort.
noticeLink.hooks.over()
check("T39 link brighter on hover", (lastComponent(function(c) return c.kind == "Text" and c.parent == noticeLink end)).rgba, 0xFFE9A8FF)
noticeLink.hooks.click()
check("T40 everything shown again", shownWorlds(), "204,6,5,4,3,2,1")
check("T41 sort kept", views[#views].sort .. "," .. views[#views].worlds .. "," .. views[#views].info .. "," .. views[#views].trees,
  "worldDesc,all,any,")
check("T42 controls show the reset", infoCombo.selectedID .. "," .. checkboxes:values() .. "," .. treeLabel().content, "any,,Tree: Any")
check("T43 link colour back when hidden", (lastComponent(function(c) return c.kind == "Text" and c.parent == noticeLink end)).rgba, 0xF2C66DFF)

-- Reset does the same.
worldsCombo:Select("p2p", true)
checkboxes:click("yew")
resetButton.action()
check("T44 Reset", shownWorlds() .. "|" .. worldsCombo.selectedID .. "|" .. checkboxes:values(), "204,6,5,4,3,2,1|all|")
check("T45 Reset saved, sort kept", views[#views].sort .. "," .. views[#views].worlds, "worldDesc,all")
local savedCount = #views
worldsCombo:Select("all", true)
check("T46 picking the same entry saves nothing", #views, savedCount)

---------------------------------------------------------------- toolbar: open dropdowns
-- PrettyUI opens a list itself (its .open turns true): the next frame shows the scrim.
sortCombo.open = true
grid.onLogic()
check("U1 open list: scrim shown and raised", tostring(scrim().hidden) .. "," .. tostring(scrim().raised ~= nil), "false,true")
scrim().hooks.click()
check("U2 a click elsewhere closes the list", tostring(sortCombo.open) .. "," .. tostring(scrim().hidden), "false,true")
grid.onLogic()
check("U3 stays closed", scrim().hidden, true)
-- Opening a list closes the Tree popup.
treeButton().hooks.click()
infoCombo.open = true
grid.onLogic()
check("U4 list opening closes the popup", tostring(popupRoot().hidden) .. "," .. tostring(scrim().hidden), "true,false")
-- The list closes by itself (an entry picked, Esc): the scrim goes.
infoCombo.open = false
grid.onLogic()
check("U5 list closed by itself: scrim gone", scrim().hidden, true)
-- The Tree button again closes the popup.
treeButton().hooks.click()
treeButton().hooks.click()
check("U6 Tree button toggles the popup", tostring(popupRoot().hidden) .. "," .. tostring(scrim().hidden), "true,true")
-- A PrettyUI without _Close: a scrim click can't close the list, but the
-- scrim must still go away (and not come back), so the window isn't blocked.
local realClose = sortCombo._Close
sortCombo._Close = nil
sortCombo.open = true
grid.onLogic()
scrim().hooks.click()
grid.onLogic()
grid.onLogic()
check("U7 without _Close: list stays open, scrim stays gone", tostring(sortCombo.open) .. "," .. tostring(scrim().hidden), "true,true")
sortCombo.open = false                -- the player picks an entry or presses Esc
grid.onLogic()
check("U8 then closes normally", scrim().hidden, true)
sortCombo._Close = realClose

---------------------------------------------------------------- toolbar: wrapping
-- 200 wide: rows of 200 - 28 = 172. No two controls fit side by side, so
-- each gets a row and all stretch to 172 (Sort is squeezed to it).
-- The card is 172 wide too, so its texts have 156 and wrap: the place
-- (36 letters, 216 wide) and the countdown (38 letters, 228 wide) each
-- need 2 lines. The card grows from 80 to 80 + 2 * 16 = 112, and the
-- toolbar and scroll area move down by those 32.
-- 4 rows: 4 * 20 + 3 * 4 = 92, so the scroll area is at 32 + 118 + 6 + 92 = 248.
window:SetSize(200, 250)
update()
local tallCard = lastComponent(function(c) return c.kind == "Layer" and c.parent == window.root and c.h == 112 end)
check("V0 card grew to fit its wrapped texts", tallCard ~= nil, true)
local wrapped = {}
for _, c in ipairs(components) do
  if c.kind == "Text" and c.parent == tallCard then wrapped[#wrapped + 1] = c end
end
-- (world, badge, status, place, countdown: in the order the card makes them)
check("V0b status 1 line, place and countdown 2 each",
  wrapped[3].maxLines .. "," .. wrapped[4].maxLines .. "," .. wrapped[5].maxLines, "1,2,2")
check("V0c place under the status, countdown under the place",
  wrapped[4].y .. "," .. wrapped[4].h .. "," .. wrapped[5].y .. "," .. wrapped[5].h, "43,32,75,32")
check("V1 one control per row, stretched", sortCombo.root.w .. "," .. worldsCombo.root.w .. "," .. treeButton().w, "172,172,172")
check("V1b toolbar moved down with the card", sortCombo.root.y, 124 + 32)
check("V2 rows", worldsCombo.root.y .. "," .. treeButton().y, (156 + 24) .. "," .. (156 + 72))
check("V3 scroll area under four rows", area.y, 248)
-- Minimum 32 + 216 + 64 + 8 = 320: the 250-high window grows to it.
check("V4 window grew to the new minimum", window.minHeight .. "," .. window.root.height, "320,320")
-- Filtering adds a fifth row (count + Reset, stretched: Reset at the right end).
worldsCombo:Select("p2p", true)
check("V5 fifth row", area.y .. "," .. countText().y, (248 + 24) .. "," .. (156 + 96))
check("V6 Reset at the right end of a stretched row", resetButton.root.x, 14 + 172 - 56)
-- The notice doesn't fit on one line (210 + 4 + 92 > 172): the link goes under it.
noticeText, noticeLink = noticeParts()
check("V7 link wraps under the text", noticeLink.x .. "," .. noticeLink.y, "6," .. (noticeText.y + 16))
check("V8 text cut to the row", noticeText.w, 172)
worldsCombo:Select("all", true)
-- Wide again: one row, natural widths.
window:SetSize(900, 400)
update()
check("V9 back to one row", area.y .. "," .. sortCombo.root.w .. "," .. treeButton().w, "144,175,140")
-- A resize closes an open popup (its button moves).
treeButton().hooks.click()
window:SetSize(500, 400)
update()
check("V10 resize closes the popup", tostring(popupRoot().hidden) .. "," .. tostring(scrim().hidden), "true,true")

---------------------------------------------------------------- toolbar: a new world
-- A world appears (cells rebuilt): the filters stay.
worldsCombo:Select("p2p", true)
records[205] = { status = "none", hint = "close to a Runecrafting altar" }
update()
check("W1 new world's cell built, but filtered (not in the list)", tostring(cellFor(205) ~= nil) .. "," .. tostring(cellFor(205).hidden), "true,true")
check("W2 the rest still filtered", shownWorlds(), "6,5,4,2,1")
check("W3 count out of the new total", countText().content, "5 / 8")
records[205] = nil
update()
worldsCombo:Select("all", true)

---------------------------------------------------------------- toolbar: saved choices
-- restoreView takes the saved strings; anything odd falls back to the default.
grid.destroy()
grid.restoreView({ sort = "bogus", worlds = 5, info = "needsHint", trees = "magic,,nonsense,yew" })
update()
sortCombo, worldsCombo, infoCombo = toolbarCombos()
check("X1 restored into the controls", sortCombo.selectedID .. "," .. worldsCombo.selectedID .. "," .. infoCombo.selectedID, "world,all,needsHint")
check("X2 tree ticks restored, in list order", table.concat(checkboxes.options.selectedValues, ","), "yew,magic")
check("X3 Tree button", treeLabel().content, "Tree: Yew, Magic")
check("X4 restored filter applied", shownWorlds(), "")
savedCount = #views
grid.update(cells(NOW + 1000), NOW + 1000, 137)
check("X5 restoring saves nothing", #views, savedCount)
infoCombo:Select("any", true)
check("X6 saved form", views[#views].sort .. "|" .. views[#views].worlds .. "|" .. views[#views].info .. "|" .. views[#views].trees,
  "world|all|any|yew,magic")
-- Round trip: what onViewChange gave comes back the same.
local roundTrip = views[#views]
grid.destroy()
grid.restoreView(roundTrip)
update()
check("X7 round trip", (toolbarCombos()).selectedID .. "|" .. table.concat(checkboxes.options.selectedValues, ","), "world|yew,magic")
grid.destroy()
grid.restoreView("junk")
update()
check("X8 junk: defaults", (toolbarCombos()).selectedID .. "," .. #checkboxes.options.selectedValues, "world,0")
grid.destroy()
grid.restoreView({ trees = { "yew" } })
update()
check("X9 a list for trees is ignored (only text is saved)", #checkboxes.options.selectedValues, 0)

---------------------------------------------------------------- toolbar: failures
-- A PrettyUI without ComboBox: the grid still opens, without the toolbar
-- and with no filters (so no world is hidden), and logs one line.
grid.destroy()
grid.restoreView({ sort = "soonest", worlds = "p2p", info = "any", trees = "" })
brokenToolbar = true
logged = {}
savedCount = #views
update()
window = windows[#windows]
check("Y1 grid still open", grid.wantsOpen() and not window.destroyed, true)
check("Y2 one toolbar error logged", #logged .. "|" .. string.sub(logged[1] or "", 1, 20), "1|[error] grid toolbar")
check("Y3 every world, by number", shownWorlds(), "1,2,3,4,5,6,204")
check("Y4 scroll area just under the card", window._scroll.root.y, 32 + 86)
check("Y5 no notice", (noticeParts()).hidden, true)
update()
check("Y6 not retried every second", #logged, 1)
check("Y7 saved choices untouched", #views, savedCount)
check("Y8 the half-built toolbar's context removed", contexts[#contexts].unregistered, true)
grid.onLogic()
check("Y9 no frame checks without a toolbar", #logged, 1)
brokenToolbar = false

-- The per-frame check failing removes the toolbar (one error, not 50 a second).
grid.destroy()
update()
window = windows[#windows]
check("Y10 toolbar back, soonest + P2P kept", shownWorlds(), "4,2,1,5,6")
logged = {}
scrim().MoveToFront = function() error("boom") end
sortCombo = toolbarCombos()
sortCombo.open = true
grid.onLogic()
grid.onLogic()
check("Y11 one error", #logged .. "|" .. string.sub(logged[1] or "", 1, 20), "1|[error] grid toolbar")
update()
check("Y12 then every world shows", shownWorlds(), "1,2,3,4,5,6,204")
check("Y13 dropdowns removed", sortCombo.destroyed, true)
grid.destroy()

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

---------------------------------------------------------------- PrettyUI 1.2.2 (the Plugin Hub's)
-- It has no prettyui.NewComponent, so parts.new calls Type.new(parent) itself.
local parts = require("ui/parts")
local newComponent = prettyui.NewComponent
prettyui.NewComponent = nil
local FakeType = { new = function(parent) return { madeBy = "Type.new", parent = parent } end }
local made = parts.new(FakeType, "the parent")
check("H1 without NewComponent: Type.new(parent)", made.madeBy .. "," .. made.parent, "Type.new,the parent")
prettyui.NewComponent = newComponent
check("H2 with NewComponent: PrettyUI's", parts.new(ui.Layer, "p").kind, "Layer")

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
