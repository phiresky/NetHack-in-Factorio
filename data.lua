require("prototypes.tiles")
require("prototypes.categories")
require("prototypes.entities")
require("prototypes.sprites")
require("prototypes.inputs")
require("prototypes.items")
require("prototypes.styles")

data:extend{{
  type = "font",
  name = "nh-mono",
  from = "default-mono",
  size = 14,
}}

-- Disable auto-healing so NetHack HP controls the health bar
data.raw["character"]["character"].healing_per_tick = 0
