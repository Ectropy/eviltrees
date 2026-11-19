-- ui/dashboard.lua through main.lua, with a fake PrettyUI and stubbed game
-- globals: the world card and the buttons under it, when the view rebuilds
-- vs the card updates in place, and the Clear world button. Fails on any
-- "[error]" log line.
-- Run with: node check.js <plugin dir> test_dashboard.lua
local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then passes = passes + 1
  else failures = failures + 1; print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)) end
end

---------------------------------------------------------------- fake PrettyUI
-- Records every component added, so the test can read the "screen".
local views = {}            -- every SimpleView created, newest last
local confirms = {}         -- options of every Confirm dialog opened
local components = {}       -- every plain game component created (the world card's), in order
prettyui = {
  NewComponent = function(kind, parent)
    local component = { kind = kind, parent = parent, x = 0, y = 0 }
    function component:SetPos(x, y) self.x, self.y = x, y end
    function component:SetSize(w, h) self.w, self.h = w, h end
    function component:Destroy() self.destroyed = true end
    function component:SetAssociatedObject(objectID) self.object = objectID end
    components[#components + 1] = component
    return component
  end,
  SimpleView = { new = function(parent, options)
    local view = { parent = parent, options = options, items = {}, scrollY = 0, destroyed = false }
    local function add(kind, value, extra)
      local text = type(value) == "table" and value.text or value
      local component = { content = text }
      view.items[#view.items + 1] = { kind = kind, component = component, extra = extra }
      return component
    end
    function view:AddTitle(value) return add("title", value) end
    function view:AddText(value) return add("text", value) end
    function view:AddDivider() return add("divider", "") end
    function view:AddSimpleButton(label, action) return add("button", label, action) end
    function view:SetScrollPosition(y) self.scrollY = y end
    function view:Destroy() self.destroyed = true end
    views[#views + 1] = view
    return view
  end },
  Confirm = { new = function(_, options) confirms[#confirms + 1] = options end },
}

-- The newest world card: its Layer (the only Layers made here are cards'),
-- and its Texts by name, in the order ui/worldcard.lua makes them.
local function cardLayers()
  local list = {}
  for _, c in ipairs(components) do
    if c.kind == "Layer" then list[#list + 1] = c end
  end
  return list
end
local function card()
  local layers = cardLayers()
  local layer = layers[#layers]
  local names = { "world", "badge", "status", "place", "countdown", "place2", "place3" }
  local parts, texts = { layer = layer }, 0
  for _, c in ipairs(components) do
    if c.parent == layer and c.kind == "Text" then
      texts = texts + 1
      parts[names[texts]] = c
    elseif c.parent == layer and c.kind == "Rectangle" and c.fill == false and parts.border == nil then
      parts.border = c
    end
  end
  return parts
end

-- All texts on the newest card and view, joined by newlines, for easy searching.
local function screen()
  local view = views[#views]
  if view == nil then return "" end
  local lines = {}
  local parts = card()
  for _, name in ipairs({ "world", "status", "place", "countdown" }) do
    if parts[name] ~= nil then lines[#lines + 1] = tostring(parts[name].content) end
  end
  for _, item in ipairs(view.items) do lines[#lines + 1] = tostring(item.component.content) end
  return table.concat(lines, "\n")
end
local function shows(text) return string.find(screen(), text, 1, true) ~= nil end
-- The newest view's button whose label starts with this text.
local function button(label)
  for _, item in ipairs(views[#views].items) do
    if item.kind == "button" and string.sub(item.component.content, 1, #label) == label then return item end
  end
end

---------------------------------------------------------------- the game
local game = require("fakegame")   -- stubs every game global (tests/fakegame.lua)
local handlers, errors, logged, interfaces = game.handlers, game.errors, game.logged, game.interfaces
local logic, server = game.logic, game.server

-- The card is made of plain components: give their kinds names. (ui.Text
-- stays fakegame's table; the plain debug panel calls ui.Text.new.)
ui.Layer, ui.Rectangle, ui.Sprite = "Layer", "Rectangle", "Sprite"
local realNewComponent = prettyui.NewComponent
prettyui.NewComponent = function(kind, parent)
  return realNewComponent(kind == ui.Text and "Text" or kind, parent)
end

interfaces["550:48"] = "Friends List RuneScape 204"
require("main")
local store = require("core/store")

logic(1)
server(2)                    -- reads the world
check("S1 nothing drawn before the page opens", #views, 0)

---------------------------------------------------------------- opening the page
handlers.ContentLayerReady({ component = { width = 400, height = 600 } })
check("O1 one view", #views, 1)
-- The card first: 8 from the edges, 80 tall while every text fits on one
-- line. The view under it: 8 + 80 + 6 = 94 down, to 8 from the bottom.
local first = card()
check("O1b one card, at the top of the page", #cardLayers() .. "," .. first.layer.x .. "," .. first.layer.y .. "," .. first.layer.w .. "," .. first.layer.h, "1,8,8,-16,80")
check("O1c view under the card", views[1].options.y .. "," .. views[1].options.width .. "," .. views[1].options.height, "94,384,498")
check("O3 scouted count in the button", button("All worlds").component.content, "All worlds (0 / " .. require("data/worlds").count .. ")")
check("O4 current world on the card", first.world.content, "w204")
check("O4b sky-blue outline on your world", first.border.rgba, 0x4FC3F7FF)
check("O4c no intel", first.status.content, "Nothing known yet.")
check("O4d how to find out", shows("Talk to a spirit tree"), true)
-- The only title left is the debug section's. (The debug text itself may
-- mention other worlds, so look at titles only.)
local titles = {}
for _, item in ipairs(views[1].items) do
  if item.kind == "title" then titles[#titles + 1] = item.component.content end
end
check("O5 no \"Evil Trees\" or \"Other worlds\" title", table.concat(titles, ","), "Debug")
check("O6 debug section", shows("Debug"), true)
check("O7 no clear button without intel", button("Clear world"), nil)

---------------------------------------------------------------- a spirit tree timer
server(1)                    -- the page shows on the frame after a server tick
interfaces["1184:4"] = "Spirit tree"
interfaces["1184:10"] = "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 7 minutes."
logic(1)                     -- dialogue is read on that frame
interfaces["1184:4"] = nil; interfaces["1184:10"] = nil
logic(49)                    -- passes logicTick 50: refresh
check("T1 rebuilt", #views, 2)
check("T1 old view destroyed", views[1].destroyed, true)
check("T1b the card is kept, not built again", #cardLayers(), 1)
check("T2 status, in the spawn colour", card().status.content .. "," .. string.format("%X", card().status.rgba), "No tree,8FB8DEFF")
-- the fake clock never learns the seconds here, so the time gets a "~"
check("T3 countdown", string.match(card().countdown.content, "^Spawns in ~%dm") ~= nil, true)
check("T4 clear button", button("Clear world") ~= nil, true)
check("T4b no hint to scout any more", shows("Talk to a spirit tree"), false)

-- A second later: the card's countdown changes in place (no rebuild).
local before = card().countdown.content
logic(50)
check("T5 no rebuild", #views, 2)
check("T5 countdown ticked", card().countdown.content ~= before, true)

---------------------------------------------------------------- another world
store.worlds[117] = { status = "none", spawnAt = 1793945263552, hint = "north as the crow flies from Seers' Village" }
logic(50)
check("W1 rebuilt for the new count", #views, 3)
check("W2 other worlds are the grid's job: not listed", shows("w117"), false)
check("W4 scouted", string.find(button("All worlds").component.content, "All worlds (2 / ", 1, true), 1)

---------------------------------------------------------------- Clear world
button("Clear world").extra()        -- click
check("C1 asks first", #confirms, 1)
check("C1 still there until confirmed", store.worlds[204] ~= nil, true)
confirms[1].onConfirm()
check("C2 cleared", store.worlds[204], nil)
check("C3 other world kept", store.worlds[117] ~= nil, true)
check("C4 redrawn without intel", card().status.content .. "," .. tostring((button("Clear world"))), "Nothing known yet.,nil")   -- the extra brackets turn "no result" into nil

---------------------------------------------------------------- page closed and reopened
local count = #views
handlers.ContentLayerReady({ component = { width = 300, height = 500 } })
check("R1 new view on reopen", #views, count + 1)
check("R1 old one destroyed", views[count].destroyed, true)
local layers = cardLayers()
check("R1b new card too, old one destroyed", #layers .. "," .. tostring(layers[1].destroyed) .. "," .. tostring(layers[2].destroyed), "2,true,nil")
check("R2 content back at once", card().world.content, "w204")

---------------------------------------------------------------- a long place wraps
-- The card is the full view: nothing is cut off. A hint that leaves two
-- places shows them on a line each, the second after "or". The card grows
-- by that line (16) to 96, and the view is built again 16 lower. The first
-- place now starts with the label "Hint: " (42 letters = 294 > 268), so it
-- wraps to 2 lines (32): everything under it moves down 16 more.
store.worlds[204] = { status = "none", spawnAt = 1793945263552, hint = "north as the crow flies from Seers' Village" }
count = #views
logic(50)
local long = card()
-- The card's second place Text is made after the countdown: the 6th Text.
local cardTexts = {}
for _, c in ipairs(components) do
  if c.kind == "Text" and c.parent == long.layer then cardTexts[#cardTexts + 1] = c end
end
local second, third = cardTexts[6], cardTexts[7]
check("L1 first place on its own line", long.place.content .. "|" .. long.place.y, "Hint: East of the house portal in Rellekka|43")
check("L2 second place under it, after \"or\"", second.content .. "|" .. second.y .. "|" .. tostring(second.hidden),
  "or Northwest of Seers' Village bank|75|false")
check("L2b no third place", third.content .. "|" .. tostring(third.hidden), "|true")
check("L3 countdown moved down under them", long.countdown.y, 43 + 32 + 16)
-- A line too long for the card still wraps. The page is 300 wide, so the
-- texts have 300 - 16 - 16 = 268; no font can be measured in this fake
-- game, so a text counts as 7 a letter: this hint is 50 letters = 350.
store.worlds[204].hint = "close to the place where fairies gather in a ring"
logic(50)
check("L3b a long single hint wraps", card().place.maxLines .. "," .. card().place.h .. "," .. tostring(second.hidden), "2,32,true")
store.worlds[204].hint = "north as the crow flies from Seers' Village"
logic(50)
check("L4 card taller", long.layer.h, 112)
check("L5 view rebuilt under the taller card", tostring(#views > count) .. "," .. views[#views].options.y .. "," .. views[#views].options.height, "true,126,366")
store.worlds[204] = nil
logic(50)
check("L6 short again: card and view back", card().layer.h .. "," .. views[#views].options.y, "80,94")

---------------------------------------------------------------- Sample data (debug)
-- Fills only the grid with made-up records; the saved ones are untouched.
local storedBefore = 0
for _ in pairs(store.worlds) do storedBefore = storedBefore + 1 end
check("D1 sample data button", button("Sample data") ~= nil, true)
-- No fake Window here (test_grid.lua covers the grid), so catch what the
-- grid would be given instead. package.loaded["ui/grid"] is the same table
-- main.lua got from require, so replacing a function on it reaches main.lua.
local grid = package.loaded["ui/grid"]
local realUpdate = grid.update
local gridCells = nil
grid.update = function(cells) gridCells = cells end
button("Sample data").extra()        -- on
logic(50)
local sampled = 0
for _, cell in ipairs(gridCells or {}) do
  if cell.kind ~= "unknown" then sampled = sampled + 1 end
end
check("D2 grid gets sample data", sampled > 10, true)
check("D3 grid opened", grid.wantsOpen(), true)
local storedAfter = 0
for _ in pairs(store.worlds) do storedAfter = storedAfter + 1 end
check("D4 saved records untouched", storedAfter, storedBefore)
button("Sample data").extra()        -- off again
sampled = 0
for _, cell in ipairs(gridCells or {}) do
  if cell.kind ~= "unknown" then sampled = sampled + 1 end
end
check("D5 off: back to the real data", sampled, storedBefore)
grid.restore({ open = 0 })           -- closed again (toggle would open it: no window was made)
grid.update = realUpdate

check("Z1 no errors so far", #errors, 0)
for _, e in ipairs(errors) do print(e) end

---------------------------------------------------------------- PrettyUI broken
-- If the dashboard can't be built on a freshly opened page, the plain
-- debug panel takes over for the rest of the session.
prettyui.SimpleView.new = function() error("no SimpleView in this PrettyUI") end
handlers.ContentLayerReady({ component = { width = 300, height = 500 } })
check("P1 build error logged", #errors == 1 and string.find(errors[1], "dashboard build", 1, true) ~= nil, true)
local fellBack = false
for _, line in ipairs(logged) do
  if string.find(line, "showing the plain panel", 1, true) then fellBack = true end
end
check("P2 fallback announced", fellBack, true)
logic(50)
check("P3 plain panel shows the debug text",
  game.lastText ~= nil and string.find(tostring(game.lastText.content), "This world:", 1, true) ~= nil, true)

PluginShutdown()
check("Z2 no further errors", #errors, 1)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
