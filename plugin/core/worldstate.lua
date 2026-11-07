--[[
    core/worldstate.lua
    -------------------
    Turns captured facts into one saved record per world, and moves those
    records along with time. Pure: no game API calls, no clock, no saving.
    The caller passes in the worlds table, the world number and "now" (Unix
    ms), and saves when a function returns true ("something changed").

    A record (store.worlds[205]) looks like:
        status        "none" | "sapling" | "alive" | "dead"
        spawnAt       when the tree spawned, or (while "none") will spawn ("S").
                      Best estimate.
        spawnEarliest, spawnLatest
                      the window S must lie in, given everything seen so far
                      (spawnAt is always inside it)
        matureAt      when the sapling became a full tree ("M"). Best estimate.
                      Lightning and death are timed from this.
        matureEarliest, matureLatest
                      the window M must lie in
        beatMs        the tree's once-a-minute "beat": the strikes and the
                      death happen at this many ms past a whole minute
                      (e.g. 32000 = at :32). nil until we know it.
        strikeSeenAt  when we last saw a lightning strike (Thor)
        stageDropAt, stageDropCap
                      when we last watched the health stage drop, and to
                      which cap (50 or 25); pairs a drop with a strike
        stepSeenAt    when we last watched a sapling stage step
        treeType      "tree" | "oak" | "willow" | "maple" | "yew" | "magic" | "elder"
        hint          "north as the crow flies from Seers' Village"
        locationClue  the spirit tree's "which has appeared ..." sentence
        tileX, tileZ  where we saw the tree
        health        percent, or nil if unknown
        healthSource  "examine" (exact) | "stage" (at most, from the tree's
                      look) | "strike" (at most, a strike we saw) |
                      "timed" (at most: by the lightning schedule, that
                      strike has certainly happened by now)
        deadAt        when it was felled or died (best estimate)
        updatedAt     when this record last changed
    Times are Unix milliseconds. Missing fields are simply nil (absent),
    like undefined properties in JS.

    The tree's schedule (as observed in the beta client):
      - S: sapling stage 1. Without nurturing, a new stage every 60 s and
        a full tree at S + 5 min. Nurturing makes it all happen sooner.
      - M: full tree. Lightning at M + 10 and M + 20 min, death at M + 30,
        each moved to the first "beat" at or after that time (so up to 59 s
        later). Untouched, M = S + 5 and everything lands on the beat.
      - Dead trunk (rewards) for about 10 min after death.

    The rule everything follows: SOMETHING SEEN BEATS A TIMED GUESS.
      - Each sighting or dialogue line narrows the window for S or M. For
        example, "approximately 7 minutes" means S is 7 to 8 minutes away.
      - Nurturing makes saplings grow faster, so a sapling stage only says
        how OLD the tree can be at most. We still guess "not nurtured", but
        only inside the window.
      - From S we assume the sapling is NOT nurtured: M = S + 5 min. At
        worst it grew up sooner, and a sighting corrects that.
      - A lightning strike we see (the NPC "Thor" at the tree) pins the beat
        to the second, and tells us M to within a minute.
      - Strikes only happen to a tree that is still ABOVE the threshold:
        strike 1 only above 50%, strike 2 only above 25%. They make sure a
        tree nobody chops still dies on time. So a strike always changes
        the tree's look (full -> _LVL2 = strike 1, _LVL2 -> _LVL3 = strike
        2, -> _DYING = the kill), and that change says which strike it was.
        And a tree already at or below a threshold skips that strike.
      - Timed rules only fill in what nobody has seen. While the tree is in
        view they pause completely: the game will tell us when it changes.
      - NEVER SHOW A GUESS AS A FACT. "The tree is alive" alone only says M
        was in the last 31 minutes. The best guess inside such a window is
        just a number, so it never sets a health or a lightning time:
          * lightning times are only shown once M is known to within a few
            minutes (see TRUSTED_WINDOW_MS),
          * a timed health is only set once the strike has certainly
            happened, even if M was as late as it can be,
          * the timed death uses the latest possible M, so a living tree
            is never declared dead.

    How updates work (React developers: think of a reducer). Each change
    copies the record, edits the copy, and compares the copy with the
    original. Only if they differ is the copy stored. That way every function
    can say whether anything really changed, so the caller only saves then.
]]

local worldstate = {}

-------------------------------------------------------------------------------
-- Timings
-------------------------------------------------------------------------------

local SECOND = 1000
local MINUTE = 60 * SECOND

