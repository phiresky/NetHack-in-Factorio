-- Shared test utilities for WASM spec/unit tests.

local Memory = require("scripts.wasm.memory")
local V = require("build.test_values")

local M = {}

-- Re-export test_values for convenience
M.convert_arg = V.convert_arg
M.is_nan_value = V.is_nan_value
M.compare_result = V.compare_result

function M.load_wasm_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function M.make_spectest_imports()
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

function M.convert_action_args(action)
    local args = {}
    for _, a in ipairs(action.args or {}) do
        args[#args + 1] = V.convert_arg(a)
    end
    return args
end

function M.extract_error_msg(err)
    if type(err) == "table" and err.msg then return err.msg end
    return tostring(err)
end

function M.check_error_prefix(err, expected_text)
    if not expected_text or expected_text == "" then return true end
    local msg = M.extract_error_msg(err)
    if msg:sub(1, #expected_text) == expected_text then return true end
    return false, msg
end

return M
