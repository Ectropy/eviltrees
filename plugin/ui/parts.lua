--[[
    ui/parts.lua
    ------------
    Two small building blocks made of plain game components, used by the
    grid's cells (ui/grid.lua) and the world card (ui/worldcard.lua): a
    Rectangle that fills its parent, and a one-line Text.

    prettyui.NewComponent(type, parent) is ui.<Type>.new(parent) plus a free
    component ID (PrettyUI tracks IDs; see its "Component IDs" docs).
]]

local parts = {}

-- The small font. id.Font.<name> is for drawing; config.Font.<name> (the
-- same name) is for measuring text, see ui/grid.lua.
parts.FONT = "MUSEO_SANS_11PT_REGULAR"

-- A Rectangle the size of its parent. fill = true: a filled box;
-- false: just the outline.
function parts.rectangle(parent, fill, colour)
    local rectangle = prettyui.NewComponent(ui.Rectangle, parent)
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
    local text = prettyui.NewComponent(ui.Text, parent)
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