-- Sapling: a stage every 60 s, full tree at S + 5 min (sooner if nurtured).
local SAPLING_STAGE_MS = 60 * SECOND
local SAPLING_MATURE_MS = 5 * MINUTE
-- After maturing: lightning at M + 10 (health to 50%) and M + 20 (to 25%),
-- death at M + 30 (the third strike), each on the next beat.
local STRIKE_1_MS = 10 * MINUTE
local STRIKE_1_HEALTH = 50
local STRIKE_2_MS = 20 * MINUTE
local STRIKE_2_HEALTH = 25
local DEATH_MS = 30 * MINUTE
-- The dead trunk (rewards) stays about 10 min. One beta observation: 9 +/- 1.
local DEAD_MS = 10 * MINUTE
-- Events reach us on server ticks (0.6 s), so a time we saw can be up to
-- about a second late. Rounding to the beat allows this much slack, so a
-- slightly late M doesn't push a prediction a whole minute later.
local JITTER_MS = 2 * SECOND
-- A strike and the health-stage change it causes arrive within this time.
local PAIR_MS = 2 * SECOND
-- How unsure we may be about M and still show lightning times: one sapling's
-- growing time. Any window that started from a spawn time fits in it; a
-- tree first met fully grown doesn't. The windows we get:
--   - watched it grow up, or saw a strike:          about 1 min
--   - a spawn timer (assumed not nurtured):         1-2 min
--   - a timer, then found grown early (nurtured):   under 5 min (S to now)
--   - a sapling seen or greeted, no timer:          up to 5 min
--   - "we saw it at full health":                   11 min (too wide)
--   - "the spirit tree says it's alive":            31 min (too wide)
local TRUSTED_WINDOW_MS = SAPLING_MATURE_MS
-- A window for M this narrow (a strike we saw) gives times to the second,
-- once the beat is known.
local EXACT_WINDOW_MS = MINUTE + 2 * JITTER_MS

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

-- Copies a table one level deep, like { ...record } in JS.
-- pairs() loops over every key/value, like Object.entries().
local function copy(record)
    local result = {}
    for key, value in pairs(record) do
        result[key] = value
    end
    return result
end

-- True if two records have exactly the same fields and values.
local function sameRecord(a, b)
    for key, value in pairs(a) do
        if b[key] ~= value then         -- ~= is Lua's !==
            return false
        end
    end
    for key, value in pairs(b) do
        if a[key] ~= value then
            return false
        end
    end
    return true
end

-- Keeps a time inside a window, moving it to the nearest edge if needed.
local function clampTime(value, earliest, latest)
    if value > latest then
        return latest
    end
    if value < earliest then
        return earliest
    end
    return value
end

-- True if "at" is set and no more than maxAge before now.
local function isRecent(at, now, maxAge)
    return at ~= nil and now - at <= maxAge and now >= at
end

-- True if the record is about a tree that exists (or just died).
local function hasTree(record)
    return record.status == "sapling" or record.status == "alive" or record.status == "dead"
end

-- The fields that belong to one particular tree. When that tree is gone (or
-- turns out to be a different tree), all of them go.
local TREE_FIELDS = {
    "treeType", "hint", "locationClue", "tileX", "tileZ", "health", "healthSource",
    "spawnAt", "spawnEarliest", "spawnLatest", "matureAt", "matureEarliest", "matureLatest",
    "beatMs", "strikeSeenAt", "stageDropAt", "stageDropCap", "stepSeenAt", "deadAt",
}

-- Forgets the current tree: back to "none", with no spawn time.
local function forgetTree(record)
    for _, field in ipairs(TREE_FIELDS) do
        record[field] = nil             -- setting a field to nil removes it
    end
    record.status = "none"
end

-- A record with nothing worth keeping (no tree, no spawn time, no hint).
local function isEmpty(record)
    return record.status == "none" and record.spawnAt == nil and record.hint == nil
end

-- The core of every update, like a reducer:
--   1. copy the world's record (or start a blank one),
--   2. let change(record) edit the copy,
--   3. store it only if it differs from the original.
-- Returns true if something changed.
local function update(worlds, world, now, change)
    if world == nil or now == nil then
        return false        -- mid-hop or before the clock runs: drop the fact
    end
    local old = worlds[world]
    local record = copy(old or { status = "none" })
    -- "old or {...}" is Lua's version of "old ?? {...}": "or" returns its
    -- left side unless that is nil/false.
    change(record)

    if isEmpty(record) then
        if old == nil then
            return false
        end
        worlds[world] = nil         -- nothing left to know: remove the record
        return true
    end
    if old ~= nil and sameRecord(old, record) then
        return false
    end
    record.updatedAt = now
    worlds[world] = record
    return true
