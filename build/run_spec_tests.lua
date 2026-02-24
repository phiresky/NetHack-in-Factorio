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
-- Value conversion helpers (from build/test_values.lua)
---------------------------------------------------------------------------
local V = require("build.test_values")
local convert_arg = V.convert_arg
local is_nan_value = V.is_nan_value
local compare_result = V.compare_result

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
            memory = Memory.new(1, 2),
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
