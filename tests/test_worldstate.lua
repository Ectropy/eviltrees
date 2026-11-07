-- Replays real captured game text (captureLog, W204 willow 2026-11-06) through
-- parser + worldstate, plus edge cases (nurtured saplings, chopping, restarts).
-- Run with: node check.js <plugin dir> test_worldstate.lua
local parser = require("core/parser")
local ws = require("core/worldstate")
local trees = require("data/trees")

local MIDNIGHT = 1793923200000
local function t(hms)
  local h, m, s = string.match(hms, "(%d+):(%d+):(%d+)")
  return MIDNIGHT + ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 1000
end
local function fmt(ms)
  if ms == nil then return "nil" end
  local sec = (ms - MIDNIGHT) // 1000
  return string.format("%02d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60)
end

local failures, passes = 0, 0
local function check(label, actual, expected)
  if actual == expected then
    passes = passes + 1
  else
    failures = failures + 1
    print("FAIL " .. label .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected))
  end
end
local function checkTime(label, actual, expectedHms)
  check(label, fmt(actual), expectedHms)
end

local SAP = function(n) return trees.byId[11390 + n] end
local WILLOW, WILLOW2, WILLOW3, WILLOW_DYING, WILLOW_DEAD =
  trees.byId[11440], trees.byId[11441], trees.byId[11442], trees.byId[11927], trees.byId[14848]
local OAK, OAK2, OAK3 = trees.byId[11437], trees.byId[11438], trees.byId[11439]

local W = {}
local function say(speaker, text, at)
  local facts = parser.parseDialogue(speaker, text)
  return ws.applyDialogue(W, 204, facts, t(at))
end
local function loc(kind, info, prev, at, x, z)
  return ws.applyTreeLoc(W, 204, kind, info, x or 2703, z or 3641, prev, t(at))
end

---------------------------------------------------------------- A: the real W204 willow
-- Real spawn S = 03:43:32 (lightning 03:58:32 / 04:08:32, death 04:18:32).
say("Spirit tree", "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 7 minutes.", "03:36:11")
check("A1 status", W[204].status, "none")
checkTime("A1 window from", W[204].spawnEarliest, "03:43:11")
checkTime("A1 window to", W[204].spawnLatest, "03:44:11")
checkTime("A1 middle", W[204].spawnAt, "03:43:41")

say("Spirit tree", "It can be found north as the crow flies from Seers' Village.", "03:36:15")
check("A2 hint", W[204].hint, "north as the crow flies from Seers' Village")
checkTime("A2 spawn kept", W[204].spawnAt, "03:43:41")

say("Queen of Sunrise", "There are no nasty spirits possessing trees right now! There will be another evil tree in approximately 6 minutes.", "03:37:09")
check("A3 hint kept", W[204].hint, "north as the crow flies from Seers' Village")
checkTime("A3 narrowed", W[204].spawnLatest, "03:44:09")

say("Spirit tree", "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 2 minutes.", "03:40:47")
checkTime("A3c narrowed", W[204].spawnLatest, "03:43:47")

check("A3d greeting gives nil", parser.parseDialogue("Spirit tree", "If you are a friend of the gnome people, you are a friend of mine. Do you wish to travel, or do you wish to ask about the evil tree?"), nil)

say("Spirit tree", "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 1 minute.", "03:42:44")
say("Queen of Sunrise", "There are no nasty spirits possessing trees right now! There will be another evil tree in approximately 1 minute.", "03:43:18")
checkTime("A4 window from", W[204].spawnEarliest, "03:43:18")
checkTime("A4 window to", W[204].spawnLatest, "03:43:47")
checkTime("A4 timers alone hit the real spawn", W[204].spawnAt, "03:43:32")
check("A4 source", W[204].spawnSource, "timer")
check("A4 tick before", ws.tick(W, t("03:43:31"), nil), false)

-- the crown reporting the sapling while the timer is still pending
local WP = { [204] = { status = "none", spawnAt = t("03:43:32"), spawnEarliest = t("03:43:18"), spawnLatest = t("03:43:47"), hint = "h" } }
ws.applyDialogue(WP, 204, parser.parseDialogue("Queen of Sunrise", "Nasty spirits have got at a willow tree sapling. It can be found north as the crow flies from Seers' Village."), t("03:43:35"))
check("A4c sapling", WP[204].status, "sapling")
checkTime("A4c spawn kept", WP[204].spawnAt, "03:43:32")
checkTime("A4c window cut at now", WP[204].spawnLatest, "03:43:35")

check("A5 tick changed", ws.tick(W, t("03:43:45"), nil), true)
check("A5 status", W[204].status, "sapling")
checkTime("A5 spawn", W[204].spawnAt, "03:43:32")
check("A5 hint kept", W[204].hint ~= nil, true)

say("Spirit tree", "It can be found north as the crow flies from Seers' Village.", "03:43:51")
check("A5b same page again: no change", say("Spirit tree", "It can be found north as the crow flies from Seers' Village.", "03:43:52"), false)

say("Queen of Sunrise", "Nasty spirits have got at a willow tree sapling. It can be found north as the crow flies from Seers' Village.", "03:43:55")
check("A6 type", W[204].treeType, "willow")
checkTime("A6 spawn kept", W[204].spawnAt, "03:43:32")

loc("seen", SAP(2), nil, "03:45:00")                 -- arrived by teleport
checkTime("A7 first sight keeps spawn", W[204].spawnAt, "03:43:32")
check("A7 tile", W[204].tileX, 2703)

