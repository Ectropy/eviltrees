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
  components[#components + 1] = component
  return component
end

id = { Font = {}, Component = { TOPLEVEL_V2__GAME_AREA = 1 } }
local gameArea = newComponent("GameArea")
ui = {
  Interfaces = { GetComponent = function() return gameArea end },
  Layer = "Layer", Rectangle = "Rectangle", Text = "Text",
  AlignMode = { TOPLEFT = 1, CENTRE = 2, BOTTOMRIGHT = 3 },
  Hook = { ONCLICK = "click", ONSCROLLWHEEL = "wheel" },
}

local windows = {}          -- every Window created
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
local function cellsOnScreen()
  local list = {}
  for _, c in ipairs(components) do
    if c.kind == "Layer" and not c.destroyed then list[#list + 1] = c end
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
local function headerLines()
  local lines = {}
  for _, c in ipairs(components) do
    if c.kind == "Text" and c.parent == windows[#windows].content then lines[#lines + 1] = c.content end
  end
  return lines[1], lines[2]
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

local top, bottom = headerLines()
check("D1 header: the world you're on", top, "w204 - Evil willow - 45% (you're here)  -  Lightning in 15:00")
check("D2 header: place", bottom, "East of the house portal in Rellekka")

-- (45% means strike 1 is done, so the next one is strike 2 at M + 20.)
-- Layout: content 484 wide -> (484 - 12 + 3) // 87 = 5 columns; cells 6 and 7 go on row 2.
check("E1 first cell", cellFor(1).x .. "," .. cellFor(1).y, "6,42")
check("E2 seventh cell on row 2", cellFor(204).x .. "," .. cellFor(204).y, "93,63")
-- Two rows: 42 + 2 * 21 - 3 + 6 = 87 tall. The window keeps its height.
check("E3 content height", window.contentHeight, 87)
check("E4 window height left alone", window.root.height, 400)
check("E5 size reported for saving", states[#states].width .. "x" .. states[#states].height, "500x400")
check("E6 still open in the saved state", states[#states].open, 1)

-- Wider: everything on one row.
window:SetSize(700, 400)
grid.update(cells(NOW), NOW, 137)
check("E7 reflowed to one row", cellFor(204).y, 42)

---------------------------------------------------------------- ticking
local before = #components
grid.update(cells(NOW + 61000), NOW + 61000, 137)
check("F1 no new components on update", #components, before)
check("F2 countdown ticks down", select(2, textsOf(cellFor(2))).content, "43m")

---------------------------------------------------------------- clicking
cellFor(2).hooks.click()
check("G1 clicked: gold outline", borderOf(cellFor(2)).rgba, 0xF2C66DFF)
check("G1b clicked: selected background", backgroundOf(cellFor(2)).rgba, 0x4A4640FF)
top = headerLines()
check("G2 header shows the clicked world", top, "w2 - No tree  -  Spawns in 43:59")
cellFor(2).hooks.click()
check("G3 click again: unselected", borderOf(cellFor(2)).rgba, 0x8A6A2AFF)
check("G4 unselected: plain background", backgroundOf(cellFor(2)).rgba, 0x171512E8)

-- Hover text.
cellFor(204).tip.handlers.onMouseOver(cellFor(204).tip)
check("H1 tooltip", cellFor(204).tip.text,
  "w204 - Evil willow - 45% (you're here) | Lightning in 13:59 | East of the house portal in Rellekka")
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

---------------------------------------------------------------- broken PrettyUI
prettyui.Window.new = function() error("no Window in this PrettyUI") end
grid.update(cells(NOW), NOW, 137)
check("K1 error logged", string.find(logged[#logged] or "", "[error] grid", 1, true) ~= nil, true)
check("K2 stops trying", grid.wantsOpen(), false)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
