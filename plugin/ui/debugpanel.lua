--[[
    ui/debugpanel.lua
    -----------------
    A bare, temporary text panel showing what the plugin knows, so we can
    check the clock, world detection and saving in the beta. A real
    dashboard will replace it.

    It can live in one of two places (main.lua picks with USE_RIBBON):
      - Ribbon: inside the plugin's own page in the Plugins window. The client
        gives us an empty layer each time that page opens
        (Event.ContentLayerReady), so we create the text again every time.
      - Floating: a small box drawn over the game window, as in the official
        tutorial. A fallback in case the ribbon doesn't work as expected.

    UI note for React developers: there is no re-rendering. We create a Text
    component once and later just change its .content (like setting
    element.textContent in vanilla JS).
]]

local safe = require("core/safe")

local debugPanel = {}

local textComponent = nil   -- the ui.Text we write into, or nil if not shown
local floatingBox = nil     -- the floating box, if that mode is used
local lastLines = {}        -- most recent content, so a rebuilt panel isn't blank

-- Creates the Text component inside the given parent component.
local function createText(parent, x, y)
    local text = ui.Text.new(parent)
    text:SetPos(x, y)
    text:SetSize(0, 0, 1.0, 1.0)            -- fill the parent (relative size 100% x 100%)
    text.font = id.Font.MUSEO_SANS_15PT_REGULAR
    text:AlignTo(ui.AlignMode.TOPLEFT)
    return text
end

-- Shows the given lines. "<br>" is RuneScape's line break inside text.
local function render()
    if textComponent == nil then
        return
    end
    local content = table.concat(lastLines, "<br>")
    -- If the ribbon page was closed, the component may be gone; ignore that.
    safe.try(function() textComponent.content = content end)
end

-- Ribbon mode: call from the Event.ContentLayerReady handler.
function debugPanel.attachToRibbon(event)
    textComponent = createText(event.component, 8, 8)
    render()
end

-- Floating mode: call once at start-up. Returns false if the game UI isn't ready.
function debugPanel.attachFloating()
    local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if gameWindow == nil then
        return false
    end
    floatingBox = ui.GroupBox.new(gameWindow)
    floatingBox.stylesheetID = id.StyleSheet.DEFAULT
    floatingBox:SetHeaderLayout(0, 0, 0, 0, 0)  -- no title bar
    floatingBox:SetSize(260, 140)
    floatingBox:SetPos(0, 0, 0.7, 0.15)         -- 70% across, 15% down the game window
    textComponent = createText(floatingBox, 8, 8)
    render()
    return true
end

-- Replaces the panel's content with a list of lines.
function debugPanel.show(lines)
    lastLines = lines
    render()
end

-- Removes the floating box (called when the plugin shuts down).
function debugPanel.destroy()
    if floatingBox ~= nil then
        safe.try(function() floatingBox:Destroy() end)
        floatingBox = nil
    end
    textComponent = nil
end

return debugPanel
