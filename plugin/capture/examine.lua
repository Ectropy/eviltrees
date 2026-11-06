--[[
    capture/examine.lua
    -------------------
    Reports examine text, e.g. "The tree currently has approximately 25% of
    its health remaining."

    When you examine something, the game puts the text in the client variable
    INFO_BOX_TEXT (VarClient id 2251, found by testing in the beta) and shows it in
    a small info box. Reading this variable needs no permissions, unlike
    reading the chatbox.

    Note: this fires for examining anything, not just evil trees. The parser
    decides whether the text is relevant.
]]

local parser = require("core/parser")

local examine = {}

local INFO_BOX_TEXT_VAR_ID = 2251

local onText = nil      -- function(text), set by main.lua

-- Registers the function to call with each new examine text.
function examine.setOnText(callback)
    onText = callback
end

-- Event.VarTransmit handler.
function examine.onVarTransmit(event)
    if event.var.id ~= INFO_BOX_TEXT_VAR_ID or event.var.typeName ~= "VarClient" then
        return
    end
    local text = event.newValue
    if type(text) ~= "string" or text == "" then
        return
    end
    if onText ~= nil then
        onText(parser.plainText(text))
    end
end

return examine
