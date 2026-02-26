-- scripts/main.lua
-- Main orchestrator for NetHack-in-Factorio
-- Connects the WASM interpreter running NetHack to Factorio's event system.
--
-- Architecture (no coroutines in Factorio sandbox):
--   The WASM interpreter is a resumable state machine.
--   When NetHack calls nhgetch() (waiting for input), the interpreter pauses.
--   When the player moves or presses a command key, we provide input and resume.
--   The interpreter runs up to N instructions per call, returning to Factorio
--   if it hits the limit (continued on next tick via on_tick).

local Display = require("scripts.display")
local Input = require("scripts.input")
local Gui = require("scripts.gui")
local Bridge = require("scripts.bridge")
local WasmInit = require("scripts.wasm.init")
local WasmInterp = require("scripts.wasm.interp")
local wasm_data_module = require("scripts.nethack_wasm")
local compiled_sources = require("scripts.nethack_compiled")

local M = {}

-- Maximum WASM instructions to execute per run() call
local MAX_INSTRUCTIONS_PER_RUN = 10000000

-- Maximum instructions per tick (for background processing like level gen)
local MAX_INSTRUCTIONS_PER_TICK = 200000

---------------------------------------------------------------------------
-- NetHack Options (from Factorio mod startup settings)
---------------------------------------------------------------------------

-- Map of Factorio setting name -> {nh_name, default_value}
-- Boolean options: default is true/false
-- String options: default is string (empty string means "skip if blank")
local OPTION_MAP = {
  -- Boolean options
  ["nethack-acoustics"]         = {"acoustics", true},
  ["nethack-autodig"]           = {"autodig", false},
  ["nethack-autoopen"]          = {"autoopen", true},
  ["nethack-autopickup"]        = {"autopickup", true},
  ["nethack-autoquiver"]        = {"autoquiver", false},
  ["nethack-bones"]             = {"bones", true},
  ["nethack-checkpoint"]        = {"checkpoint", true},
  ["nethack-cmdassist"]         = {"cmdassist", true},
  ["nethack-confirm"]           = {"confirm", true},
  ["nethack-dark-room"]         = {"dark_room", true},
  ["nethack-fixinv"]            = {"fixinv", true},
  ["nethack-force-invmenu"]     = {"force_invmenu", false},
  ["nethack-help"]              = {"help", true},
  ["nethack-hilite-pet"]        = {"hilite_pet", false},
  ["nethack-hilite-pile"]       = {"hilite_pile", false},
  ["nethack-implicit-uncursed"] = {"implicit_uncursed", true},
  ["nethack-legacy"]            = {"legacy", true},
  ["nethack-lit-corridor"]      = {"lit_corridor", false},
  ["nethack-lootabc"]           = {"lootabc", false},
  ["nethack-mention-walls"]     = {"mention_walls", false},
  ["nethack-pickup-thrown"]     = {"pickup_thrown", true},
  ["nethack-pushweapon"]        = {"pushweapon", false},
  ["nethack-rest-on-space"]     = {"rest_on_space", false},
  ["nethack-safe-pet"]          = {"safe_pet", true},
  ["nethack-showexp"]           = {"showexp", false},
  ["nethack-showrace"]          = {"showrace", false},
  ["nethack-silent"]            = {"silent", true},
  ["nethack-sortpack"]          = {"sortpack", true},
  ["nethack-sparkle"]           = {"sparkle", true},
  ["nethack-time"]              = {"time", false},
  ["nethack-tombstone"]         = {"tombstone", true},
  ["nethack-travel"]            = {"travel", true},
  ["nethack-verbose"]           = {"verbose", true},
  -- Compound options (default is the string value; "" means skip if blank)
  ["nethack-catname"]                 = {"catname", ""},
  ["nethack-dogname"]                 = {"dogname", ""},
  ["nethack-horsename"]               = {"horsename", ""},
  ["nethack-fruit"]                   = {"fruit", "slime mold"},
  ["nethack-pettype"]                 = {"pettype", ""},
  ["nethack-menustyle"]               = {"menustyle", "full"},
  ["nethack-pickup-burden"]           = {"pickup_burden", "stressed"},
  ["nethack-pickup-types"]            = {"pickup_types", ""},
  ["nethack-runmode"]                 = {"runmode", "run"},
  ["nethack-sortloot"]                = {"sortloot", "loot"},
  ["nethack-pile-limit"]              = {"pile_limit", "5"},
  ["nethack-packorder"]               = {"packorder", ""},
  ["nethack-paranoid-confirmation"]   = {"paranoid_confirmation", "pray"},
  ["nethack-disclose"]                = {"disclose", ""},
  ["nethack-msghistory"]              = {"msghistory", "20"},
  ["nethack-statushilites"]           = {"statushilites", "0"},
}

