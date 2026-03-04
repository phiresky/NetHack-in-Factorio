-- bridge.lua: Implements WASM host imports that connect NetHack to Factorio
-- These functions are called by the WASM interpreter when NetHack invokes imported functions.
-- Some are "blocking" (need player input) and some are immediate.

local Display = require("scripts.display")
local Gui = require("scripts.gui")
local Inventory = require("scripts.inventory")
local Wasi = require("scripts.wasm.wasi")

local WasmInterp = require("scripts.wasm.interp")

-- Encyclopedia lookup table (generated at build time by parse_encyclopedia.py)
local ok_enc, encyclopedia = pcall(require, "scripts.encyclopedia")
if not ok_enc then encyclopedia = {} end

local Bridge = {}

-- Ensure storage.nh_bridge exists and return it.
local function get_bridge_state()
  if not storage.nh_bridge then storage.nh_bridge = {} end
  return storage.nh_bridge
end
Bridge.get_state = get_bridge_state

-- Window type constants (from Gui module)
local NHW_MESSAGE = Gui.NHW_MESSAGE
local NHW_STATUS  = Gui.NHW_STATUS
local NHW_MAP     = Gui.NHW_MAP
local NHW_MENU    = Gui.NHW_MENU
local NHW_TEXT    = Gui.NHW_TEXT

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

