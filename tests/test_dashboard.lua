-- ui/dashboard.lua through main.lua, with a fake PrettyUI and stubbed game
-- globals: what's on screen, when it rebuilds vs updates in place, and the
-- Clear world button. Fails on any "[error]" log line.
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
prettyui = {
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

-- All texts on the newest view, joined by newlines, for easy searching.
local function screen()
  local view = views[#views]
  if view == nil then return "" end
  local lines = {}
  for _, item in ipairs(view.items) do lines[#lines + 1] = tostring(item.component.content) end
  return table.concat(lines, "\n")
end
local function shows(text) return string.find(screen(), text, 1, true) ~= nil end
local function button(label)
  for _, item in ipairs(views[#views].items) do
    if item.kind == "button" and item.component.content == label then return item end
  end
end

---------------------------------------------------------------- the game
local game = require("fakegame")   -- stubs every game global (tests/fakegame.lua)
local handlers, errors, logged, interfaces = game.handlers, game.errors, game.logged, game.interfaces
local logic, server = game.logic, game.server

interfaces["550:48"] = "Friends List RuneScape 204"
require("main")
local store = require("core/store")

logic(1)
server(2)                    -- reads the world
check("S1 nothing drawn before the page opens", #views, 0)

---------------------------------------------------------------- opening the page
handlers.ContentLayerReady({ component = { width = 400, height = 600 } })
check("O1 one view", #views, 1)
check("O1 sized to the page", views[1].options.width, 384)
check("O2 title", shows("Evil Trees"), true)
check("O3 scouted", shows("Scouted 0 / "), true)
check("O4 current world, no intel", shows("W204 (you're here)"), true)
check("O5 no other worlds", shows("None yet."), true)
check("O6 debug section", shows("Debug"), true)
check("O7 no clear button without intel", button("Clear world"), nil)

---------------------------------------------------------------- a spirit tree timer
interfaces["1184:4"] = "Spirit tree"
interfaces["1184:10"] = "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 7 minutes."
server(1)
interfaces["1184:4"] = nil; interfaces["1184:10"] = nil
logic(50)                    -- passes logicTick 50: refresh
check("T1 rebuilt", #views, 2)
check("T1 old view destroyed", views[1].destroyed, true)
check("T2 heading", shows("W204 - No tree"), true)
-- the fake clock never learns the seconds here, so the time gets a "~"
check("T3 countdown", string.match(screen(), "Spawns in ~%d:%d%d") ~= nil, true)
check("T4 clear button", button("Clear world") ~= nil, true)

-- A second later: same layout, so the countdown updates in place (no rebuild).
local before = screen()
logic(50)
check("T5 no rebuild", #views, 2)
check("T5 countdown ticked", screen() ~= before, true)

---------------------------------------------------------------- another world
store.worlds[117] = { status = "none", spawnAt = 1793945263552, hint = "north as the crow flies from Seers' Village" }
logic(50)
check("W1 rebuilt for the new world", #views, 3)
check("W2 other world heading", shows("W117 - No tree"), true)
check("W3 two-place hint", shows("East of the house portal in Rellekka or Northwest of Seers' Village bank"), true)
check("W4 scouted", shows("Scouted 2 / "), true)

---------------------------------------------------------------- Clear world
button("Clear world").extra()        -- click
check("C1 asks first", #confirms, 1)
check("C1 still there until confirmed", store.worlds[204] ~= nil, true)
confirms[1].onConfirm()
check("C2 cleared", store.worlds[204], nil)
check("C3 other world kept", store.worlds[117] ~= nil, true)
check("C4 redrawn without intel", shows("W204 (you're here)"), true)

---------------------------------------------------------------- page closed and reopened
local count = #views
handlers.ContentLayerReady({ component = { width = 300, height = 500 } })
check("R1 new view on reopen", #views, count + 1)
check("R1 old one destroyed", views[count].destroyed, true)
check("R2 content back at once", shows("W117 - No tree"), true)

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
