-- NetHack dungeon tile prototypes for Factorio 2.0
-- Each tile uses the layers-based collision_mask format.
-- Walkable tiles only have "ground_tile" in their collision layers.
-- Blocking tiles (lava, water) additionally include "player".

local tile_defs = {
  {
    name = "nh-floor",
    color = {r = 0.65, g = 0.6, b = 0.5},
    layer = 40,
    layer_group = "ground-artificial",
    image = "__nethack-factorio__/graphics/tiles/nh-floor.png",
    walking_speed = 1.0,
    collision_layers = {ground_tile = true},
  },
  {
    name = "nh-corridor",
    color = {r = 0.45, g = 0.4, b = 0.35},
    layer = 39,
    layer_group = "ground-artificial",
    image = "__nethack-factorio__/graphics/tiles/nh-corridor.png",
    walking_speed = 1.0,
    collision_layers = {ground_tile = true},
  },
  {
    name = "nh-void",
    color = {r = 0.15, g = 0.15, b = 0.15},
    layer = 38,
    layer_group = "ground-natural",
    image = "__nethack-factorio__/graphics/tiles/nh-void.png",
    walking_speed = 1.0,
    collision_layers = {ground_tile = true},
  },
  {
    name = "nh-lava",
    color = {r = 0.9, g = 0.3, b = 0.1},
    layer = 36,
    layer_group = "water",
    image = "__nethack-factorio__/graphics/tiles/nh-lava.png",
    walking_speed = 0.5,
    -- Lava blocks walking by default; NetHack handles traversal logic
    collision_layers = {ground_tile = true, player = true, water_tile = true, item = true, resource = true, doodad = true},
  },
  {
    name = "nh-water",
    color = {r = 0.2, g = 0.3, b = 0.8},
    layer = 35,
    layer_group = "water",
    image = "__nethack-factorio__/graphics/tiles/nh-water.png",
    walking_speed = 0.5,
    collision_layers = {ground_tile = true, player = true, water_tile = true, item = true, resource = true, doodad = true},
  },
  {
    name = "nh-ice",
    color = {r = 0.6, g = 0.9, b = 0.95},
    layer = 37,
    layer_group = "ground-artificial",
    image = "__nethack-factorio__/graphics/tiles/nh-ice.png",
    walking_speed = 1.5,
    collision_layers = {ground_tile = true},
  },
  {
    name = "nh-grass",
    color = {r = 0.3, g = 0.6, b = 0.2},
    layer = 41,
    layer_group = "ground-natural",
    image = "__nethack-factorio__/graphics/tiles/nh-grass.png",
    walking_speed = 1.0,
    collision_layers = {ground_tile = true},
  },
}

local tiles = {}
for _, def in ipairs(tile_defs) do
  tiles[#tiles + 1] = {
    type = "tile",
    name = def.name,
    order = "z[nethack]-" .. def.name,
    collision_mask = {
      layers = def.collision_layers,
    },
    layer = def.layer,
    layer_group = def.layer_group,
    map_color = def.color,
    walking_speed_modifier = def.walking_speed,
    variants = {
      empty_transitions = true,
      material_background = {
        picture = def.image,
        count = 1,
        scale = 0.5,
      },
    },
    transition_merges_with_tile = "nh-void",
  }
end

data:extend(tiles)
