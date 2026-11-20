--[[
    ui/icons.lua
    ------------
    The status icon, so a world's state can be told apart without relying
    on colour (colour-blind players):

        alive, type known    that type's logs        (item icon)
        alive, type unknown  SKILL_ICON_WOODCUTTING_32PX
        sapling              Oak sapling             (item icon, item 5370)
        dead                 RS3_ICON_SKULL
        spawn timer          RS3_ICON_TIMER_23PX
        nothing known        no icon

    Two kinds of picture: a game sprite (from the client's sprite list, the
    "pan Sprite" console command), or an item's inventory icon
    (SetAssociatedObject). An icon slot holds one of each in the same place
    and shows whichever is needed, so switching never has to undo an item.

    core/overview.lua decides the words (cell.icon, cell.logs); this file
    turns them into pictures.
]]

local icons = {}

-- Icon word -> { sprite name, sprite ID from the dump }. The name is
-- looked up in id.Sprite first (it survives the game renumbering its
-- sprites); the number is the fallback.
local SPRITES = {
    tree = { "SKILL_ICON_WOODCUTTING_32PX", 31215 },
    dead = { "RS3_ICON_SKULL", 33098 },
    timer = { "RS3_ICON_TIMER_23PX", 10432 },
}

-- Icon word -> item ID, for icons that are items.
local ITEMS = {
    sapling = 5370,     -- Oak sapling
}

-- Tree type (as in data/trees.lua) -> the item ID of its logs.
local LOG_ITEMS = {
    tree = 1511,        -- Logs
    oak = 1521,
    willow = 1519,
    maple = 1517,
    yew = 1515,
    magic = 1513,
    elder = 29556,
}

local resolved = {}         -- icon word -> sprite ID, worked out once

-- The sprite ID for an icon word, or nil (not a sprite icon).
function icons.spriteID(word)
    local entry = SPRITES[word]
    if entry == nil then
        return nil
    end
    if resolved[word] == nil then
        -- id.Sprite may be missing a name (or be a table that errors on
        -- unknown keys), so ask inside pcall, like try/catch.
        local ok, value = pcall(function() return id.Sprite[entry[1]] end)
        -- "ok and value or fallback": the looked-up value if that worked, else the number.
        resolved[word] = (ok and value) or entry[2]
    end
    return resolved[word]
end

-- What to draw for an icon word and tree type: ("item", itemID),
-- ("sprite", spriteID), or nil for no icon. An alive tree ("tree") of a
-- known type shows its logs instead of the woodcutting icon.
function icons.picture(word, treeType)
    if word == "tree" and LOG_ITEMS[treeType] ~= nil then
        return "item", LOG_ITEMS[treeType]
    end
    if ITEMS[word] ~= nil then
        return "item", ITEMS[word]
    end
    local spriteID = icons.spriteID(word)
    if spriteID ~= nil then
        return "sprite", spriteID
    end
    return nil
end

-- A size x size icon slot at (x, y) in parent, empty at first. Fill it
-- with icons.set.
function icons.new(parent, x, y, size)
    local slot = {}
    -- slot.sprite draws game sprites, slot.item draws item icons.
    for _, key in ipairs({ "sprite", "item" }) do
        local component = prettyui.NewComponent(ui.Sprite, parent)
        component:SetPos(x, y)
        component:SetSize(size, size)
        component.rgba = 0xFFFFFFFF         -- white: the image's own colours
        component.clickthrough = true
        component.hidden = true
        slot[key] = component
    end
    return slot
end

-- Shows the icon for word (and the tree type, for logs) in a slot, or
-- empties it. Returns true if an icon is shown. Only touches the game
-- components when the picture changes, so it's fine to call every second.
function icons.set(slot, word, treeType)
    local kind, value = icons.picture(word, treeType)
    local key = tostring(kind) .. ":" .. tostring(value)
    if key == slot.shownKey then
        return kind ~= nil
    end
    slot.shownKey = key

    if kind == "sprite" then
        slot.sprite.sprite = value
    elseif kind == "item" then
        slot.item:SetAssociatedObject(value)
        -- No "1" quantity label (pcall: not every client may have it).
        pcall(function() slot.item.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER end)
    end
    slot.sprite.hidden = (kind ~= "sprite")
    slot.item.hidden = (kind ~= "item")
    return kind ~= nil
end

return icons
