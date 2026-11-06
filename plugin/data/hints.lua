--[[
    data/hints.lua
    --------------
    Where evil trees can grow, and what the game says about each place.
    Re-typed from EctoTrees' shared/hints.ts (coordinates from the RuneScape
    Wiki's Evil Tree page). Pure data: no game API calls. The lookups that
    use it (hint -> places, clue -> place, tile -> place) are in
    core/location.lua.

    hints.locations: every spawn location.
        name   our name for the place (shown in the dashboard)
        x, z   its map tile. EctoTrees calls the second number "y"; the
               plugin API calls the same number "z" (coordGrid.z).
        clue   part of the spirit tree's sentence once the tree has spawned:
               "It is an abomination of nature, which has appeared <clue>."
               Matched ignoring upper/lower case.

    hints.list: the hint the spirit tree / Sunbeam crown gives before you
    know the exact place ("It can be found <hint>."), and every location it
    can mean. Several hints share locations, and most hints mean more than
    one location.

    To add a location: add it to hints.locations, then add its name to the
    locations of every hint that can mean it. tests/test_location.lua checks
    that every name in hints.list exists in hints.locations, and the other way
    round, so a typo shows up there.
]]

local hints = {}

hints.locations = {
    { name = "South of Seers' Village flax field by the yew trees", x = 2757, z = 3429,
      clue = "to the south of Seers' Village, beside the flax field" },
    { name = "Ape Atoll, near the entrance to Ape Atoll Dungeon", x = 2756, z = 2699,
      clue = "in southern Ape Atoll" },
    { name = "Near the entrance of the Brimhaven Dungeon", x = 2737, z = 3159,
      clue = "adjacent to the Brimhaven Dungeon entrance" },
    { name = "Northwest of Seers' Village bank", x = 2708, z = 3509,
      clue = "in the north of Seers' Village" },
    { name = "South of Draynor Village, near the willow trees", x = 3092, z = 3232,
      clue = "just south of Draynor Village" },
    { name = "South of Legends' Guild", x = 2724, z = 3333,
      clue = "just to the south of the Legends' Guild" },
    { name = "Southwest part of Tree Gnome Stronghold, north of Brimstail's cave and east of the bridge", x = 2398, z = 3431,
      clue = "within the walls of the Tree Gnome Stronghold, south of the Gnome Ball field" },
    { name = "West of Falador", x = 2925, z = 3375,
      clue = "to the west of Falador, beside the mine" },
    { name = "Near the body altar, south of the Edgeville Monastery", x = 3053, z = 3459,
      clue = "to the south of the Monastery" },
    { name = "Southwest of mining spot near the nature altar, northwest of Shilo Village", x = 2833, z = 3020,
      clue = "just north of Shilo Village" },
    { name = "North of Legends' Guild", x = 2720, z = 3413,
      clue = "to the east of the Sorcerer's Tower" },
    { name = "Northeast of Yanille", x = 2606, z = 3121,
      clue = "just north of Yanille" },
    { name = "South of Tree Gnome Village and northwest of Yanille", x = 2523, z = 3107,
      clue = "beside the west gates of Yanille" },
    { name = "Inside McGrubor's Wood", x = 2668, z = 3490,
      clue = "inside McGrubor's Wood" },
    { name = "North of Draynor Village, near Draynor Manor", x = 3093, z = 3304,
      clue = "just south of Draynor Manor" },
    { name = "South of Castle Wars, north of the fairy ring BKP", x = 2371, z = 3055,
      clue = "to the south of the Castle Wars arena" },
    { name = "West of Oo'glog", x = 2460, z = 2850,
      clue = "to the south of the Feldip Hills, west of Oo'glog" },
    { name = "Northeast of Tyras Camp", x = 2207, z = 3172,
      clue = "in the centre of the forest of Isafdar" },
    { name = "Lletya, south of the magic trees", x = 2295, z = 3129,
      clue = "to the south-west of Lletya, beside the Poison Waste" },
    { name = "King's Road, Southeast of Fort Forinthry and above digsite", x = 3335, z = 3475,
      clue = "to the east of Varrock, past the rift" },
    { name = "North of Varrock Palace, near the Wilderness wall", x = 3221, z = 3514,
      clue = "just north of the Varrock Palace walls" },
    { name = "East of the house portal in Rellekka", x = 2695, z = 3635,
      clue = "in the Fremennik Province, to the south-east of Rellekka" },
    { name = "Southwest of the Ranging Guild", x = 2653, z = 3412,
      clue = "next to the Ranging Guild" },
    { name = "Kharazi Jungle, east of the teak trees", x = 2909, z = 2895,
      clue = "in the south-east Kharazi jungle" },
    { name = "South of Tree Gnome Stronghold and east of the Outpost", x = 2450, z = 3348,
      clue = "beside the road south of the Tree Gnome Stronghold" },
    { name = "East of the Marigold Farm on Havenhythe", x = 4308, z = 3265,
      clue = "to the south-east of Wendlewick, by the farm" },
    { name = "North of Amberfell", x = 4439, z = 3409,
      clue = "north of Amberfell" },
}

