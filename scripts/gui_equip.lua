-- gui_equip.lua: Equipment (paperdoll) display in status pane
-- Shows equipped items as a vertical list below the conditions row.

local bit32 = bit32

local Equip = {}

-- Ordered equipment slots: {mask, label}
-- Masks from NetHack's objclass.h / worn.h owornmask values
local EQUIP_SLOTS = {
  {mask = 0x00000100, label = "Weapon"},
  {mask = 0x00000400, label = "Off-hand"},
  {mask = 0x00000200, label = "Quiver"},
  {mask = 0x00010000, label = "Amulet"},
  {mask = 0x00000004, label = "Helmet"},
  {mask = 0x00000002, label = "Cloak"},
  {mask = 0x00000001, label = "Armor"},
  {mask = 0x00000040, label = "Shirt"},
  {mask = 0x00000008, label = "Shield"},
  {mask = 0x00000010, label = "Gloves"},
  {mask = 0x00000020, label = "Boots"},
  {mask = 0x00020000, label = "Ring L"},
  {mask = 0x00040000, label = "Ring R"},
  {mask = 0x00080000, label = "Eyes"},
}

function Equip.render_equipment(player)
  local screen = player.gui.screen
  local top_panel = screen.nh_top_panel
  if not top_panel then return end
  local content = top_panel.nh_top_content
  if not content then return end
  local sf = content.nh_status_flow
  if not sf then return end
  local right_col = sf.nh_st_right
  if not right_col then return end

  local equip_header = right_col.nh_equip_header
  local equip_flow = right_col.nh_equip_flow
  if not equip_flow then return end

  equip_flow.clear()

  -- Gather equipped items from inventory slot_map
  local inv_state = storage.nh_inventory
  if not inv_state or not inv_state.slot_map then
    if equip_header then equip_header.visible = false end
    return
  end

  local count = 0
  for _, slot_def in ipairs(EQUIP_SLOTS) do
    -- Find item with matching owornmask bit
    for _, item in ipairs(inv_state.slot_map) do
      if item.owornmask and bit32.band(item.owornmask, slot_def.mask) ~= 0 then
        local sprite = ""
        if item.item_name then
          sprite = "[img=item/" .. item.item_name .. "] "
        end
        equip_flow.add{
          type = "label",
          caption = sprite .. slot_def.label .. ": " .. (item.name or "?"),
          style = "nh_equip_slot_label",
        }
        count = count + 1
        break
      end
    end
  end

  -- Hide separator + header when nothing equipped
  local visible = count > 0
  if equip_header then equip_header.visible = visible end
end

return Equip
