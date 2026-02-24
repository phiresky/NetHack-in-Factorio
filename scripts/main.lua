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

-- These will be loaded when the game starts
local WasmInit   -- scripts.wasm.init
local WasmInterp -- scripts.wasm.interp

local M = {}

-- Maximum WASM instructions to execute per run() call
local MAX_INSTRUCTIONS_PER_RUN = 50000

-- Maximum instructions per tick (for background processing like level gen)
local MAX_INSTRUCTIONS_PER_TICK = 10000

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
    }
  end
  if not storage.nh_main.input_queue then
    storage.nh_main.input_queue = {}
  end
end

-- Load WASM interpreter modules (called at load time)
local function load_wasm_modules()
  WasmInit = require("scripts.wasm.init")
  WasmInterp = require("scripts.wasm.interp")
end

-- Load and instantiate the WASM NetHack module
local function load_wasm_nethack()
  local wasm_data_module = require("scripts.nethack_wasm")

  load_wasm_modules()

  -- Parse the WASM binary
  local module = WasmInit.parse(wasm_data_module.data)

  -- Create a reference function for memory (resolved after instantiation)
  local instance_ref = {inst = nil}
  local function memory_ref()
    return instance_ref.inst.memory
  end

  -- Create host import functions (pass instance_ref for invoke_* re-entrancy)
  local imports = Bridge.create_imports(memory_ref, instance_ref)

  -- Instantiate the WASM module
  local instance = WasmInterp.instantiate(module, imports)
  instance_ref.inst = instance

  -- Run Emscripten constructors (__wasm_call_ctors) before main
  local ctors_idx = WasmInterp.get_export(instance, "__wasm_call_ctors")
  if ctors_idx then
    WasmInterp.call(instance, ctors_idx, {})
    local result = WasmInterp.run(instance, 10000000)
    if result.status == "error" then
      local msg = result.message
      if type(msg) == "table" then msg = msg.msg or tostring(msg) end
      Gui.add_message("Error in __wasm_call_ctors: " .. tostring(msg), 0)
      return nil
    end
  end

  -- Store instance in a non-serialized location (rebuilt on load)
  storage.nh_main.wasm_instance_id = "active"
  return instance
end

-- The active WASM instance (not serializable, kept in upvalue)
local wasm_instance = nil

---------------------------------------------------------------------------
-- Interpreter Execution
---------------------------------------------------------------------------

-- Update Factorio player position to match where NetHack thinks @ is
local function update_player_position()
  local player = game.connected_players[1]
  if player then
    local pos = Display.get_player_pos()
    local surface = Display.get_current_surface()
    if surface and pos then
      player.teleport({x = pos.x + 0.5, y = pos.y + 0.5}, surface)
      Input.record_position(player.index, pos.x, pos.y)
    end
  end
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

  while true do
    local result = WasmInterp.run(wasm_instance, max_instructions or MAX_INSTRUCTIONS_PER_RUN)

    if result.status == "waiting_input" then
      -- Auto-feed from input queue if available
      if #state.input_queue > 0 then
        local value = table.remove(state.input_queue, 1)
        WasmInterp.provide_input(wasm_instance, value)
        max_instructions = MAX_INSTRUCTIONS_PER_RUN
        -- continue loop to keep executing
      else
        -- No queued input - determine what UI to show
        state.awaiting_input = true

        if result.input_type == "menu" then
          -- host_select_menu blocked - show menu GUI
          state.input_type = "menu"
          state.input_info = result
          local player = game.connected_players[1]
          if player then
            Gui.show_menu(player, result.winid, result.how)
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
            state.input_type = "getlin"
            state.input_info = bridge.pending_getlin
            local player = game.connected_players[1]
            if player then
              Gui.show_getlin_prompt(player, bridge.pending_getlin.prompt)
            end

          else
            -- Regular getch: waiting for direction/command key
            state.input_type = "getch"
            state.input_info = nil
          end
        end
        break  -- exit loop, wait for user input
      end

    elseif result.status == "running" then
      -- Hit instruction limit, still executing (e.g., level generation)
      state.awaiting_input = false
      break

    elseif result.status == "finished" then
      state.running = false
      state.awaiting_input = false
      Gui.add_message("NetHack has ended.", 0)
      break

    elseif result.status == "error" then
      state.running = false
      state.awaiting_input = false
      Gui.add_message("NetHack error: " .. (result.message or "unknown"), 0)
      break
    end
  end
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

  -- Record initial position
  Input.record_position(player.index, 0, 0)

  -- Start NetHack by calling main()
  local main_idx = WasmInterp.get_export(wasm_instance, "__main_argc_argv")
                or WasmInterp.get_export(wasm_instance, "main")
                or WasmInterp.get_export(wasm_instance, "_main")

  if not main_idx then
    Gui.add_message("Error: Could not find main() in WASM module", 0)
    return
  end

  -- Begin execution - call main(0, 0) for argc=0, argv=NULL
  WasmInterp.call(wasm_instance, main_idx, {0, 0})
  state.running = true
  state.game_started = true

  -- Run until we hit nhgetch (waiting for first input)
  run_and_process()
end

