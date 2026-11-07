-- data/hints.lua and core/location.lua: the data is consistent, and real
-- captured game text resolves to the right places.
-- Run with: node check.js <plugin dir> test_location.lua
local hints = require("data/hints")
local location = require("core/location")
local parser = require("core/parser")

local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then
    passes = passes + 1
  else
    failures = failures + 1
    print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
  end
end

---------------------------------------------------------------- D: the data itself
check("D1 location count", #hints.locations, 27)

-- byName["West of Falador"] = that location's entry, like a JS Map by name.
local byName = {}
for _, place in ipairs(hints.locations) do byName[place.name] = place end
check("D2 hint count", #hints.list, 20)

-- Every location named by a hint exists, and every location is named by a hint.
local used = {}
for _, entry in ipairs(hints.list) do
  for _, name in ipairs(entry.locations) do
    check("D3 hint '" .. entry.hint .. "' names a known place: " .. name, byName[name] ~= nil, true)
    used[name] = true
  end
end
for _, place in ipairs(hints.locations) do
  check("D4 used by some hint: " .. place.name, used[place.name], true)
  check("D5 has a clue: " .. place.name, type(place.clue), "string")
end
check("D6 no duplicate names", #hints.locations, (function()
  local n = 0
  for _ in pairs(byName) do n = n + 1 end
  return n
end)())

-- Each clue resolves to its own location (no clue is part of another's).
for _, place in ipairs(hints.locations) do
  check("D7 clue resolves to itself: " .. place.name, location.forClue(place.clue), place.name)
end

-- Pins are far enough apart that MAX_PIN_DISTANCE can never pick the wrong one.
local closest = math.huge
for i = 1, #hints.locations do
  for j = i + 1, #hints.locations do
    local a, b = hints.locations[i], hints.locations[j]
    closest = math.min(closest, math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2))
  end
end
check("D8 pins at least 2x MAX_PIN_DISTANCE apart", closest >= 2 * location.MAX_PIN_DISTANCE, true)

---------------------------------------------------------------- H: hints from real dialogue
-- Lines captured in the beta, run through the parser exactly as main.lua does.
local function hintOf(speaker, text)
  return parser.parseDialogue(speaker, text).hint
end

local seers = location.forHint(hintOf("Spirit tree",
  "It can be found north as the crow flies from Seers' Village."))
check("H1 seers count", #seers, 2)
check("H1 seers first", seers[1], "East of the house portal in Rellekka")

local gnome = location.forHint(hintOf("Queen of Sunrise",
  "Nasty spirits have got at an oak tree. It can be found to the south of a tree gnome settlement."))
check("H2 gnome count", #gnome, 2)
check("H2 gnome first", gnome[1], "South of Tree Gnome Stronghold and east of the Outpost")

local willow = location.forHint(hintOf("Spirit tree",
  "It can be found close to a large collection of willow trees."))
check("H3 willow count", #willow, 4)

-- Case, spacing and a trailing full stop don't matter; unknown hints give {}.
check("H4 messy spacing", #location.forHint("  Close to the town   you call YANILLE. "), 2)
check("H5 unknown hint", #location.forHint("somewhere over the rainbow"), 0)
check("H6 nil hint", #location.forHint(nil), 0)
check("H7 quoted village", location.forHint("close to the village you humans call 'Draynor'")[1],
  "North of Draynor Village, near Draynor Manor")

---------------------------------------------------------------- C: spirit tree clue sentences
local function clueOf(text)
  return parser.parseDialogue("Spirit tree", text).locationClue
end
check("C1 yanille west gates", location.forClue(clueOf(
  "It is an abomination of nature, which has appeared beside the west gates of Yanille. You should go and help.")),
  "South of Tree Gnome Village and northwest of Yanille")
check("C2 case-insensitive", location.forClue("Just North Of Yanille"), "Northeast of Yanille")
check("C3 unknown clue", location.forClue("somewhere in the Wilderness"), nil)
check("C4 nil clue", location.forClue(nil), nil)

---------------------------------------------------------------- T: tiles
-- The W204 willow, seen at 2703,3641 then 2702,3640 (bigger model).
check("T1 W204 willow tile", location.forTile(2702, 3640), "East of the house portal in Rellekka")
check("T2 sapling tile", location.forTile(2703, 3641), "East of the house portal in Rellekka")
check("T3 exactly on a pin", location.forTile(2925, 3375), "West of Falador")
check("T4 too far from any pin", location.forTile(3200, 3200), nil)
check("T5 nil tile", location.forTile(nil, nil), nil)

---------------------------------------------------------------- R: a whole record
check("R1 nothing known", location.forRecord({ status = "none" }), nil)
check("R2 two-place hint: no name",
  location.forRecord({ status = "none", hint = "north as the crow flies from Seers' Village" }), nil)

local name
name = location.forRecord({ status = "none", hint = "Due west of the town you call Lumbridge" })
check("R3 one-place hint gives the name", name, "South of Draynor Village, near the willow trees")

-- The clue beats the hint, and the tile beats both.
name = location.forRecord({ status = "sapling", hint = "north as the crow flies from Seers' Village",
  locationClue = "in the north of Seers' Village" })
check("R4 clue beats hint", name, "Northwest of Seers' Village bank")
name = location.forRecord({ status = "alive", hint = "north as the crow flies from Seers' Village",
  locationClue = "in the north of Seers' Village", tileX = 2702, tileZ = 3640 })
check("R5 tile beats clue", name, "East of the house portal in Rellekka")

---------------------------------------------------------------- M: several hints
-- The W204 oak (2026-11-07): two different hints for one tree, real text.
local COAST = hintOf("Spirit tree", "It can be found on the southern coast of a tropical island.")
local KARAMJA = hintOf("Queen of Sunrise",
  "Nasty spirits have got at an oak tree sapling. It can be found on the island known as Karamja.")
local KHARAZI = "Kharazi Jungle, east of the teak trees"
local oak = { status = "sapling", hint = KARAMJA, earlierHints = { COAST } }
check("M1 two hints share one place", location.forRecord(oak), KHARAZI)
local places = location.forHints(oak)
check("M1 only that place", #places, 1)
-- Either order gives the same answer.
check("M2 other order", location.forRecord({ status = "none", hint = COAST, earlierHints = { KARAMJA } }), KHARAZI)
-- One hint alone: still two places.
check("M3 one hint", #location.forHints({ status = "none", hint = COAST }), 2)
check("M3 one hint: no name", location.forRecord({ status = "none", hint = COAST }), nil)
-- Hints that share no place: the newest wins (the older one must be from an
-- older tree). Seers (3 places) shares nothing with Karamja.
local SEERS = "close to the village you call 'Seers'"
places = location.forHints({ status = "none", hint = KARAMJA, earlierHints = { SEERS } })
check("M4 no shared place: newest", #places, 2)
check("M4 newest's first place", places[1], location.forHint(KARAMJA)[1])
-- ...and anything older than the clash is ignored too.
places = location.forHints({ status = "none", hint = KARAMJA, earlierHints = { COAST, SEERS } })
check("M5 stops at the clash", #places, 2)
places = location.forHints({ status = "none", hint = KARAMJA, earlierHints = { SEERS, COAST } })
check("M5 shared before the clash", places[1], KHARAZI)
check("M5 shared before the clash: one", #places, 1)
-- An unknown newest hint doesn't wipe out a known older one.
places = location.forHints({ status = "none", hint = "somewhere over the rainbow", earlierHints = { COAST } })
check("M6 unknown newest skipped", #places, 2)
check("M7 nothing known", #location.forHints({ status = "none" }), 0)
-- The lookup table itself is never changed by intersecting.
location.forHints(oak)
check("M8 hint table untouched", #location.forHint(COAST), 2)
check("M9 sameHint ignores case and spaces", location.sameHint("On the island  known as Karamja.", KARAMJA), true)
check("M9 different hints", location.sameHint(COAST, KARAMJA), false)

print(passes .. " passed, " .. failures .. " failed")
if failures > 0 then error("test failures") end
