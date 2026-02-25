#!/usr/bin/env lua5.2
-- Test: run NetHack WASM and interact with it
-- Feeds a sequence of inputs to play through the first few turns

-- Track game state for display
local map = {}        -- map[y][x] = char
local map_color = {}  -- map_color[y][x] = color
local player_x, player_y = 0, 0
local status_fields = {}
local messages = {}
local menu_items = {}
local menu_prompt = ""

local function track_glyph(x, y, ch, color, special)
    if not map[y] then map[y] = {} end
    if not map_color[y] then map_color[y] = {} end
    map[y][x] = ch
    map_color[y][x] = color
    -- Track player position (@ = 64)
    if ch == 64 then
        player_x, player_y = x, y
    end
end

local function render_map()
    -- Find map bounds
    local min_x, max_x, min_y, max_y = 999, -999, 999, -999
    for y, row in pairs(map) do
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
        for x, _ in pairs(row) do
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
        end
    end
    if min_x > max_x then return end

    -- Render visible area around player (+-20 x, +-8 y)
    local view_x1 = math.max(min_x, player_x - 20)
    local view_x2 = math.min(max_x, player_x + 20)
    local view_y1 = math.max(min_y, player_y - 8)
    local view_y2 = math.min(max_y, player_y + 8)

    print(string.format("  Map (player at %d,%d):", player_x, player_y))
    for y = view_y1, view_y2 do
        local line = {}
        for x = view_x1, view_x2 do
            local ch = map[y] and map[y][x]
            if ch and ch >= 32 and ch < 127 then
                line[#line + 1] = string.char(ch)
            else
                line[#line + 1] = " "
            end
        end
        print("  " .. table.concat(line))
    end
end

-- Stub out Factorio-specific modules before requiring bridge
package.loaded["scripts.display"] = {
    init = function() end,
    print_glyph = track_glyph,
    clear_map = function()
        map = {}
        map_color = {}
    end,
    get_player_pos = function() return {x=player_x, y=player_y} end,
    get_or_create_level = function() end,
    switch_level = function() end,
    get_current_surface = function() return nil end,
}
package.loaded["scripts.gui"] = {
    init = function() end,
    putstr = function(win, attr, text)
        if win == 11 or win == 1 then  -- message window
            print("[msg] " .. text)
        end
    end,
    add_message = function(msg)
        messages[#messages + 1] = msg
        print("[msg] " .. tostring(msg))
    end,
    update_status = function(idx, val, color, percent)
        if val and #val > 0 then
            status_fields[idx] = val
        end
    end,
    flush_status = function()
        -- Print status line summary
        local parts = {}
        for idx = 0, 30 do
            if status_fields[idx] and #status_fields[idx] > 0 then
                parts[#parts + 1] = status_fields[idx]
            end
        end
        if #parts > 0 then
            print("[status] " .. table.concat(parts, " | "))
        end
    end,
    create_window = function(t) return t + 10 end,
    display_window = function() end,
    clear_window = function() end,
    destroy_window = function() end,
    start_menu = function(winid)
        menu_items = {}
        menu_prompt = ""
    end,
    add_menu_item = function(winid, glyph, id, accel, group, attr, str, presel)
        menu_items[#menu_items + 1] = {id=id, accel=accel, str=str}
    end,
    end_menu = function(winid, prompt)
        menu_prompt = prompt or ""
    end,
    show_menu = function(player, winid, how)
        if menu_prompt and #menu_prompt > 0 then
            print("[menu] " .. menu_prompt)
        end
        for _, item in ipairs(menu_items) do
            local accel_str = ""
            if item.accel and item.accel > 0 then
                accel_str = string.char(item.accel) .. " - "
            end
            print("[menu]   " .. accel_str .. (item.str or "?"))
        end
    end,
    show_yn_prompt = function() end,
    show_getlin_prompt = function() end,
    create_player_gui = function() end,
}
package.loaded["scripts.input"] = {
    init = function() end,
    record_position = function() end,
    get_custom_input_names = function() return {} end,
}

-- Stub Factorio globals
storage = {}
log = function(msg) print("[LOG] " .. msg) end

-- Parse flags
local quiet = false
for _, a in ipairs(arg or {}) do
    if a == "--no-compile" then
        -- handled after require
    elseif a == "--quiet" or a == "-q" then
        quiet = true
    end
end

-- Suppress verbose output in quiet mode
if quiet then
    log = function() end
    package.loaded["scripts.gui"].putstr = function() end
    package.loaded["scripts.gui"].add_message = function(msg) messages[#messages + 1] = msg end
    package.loaded["scripts.gui"].flush_status = function() end
    package.loaded["scripts.gui"].show_menu = function() end
end

local function fmt_time(sec)
    if sec < 0.001 then return string.format("%.1fms", sec * 1000) end
    return string.format("%.2fs", sec)
end

print("=== NetHack WASM Play Test ===")
print("")

print("Loading modules...")
local WasmInit = require("scripts.wasm.init")
local WasmInterp = require("scripts.wasm.interp")
local Bridge = require("scripts.bridge")

-- Process flags
local use_aot = false
for _, a in ipairs(arg or {}) do
    if a == "--no-compile" then WasmInterp.use_compiler = false end
    if a == "--aot" then use_aot = true end
end

print("Loading WASM data...")
local load_start = os.clock()
local wasm_data = require("scripts.nethack_wasm")
local load_elapsed = os.clock() - load_start

-- Load AOT-compiled sources if available and requested
local compiled_sources = nil
local aot_elapsed = 0
if WasmInterp.use_compiler then
    if use_aot then
        print("Loading AOT-compiled sources...")
        local aot_start = os.clock()
        local ok, aot = pcall(require, "scripts.nethack_compiled")
        aot_elapsed = os.clock() - aot_start
        if ok and aot then
            compiled_sources = aot
            print(string.format("  AOT sources loaded in %s", fmt_time(aot_elapsed)))
        else
            print("  AOT sources not found, falling back to JIT")
        end
    end
end

print("Parsing WASM module...")
local parse_start = os.clock()
local module = WasmInit.parse(wasm_data.data)
local parse_elapsed = os.clock() - parse_start

-- Set up instance
local instance_ref = {inst = nil}
local function memory_ref()
    return instance_ref.inst.memory
end

local imports = Bridge.create_imports(memory_ref, instance_ref)
print("Instantiating...")
local instantiate_start = os.clock()
local instance = WasmInterp.instantiate(module, imports, compiled_sources)
local instantiate_elapsed = os.clock() - instantiate_start
instance_ref.inst = instance

print(string.format("  Load data:    %s", fmt_time(load_elapsed)))
print(string.format("  Parse:        %s", fmt_time(parse_elapsed)))
print(string.format("  Instantiate:  %s (compiler=%s)", fmt_time(instantiate_elapsed), tostring(WasmInterp.use_compiler)))
print("")

-- Start via WASI entry point
local start_idx = WasmInterp.get_export(instance, "_start")
if not start_idx then
    print("No _start export found!")
    os.exit(1)
end

WasmInterp.call(instance, start_idx, {})

-- Run until first input prompt
local function run_until_input(label, max)
    max = max or 200000000
    local total = 0
    local instr_before = instance.total_instructions
    local result
    repeat
        result = WasmInterp.run(instance, 1000000)
        total = total + 1000000
    until result.status ~= "running" or total >= max

    local instr_delta = instance.total_instructions - instr_before
    result.instructions = instr_delta

    if result.status == "waiting_input" then
        if not quiet then
            print(string.format("[%s] Waiting for input: %s (%dK instr)",
                label, result.input_type or "?", instr_delta / 1000))
        end
        return result
    elseif result.status == "error" then
        local msg = result.message
        if type(msg) == "table" then msg = msg.msg or tostring(msg) end
        print(string.format("[%s] ERROR: %s", label, tostring(msg)))
        return result
    elseif result.status == "finished" then
        print(string.format("[%s] Finished (%dK instr)", label, instr_delta / 1000))
        return result
    else
        print(string.format("[%s] Still running after %dM (hit limit)", label, total / 1000000))
        return result
    end
end

local function provide_and_run(value, label)
    WasmInterp.provide_input(instance, value)
    return run_until_input(label)
end

print("--- Running to first input ---")
local startup_start = os.clock()
local result = run_until_input("startup")
local startup_elapsed = os.clock() - startup_start
local startup_instrs = instance.total_instructions
print(string.format("  Startup: %s, %dK instructions, %.0fK inst/sec",
    fmt_time(startup_elapsed), startup_instrs / 1000, startup_instrs / startup_elapsed / 1000))
if result.status ~= "waiting_input" then
    print("Game didn't reach input prompt!")
    os.exit(1)
end

-- Feed inputs: sequence of actions
-- Key codes: space=32, ESC=27, '.''=46, 'y'=121, 'n'=110
-- Movement: h=104 j=106 k=107 l=108 (vi keys)
-- Search: s=115, Wait: .=46, Inventory: i=105

local inputs = {
    -- First prompt is a menu - dismiss it
    {value=-1, label="dismiss first menu", show_map=not quiet},
    -- Wait a turn to see status
    {value=46, label="wait (.)"},
    -- Move around
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=107, label="move north (k)"},
    -- Search for hidden doors
    {value=115, label="search (s)"},
    -- Wait
    {value=46, label="wait (.)"},
    -- Move more
    {value=104, label="move west (h)"},
    {value=104, label="move west (h)"},
    -- Look at inventory
    {value=105, label="inventory (i)", show_map=not quiet},
    -- Dismiss inventory menu
    {value=-1, label="dismiss inventory"},
    -- More exploration
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=107, label="move north (k)"},
    {value=107, label="move north (k)"},
    {value=104, label="move west (h)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=46, label="wait (.)"},
    {value=46, label="wait (.)"},
    -- Move around more
    {value=106, label="move south (j)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=107, label="move north (k)"},
    {value=107, label="move north (k)"},
    {value=107, label="move north (k)"},
    {value=104, label="move west (h)"},
    {value=104, label="move west (h)"},
    {value=104, label="move west (h)"},
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=46, label="wait (.)"},
    {value=46, label="wait (.)"},
    {value=46, label="wait (.)"},
    -- Check inventory again
    {value=105, label="inventory (i)"},
    {value=-1, label="dismiss inventory"},
    -- More movement
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=104, label="move west (h)"},
    {value=104, label="move west (h)"},
    {value=107, label="move north (k)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=115, label="search (s)"},
    {value=46, label="wait (.)"},
    {value=106, label="move south (j)"},
    {value=106, label="move south (j)"},
    {value=108, label="move east (l)"},
    {value=107, label="move north (k)"},
    {value=107, label="move north (k)"},
    {value=108, label="move east (l)"},
    {value=108, label="move east (l)"},
    {value=106, label="move south (j)"},
    {value=104, label="move west (h)"},
    {value=115, label="search (s)"},
    -- Final inventory check
    {value=105, label="inventory (i)", show_map=not quiet},
}

print("")
print("--- Playing ---")
local play_start = os.clock()
local play_instrs_before = instance.total_instructions

for i, input in ipairs(inputs) do
    if not quiet then
        print("")
        print(string.format("--- Input %d: %s ---", i, input.label))
    end

    if result.status ~= "waiting_input" then
        print("Game not waiting for input, stopping")
        break
    end

    local input_type = result.input_type

    -- For menus, provide -1 (cancel/dismiss), for getch provide key
    local value = input.value
    if input_type == "menu" and value > 0 then
        value = -1  -- force cancel for menus we didn't plan for
    end

    local step_start = os.clock()
    result = provide_and_run(value, input.label)
    local step_elapsed = os.clock() - step_start

    if not quiet then
        print(string.format("  -> %s (%dK instr)", fmt_time(step_elapsed), (result.instructions or 0) / 1000))
    end

    -- Show map after certain actions
    if input.show_map or (i == #inputs and not quiet) then
        render_map()
    end

    if result.status == "error" then
        local msg = result.message
        if type(msg) == "table" then msg = msg.msg or tostring(msg) end
        print("ERROR: " .. tostring(msg))
        break
    end
    if result.status == "finished" then
        print("Game ended!")
        break
    end
end

local play_elapsed = os.clock() - play_start
local play_instrs = instance.total_instructions - play_instrs_before
local total_elapsed = load_elapsed + aot_elapsed + parse_elapsed + instantiate_elapsed + startup_elapsed + play_elapsed
local total_instrs = instance.total_instructions

print("")
print("=== Timing Summary ===")
print(string.format("  Load data:    %s", fmt_time(load_elapsed)))
if aot_elapsed > 0 then
    print(string.format("  Load AOT:     %s", fmt_time(aot_elapsed)))
end
print(string.format("  Parse:        %s", fmt_time(parse_elapsed)))
print(string.format("  Instantiate:  %s", fmt_time(instantiate_elapsed)))
print(string.format("  Startup:      %s  (%dK instr, %.0fK inst/sec)", fmt_time(startup_elapsed), startup_instrs / 1000, startup_instrs / startup_elapsed / 1000))
print(string.format("  Play (%d inputs): %s  (%dK instr, %.0fK inst/sec)", #inputs, fmt_time(play_elapsed), play_instrs / 1000, play_instrs / play_elapsed / 1000))
print(string.format("  ─────────────────────"))
print(string.format("  Total:        %s  (%dK instr)", fmt_time(total_elapsed), total_instrs / 1000))
print(string.format("  Overall:      %.0fK inst/sec", total_instrs / (startup_elapsed + play_elapsed) / 1000))
local mode = "off"
if WasmInterp.use_compiler then
    mode = compiled_sources and "AOT" or "JIT"
end
print(string.format("  Compiler:     %s", mode))
