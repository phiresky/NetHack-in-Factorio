-- scripts/inventory.lua
-- Syncs NetHack inventory to Factorio player inventory.
-- Receives data from WASM host_inventory_begin/item/done imports,
-- then applies changes to Factorio inventory after run_and_process().

local TC = require("scripts.tile_config")

local Inventory = {}

-- Build tile_idx -> item prototype name mapping.
-- Object tiles are in range [n_monsters, n_monsters + n_objects) in the global tile index.
local tile_to_item = {}
for i, name in ipairs(TC.object_names) do
  local tile_idx = TC.n_monsters + (i - 1)
  tile_to_item[tile_idx] = "nh-item-" .. name
end

local function get_state()
  if not storage.nh_inventory then
    storage.nh_inventory = {
      slot_map = {},       -- maps Factorio slot -> {invlet, o_id, tile, name, item_name}
      syncing = false,     -- true during our insert/clear (prevents recursive events)
      pending_drop = nil,  -- {invlet = N} when player drops from Factorio inventory
    }
  end
  return storage.nh_inventory
end

-- Module-local staging buffer (not persisted — rebuilt each WASM run)
local staging = nil
local staging_count = 0

function Inventory.init()
  get_state()
end

-- Called by host_inventory_begin import
function Inventory.begin()
  staging = {}
  staging_count = 0
end

-- Called by host_inventory_item import
function Inventory.add_item(slot, tile, o_id, invlet, name, quan, oclass, owornmask)
  if not staging then return end
  local item_name = tile_to_item[tile]
  staging_count = staging_count + 1
  staging[staging_count] = {
    slot = slot,
    tile = tile,
    o_id = o_id,
    invlet = invlet,
    name = name,
    quan = quan,
    oclass = oclass,
    owornmask = owornmask,
    item_name = item_name,
  }
end

-- Called by host_inventory_done import
function Inventory.done(count)
  -- staging is ready; apply_sync() will consume it after run_and_process()
end

-- Get the character entity to access inventory.
-- In god mode, the character is detached but stored in saved_character.
local function get_character()
  local main_state = storage.nh_main
  if not main_state then return nil end
  -- God mode: character is detached
  local char = main_state.saved_character
  if char and char.valid then return char end
  -- Normal mode: first connected player's character
  local player = game.connected_players[1]
  if player and player.character and player.character.valid then
    return player.character
  end
  return nil
end

-- Apply the staging buffer to the Factorio inventory.
-- Called after every run_and_process().
function Inventory.apply_sync()
  if not staging then return end

  local inv_state = get_state()
  if inv_state.syncing then return end

  local character = get_character()
  if not character then
    staging = nil
    return
  end

  local inventory = character.get_inventory(defines.inventory.character_main)
  if not inventory then
    staging = nil
    return
  end

  inv_state.syncing = true

  -- Phase 1: Remove all existing NH items from inventory
  for i = #inventory, 1, -1 do
    local stack = inventory[i]
    if stack and stack.valid_for_read and stack.name:find("^nh%-item%-") then
      stack.clear()
    end
  end

  -- Phase 2: Insert items from staging buffer
  local new_slot_map = {}
  for _, item in ipairs(staging) do
    if item.item_name then
      local inserted = inventory.insert({name = item.item_name, count = 1})
      if inserted > 0 then
        new_slot_map[#new_slot_map + 1] = {
          invlet = item.invlet,
          o_id = item.o_id,
          tile = item.tile,
          name = item.name,
          item_name = item.item_name,
        }
      end
    end
  end

  inv_state.slot_map = new_slot_map
  inv_state.syncing = false
  staging = nil
end

-- Find the NH invlet for a given item prototype name.
-- Searches the slot_map (most recent inventory state).
function Inventory.find_invlet_by_item(item_name)
  local inv_state = storage.nh_inventory
  if not inv_state then return nil end
  for _, entry in ipairs(inv_state.slot_map) do
    if entry.item_name == item_name then
      return entry.invlet
    end
  end
  return nil
end

-- Restore inventory from the last known slot_map.
-- Used when on_inventory_changed fires outside our sync (player tried to
-- manipulate items manually).
function Inventory.restore_from_slot_map()
  local inv_state = get_state()
  if inv_state.syncing then return end
  if not inv_state.slot_map or #inv_state.slot_map == 0 then return end

  local character = get_character()
  if not character then return end

  local inventory = character.get_inventory(defines.inventory.character_main)
  if not inventory then return end

  inv_state.syncing = true

  -- Clear all NH items
  for i = #inventory, 1, -1 do
    local stack = inventory[i]
    if stack and stack.valid_for_read and stack.name:find("^nh%-item%-") then
      stack.clear()
    end
  end

  -- Re-insert from slot_map
  for _, entry in ipairs(inv_state.slot_map) do
    if entry.item_name then
      inventory.insert({name = entry.item_name, count = 1})
    end
  end

  inv_state.syncing = false
end

-- Clear all NH items from Factorio inventory and reset state.
-- Used on on_configuration_changed.
function Inventory.reset()
  local character = get_character()
  if character then
    local inventory = character.get_inventory(defines.inventory.character_main)
    if inventory then
      for i = #inventory, 1, -1 do
        local stack = inventory[i]
        if stack and stack.valid_for_read and stack.name:find("^nh%-item%-") then
          stack.clear()
        end
      end
    end
  end
  storage.nh_inventory = nil
  staging = nil
  get_state()
end

return Inventory