---------------------------------------------------------------------------
-- Input Handling
---------------------------------------------------------------------------

-- Provide a key input to the interpreter and resume execution.
-- Used for getch (direction/command) and yn (single key answer).
local function advance_turn(key_code)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end

  state.awaiting_input = false
  state.input_type = nil
  state.input_info = nil

  -- Clear any pending prompt state (yn_function or getlin already consumed)
  if storage.nh_bridge then
    storage.nh_bridge.pending_yn = nil
    storage.nh_bridge.pending_getlin = nil
  end

  WasmInterp.provide_input(wasm_instance, key_code)
  run_and_process()
  update_player_position()
end

-- Provide string input (for getlin).
-- The C code reads the response character-by-character via host_nhgetch,
-- so we queue all characters + null terminator and let run_and_process drain.
local function advance_turn_string(text)
  local state = storage.nh_main
  if not state.awaiting_input or not wasm_instance then return end

  -- Clear pending getlin state
  if storage.nh_bridge then
    storage.nh_bridge.pending_getlin = nil
  end

  -- Queue characters for nhgetch to consume one-by-one
  -- First char goes via provide_input, rest via queue
  local queue = state.input_queue
  if text == "\027" then
    -- ESC = cancel
    queue[#queue + 1] = 27
  else
    for i = 1, #text do
      queue[#queue + 1] = string.byte(text, i)
    end
  end
  queue[#queue + 1] = 0  -- null terminator ends the getlin loop

  state.awaiting_input = false
  state.input_type = nil
  state.input_info = nil

  -- Feed first character, run_and_process drains the rest
  local first = table.remove(state.input_queue, 1)
  WasmInterp.provide_input(wasm_instance, first)
  run_and_process()
  update_player_position()
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

  state.awaiting_input = false
  state.input_type = nil
  state.input_info = nil

  -- Provide count to resume from select_menu; run_and_process feeds IDs via queue
  WasmInterp.provide_input(wasm_instance, count)
  run_and_process()
  update_player_position()
end

---------------------------------------------------------------------------
-- Event Handlers
---------------------------------------------------------------------------

-- Player movement -> NetHack direction
local function on_player_changed_position(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if state.input_type ~= "getch" then return end
  if Input.is_processing() then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local new_x = math.floor(player.position.x)
  local new_y = math.floor(player.position.y)

  local dx, dy = Input.get_movement_delta(event.player_index, new_x, new_y)
  if not dx then
    Input.record_position(event.player_index, new_x, new_y)
    return
  end

  local key = Input.direction_to_key(dx, dy)
  if not key then return end

  -- Teleport player BACK to old position immediately
  Input.set_processing(true)
  local old_pos = Display.get_player_pos()
  player.teleport({x = old_pos.x + 0.5, y = old_pos.y + 0.5})

  advance_turn(key)

  Input.set_processing(false)
end

-- Custom input: non-movement commands
-- Also handles yn prompts (user can press y/n/ESC on keyboard instead of clicking)
local function on_custom_input(event)
  local state = storage.nh_main
  if not state or not state.game_started then return end
  if not state.awaiting_input then return end
  if state.input_type ~= "getch" and state.input_type ~= "yn" then return end

  local key = Input.custom_input_to_key(event.input_name)
  if not key then return end

  -- For yn prompts, close the GUI before advancing
  if state.input_type == "yn" then
    local player = game.get_player(event.player_index)
    if player and player.gui.screen.nh_yn_frame then
      player.gui.screen.nh_yn_frame.destroy()
    end
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

  -- Text window close: send space if waiting for getch (--More--)
  if element.name:match("^nh_close_text_") then
    local winid = tonumber(element.name:match("nh_close_text_(%d+)"))
    if winid then
      Gui.destroy_window(winid)
    end
    if state.input_type == "getch" then
      advance_turn(string.byte(" "))
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
    run_and_process(MAX_INSTRUCTIONS_PER_TICK)
  end
end

---------------------------------------------------------------------------
-- Lifecycle Events
---------------------------------------------------------------------------

script.on_init(function()
  init_modules()
end)

script.on_load(function()
  -- Re-require WASM modules
  local ok, err = pcall(load_wasm_modules)
  if not ok then
    log("Failed to load WASM modules: " .. tostring(err))
  end
  -- Note: WASM instance must be rebuilt from serialized memory on load
  -- This is a known limitation - save/load will restart the game
end)

script.on_configuration_changed(function()
  init_modules()
end)

script.on_event(defines.events.on_player_created, function(event)
  init_modules()
  local state = storage.nh_main
  if not state.game_started then
    state.pending_start = event.player_index
  end
end)

script.on_event(defines.events.on_player_changed_position, on_player_changed_position)
script.on_event(defines.events.on_gui_click, on_gui_click)
script.on_event(defines.events.on_tick, on_tick)

-- Register all custom input events
for _, input_name in ipairs(Input.get_custom_input_names()) do
  script.on_event(input_name, on_custom_input)
end

---------------------------------------------------------------------------
-- Public API (for bridge callbacks)
---------------------------------------------------------------------------

function M.get_wasm_instance()
  return wasm_instance
end

return M
