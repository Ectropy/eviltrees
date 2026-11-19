--[[
    ui/colours.lua
    --------------
    The colours the grid, its card and the ribbon page share, so a status
    looks the same everywhere. All are 0xRRGGBBAA (red, green, blue, alpha;
    FF = solid). Only data and one small function: no game API calls.

    Where a colour is "PrettyUI's", it is copied from PrettyUI v1.3.0's own
    widgets (it has no public palette), so we match its look: warm browns
    and golds rather than cool greys.
]]

local colours = {}

colours.MUTED = 0x8B8882FF          -- PrettyUI's disabled text: nothing to say
colours.PLACE = 0xAFA27FFF          -- secondary text: places, hints
colours.COUNTDOWN = 0xF0A050FF      -- the card's countdown: warm orange
colours.FRAME = 0x716B61FF          -- PrettyUI's frame: a plain outline
colours.SELECTED = 0xF2C66DFF       -- PrettyUI's title gold: the world you clicked

-- The world you're on. NOT white or gold: those are the world list's F2P
-- and P2P colours (below). A bright sky blue is used by nothing else here.
colours.CURRENT = 0x4FC3F7FF

-- Text colour by overview's cell.kind. Softer than pure hues so they sit
-- well on the brown cells. (An icon always says the same thing: see
-- ui/icons.lua.)
colours.KIND = {
    unknown = colours.MUTED,    -- no intel
    none = colours.MUTED,       -- intel (a hint) but nothing due
    spawn = 0x8FB8DEFF,         -- soft blue: spawn timer
    sapling = 0xF0DC5AFF,       -- yellow
    alive = 0x7CC04AFF,         -- green (PrettyUI's buff green, brightened for text)
    dead = 0xD9786FFF,          -- red: rewards left (PrettyUI's chart red, brightened)
}

-- World numbers, coloured like the game's own world list (the lobby's
-- "Select a world"): members worlds in gold, free worlds in white. The gold
-- is matched by eye from a screenshot, so tune it here if it looks off.
-- Each has a dim version for worlds we know nothing about, so the worlds
-- with intel stand out.
local WORLD_P2P, WORLD_P2P_DIM = 0xE2BD68FF, 0x8A7645FF
local WORLD_F2P, WORLD_F2P_DIM = 0xFFFFFFFF, 0x8F8F8FFF
local WORLD_OTHER, WORLD_OTHER_DIM = 0xE7D7B0FF, colours.MUTED  -- not in our list (a new world): PrettyUI's body text

-- The colour for a world number. members is true (P2P), false (F2P) or nil
-- (a world that isn't in data/worlds.lua). dim is true for a world with no
-- intel.
function colours.world(members, dim)
    if members == true then
        return dim and WORLD_P2P_DIM or WORLD_P2P       -- "x and a or b" is x ? a : b
    elseif members == false then
        return dim and WORLD_F2P_DIM or WORLD_F2P
    end
    return dim and WORLD_OTHER_DIM or WORLD_OTHER
end

return colours
