-- WASM Interpreter Core (Resumable State Machine)
-- No coroutines - designed for Factorio's Lua sandbox.
-- Execution can pause at blocking imports or instruction budget limits,
-- and resume later via run().

local Memory = require("scripts.wasm.memory")
local Opcodes = require("scripts.wasm.opcodes")
local WasmParser = require("scripts.wasm.init")

local bit32 = bit32
local math_floor = math.floor
local unpack = table.unpack or unpack

local dispatch = Opcodes.dispatch
local op_push = Opcodes.push
local op_pop = Opcodes.pop

local Interp = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Evaluate a constant init expression value
local function eval_init_expr(init_val, init_opcode, globals)
    if type(init_val) == "table" and init_val.global_idx then
        return globals[init_val.global_idx]
    end
    if init_opcode == 0x41 then -- i32.const
        return init_val
    elseif init_opcode == 0x42 then -- i64.const
        return init_val
    elseif init_opcode == 0x43 then -- f32.const
        local b0 = string.byte(init_val, 1)
        local b1 = string.byte(init_val, 2)
        local b2 = string.byte(init_val, 3)
        local b3 = string.byte(init_val, 4)
        local bits = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
        local sign = bit32.btest(bits, 0x80000000) and -1 or 1
        local exp = bit32.band(bit32.rshift(bits, 23), 0xFF)
        local mant = bit32.band(bits, 0x7FFFFF)
        if exp == 0xFF then
            if mant == 0 then return sign * math.huge end
            return 0 / 0
        elseif exp == 0 then
            if mant == 0 then return 0.0 end
            return sign * math.ldexp(mant, -149)
        end
        return sign * math.ldexp(mant + 8388608, exp - 150)
    elseif init_opcode == 0x44 then -- f64.const
        local b0 = string.byte(init_val, 1)
        local b1 = string.byte(init_val, 2)
        local b2 = string.byte(init_val, 3)
        local b3 = string.byte(init_val, 4)
        local b4 = string.byte(init_val, 5)
        local b5 = string.byte(init_val, 6)
        local b6 = string.byte(init_val, 7)
        local b7 = string.byte(init_val, 8)
        local lo = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
        local hi = bit32.bor(b4, bit32.lshift(b5, 8), bit32.lshift(b6, 16), bit32.lshift(b7, 24))
        local sign = bit32.btest(hi, 0x80000000) and -1 or 1
        local exp = bit32.band(bit32.rshift(hi, 20), 0x7FF)
        local mant_hi = bit32.band(hi, 0xFFFFF)
        local mant = mant_hi * 4294967296 + lo
        if exp == 0x7FF then
            if mant == 0 then return sign * math.huge end
            return 0 / 0
        elseif exp == 0 then
            if mant == 0 then return 0.0 end
            return sign * math.ldexp(mant, -1074)
        end
        return sign * math.ldexp(mant + 4503599627370496, exp - 1075)
    end
    return init_val
end

-- Default zero value for a WASM type
local function default_value(valtype)
    if valtype == WasmParser.TYPE_I32 then return 0
    elseif valtype == WasmParser.TYPE_I64 then return {0, 0}
    elseif valtype == WasmParser.TYPE_F32 then return 0.0
    elseif valtype == WasmParser.TYPE_F64 then return 0.0
    else return 0
    end
end

-- Resolve an import from the imports table.
-- Supports both flat keys ("env.host_foo") and nested keys (imports["env"]["host_foo"]).
local function resolve_import(imports, mod_name, func_name)
    if not imports then return nil end
    -- Try flat key first
    local flat_key = mod_name .. "." .. func_name
    if imports[flat_key] ~= nil then
        return imports[flat_key]
    end
    -- Try nested
    local mod_table = imports[mod_name]
    if mod_table and mod_table[func_name] ~= nil then
        return mod_table[func_name]
    end
    return nil
end

---------------------------------------------------------------------------
-- Instantiation
---------------------------------------------------------------------------

