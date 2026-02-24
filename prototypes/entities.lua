-- NetHack entity prototypes for Factorio 2.0
-- Walls, doors, monsters, items, stairs, and player marker.

local entities = {}

-- Helper: create a simple 1x1 sprite definition
local function sprite(filename)
  return {
    filename = filename,
    width = 32,
    height = 32,
    scale = 0.5,
  }
end

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

---------------------------------------------------------------------------
-- Walls
---------------------------------------------------------------------------

entities[#entities + 1] = {
  type = "simple-entity-with-force",
  name = "nh-wall-h",
  icon = "__nethack-factorio__/graphics/entities/nh-wall-h.png",
  icon_size = 32,
  flags = nh_flags,
  collision_box = {{-0.49, -0.49}, {0.49, 0.49}},
  collision_mask = wall_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = sprite("__nethack-factorio__/graphics/entities/nh-wall-h.png"),
  render_layer = "object",
  is_military_target = false,
}

entities[#entities + 1] = {
  type = "simple-entity-with-force",
  name = "nh-wall-v",
  icon = "__nethack-factorio__/graphics/entities/nh-wall-v.png",
  icon_size = 32,
  flags = nh_flags,
  collision_box = {{-0.49, -0.49}, {0.49, 0.49}},
  collision_mask = wall_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = sprite("__nethack-factorio__/graphics/entities/nh-wall-v.png"),
  render_layer = "object",
  is_military_target = false,
}

---------------------------------------------------------------------------
-- Doors
---------------------------------------------------------------------------

entities[#entities + 1] = {
  type = "simple-entity-with-force",
  name = "nh-door-closed",
  icon = "__nethack-factorio__/graphics/entities/nh-door-closed.png",
  icon_size = 32,
  flags = nh_flags,
  collision_box = {{-0.49, -0.49}, {0.49, 0.49}},
  collision_mask = wall_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = sprite("__nethack-factorio__/graphics/entities/nh-door-closed.png"),
  render_layer = "object",
  is_military_target = false,
}

entities[#entities + 1] = {
  type = "simple-entity-with-force",
  name = "nh-door-open",
  icon = "__nethack-factorio__/graphics/entities/nh-door-open.png",
  icon_size = 32,
  flags = nh_flags,
  collision_box = {{-0.01, -0.01}, {0.01, 0.01}},  -- effectively no collision
  collision_mask = no_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  picture = sprite("__nethack-factorio__/graphics/entities/nh-door-open.png"),
  render_layer = "floor",
  is_military_target = false,
}

---------------------------------------------------------------------------
-- Monsters: per-letter entities (a-z, A-Z)
-- White letter on transparent background, tinted at runtime
---------------------------------------------------------------------------

for i = 0, 25 do
  local lower = string.char(string.byte("a") + i)
  local upper = string.char(string.byte("A") + i)

  -- Lowercase monster (e.g. nh-mon-a)
  entities[#entities + 1] = {
    type = "simple-entity",
    name = "nh-mon-" .. lower,
    icon = "__nethack-factorio__/graphics/entities/nh-mon-" .. lower .. ".png",
    icon_size = 32,
    flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
    collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = no_collision,
    selection_box = {{-0.4, -0.4}, {0.4, 0.4}},
    pictures = {
      {
        filename = "__nethack-factorio__/graphics/entities/nh-mon-" .. lower .. ".png",
        width = 32,
        height = 32,
        scale = 0.5,
      },
    },
    render_layer = "object",
  }

  -- Uppercase monster (e.g. nh-mon-upper-A)
  entities[#entities + 1] = {
    type = "simple-entity",
    name = "nh-mon-upper-" .. upper,
    icon = "__nethack-factorio__/graphics/entities/nh-mon-upper-" .. upper .. ".png",
    icon_size = 32,
    flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
    collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = no_collision,
    selection_box = {{-0.4, -0.4}, {0.4, 0.4}},
    pictures = {
      {
        filename = "__nethack-factorio__/graphics/entities/nh-mon-upper-" .. upper .. ".png",
        width = 32,
        height = 32,
        scale = 0.5,
      },
    },
    render_layer = "object",
  }
end

---------------------------------------------------------------------------
-- Special monster characters (@, &, ;, :, ', ~, ], generic)
---------------------------------------------------------------------------

local special_monsters = {
  {name = "nh-mon-at",      char = "@"},
  {name = "nh-mon-amp",     char = "&"},
  {name = "nh-mon-semi",    char = ";"},
  {name = "nh-mon-colon",   char = ":"},
  {name = "nh-mon-apos",    char = "'"},
  {name = "nh-mon-tilde",   char = "~"},
  {name = "nh-mon-bracket", char = "]"},
  {name = "nh-mon-generic", char = "?"},
}

for _, mon in ipairs(special_monsters) do
  entities[#entities + 1] = {
    type = "simple-entity",
    name = mon.name,
    icon = "__nethack-factorio__/graphics/entities/nh-mon-generic.png",
    icon_size = 32,
    flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
    collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
    collision_mask = no_collision,
    selection_box = {{-0.4, -0.4}, {0.4, 0.4}},
    pictures = {
      {
        filename = "__nethack-factorio__/graphics/entities/nh-mon-generic.png",
        width = 32,
        height = 32,
        scale = 0.5,
      },
    },
    render_layer = "object",
  }
end

---------------------------------------------------------------------------
-- Generic item entity
---------------------------------------------------------------------------

entities[#entities + 1] = {
  type = "simple-entity",
  name = "nh-item",
  icon = "__nethack-factorio__/graphics/entities/nh-item.png",
  icon_size = 32,
  flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
  collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
  collision_mask = no_collision,
  selection_box = {{-0.3, -0.3}, {0.3, 0.3}},
  pictures = {
    {
      filename = "__nethack-factorio__/graphics/entities/nh-item.png",
      width = 32,
      height = 32,
      scale = 0.5,
    },
  },
  render_layer = "lower-object",
}

---------------------------------------------------------------------------
-- Stair markers
---------------------------------------------------------------------------

entities[#entities + 1] = {
  type = "simple-entity",
  name = "nh-stairs-up",
  icon = "__nethack-factorio__/graphics/entities/nh-stairs-up.png",
  icon_size = 32,
  flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
  collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
  collision_mask = no_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  pictures = {
    {
      filename = "__nethack-factorio__/graphics/entities/nh-stairs-up.png",
      width = 32,
      height = 32,
      scale = 0.5,
    },
  },
  render_layer = "floor",
}

entities[#entities + 1] = {
  type = "simple-entity",
  name = "nh-stairs-down",
  icon = "__nethack-factorio__/graphics/entities/nh-stairs-down.png",
  icon_size = 32,
  flags = {"placeable-neutral", "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-flammable"},
  collision_box = {{-0.01, -0.01}, {0.01, 0.01}},
  collision_mask = no_collision,
  selection_box = {{-0.5, -0.5}, {0.5, 0.5}},
  pictures = {
    {
      filename = "__nethack-factorio__/graphics/entities/nh-stairs-down.png",
      width = 32,
      height = 32,
      scale = 0.5,
    },
  },
  render_layer = "floor",
}

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
