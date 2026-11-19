--[[
    ui/parts.lua
    ------------
    Small building blocks made of plain game components, used by the
    grid's cells (ui/grid.lua), the world card (ui/worldcard.lua) and the
    grid's toolbar and settings: parts.new (any component), a Rectangle
    that fills its parent, and a one-line Text.
]]

local parts = {}

-- A new game component, e.g. parts.new(ui.Layer, parent). PrettyUI 1.3.0
-- and later have prettyui.NewComponent: ui.<Type>.new(parent) plus a free
-- component ID (PrettyUI tracks IDs; see its "Component IDs" docs). The
-- PrettyUI on the Plugin Hub (1.2.2) doesn't, so there we call
-- ui.<Type>.new(parent) ourselves, as PrettyUI 1.2.2 does for its own
-- widgets. options (optional) only matter to NewComponent.
function parts.new(componentType, parent, options)
    if prettyui.NewComponent ~= nil then
        return prettyui.NewComponent(componentType, parent, options)
    end
    return componentType.new(parent)
end

-- The small font. id.Font.<name> is for drawing; config.Font.<name> (the
-- same name) is for measuring text, see ui/grid.lua.
parts.FONT = "MUSEO_SANS_11PT_REGULAR"

-- A Rectangle the size of its parent. fill = true: a filled box;
-- false: just the outline.
function parts.rectangle(parent, fill, colour)
    local rectangle = parts.new(ui.Rectangle, parent)
    rectangle:SetSize(0, 0, 1.0, 1.0)       -- (width, height, widthAnchor, heightAnchor): fill the parent
    rectangle.fill = fill
    rectangle.rgba = colour
    rectangle.clickthrough = true           -- let the mouse reach what is underneath
    return rectangle
end

-- A one-line Text. alignHorizontal BOTTOMRIGHT puts the text on the right
-- (the game's align modes are shared by both directions). font is
-- optional: the small 11pt font if left out.
function parts.text(parent, x, y, width, height, alignHorizontal, font)
    local text = parts.new(ui.Text, parent)
    text:SetPos(x, y)
    text:SetSize(width, height)
    text.font = font or id.Font[parts.FONT] -- t[name] is t.name with the name in a variable, as in JS
    text.isShadowed = true
    text.alignHorizontal = alignHorizontal or ui.AlignMode.TOPLEFT
    text.alignVertical = ui.AlignMode.CENTRE
    text.maxLines = 1                       -- too long: cut off with "..."
    text.clickthrough = true
    text.content = ""
    return text
end

return parts