function Interp.instantiate(module, imports)
    imports = imports or {}

    local instance = {
        module = module,
        memory = nil,
        globals = {},
        table = {},
        import_funcs = {},      -- func_idx -> lua function or {blocking=true, handler=fn}
        data_segments_raw = {},
        element_segments_raw = {},
        exec = nil,             -- execution state (set by call(), persists between run()s)
    }

    -- Allocate memory
    local mem_def = module.memory_def
    local initial_pages = 1
    local max_pages = nil
    if mem_def then
        initial_pages = mem_def.initial or 1
        max_pages = mem_def.maximum
    end
    -- Check if memory is imported
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_MEMORY then
            local mem = resolve_import(imports, imp.module, imp.name)
            if mem then
                instance.memory = mem
            else
                -- Use import's limits if no provider found
                if imp.desc and imp.desc.limits then
                    initial_pages = imp.desc.limits.initial or 0
                    max_pages = imp.desc.limits.maximum
                end
            end
        end
    end
    if not instance.memory then
        instance.memory = Memory.new(initial_pages, max_pages)
    end

    -- Set up imported globals
    local global_idx = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_GLOBAL then
            local val = resolve_import(imports, imp.module, imp.name)
            if val ~= nil then
                instance.globals[global_idx] = val
            else
                instance.globals[global_idx] = default_value(imp.desc.valtype)
            end
            global_idx = global_idx + 1
        end
    end

    -- Set up module globals
    for _, g in ipairs(module.globals) do
        local val = eval_init_expr(g.init, g.init_opcode, instance.globals)
        instance.globals[global_idx] = val
        global_idx = global_idx + 1
    end

    -- Build import function table
    -- Blocking imports are stored as-is (table with .blocking=true, .handler=fn)
    -- Regular imports are stored as plain functions
    local func_idx = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_FUNC then
            local resolved = resolve_import(imports, imp.module, imp.name)
            if resolved then
                instance.import_funcs[func_idx] = resolved
            else
                local mod_name, func_name = imp.module, imp.name
                instance.import_funcs[func_idx] = function()
                    error(string.format("Unresolved import: %s.%s", mod_name, func_name))
                end
            end
            func_idx = func_idx + 1
        end
    end

    -- Initialize data segments
    for i, seg in ipairs(module.data_segments) do
        local offset = eval_init_expr(seg.offset, seg.offset_opcode, instance.globals)
        if type(offset) == "number" then
            if offset + #seg.data > instance.memory.byte_length or offset < 0 then
                error("out of bounds memory access")
            end
            instance.memory:write_bytes(offset, seg.data)
        end
        instance.data_segments_raw[i] = seg.data
    end

    -- Initialize table
    if #module.tables > 0 then
        local tbl_def = module.tables[1]
        for i = 0, (tbl_def.limits.initial or 0) - 1 do
            instance.table[i] = nil
        end
    end

    -- Initialize element segments
    for i, seg in ipairs(module.element_segments) do
        local offset = eval_init_expr(seg.offset, seg.offset_opcode, instance.globals)
        if type(offset) == "number" then
            -- Bounds check against table size
            local tbl_size = 0
            if #module.tables > 0 then
                tbl_size = module.tables[1].limits.initial or 0
            end
            if offset + #seg.func_indices > tbl_size or offset < 0 then
                error("out of bounds table access")
            end
            for j, fidx in ipairs(seg.func_indices) do
                instance.table[offset + j - 1] = fidx
            end
        end
        instance.element_segments_raw[i] = seg.func_indices
    end

    -- Build exports convenience map
    -- Each exported function becomes a synchronous wrapper (for tests / simple use)
    instance.exports = {}
    for _, exp in ipairs(module.exports) do
        if exp.kind == WasmParser.EXT_FUNC then
            local eidx = exp.index
            instance.exports[exp.name] = function(...)
                local results = Interp.execute(instance, eidx, {...})
                if results then return unpack(results) end
            end
        elseif exp.kind == WasmParser.EXT_MEMORY then
            instance.exports[exp.name] = instance.memory
        elseif exp.kind == WasmParser.EXT_GLOBAL then
            instance.exports[exp.name] = {
                get = function() return instance.globals[exp.index] end,
                set = function(v) instance.globals[exp.index] = v end,
            }
        elseif exp.kind == WasmParser.EXT_TABLE then
            instance.exports[exp.name] = instance.table
        end
    end

    -- Run start function if present
    if module.start_func then
        Interp.call(instance, module.start_func, {})
        local result = Interp.run(instance, 10000000) -- generous budget for start
        if result.status == "error" then
            error("WASM start function failed: " .. (result.message or "unknown"))
        end
    end

    return instance
end

---------------------------------------------------------------------------
-- Export lookup
---------------------------------------------------------------------------

function Interp.get_export(instance, name)
    local exp = instance.module.export_map[name]
    if exp and exp.kind == WasmParser.EXT_FUNC then
        return exp.index
    end
    return nil
end

---------------------------------------------------------------------------
-- Set up a function call (does NOT execute - use run() after this)
---------------------------------------------------------------------------

