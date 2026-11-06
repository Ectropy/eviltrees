--[[
    data/trees.lua
    --------------
    Which game objects ("locs") are evil trees, and what each one means.
    IDs come from the beta client's `pan Loc` console command.
    Pure data: no game API calls.

    trees.byId[locId] gives a small table describing that object, e.g.
        trees.byId[11438] = { treeType = "oak", stage = "alive", healthCap = 50 }

    Stages:
        "sapling" - growing; saplingLevel is 1..5, the type isn't in the ID
        "alive"   - mature tree; healthCap is 100, 50 or 25 (it can't be above that)
        "dying"   - just felled
        "dead"    - the dead trunk with rewards (removed ~10 minutes later)

    We match by exact ID on purpose: other content (the Wilderness flash event,
    Treasure Hunter items) also has "EVILTREE" in its names.
]]

local trees = {}

-- One row per tree type. The type names match EctoTrees ("tree" = normal tree).
-- The IDs are not in a neat sequence (e.g. maple's lvl3 is 11915), so they are
-- listed one by one rather than calculated.
local IDS_BY_TYPE = {
    tree   = { full = 11434, lvl2 = 11435, lvl3 = 11436, dying = 11925, dead = 14846, deadEmpty = 12713, deadFull = 14839 },
    oak    = { full = 11437, lvl2 = 11438, lvl3 = 11439, dying = 11926, dead = 14847, deadEmpty = 12714, deadFull = 14840 },
    willow = { full = 11440, lvl2 = 11441, lvl3 = 11442, dying = 11927, dead = 14848, deadEmpty = 12715, deadFull = 14841 },
    maple  = { full = 11443, lvl2 = 11444, lvl3 = 11915, dying = 11928, dead = 14849, deadEmpty = 14835, deadFull = 14842 },
    yew    = { full = 11916, lvl2 = 11917, lvl3 = 11918, dying = 11929, dead = 14883, deadEmpty = 14836, deadFull = 14843 },
    magic  = { full = 11919, lvl2 = 11920, lvl3 = 11921, dying = 12711, dead = 14884, deadEmpty = 14837, deadFull = 14844 },
    elder  = { full = 11922, lvl2 = 11923, lvl3 = 11924, dying = 12712, dead = 14885, deadEmpty = 14838, deadFull = 14845 },
}

-- The five sapling stages. Their IDs don't say what the tree will become.
local SAPLING_IDS = { 11391, 11392, 11393, 11394, 11395 }

trees.byId = {}

for treeType, ids in pairs(IDS_BY_TYPE) do
    trees.byId[ids.full]      = { treeType = treeType, stage = "alive", healthCap = 100 }
    trees.byId[ids.lvl2]      = { treeType = treeType, stage = "alive", healthCap = 50 }
    trees.byId[ids.lvl3]      = { treeType = treeType, stage = "alive", healthCap = 25 }
    trees.byId[ids.dying]     = { treeType = treeType, stage = "dying" }
    trees.byId[ids.dead]      = { treeType = treeType, stage = "dead" }
    trees.byId[ids.deadEmpty] = { treeType = treeType, stage = "dead" }
    trees.byId[ids.deadFull]  = { treeType = treeType, stage = "dead" }
end

-- ipairs gives (index, value) pairs: here (1, 11391), (2, 11392), ...
for level, locId in ipairs(SAPLING_IDS) do
    trees.byId[locId] = { stage = "sapling", saplingLevel = level }
end

return trees
