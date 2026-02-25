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

-- GUI icons (generated from NetHack Qt XPM data by build/generate_icons.py)
local ICON_DIR = "__nethack-factorio__/graphics/icons/"

-- Stat icons (40x40)
local stat_icons = {"str", "dex", "con", "int", "wis", "cha"}
for _, name in ipairs(stat_icons) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-icon-" .. name,
    filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
    width = 40, height = 40,
    scale = 0.5,
    flags = {"icon"},
  }
end

-- Alignment icons (40x40)
local align_icons = {"lawful", "neutral", "chaotic"}
for _, name in ipairs(align_icons) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-icon-" .. name,
    filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
    width = 40, height = 40,
    scale = 0.5,
    flags = {"icon"},
  }
end

-- Condition icons (40x40)
local cond_icons = {"hungry", "satiated", "confused", "blind", "stunned", "hallu",
                    "sick-fp", "sick-il"}
for _, name in ipairs(cond_icons) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-icon-" .. name,
    filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
    width = 40, height = 40,
    scale = 0.5,
    flags = {"icon"},
  }
end

-- Encumbrance icons (40x40)
local enc_icons = {"enc-slt", "enc-mod", "enc-hvy", "enc-ext", "enc-ovr"}
for _, name in ipairs(enc_icons) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-icon-" .. name,
    filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
    width = 40, height = 40,
    scale = 0.5,
    flags = {"icon"},
  }
end

-- Toolbar icons (12x13)
local tb_icons = {"tb-again", "tb-get", "tb-kick", "tb-throw",
                  "tb-fire", "tb-drop", "tb-eat", "tb-rest"}
for _, name in ipairs(tb_icons) do
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "nh-icon-" .. name,
    filename = ICON_DIR .. "nh-icon-" .. name .. ".png",
    width = 12, height = 13,
    flags = {"icon"},
  }
end

data:extend(sprites)