function Interp.call(instance, func_idx, args)
    local module = instance.module
    local func_def = module.funcs[func_idx]
    if not func_def then
        error("Unknown function index: " .. tostring(func_idx))
    end

    local type_info = module.types[func_def.type_idx + 1]

    -- Set up locals: params first, then declared locals
    local locals = {}
    for i = 1, #args do
        locals[i - 1] = args[i]
    end
    for i = #args, #type_info.params - 1 do
        locals[i] = default_value(type_info.params[i + 1])
    end

    if not func_def.import then
        local local_offset = #type_info.params
        for _, decl in ipairs(func_def.code.locals) do
            local def_val = default_value(decl.type)
            for _ = 1, decl.count do
                locals[local_offset] = def_val
                local_offset = local_offset + 1
            end
        end
    end

    -- Create execution state on the instance
    local stack = {}
    local block_stack = {}

    local state = {
        stack = stack,
        sp = 0,
        locals = locals,
        memory = instance.memory,
        globals = instance.globals,
        instance = instance,
        module = module,
        pc = 1,
        code = func_def.import and "" or func_def.code.code,
        block_stack = block_stack,
        block_sp = 1,
        running = true,
        do_return = false,
        call_func = nil,
    }

    -- Function-level block
    block_stack[1] = {
        opcode = 0x02,
        arity = #type_info.results,
        stack_height = 0,
        continuation_pc = nil,
    }

    -- Call stack for nested calls
    instance.exec = {
        state = state,
        call_stack = {},
        call_sp = 0,
        func_idx = func_idx,
        top_type_info = type_info,
        waiting_input = false,
        blocking_return_arity = 0,
        finished = false,
    }

    -- If the top-level function is an import, handle it immediately in run()
    if func_def.import then
        state.is_import_call = true
    end
end

---------------------------------------------------------------------------
-- Provide input value after a blocking import paused execution
---------------------------------------------------------------------------

function Interp.provide_input(instance, value)
    local exec = instance.exec
    if not exec or not exec.waiting_input then return end

    exec.waiting_input = false

    -- Push the return value if the blocking import has results
    if exec.blocking_return_arity > 0 and value ~= nil then
        op_push(exec.state, value)
    end
end

---------------------------------------------------------------------------
-- Main execution loop (resumable)
-- Returns: {status="waiting_input"|"running"|"finished"|"error", ...}
---------------------------------------------------------------------------

