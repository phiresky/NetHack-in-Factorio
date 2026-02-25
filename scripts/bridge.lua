-- bridge.lua: Implements WASM host imports that connect NetHack to Factorio
-- These functions are called by the WASM interpreter when NetHack invokes imported functions.
-- Some are "blocking" (need player input) and some are immediate.

local Display = require("scripts.display")
local Gui = require("scripts.gui")
local Wasi = require("scripts.wasm.wasi")

local WasmInterp = require("scripts.wasm.interp")

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
      -- Only do this ONCE per prompt cycle to prevent infinite loops:
      -- if display_inventory returns without blocking (empty inventory),
      -- getobj loops and calls yn_function again — without this guard,
      -- '?' would be re-queued endlessly, freezing Factorio.
      if not storage.nh_bridge.auto_fed_inventory then
        storage.nh_bridge.auto_fed_inventory = true
        local main_state = storage.nh_main
        if main_state then
          main_state.input_queue[#main_state.input_queue + 1] = string.byte("?")
        end
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

  -- Player selection dialog imports (non-blocking setup + blocking show)

  imports["env.host_plsel_setup_role"] = function(idx, name_ptr, len, allow)
    local memory = memory_ref()
    local name = Bridge.read_string_len(memory, name_ptr, len)
    if not storage.nh_bridge then storage.nh_bridge = {} end
    if not storage.nh_bridge.plsel then
      storage.nh_bridge.plsel = {roles = {}, races = {}, genders = {}, aligns = {}}
    end
    storage.nh_bridge.plsel.roles[idx] = {name = name, allow = allow}
  end

  imports["env.host_plsel_setup_race"] = function(idx, noun_ptr, len, allow)
    local memory = memory_ref()
    local noun = Bridge.read_string_len(memory, noun_ptr, len)
    if not storage.nh_bridge then storage.nh_bridge = {} end
    if not storage.nh_bridge.plsel then
      storage.nh_bridge.plsel = {roles = {}, races = {}, genders = {}, aligns = {}}
    end
    storage.nh_bridge.plsel.races[idx] = {name = noun, allow = allow}
  end

  imports["env.host_plsel_setup_gend"] = function(idx, adj_ptr, len, allow)
    local memory = memory_ref()
    local adj = Bridge.read_string_len(memory, adj_ptr, len)
    if not storage.nh_bridge then storage.nh_bridge = {} end
    if not storage.nh_bridge.plsel then
      storage.nh_bridge.plsel = {roles = {}, races = {}, genders = {}, aligns = {}}
    end
    storage.nh_bridge.plsel.genders[idx] = {name = adj, allow = allow}
  end

  imports["env.host_plsel_setup_align"] = function(idx, adj_ptr, len, allow)
    local memory = memory_ref()
    local adj = Bridge.read_string_len(memory, adj_ptr, len)
    if not storage.nh_bridge then storage.nh_bridge = {} end
    if not storage.nh_bridge.plsel then
      storage.nh_bridge.plsel = {roles = {}, races = {}, genders = {}, aligns = {}}
    end
    storage.nh_bridge.plsel.aligns[idx] = {name = adj, allow = allow}
  end

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
    if not storage.nh_bridge then storage.nh_bridge = {} end
    storage.nh_bridge.describe_result = {buf = buf, monbuf = monbuf}
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

-- Description caches (not in storage — transient, rebuilt as needed)
-- Position cache: short descriptions keyed by "x,y", cleared each turn
Bridge._pos_cache = {}
-- Long description cache: keyed by entity name, persists across game session
Bridge._long_cache = {}

-- Clear position cache (call after each turn advance).
-- Precache is NOT aborted — it swaps exec states per-tick so game exec is always current.
function Bridge.clear_pos_cache(instance)
  Bridge._pos_cache = {}
end

-- Pre-cache queue: list of {x, y, entity_name} to process one per tick
Bridge._precache_queue = {}
Bridge._precache_dirty = false

-- Mark that the map may have changed (call after turn advance)
function Bridge.mark_precache_dirty()
  log("[precache] mark_dirty, queue=" .. #Bridge._precache_queue
      .. " active=" .. tostring(Bridge._precache_active ~= nil))
  Bridge._precache_dirty = true
end

-- Scan a surface for unique NH entity types and queue uncached ones
function Bridge.start_precache(surface)
  Bridge._precache_dirty = false
  local seen = {}
  local queue = {}
  local skipped = 0
  for _, entity in pairs(surface.find_entities_filtered{name = "nh-player-marker", invert = true}) do
    local ename = entity.name
    if ename:find("^nh%-") and not seen[ename] then
      seen[ename] = true
      if Bridge._long_cache[ename] ~= nil then
        skipped = skipped + 1
      else
        queue[#queue + 1] = {
          x = math.floor(entity.position.x),
          y = math.floor(entity.position.y),
          entity_name = ename,
        }
      end
    end
  end
  Bridge._precache_queue = queue
  log("[precache] start_precache: queued=" .. #queue .. " already_cached=" .. skipped)
end

-- Active precache state: saved game exec + in-progress describe exec
Bridge._precache_active = nil  -- {saved_exec, entity_name}

-- Process one queued pre-cache entry across multiple ticks.
-- Runs up to `budget` WASM instructions per call. Returns true if more work remains.
-- IMPORTANT: instance.exec always holds the GAME state between ticks.
-- The describe call's exec is stored in _precache_active.describe_exec.
function Bridge.tick_precache(instance, budget)
  budget = budget or 1000
  if not instance or not instance.exec then return false end

  -- Resume an in-progress precache lookup
  if Bridge._precache_active then
    local active = Bridge._precache_active
    -- Refresh saved game exec (it may have changed if player moved between ticks)
    active.saved_exec = instance.exec
    -- Swap in the describe exec state
    instance.exec = active.describe_exec
    local ok, err = pcall(function()
      WasmInterp.run(instance, budget)
    end)
    local done = not ok or not instance.exec or instance.exec.finished
    if done then
      -- Finished (or errored) — read result and restore game state
      local captured = storage.nh_bridge and storage.nh_bridge.describe_capture
      if storage.nh_bridge then storage.nh_bridge.describe_capture = nil end
      instance.exec = active.saved_exec

      local result = storage.nh_bridge and storage.nh_bridge.describe_result
      if storage.nh_bridge then storage.nh_bridge.describe_result = nil end
      local short = nil
      if result then
        local parts = {}
        if result.monbuf ~= "" then parts[#parts + 1] = result.monbuf end
        if result.buf ~= "" then parts[#parts + 1] = result.buf end
        if #parts > 0 then
          short = table.concat(parts, "  ")
          Bridge._pos_cache[active.x .. "," .. active.y] = short
        end
      end
      local long_text = nil
      if captured and #captured > 0 then
        long_text = table.concat(captured, "\n")
        Bridge._long_cache[active.entity_name] = long_text
      else
        Bridge._long_cache[active.entity_name] = false
      end
      log("[precache] DONE " .. active.entity_name
          .. " ok=" .. tostring(ok) .. " err=" .. tostring(err)
          .. " short=" .. tostring(short ~= nil)
          .. " long=" .. tostring(long_text ~= nil)
          .. " queue=" .. #Bridge._precache_queue)
      Bridge._precache_active = nil
    else
      -- Not done yet — save describe exec, restore game exec
      active.describe_exec = instance.exec
      instance.exec = active.saved_exec
    end
    return true
  end

  -- Ensure export index is cached
  if not Bridge._describe_idx then
    Bridge._describe_idx = WasmInterp.get_export(instance, "nh_describe_pos")
    if not Bridge._describe_idx then return false end
  end

  -- Pick next uncached entry from queue
  local queue = Bridge._precache_queue
  while #queue > 0 do
    local entry = table.remove(queue)
    if Bridge._long_cache[entry.entity_name] == nil then
      -- Start a new describe call
      if not storage.nh_bridge then storage.nh_bridge = {} end
      storage.nh_bridge.describe_result = nil
      storage.nh_bridge.describe_capture = {}

      local saved_exec = instance.exec
      local ok, err = pcall(function()
        WasmInterp.call(instance, Bridge._describe_idx, {entry.x, entry.y, 1})
        WasmInterp.run(instance, budget)
      end)
      if not ok then
        log("[precache] START ERROR " .. entry.entity_name .. " err=" .. tostring(err))
        instance.exec = saved_exec
        storage.nh_bridge.describe_capture = nil
      else
        log("[precache] START " .. entry.entity_name .. " at " .. entry.x .. "," .. entry.y
            .. " queue=" .. #queue)
        -- Save describe exec, restore game exec between ticks
        Bridge._precache_active = {
          saved_exec = saved_exec,
          describe_exec = instance.exec,
          entity_name = entry.entity_name,
          x = entry.x, y = entry.y,
        }
        instance.exec = saved_exec
      end
      return true
    else
      log("[precache] SKIP " .. entry.entity_name .. " (already cached)")
    end
  end
  return false
end

-- Describe a map position by calling nh_describe_pos in WASM.
-- Safe to call while paused at nhgetch: saves/restores exec state.
-- entity_name: Factorio prototype name (e.g. "nh-mon-little-dog"), used as long desc cache key.
-- Returns {short=..., long=...} or nil on failure.
-- short = lookat() one-liner, long = checkfile() encyclopedia entry (only when full=true).
function Bridge.describe_pos(instance, x, y, full, entity_name, max_instructions)
  if not instance or not instance.exec then return nil end

  local pos_key = x .. "," .. y

  -- Check caches FIRST (before aborting any in-progress precache)
  local cached_short = Bridge._pos_cache[pos_key]
  if not full then
    if cached_short ~= nil then
      if cached_short == false then return nil end
      return {short = cached_short}
    end
  else
    -- Full requested — check long cache by entity name
    local cached_long = entity_name and Bridge._long_cache[entity_name]
    if cached_long ~= nil then
      -- Still need short desc (may or may not be cached)
      local short = cached_short
      if short == nil then
        -- Fall through to WASM call below for short, but skip checkfile
        full = false
      elseif short == false then
        return cached_long ~= false and {long = cached_long} or nil
      else
        return {short = short, long = cached_long or nil}
      end
    end
  end

  -- Cache miss — need a WASM call. Abort any in-progress precache first.
  if Bridge._precache_active then
    local aborted = Bridge._precache_active
    log("[precache] ABORT by describe_pos, was=" .. aborted.entity_name
        .. " queue=" .. #Bridge._precache_queue)
    -- Push aborted entry back to queue so it's not lost
    Bridge._precache_queue[#Bridge._precache_queue + 1] = {
      x = aborted.x, y = aborted.y, entity_name = aborted.entity_name,
    }
    Bridge._precache_active = nil
    if storage.nh_bridge then
      storage.nh_bridge.describe_capture = nil
      storage.nh_bridge.describe_result = nil
    end
  end

  -- Cache the export index
  if not Bridge._describe_idx then
    Bridge._describe_idx = WasmInterp.get_export(instance, "nh_describe_pos")
    if not Bridge._describe_idx then return nil end
  end

  -- Save current execution state
  local saved_exec = instance.exec

  -- Clear any previous result; enable capture mode only when fetching full desc
  if not storage.nh_bridge then storage.nh_bridge = {} end
  storage.nh_bridge.describe_result = nil
  if full then
    storage.nh_bridge.describe_capture = {}
  end

  -- Call nh_describe_pos(x, y, full) and run to completion.
  -- checkfile() with without_asking=TRUE is non-blocking, so a single run suffices.
  local ok, err = pcall(function()
    WasmInterp.call(instance, Bridge._describe_idx, {x, y, full and 1 or 0})
    WasmInterp.run(instance, max_instructions or 500000)
  end)

  -- Read captured checkfile text before cleanup
  local captured = full and storage.nh_bridge.describe_capture or nil
  storage.nh_bridge.describe_capture = nil

  -- Restore execution state (even on error)
  instance.exec = saved_exec

  if not ok then return nil end

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

  -- Cache short description (false = no description)
  Bridge._pos_cache[pos_key] = short_desc or false

  -- Build long description from checkfile capture
  local long_desc = nil
  if captured and #captured > 0 then
    long_desc = table.concat(captured, "\n")
  end

  -- Cache long description keyed by entity name (persists across session)
  if full and entity_name then
    Bridge._long_cache[entity_name] = long_desc or false
  end

  if not short_desc and not long_desc then return nil end
  return {short = short_desc, long = long_desc}
end

return Bridge
