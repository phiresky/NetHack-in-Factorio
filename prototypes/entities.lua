-- NetHack entity prototypes for Factorio 2.0
-- Generated programmatically from sprite sheet indices.
-- Each monster, object, and dungeon feature gets its own unique tile sprite.

local TC = require("scripts.tile_config")

local entities = {}

-- Shared icon for all script-placed entities (never shown in GUI)
local shared_icon = "__nethack-factorio__/graphics/entities/nh-player-marker.png"

-- Helper: common flags for NetHack entities placed by script
local nh_flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"}

-- No-collision mask: entity does not collide with anything
local no_collision = {layers = {}}

-- Wall collision: blocks player and objects
local wall_collision = {
  layers = {
    object = true,
    player = true,
    is_object = true,
  },
}

-- Sprite sheet paths
local SHEET_MONSTERS = "__nethack-factorio__/graphics/sheets/nh-monsters.png"
local SHEET_OBJECTS  = "__nethack-factorio__/graphics/sheets/nh-objects.png"
local SHEET_OTHER    = "__nethack-factorio__/graphics/sheets/nh-other.png"

-- Helper: create a sprite referencing a region of a sprite sheet
local function sheet_sprite(sheet_path, idx, cols)
  cols = cols or TC.sheet_cols
  return {
    filename = sheet_path,
    width = 32,
    height = 32,
    x = (idx % cols) * 32,
    y = math.floor(idx / cols) * 32,
    scale = 1.0,
  }
end

-- Build lookup sets for wall and door indices
local wall_set = {}
for _, idx in ipairs(TC.wall_indices) do wall_set[idx] = true end
local door_closed_set = {}
for _, idx in ipairs(TC.door_closed_indices) do door_closed_set[idx] = true end
local door_open_set = {}
for _, idx in ipairs(TC.door_open_indices) do door_open_set[idx] = true end

---------------------------------------------------------------------------
-- Monster entities (nh-mon-giant-ant, nh-mon-killer-bee, etc.)
---------------------------------------------------------------------------

for i = 0, TC.n_monsters - 1 do
  entities[#entities + 1] = {
    type = "simple-entity",
    name = "nh-mon-" .. TC.monster_names[i + 1],
    icon = shared_icon,
    icon_size = 32,
    flags = nh_flags,
    collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = no_collision,
    selection_box = {{-0.4, -0.4}, {0.4, 0.4}},
    pictures = { sheet_sprite(SHEET_MONSTERS, i) },
    render_layer = "object",
  }
end

---------------------------------------------------------------------------
-- Object entities (nh-obj-arrow, nh-obj-long-sword, etc.)
---------------------------------------------------------------------------

for i = 0, TC.n_objects - 1 do
  entities[#entities + 1] = {
    type = "simple-entity",
    name = "nh-obj-" .. TC.object_names[i + 1],
    icon = shared_icon,
    icon_size = 32,
    flags = nh_flags,
    collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = no_collision,
    selection_box = {{-0.3, -0.3}, {0.3, 0.3}},
    pictures = { sheet_sprite(SHEET_OBJECTS, i) },
    render_layer = "lower-object",
  }
end

---------------------------------------------------------------------------
-- Dungeon feature entities (nh-other-vertical-wall, nh-other-floor-of-a-room, etc.)
-- Walls get collision; closed doors get collision; everything else doesn't.
---------------------------------------------------------------------------

for i = 0, TC.n_other - 1 do
  local has_collision = wall_set[i] or door_closed_set[i]
  local layer = "object"
  if not has_collision and not door_open_set[i] then
    layer = "floor"
  end

  entities[#entities + 1] = {
    type = has_collision and "simple-entity-with-force" or "simple-entity",
    name = "nh-other-" .. TC.other_names[i + 1],
    icon = shared_icon,
    icon_size = 32,
    flags = nh_flags,
    collision_box = has_collision and {{-0.49, -0.49}, {0.49, 0.49}} or {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = has_collision and wall_collision or no_collision,
    selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
    picture = has_collision and sheet_sprite(SHEET_OTHER, i) or nil,
    pictures = (not has_collision) and { sheet_sprite(SHEET_OTHER, i) } or nil,
    render_layer = layer,
    is_military_target = has_collision and false or nil,
  }
end

---------------------------------------------------------------------------
-- Player marker (invisible tracker for where NH thinks @ is)
---------------------------------------------------------------------------

entities[#entities + 1] = {
  type = "simple-entity",
  name = "nh-player-marker",
  icon = "__nethack-factorio__/graphics/entities/nh-player-marker.png",
  icon_size = 32,
  flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable", "not-selectable-in-game"},
  collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
  collision_mask = no_collision,
  pictures = {
    {
      filename = "__nethack-factorio__/graphics/entities/nh-player-marker.png",
      width = 32,
      height = 32,
      scale = 0.5,
    },
  },
  render_layer = "higher-object-above",
}

data:extend(entities)
