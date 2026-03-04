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

-- Invisible character for nethack sprite mode (no engineer visible)
-- Invisible character: keep base animations but replace all sprite sheets
-- with the transparent dummy PNG. Must preserve direction_count (18).
local base = data.raw["character"]["character"]
local invis = table.deepcopy(base)
invis.name = "nh-invisible-character"
invis.healing_per_tick = 0
invis.light = nil
invis.footprint_particles = nil
local transparent = "__nethack-factorio__/graphics/icons/nh-invisible.png"
local function blank_anim(anim)
  if not anim then return end
  if anim.layers then
    for _, layer in ipairs(anim.layers) do blank_anim(layer) end
  end
  if anim.stripes then
    for _, stripe in ipairs(anim.stripes) do blank_anim(stripe) end
  end
  if anim.filenames then
    for i = 1, #anim.filenames do anim.filenames[i] = transparent end
  end
  if anim.filename then
    anim.filename = transparent
  end
  if anim.width then anim.width = 32 end
  if anim.height then anim.height = 32 end
  anim.line_length = 1
  anim.lines_per_file = nil
  anim.frame_count = 1
  anim.shift = nil
  anim.scale = nil
  anim.hr_version = nil
  anim.draw_as_shadow = nil
end
for _, armor_anim in ipairs(invis.animations) do
  for _, key in ipairs({"idle", "idle_with_gun", "running", "running_with_gun",
      "mining_with_tool", "flipped_shadow_running_with_gun"}) do
    blank_anim(armor_anim[key])
  end
end
data:extend{invis}
