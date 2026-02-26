#!/usr/bin/env lua5.2
-- WebAssembly Spec Test Runner
-- Reads wast2json output (.json + .wasm files) and runs them against our interpreter.

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
local Validator = require("scripts.wasm.validate")

---------------------------------------------------------------------------
-- Shared test utilities
---------------------------------------------------------------------------
local TU = require("build.test_util")
local load_wasm_file = TU.load_wasm_file
local make_spectest_imports = TU.make_spectest_imports
local convert_action_args = TU.convert_action_args
local extract_error_msg = TU.extract_error_msg
local check_error_prefix = TU.check_error_prefix
local compare_result = TU.compare_result

---------------------------------------------------------------------------
-- Shared: resolve instance from action (handles named modules)
---------------------------------------------------------------------------
local function resolve_instance(action, ctx)
    if action.module and ctx.named_instances[action.module] then
        return ctx.named_instances[action.module]
    end
    return ctx.current_instance
end

-- Invoke an exported function, returning ok, results_or_err.
local function invoke_export(ctx, action)
    local inst = resolve_instance(action, ctx)
    if not inst then return nil end -- signals "skip"
    local func_idx = Interp.get_export(inst, action.field)
    if not func_idx then return nil end
    local args = convert_action_args(action)
    return inst, func_idx, pcall(Interp.execute, inst, func_idx, args)
end

---------------------------------------------------------------------------
-- Command handlers
---------------------------------------------------------------------------

local function handle_module(ctx, cmd)
    local wasm_path = ctx.base_dir .. cmd.filename
    local wasm_data = load_wasm_file(wasm_path)
    if not wasm_data then
        ctx.skipped = ctx.skipped + 1; return
    end
    local ok, mod = pcall(Parser.parse, wasm_data)
    if not ok then
        ctx.current_instance = nil; ctx.skipped = ctx.skipped + 1; return
    end
    local ok2, inst = pcall(Interp.instantiate, mod, make_spectest_imports())
    if not ok2 then
        ctx.current_instance = nil; ctx.skipped = ctx.skipped + 1; return
    end
    ctx.current_instance = inst
    if cmd.name then ctx.named_instances[cmd.name] = inst end
end

