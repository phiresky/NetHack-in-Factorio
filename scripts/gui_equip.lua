-- gui_equip.lua: Equipment paperdoll display in status pane
-- Fixed grid of sprite-buttons matching the Qt port's paperdoll layout.
-- Empty slots show a dim placeholder; equipped slots show the item sprite.
-- Clicking an equipped slot returns its inventory letter for item selection.

local bit32 = bit32

local Equip = {}

-- Masks from NetHack's worn.h owornmask values
local W_ARM   = 0x00000001  -- armor
local W_ARMC  = 0x00000002  -- cloak
local W_ARMH  = 0x00000004  -- helmet
local W_ARMS  = 0x00000008  -- shield
local W_ARMG  = 0x00000010  -- gloves
local W_ARMF  = 0x00000020  -- boots
local W_ARMU  = 0x00000040  -- shirt
local W_WEP   = 0x00000100  -- weapon
local W_QUIVER= 0x00000200  -- quiver
local W_SWAPWEP=0x00000400  -- secondary weapon
local W_AMUL  = 0x00010000  -- amulet
local W_RINGL = 0x00020000  -- left ring
local W_RINGR = 0x00040000  -- right ring
local W_BLINDF= 0x00080000  -- blindfold/lenses

-- 4 rows x 5 columns paperdoll layout:
--   01234
-- 0  BhQ        glasses, helmet, quiver
-- 1 SwCA        shield, weapon, cloak, amulet
-- 2 g=A=s       gloves, rings, armor, secondary
-- 3    F        boots
-- false = blank filler
local PAPERDOLL_GRID = {
  -- Row 0: head
  false,
  {mask = W_BLINDF,  label = "Eyes",      ghost = "nh-equip-ghost-eyes"},
  {mask = W_ARMH,    label = "Helmet",    ghost = "nh-equip-ghost-helmet"},
  {mask = W_QUIVER,  label = "Quiver",    ghost = "nh-equip-ghost-quiver"},
  false,
  -- Row 1: upper body
  {mask = W_ARMS,    label = "Shield",    ghost = "nh-equip-ghost-shield"},
  {mask = W_WEP,     label = "Weapon",    ghost = "nh-equip-ghost-weapon"},
  {mask = W_ARMC,    label = "Cloak",     ghost = "nh-equip-ghost-cloak"},
  {mask = W_AMUL,    label = "Amulet",    ghost = "nh-equip-ghost-amulet"},
  false,
  -- Row 2: hands + rings + armor
  {mask = W_ARMG,    label = "Gloves",    ghost = "nh-equip-ghost-gloves"},
  {mask = W_RINGL,   label = "Ring L",    ghost = "nh-equip-ghost-ring"},
  {mask = W_ARM,     label = "Armor",     ghost = "nh-equip-ghost-armor"},
  {mask = W_RINGR,   label = "Ring R",    ghost = "nh-equip-ghost-ring"},
  {mask = W_SWAPWEP, label = "Off-hand",  ghost = "nh-equip-ghost-off-hand"},
  -- Row 3: feet
  false,
  false,
  {mask = W_ARMF,    label = "Boots",     ghost = "nh-equip-ghost-boots"},
  false,
  false,
}

local COLUMNS = 5
local GRID_SIZE = 20  -- 4 rows x 5 columns

function Equip.render_equipment(player)
  local screen = player.gui.screen
  local top_panel = screen.nh_top_panel
  if not top_panel then return end
  local content = top_panel.nh_top_content
  if not content then return end
  local right_col = content.nh_st_right
  if not right_col then return end
  local equip_frame = right_col.nh_equip_frame
  if not equip_frame then return end
  local equip_table = equip_frame.nh_equip_table
  if not equip_table then return end

  equip_table.clear()

  -- Build lookup: mask -> item from inventory
  local equipped = {}
  local inv_state = storage.nh_inventory
  if inv_state and inv_state.slot_map then
    for _, item in ipairs(inv_state.slot_map) do
      if item.owornmask and item.owornmask ~= 0 then
        for i = 1, GRID_SIZE do
          local slot = PAPERDOLL_GRID[i]
          if slot and bit32.band(item.owornmask, slot.mask) ~= 0 then
            equipped[slot.mask] = item
          end
        end
      end
    end
  end

  -- Build grid cells
  for i = 1, GRID_SIZE do
    local slot = PAPERDOLL_GRID[i]
    if slot then
      local item = equipped[slot.mask]
      if item and item.item_name then
        equip_table.add{
          type = "sprite-button",
          name = "nh_equip_" .. i,
          sprite = "item/" .. item.item_name,
          tooltip = slot.label .. ": " .. (item.name or "?"),
          style = "nh_equip_slot_button",
        }
      else
        equip_table.add{
          type = "sprite-button",
          name = "nh_equip_" .. i,
          sprite = slot.ghost,
          tooltip = slot.label .. " (empty)",
          style = "nh_equip_slot_empty",
        }
      end
    else
      equip_table.add{
        type = "empty-widget",
        style = "nh_equip_filler",
      }
    end
  end
end

-- Handle click on a paperdoll slot.
-- Returns the inventory letter (key code) of the equipped item, or nil.
function Equip.handle_click(element_name)
  local idx = element_name:match("^nh_equip_(%d+)$")
  if not idx then return nil end
  idx = tonumber(idx)

  local slot = PAPERDOLL_GRID[idx]
  if not slot then return nil end

  -- Find equipped item matching this slot's mask
  local inv_state = storage.nh_inventory
  if not inv_state or not inv_state.slot_map then return nil end

  for _, item in ipairs(inv_state.slot_map) do
    if item.owornmask and bit32.band(item.owornmask, slot.mask) ~= 0 then
      return item.invlet
    end
  end

  return nil
end

return Equip
