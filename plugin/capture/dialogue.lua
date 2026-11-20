--[[
    capture/dialogue.lua
    --------------------
    Watches two kinds of on-screen text boxes for new pages:

      1. NPC dialogue, interface 1184 (CHAT_V2_LEFT):
             component 4  = the speaker's name, e.g. "Spirit tree"
             component 10 = the text of the current page
         Used by the Spirit tree and the Queen of Sunrise (Sunbeam crown).

      2. Plain message box, interface 1186 (MESBOX_V2):
             component 3  = the text (there is no speaker)
         Used by the Nature's Sentinel helm. We report these with the speaker
         parser.MESSAGE_BOX_SPEAKER.

    Both interfaces are only loaded while the box is on screen (seen when testing
    in the beta client). We report each new page once through the callback
    given to dialogue.setOnPage(). Deciding what the text means is the
    parser's job, not this file's.

    When to read: once per server tick (~0.6 s), but on the client frame
    AFTER the server tick, not during it. Testing in the beta showed the game
    fills in a page's text one frame (20 ms) after the server packet arrives:
    a read during Event.ServerLogic sees the previous page, or an empty box.
    When clicking quickly, each page lasts exactly one server tick, so the
    last page before the box closes (the Spirit tree's location hint) was
    never read. Reading on the next frame sees each page as soon as it shows,
    and it's still only one read per server tick.
]]

local safe = require("core/safe")
local parser = require("core/parser")

local dialogue = {}

-- Each box we watch: where its text (and speaker, if any) lives.
local BOXES = {
    { name = "npc",     interfaceId = 1184, speakerComponentId = 4, textComponentId = 10 },
    { name = "message", interfaceId = 1186, speakerComponentId = nil, textComponentId = 3 },
}

local onPage = nil      -- function(speaker, text), set by main.lua
local lastPage = {}     -- [box name] = "speaker|text" of the page we last reported
local readNextFrame = false  -- set each server tick; the next frame reads the boxes

-- Reads a label's text from an interface, or nil if it isn't there.
local function readLabel(interfaceId, componentId)
    local text = safe.try(function()
        local label = ui.Interfaces:GetComponent(interfaceId, componentId)
        if label == nil then
            return nil
        end
        return label.content
    end)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    return parser.plainText(text)
end

-- Checks one box and reports its page if it's new.
local function checkBox(box)
    local text = readLabel(box.interfaceId, box.textComponentId)
    if text == nil then
        lastPage[box.name] = nil    -- box closed: the same page can be reported again next time
        return
    end
    local speaker = parser.MESSAGE_BOX_SPEAKER
    if box.speakerComponentId ~= nil then
        speaker = readLabel(box.interfaceId, box.speakerComponentId) or ""
    end
    local page = speaker .. "|" .. text
    if page ~= lastPage[box.name] then
        lastPage[box.name] = page
        if onPage ~= nil then
            onPage(speaker, text)
        end
    end
end

-- Registers the function to call for each new page.
function dialogue.setOnPage(callback)
    onPage = callback
end

-- Event.ServerLogic handler: the page text isn't there yet, so just ask the
-- next frame to read it (see the header).
function dialogue.onServerTick()
    readNextFrame = true
end

-- Event.Logic handler (50 times a second). Does nothing except on the first
-- frame after a server tick.
function dialogue.onLogic()
    if not readNextFrame then
        return
    end
    readNextFrame = false
    for _, box in ipairs(BOXES) do
        checkBox(box)
    end
end

return dialogue