-- Build the NETHACKOPTIONS environment variable from startup settings.
-- Only includes options that differ from NetHack's defaults.
local function build_nethack_environ()
  local parts = {}
  for setting_name, info in pairs(OPTION_MAP) do
    local nh_name, default = info[1], info[2]
    local value = settings.startup[setting_name].value
    if type(default) == "boolean" then
      if value ~= default then
        if value then
          parts[#parts + 1] = nh_name
        else
          parts[#parts + 1] = "!" .. nh_name
        end
      end
    else
      if value ~= default and value ~= "" then
        parts[#parts + 1] = nh_name .. ":" .. value
      elseif value == "" and default ~= "" then
        parts[#parts + 1] = nh_name .. ":"
      end
    end
  end

  local environ = {}
  if #parts > 0 then
    environ[1] = "NETHACKOPTIONS=" .. table.concat(parts, ",")
  end
  return environ
end

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------

local function init_modules()
  Display.init()
  Input.init()
  Gui.init()
  Bridge.init()
  if not storage.nh_main then
    storage.nh_main = {
      game_started = false,
      awaiting_input = false,   -- true when NetHack is waiting for player input
      input_type = nil,         -- "getch", "yn", "getlin", "menu"
      input_info = nil,         -- additional info about what input is needed
      input_queue = {},         -- queued key codes to auto-feed to nhgetch
      running = false,          -- true when interpreter is actively executing
      current_level = "level_1",
      level_counter = 1,
      pending_start = nil,      -- player_index to start game for
      first_input_received = false, -- true once startup loading completes
    }
  end
  if not storage.nh_main.input_queue then
    storage.nh_main.input_queue = {}
  end
  -- Migration: existing saves without first_input_received
  if storage.nh_main.first_input_received == nil then
    storage.nh_main.first_input_received = storage.nh_main.game_started or false
  end
  -- WASM state persistence structure
  if not storage.wasm_state then
    storage.wasm_state = {
      memory_data = nil,      -- shared ref to Memory.data table
      memory_pages = 0,
      memory_max_pages = 0,
      globals = nil,          -- shared ref to instance.globals
      tables = nil,           -- shared ref to instance.tables
      table_sizes = nil,
      dropped_data_segs = {},
      dropped_elem_segs = {},
      vfs_overlay = {},       -- modified/created VFS files (delta over nethack_data)
      vfs_fds = {},           -- open file descriptors
      vfs_next_fd = 4,
      exec_snapshot = nil,    -- serialized exec state
      ctx_sbs = nil,          -- compiled code __sbs
      total_instructions = 0,
      active = false,         -- true after _start has run
    }
  end
end

-- Load and instantiate the WASM NetHack module
local function load_wasm_nethack()
  -- Parse the WASM binary
  local module = WasmInit.parse(wasm_data_module.data)

  -- Create a reference function for memory (resolved after instantiation)
  local instance_ref = {inst = nil}
  local function memory_ref()
    return instance_ref.inst.memory
  end

  -- Create host import functions (pass instance_ref for invoke_* re-entrancy)
  local opts = {environ = build_nethack_environ()}
  local imports = Bridge.create_imports(memory_ref, instance_ref, opts)

  -- Instantiate the WASM module
  local instance = WasmInterp.instantiate(module, imports, compiled_sources)
  instance_ref.inst = instance

  -- Link mutable state to storage so Factorio's save persists it automatically.
  -- These are SHARED references: writes via the instance update storage directly.
  local ws = storage.wasm_state
  ws.memory_data = instance.memory.data
  ws.memory_pages = instance.memory.page_count
  ws.memory_max_pages = instance.memory.max_pages
  ws.globals = instance.globals
  ws.tables = instance.tables
  ws.table_sizes = instance.table_sizes
  ws.active = true

  return instance
end

-- The active WASM instance (not serializable, kept in upvalue)
-- Declared here so snapshot/restore functions can see it as an upvalue.
local wasm_instance = nil

-- Restore WASM instance from saved state in storage (called from on_load)
local function restore_wasm_instance()
  local ws = storage.wasm_state

  -- Re-parse the WASM binary
  local module = WasmInit.parse(wasm_data_module.data)

  -- Create import functions (closures only — not called until event handlers)
  local instance_ref = {inst = nil}
  local function memory_ref()
    return instance_ref.inst.memory
  end
  local opts = {environ = build_nethack_environ()}
  local imports = Bridge.create_imports(memory_ref, instance_ref, opts)

  -- Instantiate in restore mode (skips segment init + _start, uses saved state)
  local instance = WasmInterp.instantiate(module, imports, compiled_sources, ws)
  instance_ref.inst = instance

  -- Restore VFS: overlay on top of immutable nethack_data
  local ok_data, nethack_data = pcall(require, "scripts.nethack_data")
  if not ok_data then nethack_data = {} end
  instance._vfs = {
    files = setmetatable({}, {__index = nethack_data}),
    fds = ws.vfs_fds or {},
    next_fd = ws.vfs_next_fd or 4,
  }
  for k, v in pairs(ws.vfs_overlay or {}) do
    instance._vfs.files[k] = v
  end

  -- Restore execution state from snapshot
  WasmInterp.restore_exec(instance, ws.exec_snapshot)

  return instance
end

-- Snapshot WASM state to storage (called after every run_and_process)
local function snapshot_wasm_state()
  if not wasm_instance then return end
  local ws = storage.wasm_state
  if not ws then return end

  -- Sync memory metadata (data table is already shared)
  ws.memory_pages = wasm_instance.memory.page_count
  ws.memory_max_pages = wasm_instance.memory.max_pages

  -- Snapshot exec state
  ws.exec_snapshot = WasmInterp.snapshot_exec(wasm_instance)
  ws.ctx_sbs = wasm_instance.ctx and wasm_instance.ctx.__sbs
  ws.total_instructions = wasm_instance.total_instructions

  -- Sync VFS state
  if wasm_instance._vfs then
    -- Flush open writable fds to files table
    for _, entry in pairs(wasm_instance._vfs.fds) do
      if entry.writable and entry.name then
        wasm_instance._vfs.files[entry.name] = entry.data
      end
    end
    -- Save overlay (only files explicitly set, not inherited from nethack_data)
    local overlay = {}
    for k, v in pairs(wasm_instance._vfs.files) do
      overlay[k] = v
    end
    ws.vfs_overlay = overlay
    ws.vfs_fds = wasm_instance._vfs.fds
    ws.vfs_next_fd = wasm_instance._vfs.next_fd
  end

  -- Sync segment drop state
  ws.dropped_data_segs = wasm_instance.data_segments_raw
  ws.dropped_elem_segs = wasm_instance.element_segments_raw
end

---------------------------------------------------------------------------
-- Interpreter Execution
---------------------------------------------------------------------------

-- Factorio direction enum → NH vi-key codes
local GOD_DIR_TO_KEY = {
  [defines.direction.north]     = string.byte("k"),
  [defines.direction.northeast] = string.byte("u"),
  [defines.direction.east]      = string.byte("l"),
  [defines.direction.southeast] = string.byte("n"),
  [defines.direction.south]     = string.byte("j"),
  [defines.direction.southwest] = string.byte("b"),
  [defines.direction.west]      = string.byte("h"),
  [defines.direction.northwest] = string.byte("y"),
}

-- Clamp a position to within a tile's boundaries (for blocking movement).
local function clamp_to_tile(player_pos, tile_x, tile_y)
  local eps = 0.05
  local tx = math.max(tile_x + eps, math.min(tile_x + 1 - eps, player_pos.x))
  local ty = math.max(tile_y + eps, math.min(tile_y + 1 - eps, player_pos.y))
  return tx, ty
end

-- Correct Factorio player position if it doesn't match NetHack's @ position.
-- During travel (state.travel_active), snaps to tile center every tick.
-- During normal play (awaiting input), clamps to nearest tile edge.
local function update_player_position()
  local state = storage.nh_main
  if not state then return end

  local is_travel = state.travel_active
  if not state.awaiting_input and not is_travel then return end

  -- Travel finished — clear flag but still center-snap this final frame
  if is_travel and state.awaiting_input then
    state.travel_active = false
  end

  local player = game.connected_players[1]
  if not player then return end

  local pos = Display.get_player_pos()
  local surface = Display.get_current_surface()
  if not surface or not pos then return end

  local cur_x = math.floor(player.position.x)
  local cur_y = math.floor(player.position.y)
  if cur_x == pos.x and cur_y == pos.y and player.surface == surface then
    return  -- already in the right tile
  end

  local tx, ty
  if is_travel then
    -- Center on tile during travel animation
    tx = pos.x + 0.5
    ty = pos.y + 0.5
  else
    -- Clamp to nearest edge for walking (feels natural)
    tx, ty = clamp_to_tile(player.position, pos.x, pos.y)
  end
  player.teleport({x = tx, y = ty}, surface)
end

-- Update the engine state GUI (loading bar + corner widget).
-- Called after every run_and_process to reflect current state.
local function update_engine_gui()
  local state = storage.nh_main
  if not state or not state.game_started then return end

  local instructions = wasm_instance and wasm_instance.total_instructions or 0

  -- Determine engine state and color
  local engine_state, color
  if state.awaiting_input then
    -- First time reaching a non-startup input = loading complete.
    -- The plsel dialog appears during startup before the first level is
    -- rendered, so don't count it as "loaded".
    if not state.first_input_received and state.input_type ~= "plsel" then
      state.first_input_received = true
      Gui.destroy_loading_bar()
      -- Track getch count to show tips after the intro "--More--" is dismissed
      state.getch_count = 1
    elseif state.getch_count and state.input_type == "getch" then
      state.getch_count = state.getch_count + 1
      if state.getch_count == 2 then
        state.getch_count = nil  -- done tracking
        local player = game.connected_players[1]
        if player then
          Gui.show_tips_popup(player)
        end
      end
    end
    local sub = state.input_type
    if sub == "getch" then engine_state = "Waiting for command"
    elseif sub == "yn" then engine_state = "Waiting for Y/N"
    elseif sub == "getlin" then engine_state = "Waiting for text"
    elseif sub == "menu" then engine_state = "Waiting for selection"
    elseif sub == "plsel" then engine_state = "Character selection"
    else engine_state = "Waiting for input" end
    color = {r = 0.3, g = 0.9, b = 0.3}
  elseif state.running then
    if state.first_input_received then
      engine_state = "Executing"
      color = {r = 1, g = 0.6, b = 0.2}
    else
      engine_state = "Loading"
      color = {r = 1, g = 0.9, b = 0.3}
      Gui.update_loading_progress(instructions)
    end
  else
    engine_state = "Stopped"
    color = {r = 0.6, g = 0.6, b = 0.6}
  end

  Gui.update_engine_state(engine_state, instructions, color)
  local show_cancel = state.awaiting_input and state.input_type ~= nil
                      and state.input_type ~= "getch" and state.input_type ~= "plsel"
  Gui.set_cancel_visible(show_cancel)
end

-- Run the interpreter, automatically draining the input queue.
--
-- The input protocol:
--   host_nhgetch is the ONLY getch-style blocking import. When it blocks,
--   we check for queued inputs (from getlin/menu) and auto-feed them.
--   If the queue is empty, we check bridge state for pending prompts
--   (yn_function / getlin set these non-blockingly before nhgetch is called).
--   host_select_menu also blocks (returns count); subsequent nhgetch calls
--   get selection IDs from the queue.
local function run_and_process(max_instructions)
  local state = storage.nh_main
  if not wasm_instance or not state.running then return end

  -- Cancel any pending hover describe — game execution will clobber shared WASM memory
  Bridge.cancel_describe(wasm_instance)

  local auto_feed_count = 0
  while true do
    local result = WasmInterp.run(wasm_instance, max_instructions)

    if result.status == "waiting_input" then
      -- Auto-feed from input queue if available
      if #state.input_queue > 0 then
        auto_feed_count = auto_feed_count + 1
        if auto_feed_count > 200 then
          -- Safety: too many consecutive auto-feeds, likely an infinite loop.
          -- Break and let on_tick resume later.
          state.awaiting_input = false
          break
        end
        local value = table.remove(state.input_queue, 1)
        WasmInterp.provide_input(wasm_instance, value)
        max_instructions = MAX_INSTRUCTIONS_PER_RUN
        -- continue loop to keep executing
      else
        -- No queued input - determine what UI to show
        state.awaiting_input = true

        local continue_loop = false

        if result.input_type == "menu" then
          -- host_select_menu blocked - show menu GUI
          state.input_type = "menu"
          state.input_info = result
          local player = game.connected_players[1]
          if player then
            Gui.show_menu(player, result.winid, result.how)
          end

        elseif result.input_type == "plsel" then
          -- host_plsel_show blocked - show player selection dialog
          state.input_type = "plsel"
          state.input_info = nil
          local player = game.connected_players[1]
          if player then
            Gui.show_plsel_dialog(player)
          end

        elseif result.input_type == "getch" then
          -- host_nhgetch blocked - check for pending prompts set by
          -- the non-blocking host_yn_function / host_getlin imports
          local bridge = storage.nh_bridge or {}

          if bridge.pending_yn then
            state.input_type = "yn"
            state.input_info = bridge.pending_yn
            local player = game.connected_players[1]
            if player then
              Gui.show_yn_prompt(player, bridge.pending_yn.query,
                                 bridge.pending_yn.resp, bridge.pending_yn.def)
            end

          elseif bridge.pending_getlin then
            -- Auto-respond if this is an extended command from the menu bar
            if state.pending_ext_command then
              local ext = state.pending_ext_command
              state.pending_ext_command = nil
              state.awaiting_input = false
              bridge.pending_getlin = nil
              -- Queue ext command chars + null terminator directly
              for ci = 1, #ext do
                state.input_queue[#state.input_queue + 1] = string.byte(ext, ci)
              end
              state.input_queue[#state.input_queue + 1] = 0
              -- Feed first char and continue the run loop (no break)
              local first = table.remove(state.input_queue, 1)
              WasmInterp.provide_input(wasm_instance, first)
              continue_loop = true
            else
              state.input_type = "getlin"
              state.input_info = bridge.pending_getlin
              local player = game.connected_players[1]
              if player then
                Gui.show_getlin_prompt(player, bridge.pending_getlin.prompt)
              end
            end

          else
            -- Regular getch: waiting for direction/command key
            state.input_type = "getch"
            state.input_info = nil
          end
        end

        if not continue_loop then
          break  -- exit loop, wait for user input
        end
      end

    elseif result.status == "running" then
      -- Hit instruction limit, still executing (e.g., level generation)
      state.awaiting_input = false
      break

    elseif result.status == "finished" then
      state.running = false
      state.awaiting_input = false
      Gui.add_message("NetHack has ended.", 0)
      local player = game.connected_players[1]
      if player and player.character then
        player.character.die()
      end
      break

    elseif result.status == "error" then
      state.running = false
      state.awaiting_input = false
      local msg = result.message
      if type(msg) == "table" then msg = msg.msg or serpent.line(msg) end
      Gui.add_message("NetHack error: " .. (msg or "unknown"), 0)
      break
    end
  end

  -- Snapshot WASM state to storage for save/load persistence
  snapshot_wasm_state()
end

---------------------------------------------------------------------------
-- Starting a NetHack game
---------------------------------------------------------------------------

local function start_nethack(player)
  local state = storage.nh_main

  -- Load and instantiate WASM
  wasm_instance = load_wasm_nethack()

  -- Create the first dungeon level surface
  Display.get_or_create_level(state.current_level)
  Display.switch_level(state.current_level, player)

  -- Create GUI for the player
  Gui.create_player_gui(player)
  Gui.create_loading_bar(player)

  -- Slow the player down so tile-based movement feels right
  if player.character then
    player.character.character_running_speed_modifier = -0.4
  end

  -- Zoom in so each NetHack tile is clearly visible
  player.zoom = 2.0

  -- Start NetHack by calling _start (WASI entry point)
  local start_idx = WasmInterp.get_export(wasm_instance, "_start")

  if not start_idx then
    Gui.add_message("Error: Could not find _start in WASM module", 0)
    return
  end

  -- Begin execution - _start takes no args (argc/argv via WASI args_get)
  WasmInterp.call(wasm_instance, start_idx, {})
  state.running = true
  state.game_started = true

  -- Run until we hit nhgetch (waiting for first input)
  run_and_process(MAX_INSTRUCTIONS_PER_RUN)
  update_engine_gui()
  update_player_position()

end

---------------------------------------------------------------------------
-- Input Handling
---------------------------------------------------------------------------

-- Clear all pending input/prompt state. Called by all advance_turn* functions
-- and on_click_move to reset for the next interpreter run.
local function clear_input_state()
  local state = storage.nh_main
  state.awaiting_input = false
  state.input_type = nil
  state.input_info = nil
  if storage.nh_bridge then
    storage.nh_bridge.pending_yn = nil
    storage.nh_bridge.pending_getlin = nil
    storage.nh_bridge.auto_fed_inventory = nil
  end
  if storage.nh_gui then
    storage.nh_gui.pending_yn = nil
  end
end

-- Common helper for all advance_turn variants: guards, clears state, provides
-- input, runs the interpreter, and updates the GUI/position.
local function do_advance(input_value, skip_position_update)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end
  state.last_advance_tick = game.tick
  clear_input_state()
  WasmInterp.provide_input(wasm_instance, input_value)
  run_and_process(MAX_INSTRUCTIONS_PER_RUN)
  update_engine_gui()
  if not skip_position_update then
    update_player_position()
  end
end

-- Provide a key input to the interpreter and resume execution.
-- Used for getch (direction/command) and yn (single key answer).
local function advance_turn(key_code)
  do_advance(key_code)
end

-- Provide string input (for getlin).
-- The C code reads the response character-by-character via host_nhgetch,
-- so we queue all characters + null terminator and let run_and_process drain.
local function advance_turn_string(text)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end

  -- Queue characters for nhgetch to consume one-by-one
  local queue = state.input_queue
  if text == "\027" then
    queue[#queue + 1] = 27  -- ESC = cancel
  else
    for i = 1, #text do
      queue[#queue + 1] = string.byte(text, i)
    end
  end
  queue[#queue + 1] = 0  -- null terminator ends the getlin loop

  -- Feed first character via do_advance, run_and_process drains the rest
  do_advance(table.remove(state.input_queue, 1))
end

-- Provide menu selection result.
-- host_select_menu is blocking and returns the count. Then the C code calls
-- host_nhgetch to get each selection identifier. We queue the IDs.
local function advance_turn_menu(result)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end

  local count
  if result and result.cancelled then
    count = -1
  elseif result and result.selections and #result.selections > 0 then
    count = #result.selections
    -- Queue selection IDs for subsequent nhgetch calls
    for _, sel in ipairs(result.selections) do
      state.input_queue[#state.input_queue + 1] = sel.identifier
    end
  else
    count = 0
  end

  do_advance(count)
end

-- Provide player selection dialog result.
-- host_plsel_show is blocking and returns a status (0=play, -1=quit).
-- Then the C code calls host_nhgetch to get name chars + null + 4 selection indices.
local function advance_turn_plsel(result)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end

  if result.action == "quit" then
    -- Provide -1 status; C code will call clearlocks + exit
    do_advance(-1, true)  -- no position update on quit
    return
  end

  -- Play: queue name chars + null + 4 selection indices
  local queue = state.input_queue
  local name = result.name or "Player"
  for i = 1, #name do
    queue[#queue + 1] = string.byte(name, i)
  end
  queue[#queue + 1] = 0  -- null terminator ends askname's read loop

  -- Selection indices (or -1 for random)
  queue[#queue + 1] = result.role >= 0 and result.role or -1
  queue[#queue + 1] = result.race >= 0 and result.race or -1
  queue[#queue + 1] = result.gend >= 0 and result.gend or -1
  queue[#queue + 1] = result.align >= 0 and result.align or -1

  do_advance(0)  -- status 0 = play
end

-- God mode movement: called from on_tick. Reads walking_state direction
-- and sends NH commands with a cooldown (~10 ticks = ~6 moves/sec).
local function god_mode_movement()
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if state.input_type ~= "getch" then return end

  local player = game.connected_players[1]
  if not player or player.character then return end  -- only in god mode

  local ws = player.walking_state
  if not ws or not ws.walking then return end

  local inp = storage.nh_input
  if inp.god_move_cooldown and game.tick < inp.god_move_cooldown then return end

  local key = GOD_DIR_TO_KEY[ws.direction]
  if not key then return end

  inp.god_move_cooldown = game.tick + 10

  Input.set_processing(true)
  advance_turn(key)
  Input.set_processing(false)
end

-- Toggle between Factorio character mode and NH sprite mode.
-- Factorio mode: engineer visible, NH hero entity hidden.
-- NH sprite mode: god mode (no body), NH hero entity visible.
local function toggle_player_mode(player)
  local mode = Display.get_player_mode()
  if mode == "factorio" then
    -- Switch to NH sprite mode: save character, enter god mode
    local char = player.character
    player.set_controller{type = defines.controllers.god}
    if char and char.valid then
      -- Teleport detached character far off-screen so it's not visible
      char.teleport({x = -1000, y = -1000})
    end
    storage.nh_main.saved_character = char
    Display.set_player_mode("nethack")
  else
    -- Switch back to Factorio character mode
    local pos = Display.get_player_pos()
    local surface = Display.get_current_surface()
    local char = storage.nh_main.saved_character
    if char and char.valid and pos and surface then
      char.teleport({x = pos.x + 0.5, y = pos.y + 0.5}, surface)
      player.set_controller{type = defines.controllers.character, character = char}
    end
    storage.nh_main.saved_character = nil
    Display.set_player_mode("factorio")
  end
end

---------------------------------------------------------------------------
-- Event Handlers
---------------------------------------------------------------------------

-- Player movement -> NetHack direction
-- Compares player's Factorio tile to NetHack's @ position directly.
-- Within the same tile: no action. Cross a tile boundary: trigger move.
-- Only teleports on mismatch (wall, trap, etc.) via update_player_position.
local function on_player_changed_position(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if Input.is_processing() then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  -- God mode: lock camera to hero position, use walking_state for direction.
  -- Movement is handled in on_tick via god_mode_movement() instead.
  if not player.character then
    local nh_pos = Display.get_player_pos()
    local surface = Display.get_current_surface()
    if nh_pos and surface then
      player.teleport({x = nh_pos.x + 0.5, y = nh_pos.y + 0.5}, surface)
    end
    return
  end

  -- While game is processing a turn, clamp player to current @ tile
  if not state.awaiting_input then
    local nh_pos = Display.get_player_pos()
    local surface = Display.get_current_surface()
    if nh_pos and surface then
      local tx, ty = clamp_to_tile(player.position, nh_pos.x, nh_pos.y)
      player.teleport({x = tx, y = ty}, surface)
    end
    return
  end

  -- For non-getch prompts (yn, menu, getlin, plsel), block movement
  if state.input_type ~= "getch" then
    player.walking_state = {walking = false, direction = defines.direction.north}
    local nh_pos = Display.get_player_pos()
    local surface = Display.get_current_surface()
    if nh_pos and surface then
      local tx, ty = clamp_to_tile(player.position, nh_pos.x, nh_pos.y)
      player.teleport({x = tx, y = ty}, surface)
    end
    return
  end

  local nh_pos = Display.get_player_pos()
  if not nh_pos then return end

  local new_x = math.floor(player.position.x)
  local new_y = math.floor(player.position.y)
  local dx = new_x - nh_pos.x
  local dy = new_y - nh_pos.y

  -- Still within the same tile as @, do nothing
  if dx == 0 and dy == 0 then return end

  -- Crossed tile boundary - send direction to NetHack (direction_to_key clamps)
  local key = Input.direction_to_key(dx, dy)
  if not key then return end

  -- Debounce: if same direction was recently attempted and @ hasn't moved,
  -- throttle to every 30 ticks (~500ms) instead of 60/s.
  local inp = storage.nh_input
  local dir_key = dx .. "," .. dy

  -- Clear debounce if @ has moved since last attempt (move succeeded, possibly
  -- over multiple ticks of WASM execution)
  if inp.last_move_pos_x ~= nh_pos.x or inp.last_move_pos_y ~= nh_pos.y then
    inp.last_move_dir = nil
    inp.last_move_tick = nil
  end

  if inp.last_move_dir == dir_key and inp.last_move_tick then
    if game.tick - inp.last_move_tick < 30 then
      update_player_position()
      return
    end
  end

  inp.last_move_dir = dir_key
  inp.last_move_tick = game.tick
  inp.last_move_pos_x = nh_pos.x
  inp.last_move_pos_y = nh_pos.y

  Input.set_processing(true)
  advance_turn(key)
  Input.set_processing(false)
end

-- Custom input: non-movement commands
-- Handles getch, yn, menu (ESC + accelerators), and getlin (ESC) states.
local function on_custom_input(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end

  local key = Input.custom_input_to_key(event.input_name)
  if not key then return end

  -- Guard: nh-menu-* and nh-apply/nh-eat/etc. share ALT+letter bindings,
  -- so Factorio fires both events in the same tick. Skip menu-letter events
  -- if advance_turn already ran this tick (it already processed the command).
  if event.input_name:match("^nh%-menu%-") and state.last_advance_tick == game.tick then
    return
  end

  local player = game.get_player(event.player_index)

  -- ESC cancels menus and getlin prompts
  if key == 27 then
    if state.input_type == "menu" then
      Gui.destroy_modal(player, "nh_menu_frame", "pending_menu")
      advance_turn_menu({cancelled = true, selections = {}})
      return
    elseif state.input_type == "getlin" then
      Gui.destroy_modal(player, "nh_getlin_frame", "pending_getlin")
      advance_turn_string("\027")
      return
    end
  end

  -- Keyboard accelerators for menus (PICK_ONE select, PICK_ANY toggle)
  if state.input_type == "menu" then
    local result = Gui.handle_menu_key(player, key)
    if result then
      advance_turn_menu(result)
    end
    return
  end

  -- Only getch and yn accept general keyboard input
  if state.input_type ~= "getch" and state.input_type ~= "yn" then return end

  -- For yn prompts, close the GUI before advancing
  if state.input_type == "yn" then
    Gui.destroy_modal(player, "nh_yn_frame")
  end

  advance_turn(key)
end

-- GUI click handler
local function on_gui_click(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end

  local player = game.get_player(event.player_index)
  if not player then return end
  local element = event.element
  if not element or not element.valid then return end

  -- Tips popup dismiss
  if element.name == "nh_tips_ok" then
    Gui.destroy_tips_popup(player)
    return
  end

  -- Text window close: works in any state so it can't block other dialogs
  if element.name:match("^nh_close_text_") then
    local winid = tonumber(element.name:match("nh_close_text_(%d+)"))
    -- Check if the window data still exists (destroy_nhwindow not yet called by C).
    -- If it does, nhgetch is waiting to dismiss this window — advance with space.
    -- If nil, the C code already called destroy_nhwindow (display_file pattern) and
    -- the current nhgetch is for the next game command — don't auto-advance.
    local win_exists = winid and storage.nh_gui and storage.nh_gui.windows[winid]
    if winid then
      Gui.destroy_window(winid)
    end
    if win_exists and state.input_type == "getch" then
      advance_turn(string.byte(" "))
    end
    return
  end

  -- Cancel button -> ESC (same as pressing Escape key)
  if element.name == "nh_cancel" then
    if state.input_type == "menu" then
      Gui.destroy_modal(player, "nh_menu_frame", "pending_menu")
      advance_turn_menu({cancelled = true, selections = {}})
    elseif state.input_type == "getlin" then
      Gui.destroy_modal(player, "nh_getlin_frame", "pending_getlin")
      advance_turn_string("\027")
    elseif state.input_type == "yn" then
      Gui.destroy_modal(player, "nh_yn_frame")
      advance_turn(27)
    else
      advance_turn(27)
    end
    return
  end

  -- Player selection dialog
  if state.input_type == "plsel" then
    local result = Gui.handle_plsel_click(player, element.name)
    if result then
      advance_turn_plsel(result)
    end
    return
  end

  -- Toolbar button -> key code
  local tb_key = Gui.handle_toolbar_click(element.name)
  if tb_key then
    if state.input_type == "getch" or state.input_type == "yn" then
      if state.input_type == "yn" then
        Gui.destroy_modal(player, "nh_yn_frame")
      end
      advance_turn(tb_key)
    end
    return
  end

  -- yn_function response
  if state.input_type == "yn" then
    local key = Gui.handle_yn_click(player, element.name)
    if key then
      advance_turn(key)
    end
    return
  end

  -- getlin response
  if state.input_type == "getlin" then
    local text = Gui.handle_getlin_click(player, element.name)
    if text then
      advance_turn_string(text)
    end
    return
  end

  -- Menu response
  if state.input_type == "menu" then
    local result = Gui.handle_menu_click(player, element.name)
    if result then
      advance_turn_menu(result)
    end
    return
  end

end

-- on_tick: continue execution if interpreter is running but not waiting for input
local function on_tick(event)
  local state = storage.nh_main
  if not state then return end

  -- Handle pending game start (delayed by 1 tick for initialization)
  if state.pending_start then
    local player = game.get_player(state.pending_start)
    state.pending_start = nil
    if player then
      start_nethack(player)
    end
    return
  end

  -- Continue running if not waiting for input (e.g., level generation)
  if state.running and not state.awaiting_input then
    local budget = MAX_INSTRUCTIONS_PER_TICK
    if state.travel_active then budget = budget * 4 end
    run_and_process(budget)
    update_engine_gui()
    update_player_position()
  end

  -- God mode: poll walking_state for movement input
  god_mode_movement()

  -- Continue pending hover describe (runs alongside game, 20k budget per tick)
  if Bridge._pending_describe and wasm_instance then
    local player_index = Bridge._pending_describe.player_index
    local result = Bridge.continue_describe(wasm_instance, 20000)
    if result and player_index then
      local player = game.get_player(player_index)
      if player then
        Gui.update_hover_info(player, result)
      end
    end
  end

end

---------------------------------------------------------------------------
-- Remote Interface (for console/MCP debugging)
---------------------------------------------------------------------------

remote.add_interface("nethack", {
  get_storage = function() return storage end,
  get_display = function() return storage.nh_display end,
  get_bridge = function() return storage.nh_bridge end,
  get_main = function() return storage.nh_main end,
  get_input = function() return storage.nh_input end,
})

---------------------------------------------------------------------------
-- Lifecycle Events
---------------------------------------------------------------------------

script.on_init(function()
  local freeplay = remote.interfaces["freeplay"]
  if freeplay then
    if freeplay["set_skip_intro"] then remote.call("freeplay", "set_skip_intro", true) end
    if freeplay["set_disable_crashsite"] then remote.call("freeplay", "set_disable_crashsite", true) end
  end
  init_modules()
end)

script.on_load(function()
  -- WASM modules are loaded at require time (top of file).
  -- Rebuild the WASM instance from saved state in storage.
  if storage.wasm_state and storage.wasm_state.active
     and storage.wasm_state.exec_snapshot then
    wasm_instance = restore_wasm_instance()
  end
end)

script.on_configuration_changed(function()
  -- Mod versions changed — WASM binary may have changed, invalidating saved state.
  -- Clear WASM state so the game starts fresh.
  if storage.wasm_state and storage.wasm_state.active then
    storage.wasm_state.active = false
    storage.wasm_state.exec_snapshot = nil
    wasm_instance = nil
    if storage.nh_main then
      storage.nh_main.game_started = false
      storage.nh_main.running = false
      storage.nh_main.awaiting_input = false
    end
  end
  init_modules()
end)

script.on_event(defines.events.on_player_created, function(event)
  init_modules()
  local state = storage.nh_main
  if not state.game_started then
    state.pending_start = event.player_index
  end
end)

-- Textfield Enter key (for getlin prompt submission)
local function on_gui_confirmed(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if state.input_type ~= "getlin" then return end

  local element = event.element
  if not element or not element.valid then return end
  if element.name ~= "nh_getlin_textfield" then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local text = element.text or ""
  Gui.destroy_modal(player, "nh_getlin_frame", "pending_getlin")
  advance_turn_string(text)
end

-- Dropdown selection change (menu bar dropdowns)
local function on_gui_selection_state_changed(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end

  local player = game.get_player(event.player_index)
  if not player then return end
  local element = event.element
  if not element or not element.valid then return end

  -- Menu bar dropdown selection
  local btn_key, ext_cmd, action = Gui.handle_menubar_selection(element)

  -- Handle special actions (not NetHack key input)
  if action == "toggle_player_mode" then
    toggle_player_mode(player)
    return
  end

  if btn_key then
    if state.input_type == "getch" or state.input_type == "yn" then
      if state.input_type == "yn" then
        Gui.destroy_modal(player, "nh_yn_frame")
      end
      if ext_cmd then
        state.pending_ext_command = ext_cmd
      end
      advance_turn(btn_key)
    end
    return
  end
end

-- Checkbox state change (for plsel radio-button mutual exclusion)
local function on_gui_checked_state_changed(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if state.input_type ~= "plsel" then return end

  local player = game.get_player(event.player_index)
  if not player then return end
  local element = event.element
  if not element or not element.valid then return end

  Gui.handle_plsel_checkbox(player, element.name, element.state)
end

-- Click-to-travel: left click on a distant tile triggers NetHack's travel command.
-- Uses player.selected to get the world position of the clicked entity.
-- Does NOT call advance_turn (which runs 50K instructions synchronously).
-- Instead, provides input and lets on_tick animate travel step-by-step.
local function on_click_move(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if state.input_type ~= "getch" then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local entity = player.selected
  if not entity or not entity.valid then return end

  -- Only handle NetHack entities
  local name = entity.name
  if not name:find("^nh%-") then return end

  -- Convert entity position to NetHack grid coordinates
  local gx = math.floor(entity.position.x)
  local gy = math.floor(entity.position.y)

  -- Check distance from current @ position
  local nh_pos = Display.get_player_pos()
  if not nh_pos then return end

  local dx = math.abs(gx - nh_pos.x)
  local dy = math.abs(gy - nh_pos.y)

  -- Adjacent click: send direction key (for movement and "In what direction?" prompts)
  if dx <= 1 and dy <= 1 then
    local dir_dx = gx - nh_pos.x
    local dir_dy = gy - nh_pos.y
    if dir_dx == 0 and dir_dy == 0 then return end  -- same tile, ignore
    local key = Input.direction_to_key(dir_dx, dir_dy)
    if key then
      advance_turn(key)
    end
    return
  end

  -- Store click data for the C-side nh_poskey to read
  Bridge.get_state().pending_click = {x = gx, y = gy, mod = 1}  -- CLICK_1 = 1

  -- Flag travel mode so update_player_position snaps to center each tick
  state.travel_active = true

  clear_input_state()

  -- Provide input 0 (click signal) — on_tick will run the interpreter
  WasmInterp.provide_input(wasm_instance, 0)
  update_engine_gui()

  -- Cancel Factorio walking to prevent the position-change handler
  -- from sending unwanted direction keys after travel completes
  if player.character then
    player.walking_state = {walking = false, direction = defines.direction.north}
  end
end

-- Hover tooltip: describe tile under cursor using NetHack's lookat()
local function on_selected_entity_changed(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if not wasm_instance then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local entity = player.selected
  if not entity or not entity.valid then
    Gui.update_hover_info(player, nil)
    return
  end

  -- Only describe NetHack entities
  local name = entity.name
  if not name:find("^nh%-") then
    Gui.update_hover_info(player, nil)
    return
  end

  -- Convert entity position to NetHack grid coordinates
  local gx = math.floor(entity.position.x)
  local gy = math.floor(entity.position.y)

  local description = Bridge.describe_pos(wasm_instance, gx, gy, true, entity.name, 20000)
  Gui.update_hover_info(player, description)
  -- If describe didn't finish, store player index for tick-based continuation
  if not description and Bridge._pending_describe then
    Bridge._pending_describe.player_index = event.player_index
  end
end

script.on_event(defines.events.on_player_changed_position, on_player_changed_position)
script.on_event(defines.events.on_gui_click, on_gui_click)
script.on_event(defines.events.on_gui_confirmed, on_gui_confirmed)
script.on_event(defines.events.on_gui_selection_state_changed, on_gui_selection_state_changed)
script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked_state_changed)
script.on_event(defines.events.on_selected_entity_changed, on_selected_entity_changed)
script.on_event(defines.events.on_tick, on_tick)
script.on_event("nh-click-move", on_click_move)

-- Rebuild GUI when display resolution or scale changes (also fires shortly after
-- on_player_created with the real resolution, replacing the default 1920x1080)
local function on_display_changed(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  Gui.create_player_gui(player)
  -- Recreate loading bar or plsel dialog if startup hasn't finished yet
  -- (create_player_gui destroys all screen elements including nh_loading_frame/nh_plsel_frame)
  if not state.first_input_received then
    if state.awaiting_input and state.input_type == "plsel" then
      Gui.show_plsel_dialog(player)
    else
      Gui.create_loading_bar(player)
    end
  end
  update_engine_gui()
end
script.on_event(defines.events.on_player_display_resolution_changed, on_display_changed)
script.on_event(defines.events.on_player_display_scale_changed, on_display_changed)

-- Register all custom input events
for _, input_name in ipairs(Input.get_custom_input_names()) do
  script.on_event(input_name, on_custom_input)
end

---------------------------------------------------------------------------
-- Secondary WASM call helper (for cheat commands, etc.)
-- Executes a WASM export while the game is paused at nhgetch.
-- Saves/restores exec state + stack pointer (same pattern as describe_pos).
---------------------------------------------------------------------------

local function execute_wasm_cheat(export_name, args, max_instructions)
  if not wasm_instance or not wasm_instance.exec then return false end

  max_instructions = max_instructions or 5000000

  local idx = WasmInterp.get_export(wasm_instance, export_name)
  if not idx then
    Gui.add_message("Error: WASM export '" .. export_name .. "' not found", 0)
    return false
  end

  -- Cancel any pending hover describe
  Bridge.cancel_describe(wasm_instance)

  -- Save current execution state and stack pointer
  local saved_exec = wasm_instance.exec
  local saved_sp = wasm_instance.globals[0]

  local ok, err = pcall(function()
    WasmInterp.call(wasm_instance, idx, args or {})
    WasmInterp.run(wasm_instance, max_instructions)
  end)

  if not ok then
    wasm_instance.exec = saved_exec
    wasm_instance.globals[0] = saved_sp
    Gui.add_message("Error executing " .. export_name .. ": " .. tostring(err), 0)
    return false
  end

  local finished = wasm_instance.exec.finished

  -- Restore game execution state
  wasm_instance.exec = saved_exec
  wasm_instance.globals[0] = saved_sp

  if not finished then
    Gui.add_message("Warning: " .. export_name .. " didn't finish within budget", 0)
    return false
  end

  return true
end

---------------------------------------------------------------------------
-- Console command: /nethack <chars> | /nethack revealall
-- Usage: /nethack * or /nethack abc to send characters to NetHack
---------------------------------------------------------------------------

commands.add_command("nethack", "Send character(s) or cheat commands to NetHack. Usage: /nethack <chars> | /nethack revealall", function(cmd)
  local str = cmd.parameter
  local state = storage.nh_main
  if not state or not state.game_started then
    game.print("NetHack not running")
    return
  end
  if not wasm_instance then
    game.print("No WASM instance")
    return
  end

  -- Handle cheat subcommands
  if str == "revealall" then
    if not state.awaiting_input then
      game.print("NetHack must be waiting for input")
      return
    end
    -- Clear display grid cache so all print_glyph calls take effect immediately
    local disp = storage.nh_display
    if disp.current_level and disp.levels[disp.current_level] then
      disp.levels[disp.current_level].grid = {}
    end
    if execute_wasm_cheat("nh_reveal_all_full", {}) then
      Gui.add_message("Cheat: entire dungeon level revealed!", 0)
    end
    return
  end

  if not state.awaiting_input then
    game.print("NetHack not waiting for input")
    return
  end

  if not str or #str == 0 then
    game.print("Usage: /nethack <char>  (e.g. /nethack * or /nethack abc)")
    return
  end

  -- Queue all characters, advance with the first
  local queue = state.input_queue
  for i = 2, #str do
    queue[#queue + 1] = string.byte(str, i)
  end
  advance_turn(string.byte(str, 1))
end)

---------------------------------------------------------------------------
-- Public API (for bridge callbacks)
---------------------------------------------------------------------------

function M.get_wasm_instance()
  return wasm_instance
end

return M