function Interp.run(instance, max_instructions)
    local exec = instance.exec
    if not exec then
        return {status = "error", message = "No active execution"}
    end
    if exec.finished then
        return {status = "finished"}
    end
    if exec.waiting_input then
        return {status = "error", message = "Waiting for input - call provide_input first"}
    end

    local state = exec.state
    local call_stack = exec.call_stack
    local call_sp = exec.call_sp
    local func_idx = exec.func_idx
    local module = instance.module
    local instructions = 0

    max_instructions = max_instructions or 50000

    -- Handle top-level import call (from call() on an import function)
    if state.is_import_call then
        state.is_import_call = nil
        local func_def = module.funcs[func_idx]
        local import_fn = instance.import_funcs[func_idx]
        if not import_fn then
            return {status = "error", message = string.format("Unresolved import: %s.%s", func_def.module, func_def.name)}
        end

        -- Check for blocking import
        if type(import_fn) == "table" and import_fn.blocking then
            local handler_result = import_fn.handler(unpack(state.locals))
            local type_info = module.types[func_def.type_idx + 1]
            exec.waiting_input = true
            exec.blocking_return_arity = #type_info.results
            local result = {status = "waiting_input"}
            if handler_result then
                for k, v in pairs(handler_result) do
                    result[k] = v
                end
            end
            exec.call_sp = call_sp
            exec.func_idx = func_idx
            return result
        end

        -- Regular import
        local args = {}
        for i = 0, #exec.top_type_info.params - 1 do
            args[#args + 1] = state.locals[i]
        end
        local result = import_fn(unpack(args))
        exec.finished = true
        if result == nil then
            return {status = "finished", results = {}}
        end
        return {status = "finished", results = {result}}
    end

    state.running = true

    -- Main interpretation loop
    local ok, err = pcall(function()
        while true do
            -- Inner execution loop
            while state.running do
                if instructions >= max_instructions then
                    -- Budget exhausted - save state and return
                    exec.state = state
                    exec.call_stack = call_stack
                    exec.call_sp = call_sp
                    exec.func_idx = func_idx
                    return -- exits pcall
                end

                local op = string.byte(state.code, state.pc)
                state.pc = state.pc + 1
                instructions = instructions + 1

                local handler = dispatch[op]
                if not handler then
                    error(string.format("Unknown opcode: 0x%02X at pc=%d in func %d", op, state.pc - 1, func_idx))
                end
                handler(state)

                -- Check if we need to call another function
                if state.call_func then
                    local target_idx = state.call_func
                    state.call_func = nil

                    local target_def = module.funcs[target_idx]
                    if not target_def then
                        error("Unknown function index: " .. tostring(target_idx))
                    end

                    local target_type = module.types[target_def.type_idx + 1]
                    local num_params = #target_type.params

                    -- Pop arguments from stack
                    local call_args = {}
                    for i = num_params, 1, -1 do
                        call_args[i] = op_pop(state)
                    end

                    if target_def.import then
                        local import_fn = instance.import_funcs[target_idx]
                        if not import_fn then
                            error(string.format("Unresolved import: %s.%s", target_def.module, target_def.name))
                        end

                        -- Check for BLOCKING import
                        if type(import_fn) == "table" and import_fn.blocking then
                            local handler_result = import_fn.handler(unpack(call_args))
                            exec.waiting_input = true
                            exec.blocking_return_arity = #target_type.results
                            exec.state = state
                            exec.call_stack = call_stack
                            exec.call_sp = call_sp
                            exec.func_idx = func_idx
                            -- Store handler result for caller
                            exec._blocking_result = handler_result
                            return -- exits pcall
                        end

                        -- Regular import: call directly
                        local result = import_fn(unpack(call_args))
                        if #target_type.results > 0 and result ~= nil then
                            op_push(state, result)
                        end
                    else
                        -- WASM-to-WASM call: save current frame, set up new one
                        call_sp = call_sp + 1
                        if call_sp > 1000 then
                            error("call stack exhausted")
                        end
                        call_stack[call_sp] = {
                            locals = state.locals,
                            pc = state.pc,
                            code = state.code,
                            block_stack = state.block_stack,
                            block_sp = state.block_sp,
                            stack_base = state.sp,
                            return_arity = #target_type.results,
                            func_idx = func_idx,
                        }

                        func_idx = target_idx
                        local new_locals = {}
                        for i = 1, num_params do
                            new_locals[i - 1] = call_args[i]
                        end
                        local new_local_offset = num_params
                        for _, decl in ipairs(target_def.code.locals) do
                            local def_val = default_value(decl.type)
                            for _ = 1, decl.count do
                                new_locals[new_local_offset] = def_val
                                new_local_offset = new_local_offset + 1
                            end
                        end

                        state.locals = new_locals
                        state.pc = 1
                        state.code = target_def.code.code
                        state.block_stack = {}
                        state.block_sp = 1
                        state.block_stack[1] = {
                            opcode = 0x02,
                            arity = #target_type.results,
                            stack_height = state.sp,
                            continuation_pc = nil,
                        }
                        state.running = true
                        state.do_return = false
                    end
                end
            end

            -- Function ended
            if call_sp > 0 then
                -- Restore caller frame
                local frame = call_stack[call_sp]
                call_stack[call_sp] = nil -- allow GC
                call_sp = call_sp - 1

                local return_arity = frame.return_arity
                local results = {}
                for i = return_arity, 1, -1 do
                    results[i] = op_pop(state)
                end

                state.sp = frame.stack_base
                state.locals = frame.locals
                state.pc = frame.pc
                state.code = frame.code
                state.block_stack = frame.block_stack
                state.block_sp = frame.block_sp
                state.running = true
                state.do_return = false
                state.call_func = nil
                func_idx = frame.func_idx

                for i = 1, return_arity do
                    op_push(state, results[i])
                end
            else
                -- Top-level function returned
                exec.finished = true
                exec.state = state
                exec.call_sp = call_sp
                exec.func_idx = func_idx
                return -- exits pcall
            end
        end
    end)

    -- Save state
    exec.state = state
    exec.call_stack = call_stack
    exec.call_sp = call_sp
    exec.func_idx = func_idx

    if not ok then
        exec.finished = true
        return {status = "error", message = tostring(err)}
    end

    -- Check what caused us to exit
    if exec.waiting_input then
        local result = {status = "waiting_input"}
        local handler_result = exec._blocking_result
        exec._blocking_result = nil
        if handler_result then
            for k, v in pairs(handler_result) do
                result[k] = v
            end
        end
        return result
    end

    if exec.finished then
        -- Collect results from stack
        local num_results = #exec.top_type_info.results
        local results = {}
        for i = num_results, 1, -1 do
            results[i] = op_pop(state)
        end
        return {status = "finished", results = results}
    end

    -- Budget exhausted, still running
    return {status = "running"}
end

---------------------------------------------------------------------------
-- Convenience: synchronous execute (for non-interactive use, e.g. tests)
-- Runs to completion with no instruction limit.
---------------------------------------------------------------------------

function Interp.execute(instance, func_idx, args)
    Interp.call(instance, func_idx, args)
    local result = Interp.run(instance, 100000000)
    if result.status == "error" then
        error(result.message)
    end
    return result.results or {}
end

return Interp
