-- Sprite prototypes for inline rich text rendering [img=nh-sprite-N]
-- Each tile gets a SpritePrototype so glyph references in status/messages
-- can be rendered as inline icons via Factorio's rich text system.

local TC = require("scripts.tile_config")

local SHEET_MONSTERS = "__nethack-factorio__/graphics/sheets/nh-monsters.png"
local SHEET_OBJECTS  = "__nethack-factorio__/graphics/sheets/nh-objects.png"
local SHEET_OTHER    = "__nethack-factorio__/graphics/sheets/nh-other.png"

local sprites = {}

-- Helper: create a sprite from a sheet region
-- sheet_idx is relative to the sheet (0-based), tile_idx is global
local function tile_sprite(name, sheet, sheet_idx, cols)
  cols = cols or TC.sheet_cols
  return {
    type = "sprite",
    name = name,
    filename = sheet,
    width = 32,
    height = 32,
    x = (sheet_idx % cols) * 32,
    y = math.floor(sheet_idx / cols) * 32,
    scale = 0.5,
    flags = {"icon"},
  }
end

-- Monsters: global tile_idx 0..n_monsters-1, sheet index = tile_idx
for i = 0, TC.n_monsters - 1 do
  sprites[#sprites + 1] = tile_sprite("nh-sprite-" .. i, SHEET_MONSTERS, i)
end

-- Objects: global tile_idx n_monsters..n_monsters+n_objects-1, sheet index 0-based
for i = 0, TC.n_objects - 1 do
  local tile_idx = TC.n_monsters + i
  sprites[#sprites + 1] = tile_sprite("nh-sprite-" .. tile_idx, SHEET_OBJECTS, i)
end

-- Other: global tile_idx n_monsters+n_objects..total-1, sheet index 0-based
for i = 0, TC.n_other - 1 do
  local tile_idx = TC.n_monsters + TC.n_objects + i
  sprites[#sprites + 1] = tile_sprite("nh-sprite-" .. tile_idx, SHEET_OTHER, i)
end

data:extend(sprites)
