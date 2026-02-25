#!/usr/bin/env lua5.2
-- Benchmark: measure exact instruction count and execution time
-- Outputs a single summary line for easy parsing

local map = {}
local map_color = {}
local player_x, player_y = 0, 0

package.loaded["scripts.display"] = {
    init = function() end,
    print_glyph = function(x, y, ch, color, special)
        if not map[y] then map[y] = {} end
        if not map_color[y] then map_color[y] = {} end
        map[y][x] = ch
        map_color[y][x] = color
        if ch == 64 then player_x, player_y = x, y end
    end,
    clear_map = function() map = {}; map_color = {} end,
    get_player_pos = function() return {x=player_x, y=player_y} end,
    get_or_create_level = function() end,
    switch_level = function() end,
    get_current_surface = function() return nil end,
}
package.loaded["scripts.gui"] = {
    init = function() end,
    putstr = function() end,
    add_message = function() end,
    update_status = function() end,
    flush_status = function() end,
    create_window = function(t) return t + 10 end,
    display_window = function() end,
    clear_window = function() end,
    destroy_window = function() end,
    start_menu = function() end,
    add_menu_item = function() end,
    end_menu = function() end,
    show_menu = function() end,
    show_yn_prompt = function() end,
    show_getlin_prompt = function() end,
    create_player_gui = function() end,
}
package.loaded["scripts.input"] = {
    init = function() end,
    record_position = function() end,
    get_custom_input_names = function() return {} end,
}
storage = {}
log = function() end

-- Phase 1: Parse + instantiate (measure separately)
local t0 = os.clock()

local WasmInit = require("scripts.wasm.init")
local WasmInterp = require("scripts.wasm.interp")
local Bridge = require("scripts.bridge")
local wasm_data = require("scripts.nethack_wasm")

local t1 = os.clock()

local module = WasmInit.parse(wasm_data.data)

local t2 = os.clock()

local instance_ref = {inst = nil}
local function memory_ref() return instance_ref.inst.memory end
local imports = Bridge.create_imports(memory_ref, instance_ref)
local instance = WasmInterp.instantiate(module, imports)
instance_ref.inst = instance

local start_idx = WasmInterp.get_export(instance, "_start")
WasmInterp.call(instance, start_idx, {})

local t3 = os.clock()

-- Phase 2: Execute to first input
local function run_until_input(max)
    max = max or 200000000
    local total = 0
    local result
    repeat
        result = WasmInterp.run(instance, 1000000)
        total = total + 1000000
    until result.status ~= "running" or total >= max
    return result
end

local result = run_until_input()
local t4 = os.clock()
local inst_startup = instance.total_instructions

if result.status ~= "waiting_input" then
    io.stderr:write("ERROR: didn't reach input\n")
    os.exit(1)
end

-- Phase 3: Run through several moves
local inputs = {
    {value=-1, label="dismiss menu"},
    {value=46, label="wait"},
    {value=106, label="south"},
    {value=106, label="south"},
    {value=108, label="east"},
    {value=108, label="east"},
    {value=108, label="east"},
    {value=107, label="north"},
    {value=115, label="search"},
    {value=46, label="wait"},
    {value=104, label="west"},
    {value=104, label="west"},
}

for _, input in ipairs(inputs) do
    if result.status ~= "waiting_input" then break end
    WasmInterp.provide_input(instance, input.value)
    result = run_until_input()
end

local t5 = os.clock()
local inst_total = instance.total_instructions

-- Output results
local load_time = t1 - t0
local parse_time = t2 - t1
local inst_time = t3 - t2
local exec_startup = t4 - t3
local exec_play = t5 - t4
local exec_total = t5 - t3

io.write(string.format("RESULT load=%.2f parse=%.2f instantiate=%.2f startup=%.2f play=%.2f total_exec=%.2f inst_startup=%d inst_total=%d\n",
    load_time, parse_time, inst_time, exec_startup, exec_play, exec_total, inst_startup, inst_total))
