#!/usr/bin/env lua5.2
-- AOT compiler: parse WASM binary, compile all functions to Lua source strings,
-- emit as a Lua module for loading at runtime.
--
-- Usage: lua5.2 compile_wasm.lua <nethack_wasm.lua> <output.lua>
--
-- The output module returns a table: { [func_idx] = "source string", ... }
-- At runtime, each source string is passed to load() to get the compiled function.

local args = arg or {}
if #args < 2 then
    io.stderr:write("Usage: lua5.2 compile_wasm.lua <nethack_wasm.lua> <output.lua>\n")
    os.exit(1)
end

local wasm_module_path = args[1]  -- e.g. "../scripts/nethack_wasm"
local output_path = args[2]       -- e.g. "../scripts/nethack_compiled.lua"

-- Stub Factorio globals
storage = storage or {}
log = log or function() end

io.stderr:write("Loading WASM data...\n")
local wasm_mod = dofile(wasm_module_path)

io.stderr:write("Parsing WASM module...\n")
local WasmInit = require("scripts.wasm.init")
local Compiler = require("scripts.wasm.compiler")

local parse_start = os.clock()
local module = WasmInit.parse(wasm_mod.data)
io.stderr:write(string.format("  Parse: %.2fs\n", os.clock() - parse_start))

-- Convert code strings to byte arrays (same as instantiate does)
io.stderr:write("Converting bytecode to byte arrays...\n")
for idx, func_def in pairs(module.funcs) do
    if type(idx) == "number" and not func_def.import
       and func_def.code and func_def.code.code
       and type(func_def.code.code) == "string" then
        local str = func_def.code.code
        local len = #str
        local arr = {}
        for j = 1, len do
            arr[j] = string.byte(str, j)
        end
        func_def.code.code = arr
    end
end

-- Compile all functions to source strings
io.stderr:write("Compiling functions...\n")
local compile_start = os.clock()
local sources = {}
local count = 0
local failed = 0

for idx, func_def in pairs(module.funcs) do
    if type(idx) == "number" and not func_def.import then
        local source = Compiler.compile_function_source(func_def, idx, module)
        if source then
            sources[idx] = source
            count = count + 1
        else
            failed = failed + 1
        end
    end
end

io.stderr:write(string.format("  Compiled %d functions (%d failed) in %.2fs\n",
    count, failed, os.clock() - compile_start))

-- Emit as Lua module
-- We use long strings [=[...]=] to avoid escaping issues
io.stderr:write(string.format("Writing %s...\n", output_path))
local out = io.open(output_path, "w")
if not out then
    io.stderr:write("Error: cannot open " .. output_path .. " for writing\n")
    os.exit(1)
end

out:write("-- Auto-generated AOT compiled WASM functions\n")
out:write("-- DO NOT EDIT - regenerate with compile_wasm.lua\n")
out:write("local M = {}\n\n")

-- Find the right long-string delimiter level that doesn't conflict
local function find_delimiter(s)
    for level = 0, 10 do
        local close = "]" .. string.rep("=", level) .. "]"
        if not s:find(close, 1, true) then
            return level
        end
    end
    return 10
end

-- Sort indices for deterministic output
local indices = {}
for idx, _ in pairs(sources) do
    indices[#indices + 1] = idx
end
table.sort(indices)

for _, idx in ipairs(indices) do
    local source = sources[idx]
    local level = find_delimiter(source)
    local open = "[" .. string.rep("=", level) .. "["
    local close = "]" .. string.rep("=", level) .. "]"
    out:write(string.format("M[%d] = %s%s%s\n\n", idx, open, source, close))
end

out:write("return M\n")
out:close()

local f = io.open(output_path, "r")
if f then
    local size = f:seek("end")
    f:close()
    io.stderr:write(string.format("Done. %d functions, %.1fMB output\n", count, size / 1024 / 1024))
else
    io.stderr:write(string.format("Done. %d functions written\n", count))
end