hints.list = {
    { hint = "Close to a collection of yew trees",
      locations = { "South of Seers' Village flax field by the yew trees" } },
    { hint = "Close to a dungeon entrance, and within a tropical jungle",
      locations = { "Ape Atoll, near the entrance to Ape Atoll Dungeon",
                    "Near the entrance of the Brimhaven Dungeon" } },
    { hint = "Close to a large collection of willow trees",
      locations = { "Northwest of Seers' Village bank",
                    "South of Draynor Village, near the willow trees",
                    "South of Legends' Guild",
                    "Southwest part of Tree Gnome Stronghold, north of Brimstail's cave and east of the bridge" } },
    { hint = "Close to a mine on the outskirts of a city",
      locations = { "South of Legends' Guild",
                    "West of Falador" } },
    { hint = "Close to a Runecrafting altar",
      locations = { "Near the body altar, south of the Edgeville Monastery",
                    "Southwest of mining spot near the nature altar, northwest of Shilo Village" } },
    { hint = "Close to the home of 'Legends'",
      locations = { "North of Legends' Guild",
                    "South of Legends' Guild" } },
    { hint = "Close to the town you call Yanille",
      locations = { "Northeast of Yanille",
                    "South of Tree Gnome Village and northwest of Yanille" } },
    { hint = "Close to the village you call 'Seers'",
      locations = { "Inside McGrubor's Wood",
                    "Northwest of Seers' Village bank",
                    "South of Seers' Village flax field by the yew trees" } },
    { hint = "Close to the village you humans call 'Draynor'",
      locations = { "North of Draynor Village, near Draynor Manor",
                    "South of Draynor Village, near the willow trees" } },
    { hint = "Due west of the town you call Lumbridge",
      locations = { "South of Draynor Village, near the willow trees" } },
    { hint = "In a location with rare trees and ogres nearby",
      locations = { "South of Castle Wars, north of the fairy ring BKP",
                    "West of Oo'glog" } },
    { hint = "In the lands inhabited by elves",
      locations = { "Northeast of Tyras Camp",
                    "Lletya, south of the magic trees" } },
    { hint = "Just outside of the city you call Varrock",
      locations = { "King's Road, Southeast of Fort Forinthry and above digsite",
                    "North of Varrock Palace, near the Wilderness wall" } },
    { hint = "North as the crow flies from Seers' Village",
      locations = { "East of the house portal in Rellekka",
                    "Northwest of Seers' Village bank" } },
    { hint = "North as the crow flies from the market of Ardougne",
      locations = { "Inside McGrubor's Wood",
                    "Southwest of the Ranging Guild" } },
    { hint = "On the island known as Karamja",
      locations = { "Kharazi Jungle, east of the teak trees",
                    "Southwest of mining spot near the nature altar, northwest of Shilo Village" } },
    { hint = "On the southern coast of a tropical island",
      locations = { "Ape Atoll, near the entrance to Ape Atoll Dungeon",
                    "Kharazi Jungle, east of the teak trees" } },
    { hint = "To the south of a tree gnome settlement",
      locations = { "South of Tree Gnome Stronghold and east of the Outpost",
                    "South of Tree Gnome Village and northwest of Yanille" } },
    { hint = "Close to the village you humans call 'Wendlewick'",
      locations = { "East of the Marigold Farm on Havenhythe" } },
    { hint = "Close to the village you humans call 'Amberfell'",
      locations = { "North of Amberfell" } },
}

return hints
