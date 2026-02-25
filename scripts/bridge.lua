-- bridge.lua: Implements WASM host imports that connect NetHack to Factorio
-- These functions are called by the WASM interpreter when NetHack invokes imported functions.
-- Some are "blocking" (need player input) and some are immediate.

local Display = require("scripts.display")
local Gui = require("scripts.gui")
local Wasi = require("scripts.wasm.wasi")

local Bridge = {}

-- Window type constants (from NetHack)
local NHW_MESSAGE = 1
local NHW_STATUS  = 2
local NHW_MAP     = 3
local NHW_MENU    = 4
local NHW_TEXT    = 5

-- Helper: read a null-terminated string from WASM linear memory
function Bridge.read_string(memory, ptr, max_len)
  max_len = max_len or 1024
  local chars = {}
  for i = 0, max_len - 1 do
    local b = memory:load_byte(ptr + i)
    if b == 0 then break end
    chars[#chars + 1] = string.char(b)
  end
  return table.concat(chars)
end

-- Helper: read a string with known length from WASM memory
function Bridge.read_string_len(memory, ptr, len)
  if len <= 0 then return "" end
  local chars = {}
  for i = 0, len - 1 do
    local b = memory:load_byte(ptr + i)
    chars[#chars + 1] = string.char(b)
  end
  return table.concat(chars)
end

-- Helper: write a string into WASM memory (null-terminated)
function Bridge.write_string(memory, ptr, str)
  for i = 1, #str do
    memory:store_byte(ptr + i - 1, string.byte(str, i))
  end
  memory:store_byte(ptr + #str, 0)
end

-- Create the import table for the WASM instance
-- Returns a table of { module.name = function(...) }
-- Blocking imports return a special sentinel that tells the interpreter to pause
function Bridge.create_imports(memory_ref, instance_ref)
  local imports = {}

  -- Immediate imports (execute and continue)

  imports["env.host_print_glyph"] = function(x, y, tile_idx, ch, color, special)
    Display.print_glyph(x, y, tile_idx, ch, color, special)
  end

  imports["env.host_putstr"] = function(win, attr, str_ptr, len)
    local memory = memory_ref()
    local text = Bridge.read_string_len(memory, str_ptr, len)
    Gui.putstr(win, attr, text)
  end

  imports["env.host_raw_print"] = function(str_ptr, len)
    local memory = memory_ref()
    local text = Bridge.read_string_len(memory, str_ptr, len)
    Gui.add_message(text, 0)
  end

  -- BL_FLUSH=-1 and BL_RESET=-2 in C, arrive as unsigned i32 from WASM
  local BL_FLUSH_U32 = 0xFFFFFFFF  -- -1 as unsigned i32
  local BL_RESET_U32 = 0xFFFFFFFE  -- -2 as unsigned i32

  imports["env.host_status_update"] = function(idx, val_ptr, len, color, percent)
    -- BL_FLUSH/BL_RESET are control signals, not field data
    if idx == BL_FLUSH_U32 or idx == BL_RESET_U32 then
      Gui.flush_status()
      return
    end

    local memory = memory_ref()
    local text = Bridge.read_string_len(memory, val_ptr, len)
    Gui.update_status(idx, text, color)
  end

  imports["env.host_create_nhwindow"] = function(win_type)
    return Gui.create_window(win_type)
  end

  imports["env.host_display_nhwindow"] = function(winid, blocking)
    Gui.display_window(winid, blocking ~= 0)
    -- When blocking a message window, show --More-- indicator.
    -- The C code will call host_nhgetch next to actually block.
    if blocking ~= 0 then
      local gui_data = storage.nh_gui
      local win = gui_data and gui_data.windows[winid]
      if win and win.type == NHW_MESSAGE then
        Gui.add_message("--More--", 1)
      end
    end
  end

  imports["env.host_clear_nhwindow"] = function(winid)
    local gui_data = storage.nh_gui
    local win = gui_data and gui_data.windows[winid]
    if win and win.type == NHW_MAP then
      Display.clear_map()
    else
      Gui.clear_window(winid)
    end
  end

  imports["env.host_destroy_nhwindow"] = function(winid)
    Gui.destroy_window(winid)
  end

  imports["env.host_exit_nhwindows"] = function(str_ptr, len)
    local memory = memory_ref()
    local text = ""
    if str_ptr ~= 0 and len > 0 then
      text = Bridge.read_string_len(memory, str_ptr, len)
    end
    if text ~= "" then
      Gui.add_message("NetHack: " .. text, 0)
    end
  end

  imports["env.host_curs"] = function(winid, x, y)
    -- Cursor positioning - used by the display system
    -- We track this for map window cursor
    if not storage.nh_bridge then storage.nh_bridge = {} end
    storage.nh_bridge.cursor = {winid = winid, x = x, y = y}
  end

  imports["env.host_cliparound"] = function(x, y)
    -- In Factorio, the camera follows the player naturally
    -- We could center the view here if needed
  end

  imports["env.host_delay_output"] = function()
    -- No-op in Factorio - we don't need display delays
  end

  imports["env.host_update_inventory"] = function()
    -- Could trigger inventory GUI refresh
  end

  imports["env.host_mark_synch"] = function()
    -- Synchronization point - flush any pending display updates
  end

  imports["env.host_start_menu"] = function(winid)
    Gui.start_menu(winid)
  end

  imports["env.host_add_menu_item"] = function(winid, glyph, identifier, accelerator, group_accel, attr, str_ptr, len, preselected)
    local memory = memory_ref()
    local text = Bridge.read_string_len(memory, str_ptr, len)
    Gui.add_menu_item(winid, glyph, identifier, accelerator, group_accel, attr, text, preselected)
  end

  imports["env.host_end_menu"] = function(winid, prompt_ptr, prompt_len)
    local memory = memory_ref()
    local prompt = ""
    if prompt_ptr ~= 0 and prompt_len > 0 then
      prompt = Bridge.read_string_len(memory, prompt_ptr, prompt_len)
    end
    Gui.end_menu(winid, prompt)
  end

  -- Blocking imports: these return a special table that tells the interpreter to pause.
  -- The interpreter checks for this sentinel and switches to "waiting_input" state.
  --
  -- IMPORTANT: The C window port calls host_yn_function / host_getlin to set up
  -- the UI prompt, then calls host_nhgetch to actually wait for user input.
  -- So yn_function and getlin are NON-blocking (void return). Only nhgetch and
  -- select_menu block.

  -- BLOCKING: wait for a key press (THE primary input function)
  imports["env.host_nhgetch"] = {
    blocking = true,
    handler = function()
      return {input_type = "getch"}
    end,
  }

  -- NON-BLOCKING: yn_function sets up a yes/no prompt, nhgetch blocks for the answer
  imports["env.host_yn_function"] = function(query_ptr, qlen, resp_ptr, rlen, def)
    local memory = memory_ref()
    local query = Bridge.read_string_len(memory, query_ptr, qlen)
    local resp = ""
    if resp_ptr ~= 0 and rlen > 0 then
      resp = Bridge.read_string_len(memory, resp_ptr, rlen)
    end
    Gui.add_message(query, 0)
    if not storage.nh_bridge then storage.nh_bridge = {} end

    if resp ~= "" then
      -- Specific valid responses (y/n/q etc.) — show yn prompt dialog
      storage.nh_bridge.pending_yn = {query = query, resp = resp, def = def}
    elseif query:match("%[.*%?.*%]") then
      -- Inventory-style prompt with no resp restriction (getobj passes resp=NULL).
      -- Auto-feed '?' to trigger NetHack's built-in inventory menu,
      -- which provides a proper item-name selection UI via select_menu.
      local main_state = storage.nh_main
      if main_state then
        main_state.input_queue[#main_state.input_queue + 1] = string.byte("?")
      end
    end
    -- Otherwise (empty resp, no brackets): no pending_yn set,
    -- nhgetch will be treated as regular getch.
  end

  -- NON-BLOCKING: getlin sets up a text prompt, nhgetch blocks for each character
  imports["env.host_getlin"] = function(prompt_ptr, len)
    local memory = memory_ref()
    local prompt = Bridge.read_string_len(memory, prompt_ptr, len)
    if not storage.nh_bridge then storage.nh_bridge = {} end
    storage.nh_bridge.pending_getlin = {prompt = prompt}
  end

  -- BLOCKING: select_menu - show menu and get selection count
  -- The C code then calls nhgetch to get each selection ID.
  imports["env.host_select_menu"] = {
    blocking = true,
    handler = function(winid, how)
      return {input_type = "menu", winid = winid, how = how}
    end,
  }

  -- Add WASI runtime imports (filesystem, clock, environment)
  Wasi.add_imports(imports, memory_ref, instance_ref)

  return imports
end

-- Initialize bridge state
function Bridge.init()
  if not storage.nh_bridge then
    storage.nh_bridge = {
      cursor = {winid = 0, x = 0, y = 0},
    }
  end
end

return Bridge