check("A8 removed is ignored", loc("removed", SAP(2), nil, "03:45:32"), false)
loc("seen", SAP(3), SAP(2), "03:45:32")
checkTime("A8 step 2->3", W[204].spawnAt, "03:43:32")
checkTime("A8 window from", W[204].spawnEarliest, "03:43:32")
loc("seen", SAP(4), SAP(3), "03:46:32", 2702, 3640)
check("A8 tile moved", W[204].tileX, 2702)
loc("seen", SAP(5), SAP(4), "03:47:32", 2702, 3640)
checkTime("A8 step 4->5", W[204].spawnAt, "03:43:32")
check("A8 beat from two steps a minute apart", W[204].beatMs, 32000)
check("A8 source: watched step", W[204].spawnSource, "step")

check("A8b timers paused in view", ws.tick(W, t("03:48:40"), 204), false)
check("A8b still sapling", W[204].status, "sapling")

say("(message box)", "Nasty spirits have got at a willow tree sapling. It can be found north as the crow flies from Seers' Village.", "03:48:08")
checkTime("A8c helm keeps spawn", W[204].spawnAt, "03:43:32")

-- grew up at S + 4:41 (nurtured, or 5:00 isn't exact): the window keeps S
loc("seen", WILLOW, SAP(5), "03:48:13", 2702, 3640)
check("A9 alive", W[204].status, "alive")
checkTime("A9 early maturing can't move S", W[204].spawnAt, "03:43:32")
check("A9 no health from full stage", W[204].health, nil)
checkTime("A9 M seen exactly", W[204].matureAt, "03:48:13")
check("A9 M source", W[204].matureSource, "watched")
local label9, at9, approx9 = ws.nextEvent(W[204], t("03:48:20"))
check("A9 next", label9, "lightning")
checkTime("A9 predicts the real first strike", at9, "03:58:32")
check("A9 exact (beat known)", approx9, false)
label9, at9 = ws.nextEvent(W[204])                  -- no clock: just the death
check("A9 death label", label9, "dies by")
checkTime("A9 predicts the real death", at9, "04:18:32")

say("(message box)", "Nasty spirits have got at a willow tree. It can be found north as the crow flies from Seers' Village.", "03:48:40")
checkTime("A9b helm mature keeps spawn", W[204].spawnAt, "03:43:32")

ws.applyExamine(W, 204, parser.parseExamine("He'll weep when he's done being evil! The tree currently has approximately 100% of its health remaining."), t("03:49:36"))
check("A10 health", W[204].health, 100)
check("A10 src", W[204].healthSource, "examine")
checkTime("A10 spawn kept", W[204].spawnAt, "03:43:32")

ws.applyStrike(W, 204, t("03:58:32"))                -- first lightning (Thor)
loc("seen", WILLOW2, WILLOW, "03:58:32", 2702, 3640)  -- ...and the drop to LVL2
check("A11 health", W[204].health, 50)
check("A11 src", W[204].healthSource, "strike")
checkTime("A11 M kept", W[204].matureAt, "03:48:13")
check("A11 strike didn't narrow a watched M: source kept", W[204].matureSource, "watched")
local label11, at11 = ws.nextEvent(W[204], t("03:59:00"))
checkTime("A11 next strike", at11, "04:08:32")
ws.applyStrike(W, 204, t("04:08:32"))                -- second lightning
loc("seen", WILLOW3, WILLOW2, "04:08:32", 2702, 3640)
check("A11b health", W[204].health, 25)
checkTime("A11b M kept", W[204].matureAt, "03:48:13")

ws.applyExamine(W, 204, { health = 20 }, t("04:10:00"))
loc("seen", WILLOW3, nil, "04:10:05", 2702, 3640)
check("A11c keeps lower examine", W[204].health, 20)

-- died untouched at M + 30: the killing strike, then the dying loc
ws.applyStrike(W, 204, t("04:18:32"))
checkTime("A12 kill strike leaves M alone", W[204].matureAt, "03:48:13")
loc("seen", WILLOW_DYING, WILLOW3, "04:18:32", 2702, 3640)
check("A13 dead", W[204].status, "dead")
checkTime("A13 deadAt", W[204].deadAt, "04:18:32")
check("A13 health cleared", W[204].health, nil)
loc("seen", WILLOW_DEAD, WILLOW_DYING, "04:18:34", 2702, 3640)
checkTime("A13 deadAt kept", W[204].deadAt, "04:18:32")
local label13, at13 = ws.nextEvent(W[204])
check("A13 next label", label13, "gone by")
checkTime("A13 next at: the real fade-out", at13, "04:27:38")

check("A14 walking away changes nothing", loc("removed", WILLOW_DEAD, nil, "04:19:00"), false)
check("A14 still dead", W[204].status, "dead")

check("A15 fading changed", loc("fading", WILLOW_DEAD, nil, "04:27:00"), true)
check("A15 record gone", W[204], nil)

---------------------------------------------------------------- N: nurtured saplings
-- No timers: first sight of stage 1, then nurtured stages every ~20 s.
local WN = {}
ws.applyTreeLoc(WN, 1, "seen", SAP(1), 1, 1, nil, t("10:00:00"))
checkTime("N1 rough guess", WN[1].spawnAt, "09:59:30")
ws.applyTreeLoc(WN, 1, "seen", SAP(2), 1, 1, SAP(1), t("10:00:20"))
checkTime("N2 step guess", WN[1].spawnAt, "09:59:20")
ws.applyTreeLoc(WN, 1, "seen", SAP(3), 1, 1, SAP(2), t("10:00:40"))
checkTime("N3 nurtured step can't push S past the window", WN[1].spawnAt, "09:59:20")
ws.applyTreeLoc(WN, 1, "seen", OAK, 1, 1, SAP(3), t("10:01:30"))
checkTime("N4 early maturing can't either", WN[1].spawnAt, "09:59:20")
check("N4 alive", WN[1].status, "alive")

-- With a tight timer window, nurtured steps and maturing stay inside it.
local WN2 = { [2] = { status = "none", spawnAt = t("10:00:40"), spawnEarliest = t("10:00:30"), spawnLatest = t("10:00:50") } }
ws.tick(WN2, t("10:01:00"), nil)
check("N5 sapling", WN2[2].status, "sapling")
ws.applyTreeLoc(WN2, 2, "seen", SAP(2), 1, 1, SAP(1), t("10:01:10"))   -- nurtured: 40 s early
checkTime("N5 kept inside timer window", WN2[2].spawnAt, "10:00:30")
ws.applyTreeLoc(WN2, 2, "seen", OAK, 1, 1, SAP(5), t("10:03:00"))      -- matured fast
checkTime("N6 kept inside timer window", WN2[2].spawnAt, "10:00:30")

---------------------------------------------------------------- L: lightning, beat, chopping
-- An alive oak with a known mature time M (exact) and, optionally, a beat.
local function aliveTree(m, beat)
  return { status = "alive", treeType = "oak", matureAt = m, matureEarliest = m, matureLatest = m, beatMs = beat }
end

-- timed lightning while away, on the beat (:00)
local WT = { [1] = aliveTree(t("03:05:00"), 0) }
ws.tick(WT, t("03:14:59"), nil)
check("L1 no lightning yet", WT[1].health, nil)
ws.tick(WT, t("03:15:00"), nil)
check("L1 lightning 1 at M+10", WT[1].health, 50)
check("L1 src", WT[1].healthSource, "timed")
ws.tick(WT, t("03:25:00"), nil)
check("L1 lightning 2 at M+20", WT[1].health, 25)
ws.applyTreeLoc(WT, 1, "seen", OAK2, 1, 1, nil, t("03:26:00"))
check("L2 stage beats a timed guess", WT[1].health, 50)
check("L2 stage src", WT[1].healthSource, "stage")

-- full tree seen while we had a 50% guess: guess dropped, and M is less
-- than ~11 min ago (it hasn't been struck)
local W2 = { [1] = { status = "alive", treeType = "oak", matureAt = t("02:45:00"), matureEarliest = t("02:40:00"), matureLatest = t("03:00:00"), health = 50, healthSource = "timed" } }
ws.applyTreeLoc(W2, 1, "seen", OAK, 1, 1, nil, t("03:12:00"))
check("L3 full beats guess", W2[1].health, nil)
checkTime("L3 M pulled into the new window", W2[1].matureAt, "03:01:00")

-- chopped to LVL2 / LVL3 with no strike: says nothing about M
local WC2 = { [1] = aliveTree(t("03:05:00"), 0) }
ws.applyTreeLoc(WC2, 1, "seen", OAK2, 1, 1, OAK, t("03:08:00"))
checkTime("L4 chop keeps M", WC2[1].matureAt, "03:05:00")
ws.applyTreeLoc(WC2, 1, "seen", OAK3, 1, 1, OAK2, t("03:10:00"))
checkTime("L4 chop again keeps M", WC2[1].matureAt, "03:05:00")

-- unfelled death at exactly M+30, with or without a known beat
local WK = { [1] = aliveTree(t("03:05:00"), 0) }
ws.tick(WK, t("03:35:00"), nil)
check("L5 dies at M+30", WK[1].status, "dead")
checkTime("L5 deadAt", WK[1].deadAt, "03:35:00")
local WK2 = { [1] = aliveTree(t("03:05:00"), nil) }
ws.tick(WK2, t("03:34:59"), nil)
check("L5b no beat: not killed early", WK2[1].status, "alive")
ws.tick(WK2, t("03:35:00"), nil)
check("L5b no beat: dead at M+30", WK2[1].status, "dead")

-- jitter: M seen 0.4 s after the beat must not push strike 1 a minute late
local WJ1 = { [1] = aliveTree(t("10:05:00") + 400, 0) }
local lj, aj, approxJ = ws.nextEvent(WJ1[1], t("10:06:00"))
check("L6 next is lightning", lj, "lightning")
checkTime("L6 on the beat, not a minute late", aj, "10:15:00")
check("L6 exact", approxJ, false)

-- unknown beat but M known to the second: exactly M+10 / M+30
local WU = { [1] = aliveTree(t("10:05:00"), nil) }
local lu, au, approxU = ws.nextEvent(WU[1], t("10:06:00"))
checkTime("L7 lightning M+10", au, "10:15:00")
check("L7 exact", approxU, false)
lu, au = ws.nextEvent(WU[1], t("10:30:00"))
check("L7 dies by", lu, "dies by")
checkTime("L7 dies at M+30", au, "10:35:00")

-- Strikes only hit a tree above the threshold. Chopped to 45% before
-- strike 1: strike 1 never comes, the next lightning is strike 2 at M+20.
local WCH = { [1] = aliveTree(t("10:05:00"), 0) }
ws.applyExamine(WCH, 1, { health = 45 }, t("10:10:00"))
local lc, ac = ws.nextEvent(WCH[1], t("10:11:00"))
check("L8 next skips strike 1", lc, "lightning")
checkTime("L8 strike 2 at M+20", ac, "10:25:00")
-- chopped to 20%: no more strikes, only the death
ws.applyExamine(WCH, 1, { health = 20 }, t("10:12:00"))
lc, ac = ws.nextEvent(WCH[1], t("10:12:00"))
check("L8b no strikes left", lc, "dies by")
checkTime("L8b death at M+30", ac, "10:35:00")

-- Thor first, then the drop to LVL2 in the same second corrects a wrong pick
local WTD = { [1] = { status = "alive", treeType = "oak", matureAt = t("10:16:00"), matureEarliest = t("10:00:00"), matureLatest = t("10:30:00") } }
ws.applyStrike(WTD, 1, t("10:35:00"))
checkTime("L9 no guess from the strike alone", WTD[1].matureEarliest, "10:00:00")
ws.applyTreeLoc(WTD, 1, "seen", OAK2, 1, 1, OAK, t("10:35:01"))
checkTime("L9 corrected to strike 1", WTD[1].matureEarliest, "10:24:01")
check("L9 health from strike 1", WTD[1].health, 50)
check("L9 beat", WTD[1].beatMs, 0)

-- drop first, then Thor
local WDT = { [1] = { status = "alive", treeType = "oak", matureAt = t("10:16:00"), matureEarliest = t("10:00:00"), matureLatest = t("10:30:00") } }
ws.applyTreeLoc(WDT, 1, "seen", OAK2, 1, 1, OAK, t("10:35:00"))
ws.applyStrike(WDT, 1, t("10:35:00") + 500)
checkTime("L10 strike 1 from the drop", WDT[1].matureEarliest, "10:24:00")
check("L10 beat to the ms", WDT[1].beatMs, 500)

-- a strike on an LVL3 tree that survives must not be read as the kill
local WS = {}
ws.applyTreeLoc(WS, 205, "seen", OAK3, 3096, 3227, nil, t("04:37:14"))
ws.applyExamine(WS, 205, { health = 25 }, t("04:37:19"))
ws.applyStrike(WS, 205, t("04:43:15"))
check("L11 still alive", WS[205].status, "alive")
ws.tick(WS, t("04:44:00"), nil)                       -- walked away
check("L11 alive after walking away", WS[205].status, "alive")
local ls, as = ws.nextEvent(WS[205], t("04:44:00"))
check("L11 next (M unknown)", ls, "dies within")
check("L11 death is later", as > t("04:44:00"), true)

-- the real W205 kill: Thor 04:43:15, dying loc 04:43:16
local WO = {}
ws.applyTreeLoc(WO, 205, "seen", OAK3, 3096, 3227, nil, t("04:37:14"))
ws.applyExamine(WO, 205, { health = 25 }, t("04:37:19"))
ws.applyStrike(WO, 205, t("04:43:15"))
ws.applyTreeLoc(WO, 205, "seen", trees.byId[11926], 3096, 3227, OAK3, t("04:43:16"))
check("L12 dead", WO[205].status, "dead")
checkTime("L12 deadAt", WO[205].deadAt, "04:43:16")
check("L12 beat :15", WO[205].beatMs, 15000)

-- a kill strike that fits neither strike 1 nor 2 leaves M alone
local WKS = { [1] = aliveTree(t("10:05:00"), 0) }
ws.applyStrike(WKS, 1, t("10:35:00"))
checkTime("L13 M untouched", WKS[1].matureAt, "10:05:00")
check("L13 health untouched", WKS[1].health, nil)

-- clock only minute-accurate (just after start-up): no beat, M still narrowed
local WNS = { [1] = aliveTree(t("10:05:00"), nil) }
ws.applyStrike(WNS, 1, t("10:14:40"), false)       -- clock 20 s behind the real 10:15:00
ws.applyTreeLoc(WNS, 1, "seen", OAK2, 1, 1, OAK, t("10:14:40"), false)
check("L15 no beat while unsynced", WNS[1].beatMs, nil)
check("L15 health still set", WNS[1].health, 50)
checkTime("L15 M kept (inside the widened window)", WNS[1].matureAt, "10:05:00")
local WNS2 = {}
ws.applyTreeLoc(WNS2, 1, "seen", SAP(2), 1, 1, SAP(1), t("10:01:00"), false)
ws.applyTreeLoc(WNS2, 1, "seen", SAP(3), 1, 1, SAP(2), t("10:02:00"), false)
check("L15b no beat from steps while unsynced", WNS2[1].beatMs, nil)

-- a record saved by an older version (spawn time only) doesn't break a strike
local WOLD = { [1] = { status = "alive", treeType = "oak", spawnAt = t("10:00:00") } }
check("L14 old record + strike", ws.applyStrike(WOLD, 1, t("10:15:00")), true)
checkTime("L14 M from spawn", WOLD[1].matureAt, "10:05:00")

---------------------------------------------------------------- B: restart catch-up
local WB = { [10] = { status = "none", spawnAt = t("05:00:00"), hint = "close to Yanille" } }
check("B1 changed", ws.tick(WB, t("07:00:00"), nil), true)
check("B1 fully expired", WB[10], nil)

local WB2 = { [11] = { status = "none", spawnAt = t("05:00:00") } }
ws.tick(WB2, t("05:20:00"), nil)
check("B2 alive", WB2[11].status, "alive")
checkTime("B2 spawn", WB2[11].spawnAt, "05:00:00")
check("B2 past lightning 1", WB2[11].health, 50)

local WB3 = { [12] = { status = "none", spawnAt = t("05:00:00") } }
ws.tick(WB3, t("05:04:59"), nil)
check("B3 sapling until S+5", WB3[12].status, "sapling")
ws.tick(WB3, t("05:05:00"), nil)
check("B3 alive at S+5", WB3[12].status, "alive")

---------------------------------------------------------------- C: other rules
check("C1 nil world", ws.applyDialogue(W, nil, { timerMs = 60000 }, t("01:00:00")), false)
check("C1 nil now", ws.applyDialogue(W, 5, { timerMs = 60000 }, nil), false)

-- different type means a new tree
local WC = { [2] = { status = "alive", treeType = "oak", spawnAt = t("00:50:00"), spawnEarliest = t("00:45:00"), spawnLatest = t("00:55:00"), hint = "old hint" } }
ws.applyDialogue(WC, 2, parser.parseDialogue("Queen of Sunrise", "Nasty spirits have got at a willow tree sapling. It can be found to the south of Yanille."), t("01:05:00"))
check("C2 new tree type", WC[2].treeType, "willow")
check("C2 status", WC[2].status, "sapling")
check("C2 hint", WC[2].hint, "to the south of Yanille")
checkTime("C2 fresh window", WC[2].spawnEarliest, "01:00:00")
checkTime("C2 middle", WC[2].spawnAt, "01:02:30")

-- timers declared it dead, but we see it alive: same tree, alive again
local WD = { [3] = { status = "dead", treeType = "oak", deadAt = t("02:00:00") } }
ws.applyTreeLoc(WD, 3, "seen", OAK, 1, 1, nil, t("02:01:00"))
check("C3 alive again", WD[3].status, "alive")
check("C3 deadAt cleared", WD[3].deadAt, nil)
checkTime("C3 M middle of window", WD[3].matureAt, "01:55:30")

-- first sight of stage 3, no other info: S 0..3 min ago, guess 2m30s
local WE = {}
ws.applyTreeLoc(WE, 4, "seen", SAP(3), 1, 1, nil, t("03:10:00"))
checkTime("C4 window from", WE[4].spawnEarliest, "03:07:00")
checkTime("C4 guess", WE[4].spawnAt, "03:07:30")
-- a contradicting old window is replaced by the new observation
local WF = { [5] = { status = "sapling", spawnAt = t("03:00:00"), spawnEarliest = t("02:58:00"), spawnLatest = t("03:02:00") } }
ws.applyTreeLoc(WF, 5, "seen", SAP(3), 1, 1, nil, t("03:10:00"))
checkTime("C5 new window", WF[5].spawnEarliest, "03:07:00")
checkTime("C5 clamped", WF[5].spawnAt, "03:07:00")

-- timer while a tree was recorded: tree forgotten, hint too
local WG = { [6] = { status = "alive", treeType = "oak", spawnAt = t("01:20:00"), hint = "old" } }
ws.applyDialogue(WG, 6, { timerMs = 30 * 60000 }, t("01:40:00"))
check("C6 none", WG[6].status, "none")
check("C6 hint gone", WG[6].hint, nil)
check("C6 type gone", WG[6].treeType, nil)
checkTime("C6 spawn", WG[6].spawnAt, "02:10:30")

local WH = {}
ws.applyDialogue(WH, 7, parser.parseDialogue("Spirit tree", "It is an abomination of nature, which has appeared beside the west gates of Yanille. You should go and help."), t("01:00:00"))
check("C7 clue", WH[7].locationClue, "beside the west gates of Yanille")
check("C7 sapling", WH[7].status, "sapling")
checkTime("C7 spawn", WH[7].spawnAt, "00:57:30")

local WI = {}
ws.applyExamine(WI, 8, { deadWithRewards = true }, t("01:00:00"))
check("C8 dead", WI[8].status, "dead")
check("C9 clear", ws.clearWorld(WI, 8), true)
check("C9 gone", WI[8], nil)
check("C9 clear again", ws.clearWorld(WI, 8), false)

-- the "1 hour left" bug: "approximately 0 minutes" means 60, not 0
local bugText = "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 0 minutes."
check("H1 parser 0 -> 60 min", parser.parseDialogue("Spirit tree", bugText).timerMs, 60 * 60000)
check("H1b crown wording too", parser.parseDialogue("Queen of Sunrise", "There are no nasty spirits possessing trees right now! There will be another evil tree in approximately 0 minutes.").timerMs, 60 * 60000)
local WH1 = {}
ws.applyDialogue(WH1, 10, parser.parseDialogue("Spirit tree", bugText), t("01:00:00"))
checkTime("H2 window from", WH1[10].spawnEarliest, "02:00:00")
checkTime("H2 window to", WH1[10].spawnLatest, "02:01:00")
check("H2 not a sapling now", WH1[10].status, "none")
-- next reading a minute later ("59 minutes") stays consistent with it
ws.applyDialogue(WH1, 10, parser.parseDialogue("Spirit tree", "The taint of the evil tree is not currently on the land. There will be another evil tree in approximately 59 minutes."), t("01:01:00"))
checkTime("H3 consistent window from", WH1[10].spawnEarliest, "02:00:00")
checkTime("H3 consistent window to", WH1[10].spawnLatest, "02:01:00")
-- neighbours: "1 hour and 1 minute" and plain "1 hour."
check("H4 1h1m", parser.parseDialogue("Spirit tree", "There will be another evil tree in approximately 1 hour and 1 minute.").timerMs, 61 * 60000)
check("H4 1 hour.", parser.parseDialogue("Spirit tree", "There will be another evil tree in approximately 1 hour.").timerMs, 60 * 60000)

---------------------------------------------------------------- R: rewards window and greetings (W205 oak log)
local longTime = "The taint of the evil tree is not currently on the land. There won't be another evil tree for a long time."
local f = parser.parseDialogue("Spirit tree", longTime)
check("R1 rewardsWindow fact", f.rewardsWindow, true)
check("R1 not noTree", f.noTree, nil)
-- the real sequence: felled 04:43:16, spirit tree asked at 04:46:19
local WR = { [205] = { status = "dead", treeType = "oak", deadAt = t("04:43:16"), tileX = 3096, tileZ = 3227 } }
ws.applyDialogue(WR, 205, f, t("04:46:19"))
check("R2 still dead", WR[205].status, "dead")
checkTime("R2 deadAt kept", WR[205].deadAt, "04:43:16")
ws.applyDialogue(WR, 205, parser.parseDialogue("Spirit tree", "It can be found close to a large collection of willow trees."), t("04:46:31"))
check("R3 hint belongs to the dead tree", WR[205].hint, "close to a large collection of willow trees")
check("R3 still dead", WR[205].status, "dead")
-- no record yet: becomes dead, rewards gone within 10 min
local WR2 = {}
ws.applyDialogue(WR2, 1, f, t("05:00:00"))
check("R4 dead from nothing", WR2[1].status, "dead")
local labelR, atR = ws.nextEvent(WR2[1])
check("R4 next", labelR, "gone by")
checkTime("R4 gone by at most 9:06", atR, "05:09:06")
-- an out-of-date timer is dropped
local WR3 = { [1] = { status = "none", spawnAt = t("06:00:00"), spawnEarliest = t("05:59:00"), spawnLatest = t("06:01:00"), hint = "h" } }
ws.applyDialogue(WR3, 1, f, t("05:00:00"))
check("R5 dead", WR3[1].status, "dead")
check("R5 timer dropped", WR3[1].spawnAt, nil)
check("R5 hint kept", WR3[1].hint, "h")
-- plain "no tree" without a timer doesn't clear a dead tree
local WR4 = { [1] = { status = "dead", deadAt = t("05:00:00") } }
check("R6 noTree keeps dead", ws.applyDialogue(WR4, 1, { noTree = true }, t("05:02:00")), false)
-- ...but a timer does (the rewards are over)
ws.applyDialogue(WR4, 1, { noTree = true, timerMs = 90 * 60000 }, t("05:11:00"))
check("R7 timer clears dead", WR4[1].status, "none")

-- greetings
local alive = parser.parseDialogue("Spirit tree", "If you are a friend of the gnome people, you are a friend of mine. Do you wish to travel, or are you here to help dispatch the evil tree?")
check("R8 alive greeting", alive and alive.treeAlive, true)
local WR5 = {}
ws.applyDialogue(WR5, 1, alive, t("05:00:00"))
check("R8 alive", WR5[1].status, "alive")
local sap = parser.parseDialogue("Spirit tree", "If you are a friend of the gnome people, you are a friend of mine. Do you wish to travel, or are you interested in the strange sapling?")
check("R9 sapling greeting", sap and sap.saplingExists, true)
local WR6 = {}
ws.applyDialogue(WR6, 1, sap, t("05:00:00"))
check("R9 sapling", WR6[1].status, "sapling")
checkTime("R9 spawn within 5 min", WR6[1].spawnEarliest, "04:55:00")
check("R10 neutral greeting ignored", parser.parseDialogue("Spirit tree", "If you are a friend of the gnome people, you are a friend of mine. Do you wish to travel, or do you wish to ask about the evil tree?"), nil)

local WJ = {}
ws.applyDialogue(WJ, 9, { hint = "x" }, t("01:00:00"))
ws.applyDialogue(WJ, 9, { hint = "x" }, t("01:05:00"))
checkTime("C10 updatedAt only moves on change", WJ[9].updatedAt, "01:00:00")

---------------------------------------------------------------- G: no guesses shown as facts (beta bug, W204 2026-11-06)
-- The spirit tree only said "...here to help dispatch the evil tree?" The
-- old code put M in the middle of 31 minutes and showed "~50%" and a
-- lightning time. Then the tree was found at 100%.
local greet = parser.parseDialogue("Spirit tree", "If you are a friend of the gnome people, you are a friend of mine. Do you wish to travel, or are you here to help dispatch the evil tree?")
local WG1 = {}
ws.applyDialogue(WG1, 204, greet, t("02:32:05"))
check("G1 alive", WG1[204].status, "alive")
check("G1 no health", WG1[204].health, nil)
check("G1 M source", WG1[204].matureSource, "alive")
local lg, ag, apg = ws.nextEvent(WG1[204], t("02:32:06"))
check("G1 no lightning time, only dies within", lg, "dies within")
checkTime("G1 latest possible death (exactly 30 min)", ag, "03:02:05")
check("G1 an upper bound, not approximate", apg, false)
-- walked away for a while: timers must not invent a health either
ws.tick(WG1, t("02:40:00"), nil)
check("G2 still no health", WG1[204].health, nil)
check("G2 still alive", WG1[204].status, "alive")
-- 10 min after the greeting strike 1 has certainly happened (M <= 02:32:05)
ws.tick(WG1, t("02:42:04"), nil)
check("G2b no strike before M+10", WG1[204].health, nil)
ws.tick(WG1, t("02:42:05"), nil)
check("G2b certain strike 1 gives at most 50%", WG1[204].health, 50)
-- ...and it is never declared dead before the latest possible death
ws.tick(WG1, t("03:02:04"), nil)
check("G2c not killed early", WG1[204].status, "alive")
ws.tick(WG1, t("03:02:05"), nil)
check("G2c forgotten after the latest death (rewards may be long gone)", WG1[204], nil)

-- The real sequence after "Clear world": greeting, teleport, full tree,
-- examine 100%, Thor at 02:33:37 (the new loc arrived without "previous").
local WG3 = {}
ws.applyDialogue(WG3, 204, greet, t("02:32:05"))
ws.applyTreeLoc(WG3, 204, "seen", WILLOW, 2602, 3117, nil, t("02:32:17"))
ws.applyExamine(WG3, 204, parser.parseExamine("He'll weep when he's done being evil! The tree currently has approximately 100% of its health remaining."), t("02:32:20"))
check("G3 seen 100%", WG3[204].health, 100)
local l3 = ws.nextEvent(WG3[204], t("02:32:21"))
check("G3 M still rough (11 min): no lightning time", l3, "dies within")
ws.applyStrike(WG3, 204, t("02:33:37"))
-- (capture/trees.lua now reports the in-place swap with previous = WILLOW)
ws.applyTreeLoc(WG3, 204, "seen", WILLOW2, 2602, 3117, WILLOW, t("02:33:37"))
check("G4 50% after strike", WG3[204].health, 50)
checkTime("G4 M = strike - 10 min", WG3[204].matureAt, "02:23:37")
check("G4 M source", WG3[204].matureSource, "strike")
local l4, a4, ap4 = ws.nextEvent(WG3[204], t("02:34:00"))
check("G4 next", l4, "lightning")
checkTime("G4 next strike exactly 10 min later", a4, "02:43:37")
check("G4 exact", ap4, false)

-- Seen health > 50% means strike 1 is still to come, even if its time
-- has passed: never skip ahead to strike 2.
local WG5 = { [1] = { status = "alive", treeType = "oak", matureAt = t("10:00:00"), matureEarliest = t("10:00:00"), matureLatest = t("10:00:00"), beatMs = 0, health = 100, healthSource = "examine" } }
local l5, a5 = ws.nextEvent(WG5[1], t("10:10:30"))
check("G5 overdue strike 1 still next", l5, "lightning")
checkTime("G5 strike 1 time", a5, "10:10:00")

-- A spawn timer, then the crown: assumed unnurtured, M = S + 5, so the
-- window for M is the timer's 1 min window moved 5 min on. A 1 min window
-- is shown as exact, like the spawn time itself.
local CROWN_TREE = parser.parseDialogue("Queen of Sunrise", "Nasty spirits have got at a willow tree. It can be found north as the crow flies from Seers' Village.")
local WG6 = {}
ws.applyDialogue(WG6, 1, { timerMs = 7 * 60000 }, t("10:00:00"))   -- S 10:07..10:08
ws.applyDialogue(WG6, 1, CROWN_TREE, t("10:14:00"))
checkTime("G6 M window from (unnurtured)", WG6[1].matureEarliest, "10:12:00")
checkTime("G6 M window to", WG6[1].matureLatest, "10:13:00")
check("G6 M inferred from S", WG6[1].matureSource, "fromSpawn")
local l6, a6, ap6 = ws.nextEvent(WG6[1], t("10:14:00"))
check("G6 lightning from timer", l6, "lightning")
checkTime("G6 guess S + 15", a6, "10:22:30")
check("G6 exact (1 min window)", ap6, false)
-- the guessed strike time passing doesn't stamp a health; certainty does
-- (latest M 10:13:00 + 10 min)
ws.tick(WG6, t("10:22:59"), nil)
check("G6b no health at the guessed time", WG6[1].health, nil)
ws.tick(WG6, t("10:23:00"), nil)
check("G6b at most 50% once certain", WG6[1].health, 50)

-- Same timer, but the crown says "tree" before S + 5: it was nurtured. The
-- unnurtured guess is dropped; M lies between the earliest S and now.
local WG7 = {}
ws.applyDialogue(WG7, 1, { timerMs = 7 * 60000 }, t("10:00:00"))   -- S 10:07..10:08
ws.tick(WG7, t("10:08:00"), nil)
check("G7 sapling by the timer", WG7[1].status, "sapling")
ws.applyDialogue(WG7, 1, CROWN_TREE, t("10:10:00"))
check("G7 alive", WG7[1].status, "alive")
checkTime("G7 M no earlier than S", WG7[1].matureEarliest, "10:07:00")
checkTime("G7 M no later than now", WG7[1].matureLatest, "10:10:00")
check("G7 M source: seen alive", WG7[1].matureSource, "alive")
check("G7 still trusted for lightning", (ws.nextEvent(WG7[1], t("10:10:00"))), "lightning")

-- The edges of "trusted": a sapling greeting alone (S in the last 5 min, so
-- a 5 min window for M) is enough; a full tree seen alone (11 min) is not.
local WG8 = {}
ws.applyDialogue(WG8, 1, sap, t("10:00:00"))
ws.tick(WG8, t("10:05:00"), nil)
check("G8 sapling greeting grows up", WG8[1].status, "alive")
check("G8 5 min window is trusted", (ws.nextEvent(WG8[1], t("10:05:00"))), "lightning")
local WG9 = {}
ws.applyTreeLoc(WG9, 1, "seen", OAK, 1, 1, nil, t("10:00:00"))
check("G9 full tree alone: only dies within", (ws.nextEvent(WG9[1], t("10:00:00"))), "dies within")

---------------------------------------------------------------- K: timer read before the clock knows the seconds
local WK = {}
ws.applyDialogue(WK, 1, { timerMs = 16 * 60000 }, t("10:00:00"))
local _, _, apK = ws.nextEvent(WK[1], t("10:00:00"))
check("K1 one synced reading: exact (no ~)", apK, false)
local WK2 = {}
ws.applyDialogue(WK2, 1, { timerMs = 16 * 60000 }, t("10:00:00"), false)
checkTime("K2 late end moved a minute", WK2[1].spawnLatest, "10:18:00")
local _, _, apK2 = ws.nextEvent(WK2[1], t("10:00:00"))
check("K2 shown with ~", apK2, true)
-- a later synced reading narrows it back to exact
ws.applyDialogue(WK2, 1, { timerMs = 15 * 60000 }, t("10:01:00"), true)
local _, _, apK3 = ws.nextEvent(WK2[1], t("10:01:00"))
check("K3 synced reading makes it exact again", apK3, false)

---------------------------------------------------------------- E: dead trunk examines (W205 elder, 2026-11-06)
check("E1 rewards", (parser.parseExamine("Looks like there's rewards to be had!") or {}).deadWithRewards, true)
local e2 = parser.parseExamine("It looks better dead than alive.")
check("E2 no rewards recognised", e2 and e2.deadNoRewards, true)
local WE = { [1] = { status = "alive", treeType = "elder", matureAt = t("10:00:00"), matureEarliest = t("10:00:00"), matureLatest = t("10:00:00") } }
check("E3 no-rewards text changes nothing", ws.applyExamine(WE, 1, e2, t("10:05:00")), false)

---------------------------------------------------------------- I: sapling inspect (chat)
local i1 = parser.parseInspect("This sapling will grow into an evil willow tree.")
check("I1 type", i1 and i1.treeType, "willow")
check("I1 sapling", i1 and i1.isSapling, true)
-- the real text (W205 elder, 2026-11-06): note the capital "Evil"
local i2 = parser.parseInspect("This sapling will grow into an Evil elder tree.")
check("I2 elder", i2 and i2.treeType, "elder")
local i3 = parser.parseInspect("This sapling will grow into an evil tree.")
check("I3 plain evil tree", i3 and i3.treeType, "tree")
check("I3b any capitals", (parser.parseInspect("THIS SAPLING WILL GROW INTO AN EVIL Magic TREE.") or {}).treeType, "magic")
check("I4 other text", parser.parseInspect("A strange sapling emerging from the ground."), nil)
check("I5 unknown type word", parser.parseInspect("This sapling will grow into an evil banana tree."), nil)
-- the crown already gave a type: the same type keeps the tree
local WI = { [1] = { status = "sapling", treeType = "elder", spawnAt = t("10:00:00"), spawnEarliest = t("09:59:00"), spawnLatest = t("10:00:30") } }
ws.applyDialogue(WI, 1, i2, t("10:02:00"))
checkTime("I6 same type keeps spawn", WI[1].spawnAt, "10:00:00")

---------------------------------------------------------------- U: capitals never matter
local u1 = parser.parseDialogue("SPIRIT TREE", "THERE WILL BE ANOTHER EVIL TREE IN APPROXIMATELY 1 HOUR AND 1 MINUTE.")
check("U1 speaker and timer in capitals", u1 and u1.timerMs, 61 * 60000)
local u2 = parser.parseDialogue("Queen of Sunrise", "NASTY SPIRITS HAVE GOT AT A Willow TREE SAPLING. it CAN be found north as the crow flies from Seers' Village.")
check("U2 type", u2 and u2.treeType, "willow")
check("U2 sapling", u2 and u2.isSapling, true)
check("U2 hint keeps the game's capitals", u2 and u2.hint, "north as the crow flies from Seers' Village")
local u3 = parser.parseDialogue("Spirit tree", "It is an abomination of nature, WHICH HAS APPEARED beside the west gates of Yanille. You should go and help.")
check("U3 clue keeps the game's capitals", u3 and u3.locationClue, "beside the west gates of Yanille")
local u4 = parser.parseDialogue(parser.MESSAGE_BOX_SPEAKER, "Nasty Spirits have got at an oak tree.")
check("U4 helm filter ignores capitals", u4 and u4.treeType, "oak")
check("U4b helm ignores other text", parser.parseDialogue(parser.MESSAGE_BOX_SPEAKER, "You can't do that right now."), nil)
check("U5 examine health", (parser.parseExamine("THE TREE CURRENTLY HAS APPROXIMATELY 25% OF ITS HEALTH REMAINING.") or {}).health, 25)
check("U6 examine rewards", (parser.parseExamine("LOOKS LIKE THERE'S REWARDS TO BE HAD!") or {}).deadWithRewards, true)
check("U7 nil speaker", parser.parseDialogue(nil, "It can be found somewhere."), nil)

print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then error("tests failed") end
