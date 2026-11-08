--[[
    capture/chat.lua
    ----------------
    Reports game messages from the chatbox.

    This needs the OPTIONAL "chatAccess" permission (plugin.json). The player
    can leave it off: then the client never sends Event.ChatMessage, this
    file does nothing, and everything else still works. We only use it for
    things no permission-free source gives us:
      - inspecting a sapling, "This sapling will grow into an evil willow
        tree." (the tree's type while it's still a sapling)
      - the activity tracker's alert, "Activity: Evil Tree will be available
        again in 5 minutes." (a spawn timer for this world, without having
        to visit a spirit tree)

    Every game message passes through here, but main.lua only keeps the ones
    the parser recognises. Nothing else is logged or saved, and messages
    from players (they have a sender name) are dropped straight away.
]]

local safe = require("core/safe")
local parser = require("core/parser")

local chat = {}

local onText = nil      -- function(text), set by main.lua

-- Registers the function to call with each game message (markup removed).
function chat.setOnText(callback)
    onText = callback
end

-- True if the player has given us chat access. Wrapped in safe.try in case
-- the API isn't there (e.g. in the tests); then the answer is false.
-- ("x == true" turns nil into false.)
function chat.hasAccess()
    return safe.try(function()
        return Plugin.HasPermission(PluginPermissions.chatAccess)
    end) == true
end

-- Event.ChatMessage handler.
function chat.onChatMessage(event)
    -- Players' messages have a sender; game messages have an empty one.
    local sender = event.senderNameUnfiltered
    if sender ~= nil and sender ~= "" then
        return
    end
    local text = event.chatMessage
    if type(text) ~= "string" or text == "" then
        return
    end
    if onText ~= nil then
        onText(parser.plainText(text))
    end
end

return chat
