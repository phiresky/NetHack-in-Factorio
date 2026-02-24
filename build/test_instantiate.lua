#!/usr/bin/env lua5.2
-- Test: instantiate the NetHack WASM module with all imports
-- Runs outside Factorio with stubbed Factorio-specific modules

-- Stub out Factorio-specific modules before requiring bridge
package.loaded["scripts.display"] = {
    init = function() end,
    print_glyph = function() end,
    clear_map = function() end,
    get_player_pos = function() return {x=0, y=0} end,
    get_or_create_level = function() end,
    switch_level = function() end,
    get_current_surface = function() return nil end,
}
package.loaded["scripts.gui"] = {
    init = function() end,
    putstr = function(win, attr, text) print("[putstr win=" .. tostring(win) .. "] " .. text) end,
    add_message = function(msg) print("[message] " .. tostring(msg)) end,
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

-- Stub Factorio globals
storage = {}
log = function(msg) print("[LOG] " .. msg) end

print("=== NetHack WASM Instantiation Test ===")
print("")

print("Loading WASM modules...")
local WasmInit = require("scripts.wasm.init")
local WasmInterp = require("scripts.wasm.interp")
local Bridge = require("scripts.bridge")

print("Loading WASM data...")
local wasm_data = require("scripts.nethack_wasm")
print("  Size: " .. wasm_data.size .. " bytes")

print("Parsing WASM module...")
local module = WasmInit.parse(wasm_data.data)
print("  Functions: " .. #module.funcs)
print("  Imports: " .. #module.imports)

-- Check for start function
if module.start_func then
    print("  Start function: " .. module.start_func)
else
    print("  No start function")
end

-- Set up imports like main.lua does
local instance_ref = {inst = nil}
local function memory_ref()
    return instance_ref.inst.memory
end

print("Creating imports...")
local imports = Bridge.create_imports(memory_ref, instance_ref)

-- Count and list provided imports
local provided = {}
local count = 0
for k, v in pairs(imports) do
    count = count + 1
    provided[k] = true
end
print("  Provided: " .. count .. " import functions")

-- Check which imports are missing
local missing = {}
for _, imp in ipairs(module.imports) do
    if imp.kind == 0 then -- EXT_FUNC
        local key = imp.module .. "." .. imp.name
        if not provided[key] then
            missing[#missing + 1] = key
        end
    end
end
if #missing > 0 then
    print("  MISSING imports:")
    for _, m in ipairs(missing) do
        print("    - " .. m)
    end
else
    print("  All function imports satisfied!")
end

print("")
print("Instantiating WASM module...")
local ok, err = pcall(function()
    local instance = WasmInterp.instantiate(module, imports)
    instance_ref.inst = instance

    local function count_table(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    print("  Memory: " .. instance.memory.page_count .. " pages (" ..
          instance.memory.byte_length .. " bytes)")
    print("  Globals: " .. count_table(instance.globals))
    print("  Tables: " .. count_table(instance.tables))

    -- Check table 0 size
    if instance.table_sizes[0] then
        print("  Table 0 size: " .. instance.table_sizes[0])
    end

    print("")

    print("")

    -- Try calling _start (WASI entry point)
    local start_idx = WasmInterp.get_export(instance, "_start")
    if start_idx then
        print("Calling _start() (func idx " .. start_idx .. ")...")
        print("  Running up to 500M instructions to see how far we get...")
        WasmInterp.call(instance, start_idx, {})
        local result
        repeat
            result = WasmInterp.run(instance, 1000000)
            local total = instance.total_instructions
            if total % 10000000 < 1000000 then
                print("  ... " .. string.format("%.1fM", total / 1000000) .. " instructions executed")
            end
        until result.status ~= "running" or instance.total_instructions >= 500000000
        print("  Total instructions: " .. instance.total_instructions)
        print("  Status: " .. result.status)
        if result.status == "error" then
            local msg = result.message
            if type(msg) == "table" then msg = msg.msg or tostring(msg) end
            print("  Error: " .. tostring(msg))
        elseif result.status == "waiting_input" then
            print("  Waiting for input! NetHack reached nhgetch()")
            if result.input_type then
                print("  Input type: " .. tostring(result.input_type))
            end
        elseif result.status == "running" then
            print("  Still running (hit instruction limit)")
        end
    else
        print("  No _start export found!")
    end

    print("")
    print("=== Test complete ===")
end)

if not ok then
    print("")
    print("FAILED!")
    if type(err) == "table" then
        print("  Error: " .. tostring(err.msg or err[1] or "unknown"))
        for k, v in pairs(err) do
            print("  ." .. tostring(k) .. " = " .. tostring(v))
        end
    else
        print("  Error: " .. tostring(err))
    end
end
