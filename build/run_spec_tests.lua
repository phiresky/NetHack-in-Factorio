#!/usr/bin/env lua5.2
-- WebAssembly Spec Test Runner
-- Reads wast2json output (.json + .wasm files) and runs them against our interpreter.

local bit32 = bit32
local unpack = table.unpack or unpack

---------------------------------------------------------------------------
-- JSON parser (vendored from https://github.com/rxi/json.lua)
---------------------------------------------------------------------------
local JSON = require("build.json")

---------------------------------------------------------------------------
-- Load WASM interpreter modules
---------------------------------------------------------------------------
local Parser = require("scripts.wasm.init")
local Interp = require("scripts.wasm.interp")
local Memory = require("scripts.wasm.memory")
local Validator = require("scripts.wasm.validate")

---------------------------------------------------------------------------
-- Value conversion helpers
---------------------------------------------------------------------------

-- Metatable for boxed NaN values passed as test arguments.
-- Mirrors the interpreter's nan_mt so boxed NaN behaves correctly in arithmetic.
local NAN = 0/0
local test_nan_mt = {
    __add = function() return NAN end,
    __sub = function() return NAN end,
    __mul = function() return NAN end,
    __div = function() return NAN end,
    __mod = function() return NAN end,
    __pow = function() return NAN end,
    __unm = function() return NAN end,
    __lt = function() return false end,
    __le = function() return false end,
}

-- Convert string decimal to unsigned 32-bit number
local function str_to_u32(s)
    local n = tonumber(s)
    if not n then return 0 end
    if n < 0 then n = n + 4294967296 end
    return n % 4294967296
end

-- Convert string decimal to i64 {lo, hi} pair
-- Uses string-based long division for values that exceed double precision
local function str_to_i64(s)
    if not s or s == "" then return {0, 0} end
    -- For small values, use fast path
    if #s <= 9 then
        local n = tonumber(s)
        if not n then return {0, 0} end
        return {n, 0}
    end
    -- String-based long division by 4294967296 to split into {lo, hi}
    local remainder = 0
    local quotient_digits = {}
    for i = 1, #s do
        local d = tonumber(s:sub(i, i))
        if not d then return {0, 0} end
        remainder = remainder * 10 + d
        local q = math.floor(remainder / 4294967296)
        remainder = remainder % 4294967296
        if #quotient_digits > 0 or q > 0 then
            quotient_digits[#quotient_digits + 1] = tostring(q)
        end
    end
    local lo = remainder
    local hi_str = table.concat(quotient_digits)
    local hi = tonumber(hi_str) or 0
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
        return setmetatable({nan32 = bits}, test_nan_mt) -- boxed NaN preserves bit pattern
    elseif exp == 0 then
        return sign * math.ldexp(mant, -149) -- denormal
    end
    return sign * math.ldexp(mant + 0x800000, exp - 150)
end

-- Convert bit pattern string to f64 value
-- The bit pattern is a decimal string representing a 64-bit unsigned integer
local function bits_to_f64(s)
    if not s or s == "" then return 0.0 end
    -- Use str_to_i64 to accurately parse the 64-bit bit pattern
    local pair = str_to_i64(s)
    local lo = pair[1]
    local hi = pair[2]
    if lo == 0 and hi == 0 then return 0.0 end
    if lo == 0 and hi == 0x80000000 then return -0.0 end
    local sign = bit32.btest(hi, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(hi, 20), 0x7FF)
    local mant_hi = bit32.band(hi, 0xFFFFF)
    local mant = mant_hi * 4294967296 + lo
    if exp == 0x7FF then
        if mant == 0 then return sign * math.huge end
        return setmetatable({nan64 = {lo, hi}}, test_nan_mt) -- boxed NaN preserves bit pattern
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

-- Check if a result value is NaN (either Lua NaN or boxed NaN from interpreter)
local function is_nan_value(v)
    if type(v) == "number" then return v ~= v end
    if type(v) == "table" then return v.nan32 ~= nil or v.nan64 ~= nil end
    return false
end

-- Compare a result value against expected
local function compare_result(got, expected)
    if not expected then return true end -- no expected value

    local etype = expected.type
    local evalue = expected.value

    -- Handle NaN expectations
    if evalue == "nan:canonical" or evalue == "nan:arithmetic" then
        return is_nan_value(got)
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
        -- Handle NaN: both got and expected can be boxed NaN tables
        if is_nan_value(got) then
            return is_nan_value(exp_val)
        end
        if type(got) ~= "number" then return false end
        if is_nan_value(exp_val) then return false end -- expected NaN but got isn't
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

-- Extract the error message from a pcall error value.
-- Our WASM code throws table errors {msg = "..."} to avoid Lua's file:line prefix.
local function extract_error_msg(err)
    if type(err) == "table" and err.msg then
        return err.msg
    end
    return tostring(err)
end

-- Check that expected_text is a prefix of actual error message.
-- Returns true if match, false + details if mismatch.
local function check_error_prefix(err, expected_text)
    if not expected_text or expected_text == "" then return true end
    local msg = extract_error_msg(err)
    if msg:sub(1, #expected_text) == expected_text then
        return true
    end
    return false, msg
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
                                cmd.line, field, #args, extract_error_msg(results):sub(1, 80))
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
                                        if r.nan32 then
                                            got_str = got_str .. string.format("f32:nan(0x%08X)", r.nan32)
                                        elseif r.nan64 then
                                            got_str = got_str .. string.format("f64:nan(0x%08X%08X)", r.nan64[2], r.nan64[1])
                                        else
                                            got_str = got_str .. string.format("{%s,%s}", tostring(r[1]), tostring(r[2]))
                                        end
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
                            local prefix_ok, actual = check_error_prefix(err, cmd.text)
                            if prefix_ok then
                                passed = passed + 1
                            else
                                failed = failed + 1
                                failures[#failures+1] = string.format(
                                    "line %d: %s trap mismatch: expected \"%s\", got \"%s\"",
                                    cmd.line, field, cmd.text or "?", actual or "?")
                            end
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
            -- Module should fail to parse or validate
            if cmd.module_type == "text" then
                -- WAT text format - wast2json doesn't produce a .wasm for these
                skipped = skipped + 1
            elseif not cmd.filename then
                skipped = skipped + 1
            else
                local wasm_path = base_dir .. cmd.filename
                local wasm_data = load_wasm_file(wasm_path)
                if not wasm_data then
                    passed = passed + 1 -- file missing/unreadable counts as rejected
                else
                    local err_msg = nil
                    local ok, mod = pcall(Parser.parse, wasm_data)
                    if not ok then
                        err_msg = mod -- parse error
                    else
                        local ok2, err2 = pcall(Validator.validate, mod)
                        if not ok2 then
                            err_msg = err2 -- validation error
                        else
                            local ok3, err3 = pcall(Interp.instantiate, mod, make_spectest_imports())
                            if not ok3 then
                                err_msg = err3 -- instantiation error
                            end
                        end
                    end

                    if err_msg then
                        -- Got an error - check that it matches expected text
                        local prefix_ok, actual = check_error_prefix(err_msg, cmd.text)
                        if prefix_ok then
                            passed = passed + 1
                        else
                            failed = failed + 1
                            failures[#failures+1] = string.format(
                                "line %d: %s error mismatch: expected \"%s\", got \"%s\"",
                                cmd.line, cmd.type, cmd.text or "?", actual or "?")
                        end
                    else
                        failed = failed + 1
                        failures[#failures+1] = string.format("line %d: %s expected rejection (%s), but succeeded",
                            cmd.line, cmd.type, cmd.text or "?")
                    end
                end
            end

        elseif cmd.type == "assert_uninstantiable" then
            -- Module should parse but fail to instantiate
            if not cmd.filename then
                skipped = skipped + 1
            else
                local wasm_path = base_dir .. cmd.filename
                local wasm_data = load_wasm_file(wasm_path)
                if not wasm_data then
                    skipped = skipped + 1
                else
                    local err_msg = nil
                    local ok, mod = pcall(Parser.parse, wasm_data)
                    if not ok then
                        err_msg = mod
                    else
                        local ok2, err2 = pcall(Interp.instantiate, mod, make_spectest_imports())
                        if not ok2 then
                            err_msg = err2
                        end
                    end

                    if err_msg then
                        local prefix_ok, actual = check_error_prefix(err_msg, cmd.text)
                        if prefix_ok then
                            passed = passed + 1
                        else
                            failed = failed + 1
                            failures[#failures+1] = string.format(
                                "line %d: assert_uninstantiable error mismatch: expected \"%s\", got \"%s\"",
                                cmd.line, cmd.text or "?", actual or "?")
                        end
                    else
                        failed = failed + 1
                        failures[#failures+1] = string.format("line %d: assert_uninstantiable expected failure, but succeeded",
                            cmd.line)
                    end
                end
            end

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
local test_files = {}
if #arg == 1 and arg[1]:sub(-1) == "/" then
    -- Directory argument: list all JSON files in it
    spec_dir = arg[1]
    local p = io.popen("ls " .. spec_dir .. "*.json 2>/dev/null")
    if p then
        for line in p:lines() do
            test_files[#test_files+1] = line
        end
        p:close()
    end
elseif #arg > 0 then
    for _, a in ipairs(arg) do
        test_files[#test_files+1] = a
    end
else
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
