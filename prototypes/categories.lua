-- NetHack Factoriopedia categories
-- Five top-level groups with subgroups matching NetHack's object classes.

local ICON_GRP = "__nethack-factorio__/graphics/icons/groups/"

data:extend{
  ---------------------------------------------------------------------------
  -- Top-level groups (64x64 composite icons with @ branding)
  ---------------------------------------------------------------------------
  {
    type = "item-group",
    name = "nh-monsters",
    localised_name = "Monsters",
    icon = ICON_GRP .. "nh-group-monsters.png",
    icon_size = 128,
    order = "z-a[nh-monsters]",
  },
  {
    type = "item-group",
    name = "nh-equipment",
    localised_name = "Equipment",
    icon = ICON_GRP .. "nh-group-equipment.png",
    icon_size = 128,
    order = "z-b[nh-equipment]",
  },
  {
    type = "item-group",
    name = "nh-magic",
    localised_name = "Magic",
    icon = ICON_GRP .. "nh-group-magic.png",
    icon_size = 128,
    order = "z-c[nh-magic]",
  },
  {
    type = "item-group",
    name = "nh-supplies",
    localised_name = "Supplies",
    icon = ICON_GRP .. "nh-group-supplies.png",
    icon_size = 128,
    order = "z-d[nh-supplies]",
  },
  {
    type = "item-group",
    name = "nh-dungeon",
    localised_name = "Dungeon",
    icon = ICON_GRP .. "nh-group-dungeon.png",
    icon_size = 128,
    order = "z-e[nh-dungeon]",
  },

  ---------------------------------------------------------------------------
  -- Subgroups: Monsters (one row)
  ---------------------------------------------------------------------------
  {
    type = "item-subgroup",
    name = "nh-monsters",
    group = "nh-monsters",
    order = "a",
  },

  ---------------------------------------------------------------------------
  -- Subgroups: Equipment (weapons, armor, rings, amulets)
  ---------------------------------------------------------------------------
  {
    type = "item-subgroup",
    name = "nh-weapons",
    group = "nh-equipment",
    order = "a",
  },
  {
    type = "item-subgroup",
    name = "nh-armor",
    group = "nh-equipment",
    order = "b",
  },
  {
    type = "item-subgroup",
    name = "nh-rings",
    group = "nh-equipment",
    order = "c",
  },
  {
    type = "item-subgroup",
    name = "nh-amulets",
    group = "nh-equipment",
    order = "d",
  },

  ---------------------------------------------------------------------------
  -- Subgroups: Magic (potions, scrolls, spellbooks, wands)
  ---------------------------------------------------------------------------
  {
    type = "item-subgroup",
    name = "nh-potions",
    group = "nh-magic",
    order = "a",
  },
  {
    type = "item-subgroup",
    name = "nh-scrolls",
    group = "nh-magic",
    order = "b",
  },
  {
    type = "item-subgroup",
    name = "nh-spellbooks",
    group = "nh-magic",
    order = "c",
  },
  {
    type = "item-subgroup",
    name = "nh-wands",
    group = "nh-magic",
    order = "d",
  },

  ---------------------------------------------------------------------------
  -- Subgroups: Supplies (tools, food, gems)
  ---------------------------------------------------------------------------
  {
    type = "item-subgroup",
    name = "nh-tools",
    group = "nh-supplies",
    order = "a",
  },
  {
    type = "item-subgroup",
    name = "nh-food",
    group = "nh-supplies",
    order = "b",
  },
  {
    type = "item-subgroup",
    name = "nh-gems",
    group = "nh-supplies",
    order = "c",
  },

  ---------------------------------------------------------------------------
  -- Subgroups: Dungeon (one row)
  ---------------------------------------------------------------------------
  {
    type = "item-subgroup",
    name = "nh-dungeon",
    group = "nh-dungeon",
    order = "a",
  },
}