-- Helper: read a string from WASM memory, returning "" for null/empty pointers
local function read_string_safe(memory, ptr, len)
  if ptr == 0 or len <= 0 then return "" end
  return Bridge.read_string_len(memory, ptr, len)
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
function Bridge.create_imports(memory_ref, instance_ref, opts)
  local imports = {}

  -- Immediate imports (execute and continue)

  imports["env.host_print_glyph"] = function(x, y, tile_idx, ch, color, special, bk_tile_idx)
    Display.print_glyph(x, y, tile_idx, ch, color, special, bk_tile_idx)
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
    local text = read_string_safe(memory_ref(), str_ptr, len)
    if text ~= "" then
      Gui.add_message("NetHack: " .. text, 0)
    end
  end

  imports["env.host_curs"] = function(winid, x, y)
    -- Cursor positioning - used by the display system
    -- We track this for map window cursor
    get_bridge_state().cursor = {winid = winid, x = x, y = y}
    -- flush_screen calls curs(WIN_MAP, u.ux, u.uy) after all print_glyph calls.
    -- Use this to suppress the hero entity at the player's position.
    -- (cliparound fires at the START of the next turn in allmain.c, too late.)
    local gui_data = storage.nh_gui
    local win = gui_data and gui_data.windows[winid]
    if win and win.type == NHW_MAP then
      Display.set_hero_pos(x, y)
    end
  end

  imports["env.host_cliparound"] = function(x, y)
    -- Called from allmain.c at the start of each turn with u.ux, u.uy.
    -- Also updates hero position (belt-and-suspenders with host_curs above).
    Display.set_hero_pos(x, y)
  end

  -- Stub imports: called by NetHack but not needed in Factorio
  local function noop() end
  imports["env.host_delay_output"] = noop
  imports["env.host_update_inventory"] = noop  -- backward compat for old WASM binaries

  imports["env.host_inventory_begin"] = function()
    Inventory.begin()
  end

  imports["env.host_inventory_item"] = function(slot, tile, o_id, invlet,
                                                name_ptr, name_len, quan, oclass, owornmask)
    local name = Bridge.read_string_len(memory_ref(), name_ptr, name_len)
    Inventory.add_item(slot, tile, o_id, invlet, name, quan, oclass, owornmask)
  end

  imports["env.host_inventory_done"] = function(count)
    Inventory.done(count)
  end
  imports["env.host_mark_synch"] = noop

  imports["env.host_start_menu"] = function(winid)
    Gui.start_menu(winid)
  end

  imports["env.host_add_menu_item"] = function(winid, glyph, identifier, accelerator, group_accel, attr, str_ptr, len, preselected)
    local memory = memory_ref()
    local text = Bridge.read_string_len(memory, str_ptr, len)
    Gui.add_menu_item(winid, glyph, identifier, accelerator, group_accel, attr, text, preselected)
  end

  imports["env.host_end_menu"] = function(winid, prompt_ptr, prompt_len)
    Gui.end_menu(winid, read_string_safe(memory_ref(), prompt_ptr, prompt_len))
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
    local resp = read_string_safe(memory, resp_ptr, rlen)
    Gui.add_message(query, 0)
    local bridge = get_bridge_state()

    -- Check for pending drop from Factorio inventory
    local inv_state = storage.nh_inventory
    if inv_state and inv_state.pending_drop then
      local drop = inv_state.pending_drop
      inv_state.pending_drop = nil
      local main_state = storage.nh_main
      if main_state then
        main_state.input_queue[#main_state.input_queue + 1] = drop.invlet
      end
      return
    end

    -- Check for inventory-style prompt (brackets with ? or *)
    local has_help = query:match("%[.*%?.*%]") or query:match("%[.*%*.*%]")

    if has_help and not bridge.auto_fed_inventory then
      -- First time: auto-feed '?' (or '*') to trigger NetHack's built-in
      -- inventory menu, which provides item-name selection via select_menu.
      -- Only do this ONCE per prompt cycle: after the inventory is dismissed,
      -- getobj loops and calls yn_function again — the second call falls
      -- through to the yn popup below.
      bridge.auto_fed_inventory = true
      bridge.inventory_prompt = query
      local help_char = query:match("%[.*%?.*%]") and string.byte("?") or string.byte("*")
      local main_state = storage.nh_main
      if main_state then
        main_state.input_queue[#main_state.input_queue + 1] = help_char
      end
    elseif resp ~= "" then
      -- Show yn prompt popup: either a simple y/n/q prompt, or the re-prompt
      -- after auto-fed inventory was dismissed (user picks item by letter).
      bridge.pending_yn = {query = query, resp = resp, def = def}
    end
    -- Otherwise (empty resp, no brackets): no pending_yn set,
    -- nhgetch will be treated as regular getch.
  end

  -- NON-BLOCKING: getlin sets up a text prompt, nhgetch blocks for each character
  imports["env.host_getlin"] = function(prompt_ptr, len)
    local memory = memory_ref()
    local prompt = Bridge.read_string_len(memory, prompt_ptr, len)
    get_bridge_state().pending_getlin = {prompt = prompt}
  end

  -- BLOCKING: select_menu - show menu and get selection count
  -- The C code then calls nhgetch to get each selection ID.
  imports["env.host_select_menu"] = {
    blocking = true,
    handler = function(winid, how)
      return {input_type = "menu", winid = winid, how = how}
    end,
  }

  -- Player selection dialog imports (non-blocking setup + blocking show)

  local function plsel_setup(field)
    return function(idx, ptr, len, allow)
      local memory = memory_ref()
      local name = Bridge.read_string_len(memory, ptr, len)
      local bridge = get_bridge_state()
      if not bridge.plsel then
        bridge.plsel = {roles = {}, races = {}, genders = {}, aligns = {}}
      end
      bridge.plsel[field][idx] = {name = name, allow = allow}
    end
  end

  imports["env.host_plsel_setup_role"]  = plsel_setup("roles")
  imports["env.host_plsel_setup_race"]  = plsel_setup("races")
  imports["env.host_plsel_setup_gend"]  = plsel_setup("genders")
  imports["env.host_plsel_setup_align"] = plsel_setup("aligns")

  -- BLOCKING: show the player selection dialog
  imports["env.host_plsel_show"] = {
    blocking = true,
    handler = function()
      return {input_type = "plsel"}
    end,
  }

  -- NON-BLOCKING: receive tile description from nh_describe_pos
  imports["env.host_describe_result"] = function(buf_ptr, buf_len, monbuf_ptr, monbuf_len)
    local memory = memory_ref()
    local buf = Bridge.read_string_len(memory, buf_ptr, buf_len)
    local monbuf = Bridge.read_string_len(memory, monbuf_ptr, monbuf_len)
    get_bridge_state().describe_result = {buf = buf, monbuf = monbuf}
  end

  -- Click-to-travel: non-blocking imports to read click coordinates.
  -- Called by nh_poskey in C after host_nhgetch returns 0 (click signal).
  imports["env.host_poskey_x"] = function()
    local click = storage.nh_bridge and storage.nh_bridge.pending_click
    return click and click.x or 0
  end

  imports["env.host_poskey_y"] = function()
    local click = storage.nh_bridge and storage.nh_bridge.pending_click
    return click and click.y or 0
  end

  imports["env.host_poskey_mod"] = function()
    local click = storage.nh_bridge and storage.nh_bridge.pending_click
    -- Clear pending_click after mod is read (last of the three imports)
    if storage.nh_bridge then
      storage.nh_bridge.pending_click = nil
    end
    return click and click.mod or 0
  end

  -- Add WASI runtime imports (filesystem, clock, environment)
  Wasi.add_imports(imports, memory_ref, instance_ref, opts)

  return imports
end

-- Initialize bridge state
function Bridge.init()
  if not storage.nh_bridge then
    storage.nh_bridge = {
      cursor = {winid = 0, x = 0, y = 0},
    }
  end
  Inventory.init()
end

-- Describe a map position by calling nh_describe_pos in WASM for the short
-- description (lookat result), and looking up the long description from the
-- pre-built encyclopedia table (no more expensive checkfile() WASM call).
-- Safe to call while paused at nhgetch: saves/restores exec state.
-- entity_name: Factorio prototype name (e.g. "nh-mon-little-dog").
-- Returns {short=..., long=...} or nil.
function Bridge.describe_pos(instance, x, y, full, entity_name, max_instructions)
  if not instance or not instance.exec then return nil end

  -- Cache the export index
  if not Bridge._describe_idx then
    Bridge._describe_idx = WasmInterp.get_export(instance, "nh_describe_pos")
    if not Bridge._describe_idx then return nil end
  end

  local saved = instance:save_state()
  local bridge = get_bridge_state()
  bridge.describe_result = nil

  -- Call nh_describe_pos(x, y, 0) -- short description only (no checkfile)
  local ok, err = pcall(function()
    WasmInterp.call(instance, Bridge._describe_idx, {x, y, 0})
    WasmInterp.run(instance, max_instructions or 500000)
  end)

  if not ok then
    instance:restore_state(saved)
    return nil
  end

  instance:restore_state(saved)

  -- Build short description from lookat result
  local result = bridge.describe_result
  bridge.describe_result = nil

  local short_desc = nil
  if result then
    local parts = {}
    if result.monbuf ~= "" then parts[#parts + 1] = result.monbuf end
    if result.buf ~= "" then parts[#parts + 1] = result.buf end
    if #parts > 0 then short_desc = table.concat(parts, "  ") end
  end

  -- Look up long description from encyclopedia (static table, no WASM call)
  local long_desc = nil
  if entity_name then
    local key = entity_name:gsub("^nh%-mon%-", ""):gsub("^nh%-obj%-", ""):gsub("^nh%-other%-", "")
    long_desc = encyclopedia[key]
  end

  if not short_desc and not long_desc then return nil end
  return {short = short_desc, long = long_desc}
end

-- Stubs for backward compat (no-ops now that describe is synchronous)
function Bridge.continue_describe() return false end
function Bridge.cancel_describe() end

-- Export the current game save from VFS.
-- Calls nh_dosave (which runs dosave0 -> proc_exit), catches the exit,
-- extracts save files from VFS, then restores game state.
-- Returns {name=filename, data=bytes} or nil, error_string on failure.
function Bridge.export_save(instance)
  if not instance or not instance.exec then return nil, "no instance" end

  -- Cache export index
  if not Bridge._dosave_idx then
    Bridge._dosave_idx = WasmInterp.get_export(instance, "nh_dosave")
    if not Bridge._dosave_idx then return nil, "nh_dosave export not found" end
  end

  -- Cancel any pending hover describe
  Bridge.cancel_describe(instance)

  -- Snapshot VFS overlay state before save (to detect new/modified files).
  -- vfs.files uses setmetatable({}, {__index = nethack_data}), so pairs()
  -- only iterates overlay keys (explicitly written files).
  local vfs = instance._vfs
  local pre_files = {}
  if vfs and vfs.files then
    for k, v in pairs(vfs.files) do
      pre_files[k] = v
    end
  end

  -- Save execution state + stack pointer (critical: same pattern as execute_wasm_cheat)
  local saved_exec = instance.exec
  local saved_sp = instance.globals[0]

  -- Run dosave (will end with proc_exit / exit())
  local ok, err = pcall(function()
    WasmInterp.call(instance, Bridge._dosave_idx, {})
    WasmInterp.run(instance, 5000000)
  end)

  -- Flush any open writable fds to the files table before scanning
  if vfs then
    for _, entry in pairs(vfs.fds) do
      if entry.writable and entry.name then
        vfs.files[entry.name] = entry.data
      end
    end
  end

  -- Restore execution state regardless of outcome
  instance.exec = saved_exec
  instance.globals[0] = saved_sp

  -- Find new/modified files in VFS (the save file)
  local save_files = {}
  if vfs and vfs.files then
    for k, v in pairs(vfs.files) do
      if type(v) == "string" and #v > 0 then
        if pre_files[k] ~= v then
          save_files[#save_files + 1] = {name = k, data = v}
        end
      end
    end
  end

  if #save_files == 0 then
    return nil, "No save files found in VFS"
  end

  -- Return the largest file (most likely the actual save)
  table.sort(save_files, function(a, b) return #a.data > #b.data end)
  return save_files[1]
end

return Bridge
