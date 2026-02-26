-- bridge.lua: Implements WASM host imports that connect NetHack to Factorio
-- These functions are called by the WASM interpreter when NetHack invokes imported functions.
-- Some are "blocking" (need player input) and some are immediate.

local Display = require("scripts.display")
local Gui = require("scripts.gui")
local Wasi = require("scripts.wasm.wasi")

local WasmInterp = require("scripts.wasm.interp")

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
    -- In capture mode, redirect text to buffer instead of GUI
    local capture = storage.nh_bridge and storage.nh_bridge.describe_capture
    if capture then
      capture[#capture + 1] = text
      return
    end
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
    -- In capture mode, suppress display entirely
    if storage.nh_bridge and storage.nh_bridge.describe_capture then
      return
    end
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
  end

  imports["env.host_cliparound"] = function(x, y)
    -- Called by flush_screen after all print_glyph calls with the hero's position.
    -- This is the authoritative source of the player's map coordinates.
    Display.set_hero_pos(x, y)
  end

  -- Stub imports: called by NetHack but not needed in Factorio
  local function noop() end
  imports["env.host_delay_output"] = noop
  imports["env.host_update_inventory"] = noop
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
end

-- Long description cache: keyed by entity name, persists across game session
Bridge._long_cache = {}

-- Pending describe continuation state (non-serializable, lives in module local)
-- Fields: saved (from instance:save_state()), full, entity_name, cached_long
Bridge._pending_describe = nil

-- Extract description results from storage and return {short=..., long=...} or nil.
local function collect_describe_result(full, entity_name, cached_long)
  -- Read captured checkfile text
  local captured = full and storage.nh_bridge.describe_capture or nil
  storage.nh_bridge.describe_capture = nil

  -- Read lookat result
  local result = storage.nh_bridge.describe_result
  storage.nh_bridge.describe_result = nil

  -- Build short description from lookat
  local short_desc = nil
  if result then
    local parts = {}
    if result.monbuf ~= "" then parts[#parts + 1] = result.monbuf end
    if result.buf ~= "" then parts[#parts + 1] = result.buf end
    if #parts > 0 then short_desc = table.concat(parts, "  ") end
  end

  -- Build long description from checkfile capture
  local long_desc = nil
  if captured and #captured > 0 then
    long_desc = table.concat(captured, "\n")
  end

  -- Cache long description keyed by entity name (persists across session)
  if full and entity_name then
    Bridge._long_cache[entity_name] = long_desc or false
  end

  -- Use cached long desc if we skipped checkfile
  if not long_desc and cached_long then
    long_desc = cached_long ~= false and cached_long or nil
  end

  if not short_desc and not long_desc then return nil end
  return {short = short_desc, long = long_desc}
end

-- Describe a map position by calling nh_describe_pos in WASM.
-- Safe to call while paused at nhgetch: saves/restores exec state.
-- entity_name: Factorio prototype name (e.g. "nh-mon-little-dog"), used as long desc cache key.
-- Returns {short=..., long=...}, or nil if not yet complete.
-- If budget is exceeded, saves continuation state in Bridge._pending_describe
-- for resumption via Bridge.continue_describe().
-- short = lookat() one-liner, long = checkfile() encyclopedia entry (only when full=true).
function Bridge.describe_pos(instance, x, y, full, entity_name, max_instructions)
  if not instance or not instance.exec then return nil end

  -- Cancel any existing pending describe
  Bridge.cancel_describe(instance)

  -- Check long cache by entity name
  local cached_long = nil
  if full and entity_name then
    cached_long = Bridge._long_cache[entity_name]
    if cached_long ~= nil then
      -- Have long desc cached, but still need short from WASM
      full = false
    end
  end

  -- Cache the export index
  if not Bridge._describe_idx then
    Bridge._describe_idx = WasmInterp.get_export(instance, "nh_describe_pos")
    if not Bridge._describe_idx then return nil end
  end

  local saved = instance:save_state()

  -- Clear any previous result; enable capture mode only when fetching full desc
  local bridge = get_bridge_state()
  bridge.describe_result = nil
  if full then
    bridge.describe_capture = {}
  end

  -- Call nh_describe_pos(x, y, full) and run with budget.
  local ok, err = pcall(function()
    WasmInterp.call(instance, Bridge._describe_idx, {x, y, full and 1 or 0})
    WasmInterp.run(instance, max_instructions or 500000)
  end)

  if not ok then
    -- Error: restore and discard
    instance:restore_state(saved)
    storage.nh_bridge.describe_capture = nil
    return nil
  end

  -- Check if the describe call finished
  local finished = instance.exec.finished

  if finished then
    instance:restore_state(saved)
    return collect_describe_result(full, entity_name, cached_long)
  end

  -- Not finished: save describe state, then restore game state
  local describe_saved = instance:save_state()
  instance:restore_state(saved)

  Bridge._pending_describe = {
    saved = describe_saved,
    full = full,
    entity_name = entity_name,
    cached_long = cached_long,
  }
  return nil
end

-- Continue a pending describe_pos call. Returns {short=..., long=...} when done,
-- nil if still running, or false if there's nothing pending.
function Bridge.continue_describe(instance, max_instructions)
  local pending = Bridge._pending_describe
  if not pending then return false end
  if not instance or not instance.exec then
    Bridge._pending_describe = nil
    return false
  end

  -- Swap in the describe exec state
  local saved = instance:save_state()
  instance:restore_state(pending.saved)

  local ok, err = pcall(function()
    WasmInterp.run(instance, max_instructions or 20000)
  end)

  if not ok then
    instance:restore_state(saved)
    Bridge._pending_describe = nil
    storage.nh_bridge.describe_capture = nil
    return false
  end

  local finished = instance.exec.finished

  -- Save progressed describe state, then restore game state
  pending.saved = instance:save_state()
  instance:restore_state(saved)

  if finished then
    Bridge._pending_describe = nil
    return collect_describe_result(pending.full, pending.entity_name, pending.cached_long)
  end

  return nil -- still running
end

-- Cancel any pending describe continuation, restoring clean state.
function Bridge.cancel_describe(instance)
  if Bridge._pending_describe then
    Bridge._pending_describe = nil
    if storage.nh_bridge then
      storage.nh_bridge.describe_capture = nil
      storage.nh_bridge.describe_result = nil
    end
  end
end

return Bridge
