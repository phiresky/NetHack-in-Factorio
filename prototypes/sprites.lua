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

-- Generate tile sprites for all sheets, tracking cumulative global offset
local tile_offset = 0
for _, batch in ipairs({
  {SHEET_MONSTERS, TC.n_monsters},
  {SHEET_OBJECTS,  TC.n_objects},
  {SHEET_OTHER,    TC.n_other},
}) do
  local sheet, count = batch[1], batch[2]
  for i = 0, count - 1 do
    sprites[#sprites + 1] = tile_sprite("nh-sprite-" .. (tile_offset + i), sheet, i)
  end
  tile_offset = tile_offset + count
end

-- GUI icons (generated from NetHack Qt XPM data by build/generate_icons.py)
local ICON_DIR = "__nethack-factorio__/graphics/icons/"

local function add_icon_batch(names, width, height, scale)
  for _, name in ipairs(names) do
    local icon = {
      type = "sprite",
      name = "nh-icon-" .. name,
      filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
      width = width, height = height,
      flags = {"icon"},
    }
    if scale then icon.scale = scale end
    sprites[#sprites + 1] = icon
  end
end

add_icon_batch({"str", "dex", "con", "int", "wis", "cha"}, 40, 40, 0.5)
add_icon_batch({"lawful", "neutral", "chaotic"}, 40, 40, 0.5)
add_icon_batch({"hungry", "satiated", "confused", "blind", "stunned", "hallu",
                "sick-fp", "sick-il"}, 40, 40, 0.5)
add_icon_batch({"enc-slt", "enc-mod", "enc-hvy", "enc-ext", "enc-ovr"}, 40, 40, 0.5)
add_icon_batch({"tb-again", "tb-get", "tb-kick", "tb-throw",
                "tb-fire", "tb-drop", "tb-eat", "tb-rest"}, 12, 13)

data:extend(sprites)