end

-------------------------------------------------------------------------------
-- Time windows (for S and for M)
-------------------------------------------------------------------------------
-- Both times are kept the same way, in three fields named after them:
-- name .. "At" (best guess), name .. "Earliest", name .. "Latest". So
-- narrow(record, "spawn", ...) works on spawnAt / spawnEarliest / spawnLatest.
-- record[name .. "At"] is like record[`${name}At`] in JS.

-- Adds what one observation says: the time lies between earliest and
-- latest. The window only ever gets narrower. If the new observation
-- contradicts the old window (something we assumed was wrong), the newest
-- observation wins and the window starts again from it.
local function narrow(record, name, earliest, latest)
    local oldEarliest = record[name .. "Earliest"]
    local oldLatest = record[name .. "Latest"]
    if oldEarliest ~= nil then
        local narrowedEarliest = math.max(earliest, oldEarliest)
        local narrowedLatest = math.min(latest, oldLatest)
        if narrowedEarliest <= narrowedLatest then
            earliest = narrowedEarliest
            latest = narrowedLatest
        end
        -- else: they don't overlap, so keep just the new observation's window
    end
    record[name .. "Earliest"] = earliest
    record[name .. "Latest"] = latest
end

-- Picks the best guess inside the window. In order of preference:
--   newGuess  a precise guess from this observation (e.g. "watched the
--             sapling step from stage 2 to 3, so S was 2 min ago if nobody
--             nurtured it")
--   the guess we already had
--   fallback  a rough guess from this observation
--   the middle of the window
-- Whichever is used, it's moved inside the window if it falls outside.
-- "a or b or c" gives the first one that isn't nil, like a ?? b ?? c in JS.
local function choose(record, name, newGuess, fallback)
    local earliest = record[name .. "Earliest"]
    local latest = record[name .. "Latest"]
    local value = newGuess or record[name .. "At"] or fallback or (earliest + latest) // 2
    record[name .. "At"] = clampTime(value, earliest, latest)
end

-- "Another evil tree in approximately N minutes" -> a window for S.
-- The game seems to round DOWN, but never shows less than 1. Seen in the beta
-- (W204, real spawn 03:43:32): 7m21s left -> "7", 6m23s -> "6", 2m45s -> "2",
-- 48s -> "1", 14s -> "1". So "N minutes" means N to N+1 minutes away, and
-- "1 minute" means 0 to 2 minutes away. Returns earliest, latest.
-- Game bug (known from EctoTrees): with exactly 1 hour left the game says
-- "approximately 0 minutes" instead of "1 hour". parser.lua already turns
-- that 0 into 60, so here it's the window 60 to 61 minutes away, which fits
-- the round-down rule (60 whole minutes = "1 hour and 0 minutes", and only
-- the "0 minutes" part gets printed).
local function timerWindow(timerMs, now)
    local minutes = timerMs // MINUTE       -- // is whole-number division
    local earliest = now + minutes * MINUTE
    if minutes <= 1 then
        earliest = now
    end
    return earliest, now + (minutes + 1) * MINUTE
end

-------------------------------------------------------------------------------
-- The lightning schedule
-------------------------------------------------------------------------------

-- The first beat at or after "due" (allowing JITTER_MS of slack).
-- The % here is Lua's remainder, which is never negative for a positive
-- divisor (unlike JS's %), so this always moves forwards, 0 to 59.999 s.
local function nextBeat(due, beatMs)
    local from = due - JITTER_MS
    return from + (beatMs - from) % MINUTE
end

-- How wide the window for M is (ms), or nil if we have no window.
local function matureWidth(record)
    if record.matureEarliest == nil or record.matureLatest == nil then
        return nil
    end
    return record.matureLatest - record.matureEarliest
end

-- True if we know M well enough to show lightning times from it.
local function matureTrusted(record)
    local width = matureWidth(record)
    return record.matureAt ~= nil and width ~= nil and width <= TRUSTED_WINDOW_MS
end

-- When event number k happens (1 = first strike, 2 = second, 3 = death).
--   latest = false: our best guess, from matureAt. Without a known beat it
--                   is the start of the minute it can happen in.
--   latest = true:  the LATEST it can happen, from matureLatest and the end
--                   of that minute. Used for "it has certainly happened by
--                   now" (timed health, timed death) and "dies by".
-- Returns the time, and true if it's approximate (could be off by up to a
-- minute or more: beat unknown, or M only known roughly).
local function eventTime(record, k, latest)
    local mature = record.matureAt
    if latest and record.matureLatest ~= nil then
        mature = record.matureLatest
    end
    local due = mature + k * STRIKE_1_MS
    local width = matureWidth(record)
    local roughM = width == nil or width > EXACT_WINDOW_MS
    if record.beatMs ~= nil then
        return nextBeat(due, record.beatMs), roughM
    end
    if latest then
        return due + MINUTE - 1, true
    end
    return due, true
end

-- How long ago the tree can have matured, given its health right now.
-- A tree with more than 50% hasn't had its first strike (M + 10) yet, so
-- it matured less than about 11 min ago; more than 25%: no second strike
-- yet. (Chopping only lowers health, so this holds whatever players did.)
-- health may be nil (unknown). Returns the earliest possible M.
local function earliestMature(health, now)
    if health ~= nil and health > STRIKE_1_HEALTH then
        return now - STRIKE_1_MS - MINUTE
    end
    if health ~= nil and health > STRIKE_2_HEALTH then
        return now - STRIKE_2_MS - MINUTE
    end
    return now - DEATH_MS - MINUTE      -- any older and it would have died
end

-- The window for M that a strike seen at "at" gives, if it was strike k:
-- that strike lands on the first beat at or after M + 10k min. clockSlack
-- is extra room at the late end while the clock is only minute-accurate
-- (see "secondsKnown" below).
local function strikeWindow(k, at, clockSlack)
    local due = at - k * STRIKE_1_MS
    return due - MINUTE, due + JITTER_MS + (clockSlack or 0)
end

-- Right after start-up the plugin's clock only knows the minute: "now" can
-- be up to 59 s behind the real time until the minute first changes (see
-- core/clock.lua). Functions that pin a time to the second take an optional
-- secondsKnown argument (main.lua passes clock.isSynced()). When it's false:
--   - the beat isn't recorded (it would be wrong by up to a minute),
--   - exact times are widened by a minute at the late end.
-- nil counts as true, so callers (and tests) that don't care can leave it out.
local function clockSlackFor(secondsKnown)
    if secondsKnown == false then
        return MINUTE
    end
    return 0
end

-- Health after strike k: set to 50% / 25%, or unchanged if already lower.
local function applyStrikeHealth(record, k)
    local cap = STRIKE_1_HEALTH
    if k == 2 then
        cap = STRIKE_2_HEALTH
    end
    if record.health == nil or record.health > cap then
        record.health = cap
        record.healthSource = "strike"
    end
end

-------------------------------------------------------------------------------
-- Stage changes shared by several sources
-------------------------------------------------------------------------------

-- A different tree type from the one we have means a new tree.
local function forgetIfOtherType(record, treeType)
    if treeType ~= nil and record.treeType ~= nil and record.treeType ~= treeType then
        forgetTree(record)
    end
end

-- Forgets what we knew about the full tree (used when it turns out to still
-- be a sapling).
local function forgetMature(record)
    record.matureAt = nil
    record.matureEarliest = nil
    record.matureLatest = nil
    record.health = nil
    record.healthSource = nil
end

-- The tree is a sapling. Even nurtured, it can't be more than 5 min old
-- (it would have grown up). The caller then calls choose(record, "spawn").
local function becomeSapling(record, now)
    if record.status == "dead" then
        forgetTree(record)          -- the old tree is gone; this is a new one
    elseif record.status == "alive" then
        forgetMature(record)        -- our timers guessed it had grown up; it hasn't
    end
    record.status = "sapling"
    narrow(record, "spawn", now - SAPLING_MATURE_MS, now)
end

-- First guess at M, from S. We assume nobody nurtured the sapling, so
-- M = S + 5 min, and the window for M is the window for S moved 5 min on.
-- (Nurturing would make M sooner. If someone sees the tree already grown,
-- that sighting doesn't fit this window and replaces it: see becomeAlive.)
-- Only used when we have no window for M yet.
local function seedMatureFromSpawn(record)
    if record.matureEarliest ~= nil or record.spawnAt == nil then
        return
    end
    local spawnEarliest = record.spawnEarliest or record.spawnAt
    local spawnLatest = record.spawnLatest or record.spawnAt
    narrow(record, "mature", spawnEarliest + SAPLING_MATURE_MS, spawnLatest + SAPLING_MATURE_MS)
    choose(record, "mature", nil, record.spawnAt + SAPLING_MATURE_MS)
end

-- The tree is a full ("alive") tree: it matured no later than now, and no
-- earlier than its health allows (see earliestMature) or than it spawned.
-- Safe to call again on a tree that's already alive: it only narrows the
-- window.
local function becomeAlive(record, now, health)
    -- If our timers had already declared it dead, they were wrong: same tree.
    record.deadAt = nil
    record.status = "alive"
    seedMatureFromSpawn(record)
    local earliest = earliestMature(health, now)
    -- It can't have matured before it spawned. This matters when it grew up
    -- sooner than S + 5 (nurtured): then this sighting replaces the
    -- unnurtured window, and S still keeps the new window small.
    if record.spawnEarliest ~= nil and record.spawnEarliest <= now then
        earliest = math.max(earliest, record.spawnEarliest)
    end
    narrow(record, "mature", earliest, now)
    choose(record, "mature")
end

-- The tree is dead (rewards available). Died no later than now, and no
-- earlier than 10 min ago (the trunk would be gone otherwise).
local function becomeDead(record, now)
    local deadAt = record.deadAt or now
    record.deadAt = clampTime(deadAt, now - DEAD_MS, now)
    record.status = "dead"
    record.health = nil
    record.healthSource = nil
end

-- We know which strike it was (k = 1 or 2) at time "at": narrow M and set
-- the health. A health that came from an earlier, wrong guess about which
-- strike it was is replaced.
local function learnStrike(record, k, at, clockSlack)
    narrow(record, "mature", strikeWindow(k, at, clockSlack))
    -- Best guess: M was exactly 10k minutes before the strike. Then the next
    -- strike lands exactly 10 min after this one, on the same beat. (Keeping
    -- an older guess here could leave M at the window's early edge, and
    -- every later prediction a minute early.)
    choose(record, "mature", at - k * STRIKE_1_MS)
    if record.healthSource == "strike" or record.healthSource == "timed" then
        record.health = nil
        record.healthSource = nil
    end
    applyStrikeHealth(record, k)
end

-------------------------------------------------------------------------------
-- Dialogue: Spirit tree, Sunbeam crown, Nature's Sentinel helm
-------------------------------------------------------------------------------

-- facts come from parser.parseDialogue. A conversation arrives one page at a
-- time (timer on one page, hint on the next), so each page only touches the
-- fields it knows about and never wipes what an earlier page set.
function worldstate.applyDialogue(worlds, world, facts, now)
    return update(worlds, world, now, function(record)
        -- "Another tree in X minutes": any tree we had is gone, including a
        -- dead trunk (the timer only starts once the rewards are over).
        -- "No tree right now" without a timer only clears a living tree.
        -- If we already had no tree, keep the hint: it's the hint for the
        -- coming tree (the spirit tree gives it on the next page).
        if facts.timerMs ~= nil and hasTree(record) then
            forgetTree(record)
        elseif facts.noTree and (record.status == "sapling" or record.status == "alive") then
            forgetTree(record)
        end

        -- "There won't be another evil tree for a long time": the tree is
        -- dead and its rewards are still there. The hint that follows is
        -- this dead tree's, so the record keeps it.
        if facts.rewardsWindow and record.status ~= "dead" then
            if record.status == "none" then
                -- A spawn timer we had must be out of date.
                record.spawnAt = nil
                record.spawnEarliest = nil
                record.spawnLatest = nil
            end
            becomeDead(record, now)
        end

        -- Spirit tree greetings: "...here to help dispatch the evil tree?"
        -- (it's alive) and "...interested in the strange sapling?"
        if facts.treeAlive and record.status ~= "alive" then
            becomeAlive(record, now, record.health)
        elseif facts.saplingExists and record.status ~= "sapling" then
            becomeSapling(record, now)
            choose(record, "spawn")
        end

        if facts.timerMs ~= nil then
            -- Each reading narrows the window; the middle is the best guess.
            narrow(record, "spawn", timerWindow(facts.timerMs, now))
            -- (timerWindow returns two values, which become narrow's 3rd
            -- and 4th arguments, like spreading [a, b] in JS.)
            record.spawnAt = (record.spawnEarliest + record.spawnLatest) // 2
        end

        -- Crown / helm: "Nasty spirits have got at a willow tree (sapling)."
        if facts.treeType ~= nil then
            forgetIfOtherType(record, facts.treeType)
            if facts.isSapling then
                becomeSapling(record, now)
                choose(record, "spawn")
            else
                becomeAlive(record, now, record.health)
            end
            record.treeType = facts.treeType
        end

        -- "It can be found north as the crow flies from Seers' Village."
        if facts.hint ~= nil then
            record.hint = facts.hint
        end

        -- "...which has appeared beside the west gates of Yanille." Only said
        -- once the tree exists, so it's at least a sapling.
        if facts.locationClue ~= nil then
            record.locationClue = facts.locationClue
            if record.status == "none" then
                becomeSapling(record, now)
                choose(record, "spawn")
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- Examine text
-------------------------------------------------------------------------------

-- facts come from parser.parseExamine: { health = 25 } or { deadWithRewards = true }.
function worldstate.applyExamine(worlds, world, facts, now)
    return update(worlds, world, now, function(record)
        if facts.health ~= nil then
            -- e.g. 100% means the first strike (M + 10) hasn't happened yet.
            becomeAlive(record, now, facts.health)
            -- Examine is exact, so it replaces any other health value.
            record.health = facts.health
            record.healthSource = "examine"
        elseif facts.deadWithRewards then
            if record.status ~= "dead" then
                becomeDead(record, now)
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- Lightning strikes
-------------------------------------------------------------------------------

-- A lightning strike happened at the tree just now (capture/lightning.lua
-- saw the "Thor" NPC).
--   - It gives the beat to the second.
--   - Which strike was it? Only the tree's new look can tell us (see the
--     header: a strike always changes it). That loc change arrives in the
--     same second, before or after the strike:
--       before: applyTreeLoc saved it as stageDropAt; we pair it here.
--       after:  applyTreeLoc sees strikeSeenAt and pairs it there.
--     _DYING means the kill: the dying loc sets the death time itself.
--     We never guess the number from timing alone.
function worldstate.applyStrike(worlds, world, now, secondsKnown)
    local clockSlack = clockSlackFor(secondsKnown)
    return update(worlds, world, now, function(record)
        if secondsKnown ~= false then
            record.beatMs = now % MINUTE
        end
        record.strikeSeenAt = now
        if record.status == "dead" and isRecent(record.deadAt, now, PAIR_MS) then
            return      -- the killing strike; the _DYING loc already arrived
        end
        if record.status ~= "alive" or record.matureEarliest == nil then
            -- Our timers had it as a sapling, dead or not spawned yet: they
            -- were wrong, it's this tree and it's alive. (Also fills in the
            -- window for M on records saved by older versions.)
            becomeAlive(record, now, record.health)
        end
        if isRecent(record.stageDropAt, now, PAIR_MS) then
            -- ("x and a or b" is Lua's x ? a : b.)
            learnStrike(record, (record.stageDropCap == STRIKE_1_HEALTH) and 1 or 2, now, clockSlack)
        end
    end)
end

-------------------------------------------------------------------------------
-- Tree objects (locs) near the player
-------------------------------------------------------------------------------

-- Applies a health cap from the tree's stage: _LVL2 means at most 50%,
-- _LVL3 at most 25%, the full tree "somewhere above 50%". These are health
-- stages, not lightning signals: chopping can cause them too.
local function applyStageCap(record, cap)
    -- A sighting beats a timed guess, even if the guess was lower.
    if record.healthSource == "timed" then
        record.health = nil
        record.healthSource = nil
    end
    -- Health only goes down during a tree's life, so keep the lowest value.
    -- A cap of 100 says nothing new.
    if cap < 100 and (record.health == nil or record.health > cap) then
        record.health = cap
        record.healthSource = "stage"
    end
end

-- Called for capture/trees.lua events:
--   kind      "seen" (a tree loc appeared), "fading" (dead trunk fading out:
--             the reward window is over), or "removed"
--   info      the data/trees.lua entry: { stage, treeType, healthCap, saplingLevel }
--   previous  the info of the loc this one replaced at the same spot, if we
--             watched it change (a real stage change); nil on first sight
--   secondsKnown  optional, see clockSlackFor above
function worldstate.applyTreeLoc(worlds, world, kind, info, tileX, tileZ, previous, now, secondsKnown)
    -- "removed" alone means nothing: it also happens when you walk away or
    -- hop. Only the fade-out animation means the trunk is really going.
    if kind == "removed" then
        return false
    end
    local clockSlack = clockSlackFor(secondsKnown)

    return update(worlds, world, now, function(record)
        if kind == "fading" then
            forgetTree(record)
            return
        end

        -- kind == "seen"
        -- Did we watch this loc replace an older stage of the same tree?
        -- data/trees.lua has one table per loc ID, so a different table means
        -- a different loc (== on tables compares identity, as in JS).
        local watchedChange = previous ~= nil and previous ~= info

        if info.stage == "sapling" then
            becomeSapling(record, now)
            -- Without nurturing, stage N starts (N-1) minutes after S.
            -- Nurturing only makes stages come sooner, so stage N means
            -- S was at most N minutes ago (or N-1, if we watched it start).
            local stageStart = (info.saplingLevel - 1) * SAPLING_STAGE_MS
            if watchedChange then
                narrow(record, "spawn", now - stageStart, now)
                choose(record, "spawn", now - stageStart)
                -- Two watched steps a minute apart: nobody is nurturing, so
                -- the steps are on the tree's beat.
                if record.beatMs == nil and secondsKnown ~= false and record.stepSeenAt ~= nil
                    and math.abs(now - record.stepSeenAt - SAPLING_STAGE_MS) <= JITTER_MS then
                    record.beatMs = now % MINUTE
                end
                record.stepSeenAt = now
            else
                narrow(record, "spawn", now - info.saplingLevel * SAPLING_STAGE_MS, now)
                -- Rough guess: halfway through the stage, not nurtured.
                choose(record, "spawn", nil, now - stageStart - SAPLING_STAGE_MS // 2)
            end

        elseif info.stage == "alive" then
            forgetIfOtherType(record, info.treeType)
            -- The stage's cap works like a health reading: the full tree
            -- (cap 100) has over 50%, _LVL2 (cap 50) over 25%.
            becomeAlive(record, now, info.healthCap)
            if watchedChange and previous.stage == "sapling" then
                -- Watched it grow up: that's M, to the second (or within
                -- the minute, if our clock only knows the minute yet).
                narrow(record, "mature", now, now + clockSlack)
                choose(record, "mature", now)
            elseif watchedChange and previous.healthCap ~= nil and info.healthCap < previous.healthCap then
                -- Watched the health stage drop. With a strike in the same
                -- second it was that strike (1 if now _LVL2, 2 if _LVL3).
                -- Without one, players chopped it, which says nothing
                -- about M; remember it in case the strike arrives next.
                record.stageDropAt = now
                record.stageDropCap = info.healthCap
                if isRecent(record.strikeSeenAt, now, PAIR_MS) then
                    learnStrike(record, (info.healthCap == STRIKE_1_HEALTH) and 1 or 2, now, clockSlack)
                end
            end
            record.treeType = info.treeType
            applyStageCap(record, info.healthCap)

        elseif info.stage == "dying" then
            -- The dying loc only lasts a few seconds, so it died just now
            -- (by lightning if a strike came with it, else felled).
            forgetIfOtherType(record, info.treeType)
            record.deadAt = now
            becomeDead(record, now)
            record.treeType = info.treeType

        elseif info.stage == "dead" then
            forgetIfOtherType(record, info.treeType)
            becomeDead(record, now)     -- keeps deadAt if the dying loc set it
            record.treeType = info.treeType
        end

        record.tileX = tileX
        record.tileZ = tileZ
    end)
end

-------------------------------------------------------------------------------
-- Time passing
-------------------------------------------------------------------------------

-- Runs the timed rules for one record. Each step can feed the next, so after
-- the plugin was off for hours, one call catches up all the way: timer ->
-- sapling -> alive -> dead -> gone.
local function runTimers(record, now)
    -- 1. The spawn time passed: a sapling appeared then.
    if record.status == "none" and record.spawnAt ~= nil and now >= record.spawnAt then
        record.status = "sapling"
    end

    -- 2. Sapling grows up (at the latest; nurturing would be sooner, but
    --    then someone near it would usually see that).
    if record.status == "sapling" and record.spawnAt ~= nil
        and now >= record.spawnAt + SAPLING_MATURE_MS then
        record.status = "alive"
    end

    -- 3. Lightning caps at M + 10 and M + 20, then death at M + 30. Each
    --    only once it has CERTAINLY happened (eventTime(..., true) is the
    --    latest it can be), so a rough M never produces a health number.
    if record.status == "alive" then
        seedMatureFromSpawn(record)     -- also fills in records saved by older versions
    end
    if record.status == "alive" and record.matureAt ~= nil then
        if now >= eventTime(record, 1, true)
            and (record.health == nil or record.health > STRIKE_1_HEALTH) then
            record.health = STRIKE_1_HEALTH
            record.healthSource = "timed"
        end
        if now >= eventTime(record, 2, true)
            and (record.health == nil or record.health > STRIKE_2_HEALTH) then
            record.health = STRIKE_2_HEALTH
            record.healthSource = "timed"
        end
        -- Death at the latest possible time, so we never kill a living tree.
        local deathAt = eventTime(record, 3, true)
        if now >= deathAt and not matureTrusted(record) then
            -- It's certainly dead, but it may have died up to half an hour
            -- ago and its rewards may be long gone. "Dead, rewards for 10
            -- more minutes" would be a guess shown as a fact, so forget it.
            forgetTree(record)
        elseif now >= deathAt then
            record.status = "dead"
            record.deadAt = deathAt
            record.health = nil
            record.healthSource = nil
        end
    end

    -- 4. The dead trunk and its rewards are gone.
    if record.status == "dead" and record.deadAt ~= nil and now >= record.deadAt + DEAD_MS then
        forgetTree(record)
    end
end

-- Call about once a second. inViewWorld is the world whose tree is in view
-- right now (or nil): its timers pause, because the game itself will tell
-- us when that tree changes. Returns true if any record changed.
function worldstate.tick(worlds, now, inViewWorld)
    if now == nil then
        return false
    end
    -- Collect the world numbers first, then update. Changing a table while
    -- pairs() walks it is only safe in limited ways in Lua, so this keeps
    -- the loop simple and safe.
    local numbers = {}
    for world in pairs(worlds) do
        if world ~= inViewWorld then
            numbers[#numbers + 1] = world
        end
    end
    local anyChanged = false
    for _, world in ipairs(numbers) do
        if update(worlds, world, now, function(record) runTimers(record, now) end) then
            anyChanged = true
        end
    end
    return anyChanged
end

-------------------------------------------------------------------------------
-- Reading a record (for the panel / dashboard)
-------------------------------------------------------------------------------

-- Strike k (1 or 2) only hits a tree above its threshold (50% / 25%).
-- Returns "done" if health is known to be at or below it (struck already,
-- or chopped below it, so this strike won't come), "due" if health is known
-- to be above it (it hasn't struck yet, even if its time has passed), or
-- "unknown" (no health: go by the time).
local function strikeState(record, k)
    local cap = STRIKE_1_HEALTH
    if k == 2 then
        cap = STRIKE_2_HEALTH
    end
    if record.health == nil then
        return "unknown"
    elseif record.health <= cap then
        return "done"
    end
    return "due"
end

-- What happens next to this world's tree, and when (Unix ms). now may be
-- nil (clock not running yet); then an alive tree just reports its death.
-- Returns three values (Lua functions can return several, like returning
-- [label, time, approximate] in JS), e.g. "lightning", 1793932480000, false.
-- approximate is true when the time could be a minute or more off.
-- Labels for an alive tree:
--   "lightning"   M is known well enough (matureTrusted) to time it
--   "dies by"     the same, after the last strike
--   "dies within" M is NOT known: only the latest it can possibly die
-- Returns nil if nothing is due.
function worldstate.nextEvent(record, now)
    if record.status == "none" and record.spawnAt ~= nil then
        return "spawns", record.spawnAt, false
    elseif record.status == "sapling" and record.spawnAt ~= nil then
        return "matures by", record.spawnAt + SAPLING_MATURE_MS, false
    elseif record.status == "alive" and record.matureAt ~= nil then
        if not matureTrusted(record) then
            -- Only an upper bound, so not "approximate": it can't be later.
            local at = eventTime(record, 3, true)
            return "dies within", at, false
        end
        if now ~= nil then
            for k = 1, 2 do
                local at, approximate = eventTime(record, k, false)
                local state = strikeState(record, k)
                -- "due" while overdue: the countdown shows 0:00 until it lands.
                if state == "due" or (state == "unknown" and now < at) then
                    return "lightning", at, approximate
                end
            end
        end
        local at, approximate = eventTime(record, 3, true)
        return "dies by", at, approximate
    elseif record.status == "dead" and record.deadAt ~= nil then
        return "gone by", record.deadAt + DEAD_MS, false
    end
    return nil
end

-------------------------------------------------------------------------------
-- Manual
-------------------------------------------------------------------------------

-- "Clear world": forget everything about one world (fixes wrong or stale data).
function worldstate.clearWorld(worlds, world)
    if worlds[world] == nil then
        return false
    end
    worlds[world] = nil
    return true
end

return worldstate