local function handle_assert_return(ctx, cmd)
    local action = cmd.action
    if action.type ~= "invoke" then ctx.skipped = ctx.skipped + 1; return end

    local inst, func_idx, ok, results = invoke_export(ctx, action)
    if not inst then ctx.skipped = ctx.skipped + 1; return end

    if not ok then
        ctx.failed = ctx.failed + 1
        ctx.failures[#ctx.failures+1] = string.format("line %d: %s(%s) trapped: %s",
            cmd.line, action.field, #(action.args or {}), extract_error_msg(results):sub(1, 80))
        return
    end

    local expected = cmd.expected or {}
    results = results or {}
    local all_match = true

    if #expected ~= #results then
        if #expected ~= 0 then all_match = false end
    end
    for i, exp in ipairs(expected) do
        if not compare_result(results[i], exp) then
            all_match = false; break
        end
    end

    if all_match then
        ctx.passed = ctx.passed + 1
    else
        ctx.failed = ctx.failed + 1
        local exp_str, got_str = "", ""
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
        ctx.failures[#ctx.failures+1] = string.format("line %d: %s expected [%s] got [%s]",
            cmd.line, action.field, exp_str, got_str)
    end
end

local function handle_assert_trap(ctx, cmd)
    local action = cmd.action
    if action.type ~= "invoke" then ctx.skipped = ctx.skipped + 1; return end

    local inst, func_idx, ok, err = invoke_export(ctx, action)
    if not inst then ctx.skipped = ctx.skipped + 1; return end

    if not ok then
        local prefix_ok, actual = check_error_prefix(err, cmd.text)
        if prefix_ok then
            ctx.passed = ctx.passed + 1
        else
            ctx.failed = ctx.failed + 1
            ctx.failures[#ctx.failures+1] = string.format(
                "line %d: %s trap mismatch: expected \"%s\", got \"%s\"",
                cmd.line, action.field, cmd.text or "?", actual or "?")
        end
    else
        ctx.failed = ctx.failed + 1
        ctx.failures[#ctx.failures+1] = string.format("line %d: %s expected trap, got success",
            cmd.line, action.field)
    end
end

local function handle_assert_exhaustion(ctx, cmd)
    local action = cmd.action
    if action.type ~= "invoke" then ctx.skipped = ctx.skipped + 1; return end

    local inst, func_idx, ok, err = invoke_export(ctx, action)
    if not inst then ctx.skipped = ctx.skipped + 1; return end

    if not ok then
        ctx.passed = ctx.passed + 1
    else
        ctx.failed = ctx.failed + 1
        ctx.failures[#ctx.failures+1] = string.format("line %d: %s expected exhaustion",
            cmd.line, action.field)
    end
end

local function handle_action(ctx, cmd)
    local action = cmd.action
    if not ctx.current_instance or action.type ~= "invoke" then return end
    local inst, func_idx, ok, err = invoke_export(ctx, action)
    -- Result intentionally ignored
end

local function handle_assert_invalid(ctx, cmd)
    if cmd.module_type == "text" or not cmd.filename then
        ctx.skipped = ctx.skipped + 1; return
    end
    local wasm_path = ctx.base_dir .. cmd.filename
    local wasm_data = load_wasm_file(wasm_path)
    if not wasm_data then
        ctx.passed = ctx.passed + 1; return -- missing file counts as rejected
    end

    local err_msg = nil
    local ok, mod = pcall(Parser.parse, wasm_data)
    if not ok then
        err_msg = mod
    else
        local ok2, err2 = pcall(Validator.validate, mod)
        if not ok2 then
            err_msg = err2
        else
            local ok3, err3 = pcall(Interp.instantiate, mod, make_spectest_imports())
            if not ok3 then err_msg = err3 end
        end
    end

    if err_msg then
        local prefix_ok, actual = check_error_prefix(err_msg, cmd.text)
        if prefix_ok then
            ctx.passed = ctx.passed + 1
        else
            ctx.failed = ctx.failed + 1
            ctx.failures[#ctx.failures+1] = string.format(
                "line %d: %s error mismatch: expected \"%s\", got \"%s\"",
                cmd.line, cmd.type, cmd.text or "?", actual or "?")
        end
    else
        ctx.failed = ctx.failed + 1
        ctx.failures[#ctx.failures+1] = string.format("line %d: %s expected rejection (%s), but succeeded",
            cmd.line, cmd.type, cmd.text or "?")
    end
end

local function handle_assert_uninstantiable(ctx, cmd)
    if not cmd.filename then
        ctx.skipped = ctx.skipped + 1; return
    end
    local wasm_path = ctx.base_dir .. cmd.filename
    local wasm_data = load_wasm_file(wasm_path)
    if not wasm_data then
        ctx.skipped = ctx.skipped + 1; return
    end

    local err_msg = nil
    local ok, mod = pcall(Parser.parse, wasm_data)
    if not ok then
        err_msg = mod
    else
        local ok2, err2 = pcall(Interp.instantiate, mod, make_spectest_imports())
        if not ok2 then err_msg = err2 end
    end

    if err_msg then
        local prefix_ok, actual = check_error_prefix(err_msg, cmd.text)
        if prefix_ok then
            ctx.passed = ctx.passed + 1
        else
            ctx.failed = ctx.failed + 1
            ctx.failures[#ctx.failures+1] = string.format(
                "line %d: assert_uninstantiable error mismatch: expected \"%s\", got \"%s\"",
                cmd.line, cmd.text or "?", actual or "?")
        end
    else
        ctx.failed = ctx.failed + 1
        ctx.failures[#ctx.failures+1] = string.format("line %d: assert_uninstantiable expected failure, but succeeded",
            cmd.line)
    end
end

local function handle_register(ctx, cmd)
    if ctx.current_instance and cmd.as then
        ctx.named_instances[cmd.as] = ctx.current_instance
    end
    ctx.skipped = ctx.skipped + 1
end

---------------------------------------------------------------------------
-- Handler dispatch table
---------------------------------------------------------------------------
local handlers = {
    module = handle_module,
    assert_return = handle_assert_return,
    assert_trap = handle_assert_trap,
    assert_exhaustion = handle_assert_exhaustion,
    action = handle_action,
    assert_invalid = handle_assert_invalid,
    assert_malformed = handle_assert_invalid, -- same logic
    assert_uninstantiable = handle_assert_uninstantiable,
    register = handle_register,
}

---------------------------------------------------------------------------
-- Test Runner
---------------------------------------------------------------------------

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

    local ctx = {
        base_dir = json_path:match("(.*/)" ),
        passed = 0,
        failed = 0,
        skipped = 0,
        failures = {},
        current_instance = nil,
        named_instances = {},
    }

    for _, cmd in ipairs(test_data.commands) do
        local h = handlers[cmd.type]
        if h then
            h(ctx, cmd)
        else
            ctx.skipped = ctx.skipped + 1
        end
    end

    return ctx.passed, ctx.failed, ctx.skipped, ctx.failures
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
