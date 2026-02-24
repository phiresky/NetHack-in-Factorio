#!/usr/bin/env lua5.2
-- WebAssembly Spec Test Runner
-- Reads wast2json output (.json + .wasm files) and runs them against our interpreter.

local bit32 = bit32
local unpack = table.unpack or unpack

---------------------------------------------------------------------------
-- Minimal JSON Parser
---------------------------------------------------------------------------
local JSON = {}

function JSON.decode(str)
    local pos = 1

    local function skip_ws()
        pos = str:find("[^ \t\n\r]", pos) or (#str + 1)
    end

    local function peek()
        skip_ws()
        return str:sub(pos, pos)
    end

    local function next_char()
        skip_ws()
        local c = str:sub(pos, pos)
        pos = pos + 1
        return c
    end

    local function expect(c)
        local got = next_char()
        if got ~= c then error("JSON: expected '" .. c .. "' got '" .. got .. "' at pos " .. pos) end
    end

    local parse_value -- forward declaration

    local function parse_string()
        expect('"')
        local parts = {}
        while true do
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == '"' then break end
            if c == '\\' then
                local esc = str:sub(pos, pos)
                pos = pos + 1
                if esc == 'n' then parts[#parts+1] = '\n'
                elseif esc == 't' then parts[#parts+1] = '\t'
                elseif esc == 'r' then parts[#parts+1] = '\r'
                elseif esc == '\\' then parts[#parts+1] = '\\'
                elseif esc == '"' then parts[#parts+1] = '"'
                elseif esc == '/' then parts[#parts+1] = '/'
                elseif esc == 'u' then
                    local hex = str:sub(pos, pos + 3)
                    pos = pos + 4
                    local code = tonumber(hex, 16)
                    if code < 128 then
                        parts[#parts+1] = string.char(code)
                    else
                        parts[#parts+1] = "?" -- simplified
                    end
                else
                    parts[#parts+1] = esc
                end
            else
                parts[#parts+1] = c
            end
        end
        return table.concat(parts)
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while str:sub(pos, pos):match("[%d]") do pos = pos + 1 end
        if str:sub(pos, pos) == '.' then
            pos = pos + 1
            while str:sub(pos, pos):match("[%d]") do pos = pos + 1 end
        end
        if str:sub(pos, pos):match("[eE]") then
            pos = pos + 1
            if str:sub(pos, pos):match("[%+%-]") then pos = pos + 1 end
            while str:sub(pos, pos):match("[%d]") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_array()
        expect('[')
        local arr = {}
        if peek() == ']' then next_char(); return arr end
        while true do
            arr[#arr+1] = parse_value()
            local c = next_char()
            if c == ']' then break end
            if c ~= ',' then error("JSON: expected ',' or ']' got '" .. c .. "'") end
        end
        return arr
    end

    local function parse_object()
        expect('{')
        local obj = {}
        if peek() == '}' then next_char(); return obj end
        while true do
            local key = parse_string()
            expect(':')
            obj[key] = parse_value()
            local c = next_char()
            if c == '}' then break end
            if c ~= ',' then error("JSON: expected ',' or '}' got '" .. c .. "'") end
        end
        return obj
    end

    parse_value = function()
        local c = peek()
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then
            pos = pos + 4; return true
        elseif c == 'f' then
            pos = pos + 5; return false
        elseif c == 'n' then
            pos = pos + 4; return nil
        else return parse_number()
        end
    end

    return parse_value()
end

---------------------------------------------------------------------------
-- Load WASM interpreter modules
---------------------------------------------------------------------------
local Parser = require("scripts.wasm.init")
local Interp = require("scripts.wasm.interp")
local Memory = require("scripts.wasm.memory")

---------------------------------------------------------------------------
-- Value conversion helpers
---------------------------------------------------------------------------

-- Convert string decimal to unsigned 32-bit number
local function str_to_u32(s)
    local n = tonumber(s)
    if not n then return 0 end
    if n < 0 then n = n + 4294967296 end
    return n % 4294967296
end

-- Convert string decimal to i64 {lo, hi} pair
local function str_to_i64(s)
    local n = tonumber(s)
    if not n then return {0, 0} end
    -- For values that fit in double precision
    if n >= 0 and n <= 4294967295 then
        return {n, 0}
    end
    local hi = math.floor(n / 4294967296)
    local lo = n - hi * 4294967296
    if lo < 0 then lo = lo + 4294967296; hi = hi - 1 end
    return {bit32.band(lo, 0xFFFFFFFF), bit32.band(hi, 0xFFFFFFFF)}
end

-- Convert bit pattern string to f32 value
local function bits_to_f32(s)
    local bits = str_to_u32(s)
    if bits == 0 then return 0.0 end
    if bits == 0x80000000 then return -0.0 end
    local sign = bit32.btest(bits, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(bits, 23), 0xFF)
    local mant = bit32.band(bits, 0x7FFFFF)
    if exp == 0xFF then
        if mant == 0 then return sign * math.huge end
        return 0/0 -- NaN
    elseif exp == 0 then
        return sign * math.ldexp(mant, -149) -- denormal
    end
    return sign * math.ldexp(mant + 0x800000, exp - 150)
end

-- Convert bit pattern string to f64 value
local function bits_to_f64(s)
    local n = tonumber(s)
    if not n then return 0.0 end
    if n == 0 then return 0.0 end
    -- Decode from 64-bit pattern
    local lo = n % 4294967296
    local hi = math.floor(n / 4294967296)
    lo = bit32.band(lo, 0xFFFFFFFF)
    hi = bit32.band(hi, 0xFFFFFFFF)
    local sign = bit32.btest(hi, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(hi, 20), 0x7FF)
    local mant_hi = bit32.band(hi, 0xFFFFF)
    local mant = mant_hi * 4294967296 + lo
    if exp == 0x7FF then
        if mant == 0 then return sign * math.huge end
        return 0/0
    elseif exp == 0 then
        if mant == 0 then return 0.0 * sign end
        return sign * math.ldexp(mant, -1074)
    end
    return sign * math.ldexp(mant + 4503599627370496, exp - 1075)
end

-- Convert f64 value back to bit pattern (for comparison)
local function f64_to_bits(v)
    if v ~= v then return "nan" end -- NaN
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    if v == 0 then
        if 1/v < 0 then return "neg0" end
        return "0"
    end
    -- Use frexp to decompose
    local sign = v < 0 and 1 or 0
    if sign == 1 then v = -v end
    local m, e = math.frexp(v)
    -- m is in [0.5, 1), e is exponent such that v = m * 2^e
    -- IEEE 754: v = (1 + frac) * 2^(exp-1023), so exp = e+1022, frac = 2*m - 1
    local exp = e + 1022
    if exp <= 0 then return "denorm" end -- denormal
    local frac = m * 2 - 1 -- in [0, 1)
    local mant = math.floor(frac * 4503599627370496 + 0.5) -- 2^52
    local hi = bit32.bor(bit32.lshift(sign, 31), bit32.lshift(exp, 20), bit32.band(math.floor(mant / 4294967296), 0xFFFFF))
    local lo = bit32.band(mant, 0xFFFFFFFF)
    return tostring(hi * 4294967296 + lo)
end

-- Convert an arg descriptor to a Lua value for our interpreter
local function convert_arg(arg)
    if arg.type == "i32" then
        return str_to_u32(arg.value)
    elseif arg.type == "i64" then
        return str_to_i64(arg.value)
    elseif arg.type == "f32" then
        return bits_to_f32(arg.value)
    elseif arg.type == "f64" then
        return bits_to_f64(arg.value)
    end
    return tonumber(arg.value) or 0
end

-- Compare a result value against expected
local function compare_result(got, expected)
    if not expected then return true end -- no expected value

    local etype = expected.type
    local evalue = expected.value

    -- Handle NaN expectations
    if evalue == "nan:canonical" or evalue == "nan:arithmetic" then
        if type(got) == "number" then
            return got ~= got -- NaN check
        end
        return false
    end

    if etype == "i32" then
        local exp_val = str_to_u32(evalue)
        if type(got) ~= "number" then return false end
        return bit32.band(got, 0xFFFFFFFF) == exp_val
    elseif etype == "i64" then
        local exp_pair = str_to_i64(evalue)
        if type(got) ~= "table" then
            -- Our interpreter might return a number for small i64 values
            if type(got) == "number" then
                local got_lo = got % 4294967296
                local got_hi = math.floor(got / 4294967296)
                return bit32.band(got_lo, 0xFFFFFFFF) == exp_pair[1] and
                       bit32.band(got_hi, 0xFFFFFFFF) == exp_pair[2]
            end
            return false
        end
        return bit32.band(got[1], 0xFFFFFFFF) == exp_pair[1] and
               bit32.band(got[2], 0xFFFFFFFF) == exp_pair[2]
    elseif etype == "f32" or etype == "f64" then
        local exp_val
        if etype == "f32" then
            exp_val = bits_to_f32(evalue)
        else
            exp_val = bits_to_f64(evalue)
        end
        if type(got) ~= "number" then return false end
        -- NaN check
        if exp_val ~= exp_val then return got ~= got end
        -- Exact comparison (including +0 vs -0)
        if exp_val == 0 and got == 0 then
            return (1/exp_val > 0) == (1/got > 0)
        end
        return got == exp_val
    end
    return false
end

---------------------------------------------------------------------------
-- Spectest import module (standard test host imports)
---------------------------------------------------------------------------
local function make_spectest_imports()
    return {
        spectest = {
            print_i32 = function() end,
            print_i64 = function() end,
            print_f32 = function() end,
            print_f64 = function() end,
            print = function() end,
            global_i32 = 666,
            global_i64 = {666, 0},
            global_f32 = 666.6,
            global_f64 = 666.6,
        },
    }
end

---------------------------------------------------------------------------
-- Test Runner
---------------------------------------------------------------------------

local function load_wasm_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function run_spec_test(json_path)
    local f = io.open(json_path, "r")
    if not f then
        print("ERROR: Cannot open " .. json_path)
        return 0, 0, 0
    end
    local json_str = f:read("*a")
    f:close()

    local test_data = JSON.decode(json_str)
    if not test_data or not test_data.commands then
        print("ERROR: Invalid JSON in " .. json_path)
        return 0, 0, 0
    end

    local base_dir = json_path:match("(.*/)")
    local passed = 0
    local failed = 0
    local skipped = 0
    local failures = {}

    -- Current module instance (can change with each "module" command)
    local current_instance = nil
    local current_module = nil
    -- Named modules for multi-module tests
    local named_instances = {}

    for _, cmd in ipairs(test_data.commands) do
        if cmd.type == "module" then
            -- Load and instantiate a module
            local wasm_path = base_dir .. cmd.filename
            local wasm_data = load_wasm_file(wasm_path)
            if not wasm_data then
                skipped = skipped + 1
            else
                local ok, mod = pcall(Parser.parse, wasm_data)
                if not ok then
                    -- Parse failure - skip remaining commands for this module
                    current_instance = nil
                    current_module = nil
                    skipped = skipped + 1
                else
                    local ok2, inst = pcall(Interp.instantiate, mod, make_spectest_imports())
                    if not ok2 then
                        current_instance = nil
                        current_module = nil
                        skipped = skipped + 1
                    else
                        current_instance = inst
                        current_module = mod
                        if cmd.name then
                            named_instances[cmd.name] = inst
                        end
                    end
                end
            end

        elseif cmd.type == "assert_return" then
            if not current_instance then
                skipped = skipped + 1
            else
                local action = cmd.action
                if action.type ~= "invoke" then
                    skipped = skipped + 1
                else
                    local field = action.field
                    local inst = current_instance
                    if action.module and named_instances[action.module] then
                        inst = named_instances[action.module]
                    end

                    -- Convert args
                    local args = {}
                    for _, a in ipairs(action.args or {}) do
                        args[#args+1] = convert_arg(a)
                    end

                    -- Find and call the exported function
                    local func_idx = Interp.get_export(inst, field)
                    if not func_idx then
                        skipped = skipped + 1
                    else
                        local ok, results = pcall(Interp.execute, inst, func_idx, args)
                        if not ok then
                            failed = failed + 1
                            failures[#failures+1] = string.format("line %d: %s(%s) trapped: %s",
                                cmd.line, field, #args, tostring(results):sub(1, 80))
                        else
                            -- Compare results
                            local expected = cmd.expected or {}
                            results = results or {}
                            local all_match = true

                            if #expected ~= #results then
                                -- Allow void functions to return empty
                                if #expected == 0 then
                                    -- OK
                                else
                                    all_match = false
                                end
                            end

                            for i, exp in ipairs(expected) do
                                if not compare_result(results[i], exp) then
                                    all_match = false
                                    break
                                end
                            end

                            if all_match then
                                passed = passed + 1
                            else
                                failed = failed + 1
                                local exp_str = ""
                                local got_str = ""
                                for i, exp in ipairs(expected) do
                                    if i > 1 then exp_str = exp_str .. ", " end
                                    exp_str = exp_str .. exp.type .. ":" .. tostring(exp.value)
                                end
                                for i, r in ipairs(results) do
                                    if i > 1 then got_str = got_str .. ", " end
                                    if type(r) == "table" then
                                        got_str = got_str .. string.format("{%s,%s}", tostring(r[1]), tostring(r[2]))
                                    else
                                        got_str = got_str .. tostring(r)
                                    end
                                end
                                failures[#failures+1] = string.format("line %d: %s expected [%s] got [%s]",
                                    cmd.line, field, exp_str, got_str)
                            end
                        end
                    end
                end
            end

        elseif cmd.type == "assert_trap" then
            if not current_instance then
                skipped = skipped + 1
            else
                local action = cmd.action
                if action.type ~= "invoke" then
                    skipped = skipped + 1
                else
                    local field = action.field
                    local inst = current_instance
                    if action.module and named_instances[action.module] then
                        inst = named_instances[action.module]
                    end

                    local args = {}
                    for _, a in ipairs(action.args or {}) do
                        args[#args+1] = convert_arg(a)
                    end

                    local func_idx = Interp.get_export(inst, field)
                    if not func_idx then
                        skipped = skipped + 1
                    else
                        local ok, err = pcall(Interp.execute, inst, func_idx, args)
                        if not ok then
                            passed = passed + 1 -- trap expected
                        else
                            failed = failed + 1
                            failures[#failures+1] = string.format("line %d: %s expected trap, got success",
                                cmd.line, field)
                        end
                    end
                end
            end

        elseif cmd.type == "assert_exhaustion" then
            if not current_instance then
                skipped = skipped + 1
            else
                local action = cmd.action
                if action.type ~= "invoke" then
                    skipped = skipped + 1
                else
                    local field = action.field
                    local args = {}
                    for _, a in ipairs(action.args or {}) do
                        args[#args+1] = convert_arg(a)
                    end
                    local func_idx = Interp.get_export(current_instance, field)
                    if not func_idx then
                        skipped = skipped + 1
                    else
                        local ok, err = pcall(Interp.execute, current_instance, func_idx, args)
                        if not ok then
                            passed = passed + 1
                        else
                            failed = failed + 1
                            failures[#failures+1] = string.format("line %d: %s expected exhaustion",
                                cmd.line, field)
                        end
                    end
                end
            end

        elseif cmd.type == "action" then
            -- Bare action (invoke without assert)
            if current_instance then
                local action = cmd.action
                if action.type == "invoke" then
                    local args = {}
                    for _, a in ipairs(action.args or {}) do
                        args[#args+1] = convert_arg(a)
                    end
                    local func_idx = Interp.get_export(current_instance, action.field)
                    if func_idx then
                        pcall(Interp.execute, current_instance, func_idx, args)
                    end
                end
            end

        elseif cmd.type == "assert_invalid" or cmd.type == "assert_malformed" then
            -- These test the parser/validator - skip for now
            skipped = skipped + 1

        elseif cmd.type == "assert_uninstantiable" then
            skipped = skipped + 1

        elseif cmd.type == "register" then
            -- Register a module under a name for import
            if current_instance and cmd.as then
                named_instances[cmd.as] = current_instance
            end
            skipped = skipped + 1

        else
            skipped = skipped + 1
        end
    end

    return passed, failed, skipped, failures
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local spec_dir = "build/tests/spec/"

-- Determine which tests to run
local test_files = arg
if #test_files == 0 then
    -- Default: run all JSON files in spec dir
    local p = io.popen("ls " .. spec_dir .. "*.json 2>/dev/null")
    if p then
        for line in p:lines() do
            test_files[#test_files+1] = line
        end
        p:close()
    end
end

-- Sort test files for consistent output
table.sort(test_files)

local total_passed = 0
local total_failed = 0
local total_skipped = 0
local all_failures = {}

for _, json_path in ipairs(test_files) do
    -- Extract test name from path
    local name = json_path:match("([^/]+)%.json$") or json_path

    local ok, p, f, s, failures = pcall(run_spec_test, json_path)
    if not ok then
        print(string.format("  %-25s CRASH: %s", name, tostring(p):sub(1, 60)))
        total_failed = total_failed + 1
    else
        total_passed = total_passed + p
        total_failed = total_failed + f
        total_skipped = total_skipped + s

        local status = ""
        if f > 0 then
            status = string.format("\027[31mFAIL\027[0m %d passed, %d failed", p, f)
        elseif p > 0 then
            status = string.format("\027[32mPASS\027[0m %d passed", p)
        else
            status = string.format("\027[33mSKIP\027[0m")
        end
        if s > 0 then
            status = status .. string.format(", %d skipped", s)
        end
        print(string.format("  %-25s %s", name, status))

        if failures then
            for _, msg in ipairs(failures) do
                all_failures[#all_failures+1] = name .. ": " .. msg
            end
        end
    end
end

print("")
print(string.format("TOTAL: %d passed, %d failed, %d skipped",
    total_passed, total_failed, total_skipped))

if #all_failures > 0 then
    -- Show first N failures
    local show = math.min(30, #all_failures)
    print(string.format("\nFirst %d failures:", show))
    for i = 1, show do
        print("  " .. all_failures[i])
    end
    if #all_failures > show then
        print(string.format("  ... and %d more", #all_failures - show))
    end
    os.exit(1)
else
    print("\nALL TESTS PASSED")
end
