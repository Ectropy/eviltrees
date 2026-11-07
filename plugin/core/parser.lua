--[[
    core/parser.lua
    ---------------
    Turns game text into facts. Pure: no game API calls, just string work.

    Two kinds of text:
      - Dialogue from the Spirit tree or the Queen of Sunrise (Sunbeam crown).
      - Examine text (shown in the info box when you examine something).

    Lua patterns are a simpler cousin of regex:
        %d   a digit          (regex \d)
        %a   a letter         (regex [A-Za-z])
        %.   a literal dot    (regex \.)
        %%   a literal %
        +    one or more      (greedy)      -  zero or more (shortest match)
        *    zero or more     (greedy)      ?  optional (one character only)
        (..) captures that part, which string.match returns
    Example: string.match("in 42 minutes", "(%d+) minutes") returns "42".
]]

local parser = {}

local MS_PER_MINUTE = 60000

-- Who we listen to in dialogue, and a short name for each.
-- The Nature's Sentinel helm uses a plain message box with no speaker; the
-- capture code passes MESSAGE_BOX_SPEAKER as the speaker for those.
parser.MESSAGE_BOX_SPEAKER = "(message box)"

local SOURCES = {
    ["Spirit tree"] = "spirit tree",
    ["Queen of Sunrise"] = "sunbeam crown",
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

-- "approximately 1 hour and 42 minutes" -> milliseconds, or nil if not found.
-- Mirrors EctoTrees' alt1-plugin/src/parser.ts, including its quirk that
-- "approximately 0 minutes" means 60 minutes.
-- "hours?" means "hour" with an optional "s".
function parser.spawnTimerMs(text)
    local hours, minutes = string.match(text, "approximately (%d+) hours? and (%d+) minutes?")
    if hours ~= nil then
        return (tonumber(hours) * 60 + tonumber(minutes)) * MS_PER_MINUTE
    end

    hours = string.match(text, "approximately (%d+) hours?%.")
    if hours ~= nil then
        return tonumber(hours) * 60 * MS_PER_MINUTE
    end

    minutes = string.match(text, "approximately (%d+) minutes?")
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
    local source = SOURCES[speaker]
    if source == nil or text == nil then
        return nil
    end
    -- Message boxes show all sorts of game text, so only accept ones that are
    -- clearly about evil trees (the helm uses the same wording as the crown).
    if speaker == parser.MESSAGE_BOX_SPEAKER
        and not string.find(text, "evil tree", 1, true)
        and not string.find(text, "nasty spirits", 1, true)
        and not string.find(text, "Nasty spirits", 1, true) then
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
    if string.find(text, "for a long time", 1, true) then
        facts.rewardsWindow = true
        found = true
    -- Spirit tree: "The taint of the evil tree is not currently on the land."
    -- Crown: "There are no nasty spirits possessing trees right now!"
    elseif string.find(text, "not currently on the land", 1, true)
        or string.find(text, "no nasty spirits", 1, true) then
        facts.noTree = true
        found = true
    end

    -- Spirit tree greetings ("...Do you wish to travel, or ..."):
    --   "...or are you here to help dispatch the evil tree?"   = tree is alive
    --   "...or are you interested in the strange sapling?"     = it's a sapling
    if string.find(text, "help dispatch the evil tree", 1, true) then
        facts.treeAlive = true
        found = true
    elseif string.find(text, "interested in the strange sapling", 1, true) then
        facts.saplingExists = true
        found = true
    end

    -- "It can be found north as the crow flies from Seers' Village."
    -- (.-) takes the shortest text up to the final full stop.
    facts.hint = string.match(text, "It can be found (.-)%.%s*$")
    if facts.hint ~= nil then
        found = true
    end

    -- "...which has appeared beside the west gates of Yanille. You should go..."
    facts.locationClue = string.match(text, "which has appeared (.-)%.")
    if facts.locationClue ~= nil then
        found = true
    end

    -- "Nasty spirits have got at an oak tree." / "...got at a tree."
    -- "an?" = "a" with an optional "n"; (%a*) is the type word, possibly empty.
    local treeWord = string.match(text, "got at an? (%a*) ?tree")
    if treeWord ~= nil and TREE_WORDS[string.lower(treeWord)] ~= nil then
        facts.treeType = TREE_WORDS[string.lower(treeWord)]
        -- "...got at a willow tree sapling." = still growing;
        -- "...got at a willow tree." = mature.
        facts.isSapling = string.find(text, "tree sapling", 1, true) ~= nil
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
    -- We haven't captured this message through the chat event yet, so its
    -- exact capitals aren't known. Matching on a lower-case copy makes the
    -- check case-insensitive (Lua patterns have no "i" flag like JS's /.../i).
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

-- Reads examine text from the info box.
-- Returns { health = 25 }, { deadWithRewards = true }, { deadNoRewards = true },
-- or nil if not recognised.
function parser.parseExamine(text)
    if text == nil then
        return nil
    end
    -- "The tree currently has approximately 25% of its health remaining."
    local health = string.match(text, "approximately (%d+)%% of its health")
    if health ~= nil then
        return { health = tonumber(health) }
    end
    -- Examining the dead trunk: "Looks like there's rewards to be had!"
    if string.find(text, "rewards to be had", 1, true) then
        return { deadWithRewards = true }
    end
    -- The same trunk once your rewards are gone (seen W205, 2026-11-06):
    -- "It looks better dead than alive." This wording may be shared with
    -- other dead things, so worldstate ignores it; it's only recognised
    -- to keep the capture log readable.
    if string.find(text, "It looks better dead than alive", 1, true) then
        return { deadNoRewards = true }
    end
    return nil
end

return parser
