--[[
    core/parser.lua
    ---------------
    Turns game text into facts. Pure: no game API calls, just string work.

    Three kinds of text:
      - Dialogue from the Spirit tree or the Queen of Sunrise (Sunbeam crown).
      - Examine text (shown in the info box when you examine something).
      - Chat messages (optional chatAccess): sapling inspect, activity alert.

    Lua patterns are a simpler cousin of regex:
        %d   a digit          (regex \d)
        %a   a letter         (regex [A-Za-z])
        %.   a literal dot    (regex \.)
        %%   a literal %
        +    one or more      (greedy)      -  zero or more (shortest match)
        *    zero or more     (greedy)      ?  optional (one character only)
        (..) captures that part, which string.match returns
    Example: string.match("in 42 minutes", "(%d+) minutes") returns "42".

    Capitals never matter: each function makes a lower-case copy of the
    game text and matches lower-case patterns against it (Lua patterns have
    no "i" flag like JS's /.../i). So a capital that differs from what we
    expected, in the game or in our own strings, can't break a match. Text
    we keep and show (the hint, the location clue) is cut from the original,
    so it keeps the game's capitals.
]]

local parser = {}

local MS_PER_MINUTE = 60000

-- Who we listen to in dialogue (speaker names in lower case), and a short
-- name for each. The Nature's Sentinel helm uses a plain message box with no
-- speaker; the capture code passes MESSAGE_BOX_SPEAKER as the speaker for those.
parser.MESSAGE_BOX_SPEAKER = "(message box)"

local SOURCES = {
    ["spirit tree"] = "spirit tree",
    ["queen of sunrise"] = "sunbeam crown",
    [parser.MESSAGE_BOX_SPEAKER] = "sentinel helm",
}

-- Tree type words as the game says them -> our names (EctoTrees' names).
-- "a tree" (no type word) is the normal tree.
local TREE_WORDS = {
    [""] = "tree",
    oak = "oak",
    willow = "willow",
    maple = "maple",
    yew = "yew",
    magic = "magic",
    elder = "elder",
}

-- Removes RuneScape text markup such as <col=ff0000>, and turns <br> into a space.
function parser.plainText(text)
    text = string.gsub(text, "<br>", " ")
    text = string.gsub(text, "<[^>]*>", "")
    return text
end

-- True if lower (lower-case text) contains phrase as plain text.
-- string.find(text, phrase, 1, true) searches from character 1 with
-- patterns turned off (the "true"), like text.includes(phrase) in JS.
local function contains(lower, phrase)
    return string.find(lower, phrase, 1, true) ~= nil
end

-- Finds pattern in lower (the lower-case copy of text) and returns the part
-- between the pattern's two "()" markers, cut from the original text so the
-- game's capitals are kept (e.g. "Seers' Village"). In a Lua pattern, "()"
-- captures a position (a character number) instead of text. string.lower
-- never changes the length, so a position in lower is the same in text.
-- string.sub(text, a, b) is text.slice(a - 1, b) in JS.
local function cutKeepingCase(text, lower, pattern)
    local first, after = string.match(lower, pattern)
    if first == nil then
        return nil
    end
    return string.sub(text, first, after - 1)
end

-- "approximately 1 hour and 42 minutes" -> milliseconds, or nil if not found.
-- Mirrors EctoTrees' alt1-plugin/src/parser.ts, including its quirk that
-- "approximately 0 minutes" means 60 minutes.
-- "hours?" means "hour" with an optional "s".
function parser.spawnTimerMs(text)
    local lower = string.lower(text)
    local hours, minutes = string.match(lower, "approximately (%d+) hours? and (%d+) minutes?")
    if hours ~= nil then
        return (tonumber(hours) * 60 + tonumber(minutes)) * MS_PER_MINUTE
    end

    hours = string.match(lower, "approximately (%d+) hours?%.")
    if hours ~= nil then
        return tonumber(hours) * 60 * MS_PER_MINUTE
    end

    minutes = string.match(lower, "approximately (%d+) minutes?")
    if minutes ~= nil then
        minutes = tonumber(minutes)
        if minutes == 0 then
            minutes = 60
        end
        return minutes * MS_PER_MINUTE
    end

    return nil
end

-- Reads one page of Spirit tree / Queen of Sunrise dialogue.
-- Returns a table of facts, or nil if the speaker or text isn't relevant.
-- Possible facts (each may be missing):
--   source       "spirit tree" or "sunbeam crown"
--   timerMs      time until the next tree spawns
--   noTree       true when the speaker says there is no tree right now
--   rewardsWindow true for "won't be another evil tree for a long time":
--                the tree is dead and its rewards are still there
--   treeAlive    true for the spirit tree's "help dispatch" greeting
--   saplingExists true for the spirit tree's "strange sapling" greeting
--   hint         e.g. "north as the crow flies from Seers' Village"
--   locationClue e.g. "beside the west gates of Yanille" (tree already spawned)
--   treeType     e.g. "oak" (Sunbeam crown / helm, tree already spawned)
--   isSapling    true if the crown / helm says it's still a sapling
--                (only set together with treeType)
function parser.parseDialogue(speaker, text)
    if speaker == nil or text == nil then
        return nil
    end
    local source = SOURCES[string.lower(speaker)]
    if source == nil then
        return nil
    end
    local lower = string.lower(text)
    -- Message boxes show all sorts of game text, so only accept ones that are
    -- clearly about evil trees (the helm uses the same wording as the crown).
    if speaker == parser.MESSAGE_BOX_SPEAKER
        and not contains(lower, "evil tree")
        and not contains(lower, "nasty spirits") then
        return nil
    end

    local facts = { source = source }
    local found = false

    facts.timerMs = parser.spawnTimerMs(text)
    if facts.timerMs ~= nil then
        found = true
    end

    -- Spirit tree, right after a tree died: "The taint of the evil tree is
    -- not currently on the land. There won't be another evil tree for a long
    -- time." This means the dead trunk is still there (the rewards window),
    -- and the hint on the next page is for THAT tree, not a new one.
    if contains(lower, "for a long time") then
        facts.rewardsWindow = true
        found = true
    -- Spirit tree: "The taint of the evil tree is not currently on the land."
    -- Crown: "There are no nasty spirits possessing trees right now!"
    elseif contains(lower, "not currently on the land")
        or contains(lower, "no nasty spirits") then
        facts.noTree = true
        found = true
    end

    -- Spirit tree greetings ("...Do you wish to travel, or ..."):
    --   "...or are you here to help dispatch the evil tree?"   = tree is alive
    --   "...or are you interested in the strange sapling?"     = it's a sapling
    if contains(lower, "help dispatch the evil tree") then
        facts.treeAlive = true
        found = true
    elseif contains(lower, "interested in the strange sapling") then
        facts.saplingExists = true
        found = true
    end

    -- "It can be found north as the crow flies from Seers' Village."
    -- ".-" takes the shortest text up to the final full stop; the "()"
    -- markers around it say which part to keep (see cutKeepingCase).
    facts.hint = cutKeepingCase(text, lower, "it can be found ().-()%.%s*$")
    if facts.hint ~= nil then
        found = true
    end

    -- "...which has appeared beside the west gates of Yanille. You should go..."
    facts.locationClue = cutKeepingCase(text, lower, "which has appeared ().-()%.")
    if facts.locationClue ~= nil then
        found = true
    end

    -- "Nasty spirits have got at an oak tree." / "...got at a tree."
    -- "an?" = "a" with an optional "n"; (%a*) is the type word, possibly empty.
    local treeWord = string.match(lower, "got at an? (%a*) ?tree")
    if treeWord ~= nil and TREE_WORDS[treeWord] ~= nil then
        facts.treeType = TREE_WORDS[treeWord]
        -- "...got at a willow tree sapling." = still growing;
        -- "...got at a willow tree." = mature.
        facts.isSapling = contains(lower, "tree sapling")
        found = true
    end

    if found then
        return facts
    end
    return nil
end

-- Reads the chat message you get when you inspect a sapling (only seen with
-- the optional chatAccess permission, see capture/chat.lua):
--   "This sapling will grow into an Evil elder tree." (real text; capital "Evil")
-- Returns facts shaped like the crown's "...got at a willow tree sapling",
-- so worldstate.applyDialogue can use them unchanged:
--   { source = "sapling inspect", treeType = "willow", isSapling = true }
-- or nil if it isn't that message. (%a*) works as in parseDialogue: for
-- "an evil tree" it ends up empty, which TREE_WORDS turns into "tree".
function parser.parseInspect(text)
    if text == nil then
        return nil
    end
    local lower = string.lower(text)
    local treeWord = string.match(lower, "this sapling will grow into an? evil (%a*) ?tree")
    if treeWord == nil or TREE_WORDS[treeWord] == nil then
        return nil
    end
    return {
        source = "sapling inspect",
        treeType = TREE_WORDS[treeWord],
        isSapling = true,
    }
end

-- Reads the activity tracker's chat alert (only seen with the optional
-- chatAccess permission, see capture/chat.lua):
--   "Activity: Evil Tree will be available again in 5 minutes."
-- It is NOT exact: tested on W204 (2026-11-08), the alert came at 03:21:57
-- and the sapling at 03:27:15-03:27:18, 5:18-5:21 later. So "5 minutes" is
-- rounded down like the spirit tree's "approximately 5 minutes" (5 to 6 min).
-- Returns facts shaped like a dialogue timer, so worldstate.applyDialogue
-- handles it exactly like one:
--   { source = "activity alert", timerMs = 300000 }
-- or nil if it isn't that message. "minutes?" also accepts "1 minute".
function parser.parseActivityAlert(text)
    if text == nil then
        return nil
    end
    local lower = string.lower(text)
    local minutes = string.match(lower, "evil tree will be available again in (%d+) minutes?")
    if minutes == nil then
        return nil
    end
    return {
        source = "activity alert",
        timerMs = tonumber(minutes) * MS_PER_MINUTE,
    }
end

-- Reads examine text from the info box.
-- Returns { health = 25 }, { deadWithRewards = true }, { deadNoRewards = true },
-- or nil if not recognised.
function parser.parseExamine(text)
    if text == nil then
        return nil
    end
    -- "The tree currently has approximately 25% of its health remaining."
    local lower = string.lower(text)
    local health = string.match(lower, "approximately (%d+)%% of its health")
    if health ~= nil then
        return { health = tonumber(health) }
    end
    -- Examining the dead trunk: "Looks like there's rewards to be had!"
    if contains(lower, "rewards to be had") then
        return { deadWithRewards = true }
    end
    -- The trunk once your rewards are gone. Recognised for the capture log
    -- only; worldstate ignores it.
    if contains(lower, "it looks better dead than alive") then
        return { deadNoRewards = true }
    end
    return nil
end

return parser
