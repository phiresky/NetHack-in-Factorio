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

local function add_icon_batch(names, width, height, scale, flags)
  flags = flags or {"icon"}
  for _, name in ipairs(names) do
    local icon = {
      type = "sprite",
      name = "nh-icon-" .. name,
      filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
      width = width, height = height,
      flags = flags,
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
                "tb-fire", "tb-drop", "tb-eat", "tb-rest"}, 12, 13, nil,
                {"no-crop", "no-scale", "group=icon"})
add_icon_batch({"tb-search"}, 14, 15, nil,
                {"no-crop", "no-scale", "group=icon"})

-- Equipment paperdoll placeholder sprites (ghosted/faint)
local ICON_OBJ = "__nethack-factorio__/graphics/icons/objects/"
local ghost_tint = {r = 0.4, g = 0.4, b = 0.4, a = 0.8}
local ghost_items = {
  {"off-hand",  "nh-item-dagger"},
  {"helmet",    "nh-item-etched-helmet-helm-of-brilliance"},
  {"eyes",      "nh-item-blindfold"},
  {"shield",    "nh-item-small-shield"},
  {"amulet",    "nh-item-circular-amulet-of-esp"},
  {"weapon",    "nh-item-long-sword"},
  {"gloves",    "nh-item-old-gloves-leather-gloves"},
  {"cloak",     "nh-item-opera-cloak-cloak-of-invisibility"},
  {"ring",      "nh-item-wooden-adornment"},
  {"armor",     "nh-item-leather-armor"},
  {"boots",     "nh-item-jackboots-high-boots"},
  {"quiver",    "nh-item-arrow"},
}
for _, def in ipairs(ghost_items) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-equip-ghost-" .. def[1],
    filename = ICON_OBJ .. def[2] .. ".png",
    width = 32,
    height = 32,
    scale = 0.5,
    tint = ghost_tint,
    tint_as_overlay = true,
    blend_mode = "additive-soft",
    flags = {"icon"},
  }
end

data:extend(sprites)
