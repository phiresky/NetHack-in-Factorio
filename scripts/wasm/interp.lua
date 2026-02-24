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
local do_branch = Opcodes.do_branch
local op_push = Opcodes.push

local function fail(msg) error({msg = msg}) end
local op_pop = Opcodes.pop

-- Cached bit32 functions for the hot loop
local bit32_band = bit32.band
local bit32_bor = bit32.bor
local bit32_bxor = bit32.bxor
local bit32_lshift = bit32.lshift
local bit32_rshift = bit32.rshift
local bit32_arshift = bit32.arshift
local bit32_btest = bit32.btest

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
        tables = {},            -- tables[0], tables[1], ... (0-indexed)
        table_sizes = {},       -- table_sizes[0], table_sizes[1], ...
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
                    fail(string.format("Unresolved import: %s.%s", mod_name, func_name))
                end
            end
            func_idx = func_idx + 1
        end
    end

    -- Initialize data segments
    for i, seg in ipairs(module.data_segments) do
        if seg.passive then goto continue_data end
        local offset = eval_init_expr(seg.offset, seg.offset_opcode, instance.globals)
        if type(offset) == "number" then
            if offset + #seg.data > instance.memory.byte_length or offset < 0 then
                fail("out of bounds memory access")
            end
            instance.memory:write_bytes(offset, seg.data)
        end
        instance.data_segments_raw[i] = seg.data
        ::continue_data::
    end

    -- Initialize tables (imported + module-defined)
    local table_count = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_TABLE then
            instance.tables[table_count] = {}
            instance.table_sizes[table_count] = imp.desc.limits.initial or 0
            table_count = table_count + 1
        end
    end
    for _, tbl_def in ipairs(module.tables) do
        instance.tables[table_count] = {}
        instance.table_sizes[table_count] = tbl_def.limits.initial or 0
        table_count = table_count + 1
    end

    -- Initialize element segments
    for i, seg in ipairs(module.element_segments) do
        if not seg.passive and not seg.declarative then
            local tbl_idx = seg.table_idx or 0
            local offset = eval_init_expr(seg.offset, seg.offset_opcode, instance.globals)
            if type(offset) == "number" then
                local tbl_size = instance.table_sizes[tbl_idx] or 0
                if offset + #seg.func_indices > tbl_size or offset < 0 then
                    fail("out of bounds table access")
                end
                local tbl = instance.tables[tbl_idx]
                for j, fidx in ipairs(seg.func_indices) do
                    tbl[offset + j - 1] = fidx
                end
            end
        end
        instance.element_segments_raw[i] = seg.func_indices
    end

    -- Convert function bytecode from strings to byte arrays for faster access
    -- (table integer-index is faster than string.byte C function call)
    for idx, func_def in pairs(module.funcs) do
        if type(idx) == "number" and not func_def.import and func_def.code
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
            instance.exports[exp.name] = instance.tables[exp.index] or instance.tables[0]
        end
    end

    -- Run start function if present
    if module.start_func then
        Interp.call(instance, module.start_func, {})
        local result = Interp.run(instance, 10000000) -- generous budget for start
        if result.status == "error" then
            local msg = result.message
            if type(msg) == "table" and msg.msg then msg = msg.msg end
            fail(tostring(msg or "unknown"))
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
        fail("Unknown function index: " .. tostring(func_idx))
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
        code = func_def.import and {} or func_def.code.code,
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
        -- Cache state fields as locals (not upvalues) for maximum speed
        local stack = state.stack
        local sp = state.sp
        local loc = state.locals
        local code = state.code
        local pc = state.pc
        local memory = state.memory
        local mem_data = memory.data
        local mem_len = memory.byte_length
        local block_stack = state.block_stack
        local block_sp = state.block_sp
        local globals = state.globals
        local running = true
        local instructions = 0
        local max_instr = max_instructions or 50000

        -- Cache bit32 functions as locals
        local bit32_band = bit32_band
        local bit32_bor = bit32_bor
        local bit32_bxor = bit32_bxor
        local bit32_lshift = bit32_lshift
        local bit32_rshift = bit32_rshift
        local bit32_arshift = bit32_arshift
        local bit32_btest = bit32_btest

        while true do
            -- Inner execution loop with inlined hot opcodes
            while running do
                if instructions >= max_instr then
                    -- Save state before exiting
                    state.sp = sp; state.pc = pc; state.locals = loc
                    state.code = code; state.block_stack = block_stack
                    state.block_sp = block_sp; state.memory = memory
                    state.globals = globals
                    exec.call_stack = call_stack
                    exec.call_sp = call_sp; exec.func_idx = func_idx
                    return
                end

                local op = code[pc]
                pc = pc + 1
                instructions = instructions + 1

                -- Inlined opcodes ordered by frequency (covers ~90% of instructions)
                if op == 0x20 then -- local.get (24.3%)
                    local b = code[pc]; pc = pc + 1
                    local idx = b
                    if b >= 128 then
                        idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            idx = bit32_bor(idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    sp = sp + 1
                    stack[sp] = loc[idx]

                elseif op == 0x41 then -- i32.const (18.1%)
                    local b = code[pc]; pc = pc + 1
                    if b < 64 then
                        sp = sp + 1; stack[sp] = b
                    elseif b < 128 then
                        -- Single-byte negative: signed value is b-128, as u32: b+0xFFFFFF80
                        sp = sp + 1; stack[sp] = b + 0xFFFFFF80
                    else
                        -- Multi-byte signed LEB128
                        local val = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            val = bit32_bor(val, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                        if shift < 32 and bit32_btest(b, 0x40) then
                            val = bit32_bor(val, bit32_lshift(-1, shift))
                        end
                        sp = sp + 1; stack[sp] = val
                    end

                elseif op == 0x22 then -- local.tee (6.2%)
                    local b = code[pc]; pc = pc + 1
                    local idx = b
                    if b >= 128 then
                        idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            idx = bit32_bor(idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    loc[idx] = stack[sp]

                elseif op == 0x21 then -- local.set (4.7%)
                    local b = code[pc]; pc = pc + 1
                    local idx = b
                    if b >= 128 then
                        idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            idx = bit32_bor(idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    loc[idx] = stack[sp]
                    sp = sp - 1

                elseif op == 0x6A then -- i32.add (4.7%)
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_band(stack[sp] + b_val, 0xFFFFFFFF)

                elseif op == 0x0D then -- br_if (4.5%)
                    local b = code[pc]; pc = pc + 1
                    local depth = b
                    if b >= 128 then
                        depth = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            depth = bit32_bor(depth, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    local cond = stack[sp]; sp = sp - 1
                    if cond ~= 0 then
                        -- Branch taken: flush to state, use do_branch, refresh
                        state.sp = sp; state.pc = pc; state.locals = loc
                        state.code = code; state.block_stack = block_stack; state.block_sp = block_sp
                        do_branch(state, depth)
                        sp = state.sp; pc = state.pc
                        block_stack = state.block_stack; block_sp = state.block_sp
                        running = state.running
                    end

                elseif op == 0x71 then -- i32.and (3.3%)
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_band(stack[sp], b_val)

                elseif op == 0x6B then -- i32.sub (3.2%)
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_band(stack[sp] - b_val + 0x100000000, 0xFFFFFFFF)

                elseif op == 0x2D then -- i32.load8_u (2.6%)
                    -- Read memarg: skip align, read offset
                    local _a = code[pc]; pc = pc + 1
                    while _a >= 128 do _a = code[pc]; pc = pc + 1 end
                    local offset = code[pc]; pc = pc + 1
                    if offset >= 128 then
                        offset = bit32_band(offset, 0x7F); local sh = 7
                        repeat local ob = code[pc]; pc = pc + 1
                            offset = bit32_bor(offset, bit32_lshift(bit32_band(ob, 0x7F), sh))
                            sh = sh + 7
                        until ob < 128
                    end
                    local addr = stack[sp] + offset
                    if addr + 1 > mem_len or addr < 0 then fail("out of bounds memory access") end
                    local word_idx = bit32_rshift(addr, 2)
                    local byte_off = bit32_band(addr, 3)
                    stack[sp] = bit32_band(bit32_rshift(mem_data[word_idx] or 0, byte_off * 8), 0xFF)

                elseif op == 0x28 then -- i32.load (2.5%)
                    local _a = code[pc]; pc = pc + 1
                    while _a >= 128 do _a = code[pc]; pc = pc + 1 end
                    local offset = code[pc]; pc = pc + 1
                    if offset >= 128 then
                        offset = bit32_band(offset, 0x7F); local sh = 7
                        repeat local ob = code[pc]; pc = pc + 1
                            offset = bit32_bor(offset, bit32_lshift(bit32_band(ob, 0x7F), sh))
                            sh = sh + 7
                        until ob < 128
                    end
                    local addr = stack[sp] + offset
                    if addr + 4 > mem_len or addr < 0 then fail("out of bounds memory access") end
                    if bit32_band(addr, 3) == 0 then
                        stack[sp] = mem_data[bit32_rshift(addr, 2)] or 0
                    else
                        stack[sp] = memory:load_i32(addr)
                    end

                elseif op == 0x1B then -- select (2.5%)
                    local cond = stack[sp]; sp = sp - 1
                    local val2 = stack[sp]; sp = sp - 1
                    if cond == 0 then
                        stack[sp] = val2
                    end

                elseif op == 0x0B then -- end (2.4%)
                    if block_sp <= 0 then
                        running = false
                    else
                        local block = block_stack[block_sp]
                        block_sp = block_sp - 1
                        local n_results = block.result_arity or block.arity
                        if n_results == 0 then
                            sp = block.stack_height
                        elseif n_results == 1 then
                            local val = stack[sp]
                            sp = block.stack_height + 1
                            stack[sp] = val
                        else
                            local base = block.stack_height
                            for i = n_results - 1, 0, -1 do
                                stack[base + 1 + i] = stack[sp - (n_results - 1 - i)]
                            end
                            sp = base + n_results
                        end
                        if block_sp <= 0 then
                            running = false
                        end
                    end

                elseif op == 0x72 then -- i32.or (2.2%)
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_bor(stack[sp], b_val)

                elseif op == 0x02 then -- block (2.0%)
                    local bt = code[pc]
                    if bt == 0x40 then
                        -- Void block (most common)
                        pc = pc + 1
                        block_sp = block_sp + 1
                        block_stack[block_sp] = {
                            opcode = 0x02,
                            arity = 0,
                            stack_height = sp,
                            continuation_pc = nil,
                        }
                    else
                        -- Non-void blocktype: dispatch
                        state.sp = sp; state.pc = pc; state.locals = loc
                        state.code = code; state.block_stack = block_stack; state.block_sp = block_sp
                        dispatch[0x02](state)
                        sp = state.sp; pc = state.pc
                        block_stack = state.block_stack; block_sp = state.block_sp
                    end

                elseif op == 0x10 then -- call
                    local b = code[pc]; pc = pc + 1
                    local target_idx = b
                    if b >= 128 then
                        target_idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            target_idx = bit32_bor(target_idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end

                    local target_def = module.funcs[target_idx]
                    if not target_def then fail("Unknown function index: " .. tostring(target_idx)) end
                    local target_type = module.types[target_def.type_idx + 1]
                    local num_params = #target_type.params

                    local call_args = {}
                    for i = num_params, 1, -1 do
                        call_args[i] = stack[sp]; sp = sp - 1
                    end

                    if target_def.import then
                        local import_fn = instance.import_funcs[target_idx]
                        if not import_fn then
                            fail(string.format("Unresolved import: %s.%s", target_def.module, target_def.name))
                        end

                        if type(import_fn) == "table" and import_fn.blocking then
                            state.sp = sp; state.pc = pc; state.locals = loc
                            state.code = code; state.block_stack = block_stack; state.block_sp = block_sp
                            local handler_result = import_fn.handler(unpack(call_args))
                            exec.waiting_input = true
                            exec.blocking_return_arity = #target_type.results
                            exec.state = state; exec.call_stack = call_stack
                            exec.call_sp = call_sp; exec.func_idx = func_idx
                            exec._blocking_result = handler_result
                            return
                        end

                        local result = import_fn(unpack(call_args))
                        if #target_type.results > 0 and result ~= nil then
                            sp = sp + 1; stack[sp] = result
                        end
                        mem_len = memory.byte_length
                    else
                        -- WASM-to-WASM call
                        call_sp = call_sp + 1
                        if call_sp > 1000 then fail("call stack exhaustion") end
                        call_stack[call_sp] = {
                            locals = loc,
                            pc = pc,
                            code = code,
                            block_stack = block_stack,
                            block_sp = block_sp,
                            stack_base = sp,
                            return_arity = #target_type.results,
                            func_idx = func_idx,
                        }

                        func_idx = target_idx
                        loc = {}
                        for i = 1, num_params do
                            loc[i - 1] = call_args[i]
                        end
                        local new_local_offset = num_params
                        for _, decl in ipairs(target_def.code.locals) do
                            local def_val = default_value(decl.type)
                            for _ = 1, decl.count do
                                loc[new_local_offset] = def_val
                                new_local_offset = new_local_offset + 1
                            end
                        end

                        pc = 1
                        code = target_def.code.code
                        block_stack = {}
                        block_sp = 1
                        block_stack[1] = {
                            opcode = 0x02,
                            arity = #target_type.results,
                            stack_height = sp,
                            continuation_pc = nil,
                        }
                    end

                elseif op == 0x1A then -- drop
                    sp = sp - 1

                elseif op == 0x45 then -- i32.eqz
                    stack[sp] = stack[sp] == 0 and 1 or 0

                elseif op == 0x46 then -- i32.eq
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] == b_val and 1 or 0

                elseif op == 0x47 then -- i32.ne
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] ~= b_val and 1 or 0

                elseif op == 0x48 then -- i32.lt_s
                    local b_val = stack[sp]; sp = sp - 1
                    local a_val = stack[sp]
                    local a_s = a_val >= 0x80000000 and a_val - 0x100000000 or a_val
                    local b_s = b_val >= 0x80000000 and b_val - 0x100000000 or b_val
                    stack[sp] = a_s < b_s and 1 or 0

                elseif op == 0x49 then -- i32.lt_u
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] < b_val and 1 or 0

                elseif op == 0x4A then -- i32.gt_s
                    local b_val = stack[sp]; sp = sp - 1
                    local a_val = stack[sp]
                    local a_s = a_val >= 0x80000000 and a_val - 0x100000000 or a_val
                    local b_s = b_val >= 0x80000000 and b_val - 0x100000000 or b_val
                    stack[sp] = a_s > b_s and 1 or 0

                elseif op == 0x4B then -- i32.gt_u
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] > b_val and 1 or 0

                elseif op == 0x4C then -- i32.le_s
                    local b_val = stack[sp]; sp = sp - 1
                    local a_val = stack[sp]
                    local a_s = a_val >= 0x80000000 and a_val - 0x100000000 or a_val
                    local b_s = b_val >= 0x80000000 and b_val - 0x100000000 or b_val
                    stack[sp] = a_s <= b_s and 1 or 0

                elseif op == 0x4D then -- i32.le_u
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] <= b_val and 1 or 0

                elseif op == 0x4E then -- i32.ge_s
                    local b_val = stack[sp]; sp = sp - 1
                    local a_val = stack[sp]
                    local a_s = a_val >= 0x80000000 and a_val - 0x100000000 or a_val
                    local b_s = b_val >= 0x80000000 and b_val - 0x100000000 or b_val
                    stack[sp] = a_s >= b_s and 1 or 0

                elseif op == 0x4F then -- i32.ge_u
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = stack[sp] >= b_val and 1 or 0

                elseif op == 0x73 then -- i32.xor
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_bxor(stack[sp], b_val)

                elseif op == 0x74 then -- i32.shl
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_lshift(stack[sp], bit32_band(b_val, 31))

                elseif op == 0x75 then -- i32.shr_s
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_arshift(stack[sp], bit32_band(b_val, 31))

                elseif op == 0x76 then -- i32.shr_u
                    local b_val = stack[sp]; sp = sp - 1
                    stack[sp] = bit32_rshift(stack[sp], bit32_band(b_val, 31))

                elseif op == 0x6C then -- i32.mul
                    local b_val = stack[sp]; sp = sp - 1
                    local a_val = stack[sp]
                    local a_lo = bit32_band(a_val, 0xFFFF)
                    local a_hi = bit32_rshift(a_val, 16)
                    local b_lo = bit32_band(b_val, 0xFFFF)
                    local b_hi = bit32_rshift(b_val, 16)
                    stack[sp] = bit32_band(a_lo * b_lo + (a_lo * b_hi + a_hi * b_lo) * 65536, 0xFFFFFFFF)

                elseif op == 0x23 then -- global.get
                    local b = code[pc]; pc = pc + 1
                    local idx = b
                    if b >= 128 then
                        idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            idx = bit32_bor(idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    sp = sp + 1
                    stack[sp] = globals[idx]

                elseif op == 0x24 then -- global.set
                    local b = code[pc]; pc = pc + 1
                    local idx = b
                    if b >= 128 then
                        idx = bit32_band(b, 0x7F)
                        local shift = 7
                        repeat b = code[pc]; pc = pc + 1
                            idx = bit32_bor(idx, bit32_lshift(bit32_band(b, 0x7F), shift))
                            shift = shift + 7
                        until b < 128
                    end
                    globals[idx] = stack[sp]
                    sp = sp - 1

                elseif op == 0x36 then -- i32.store
                    local _a = code[pc]; pc = pc + 1
                    while _a >= 128 do _a = code[pc]; pc = pc + 1 end
                    local offset = code[pc]; pc = pc + 1
                    if offset >= 128 then
                        offset = bit32_band(offset, 0x7F); local sh = 7
                        repeat local ob = code[pc]; pc = pc + 1
                            offset = bit32_bor(offset, bit32_lshift(bit32_band(ob, 0x7F), sh))
                            sh = sh + 7
                        until ob < 128
                    end
                    local val = stack[sp]; sp = sp - 1
                    local addr = stack[sp] + offset; sp = sp - 1
                    if addr + 4 > mem_len or addr < 0 then fail("out of bounds memory access") end
                    val = bit32_band(val, 0xFFFFFFFF)
                    if bit32_band(addr, 3) == 0 then
                        mem_data[bit32_rshift(addr, 2)] = val
                    else
                        memory:store_i32(addr, val)
                    end

                elseif op == 0x3A then -- i32.store8
                    local _a = code[pc]; pc = pc + 1
                    while _a >= 128 do _a = code[pc]; pc = pc + 1 end
                    local offset = code[pc]; pc = pc + 1
                    if offset >= 128 then
                        offset = bit32_band(offset, 0x7F); local sh = 7
                        repeat local ob = code[pc]; pc = pc + 1
                            offset = bit32_bor(offset, bit32_lshift(bit32_band(ob, 0x7F), sh))
                            sh = sh + 7
                        until ob < 128
                    end
                    local val = stack[sp]; sp = sp - 1
                    local addr = stack[sp] + offset; sp = sp - 1
                    if addr + 1 > mem_len or addr < 0 then fail("out of bounds memory access") end
                    local word_idx = bit32_rshift(addr, 2)
                    local byte_off = bit32_band(addr, 3)
                    local bshift = byte_off * 8
                    local mask = bit32.bnot(bit32_lshift(0xFF, bshift))
                    local word = mem_data[word_idx] or 0
                    mem_data[word_idx] = bit32_bor(bit32_band(word, mask), bit32_lshift(bit32_band(val, 0xFF), bshift))

                else
                    -- Dispatch fallback for all other opcodes (~10% of instructions)
                    state.sp = sp; state.pc = pc; state.locals = loc
                    state.code = code; state.block_stack = block_stack; state.block_sp = block_sp
                    local handler = dispatch[op]
                    if not handler then
                        fail(string.format("Unknown opcode: 0x%02X at pc=%d in func %d", op, pc - 1, func_idx))
                    end
                    handler(state)
                    -- Refresh all cached locals from state
                    sp = state.sp; pc = state.pc; loc = state.locals
                    code = state.code; block_stack = state.block_stack
                    block_sp = state.block_sp; running = state.running
                    memory = state.memory; mem_data = memory.data
                    mem_len = memory.byte_length; globals = state.globals

                    -- Check call_func (from call_indirect or similar dispatched opcodes)
                    if state.call_func then
                        local target_idx = state.call_func
                        state.call_func = nil

                        local target_def = module.funcs[target_idx]
                        if not target_def then
                            fail("Unknown function index: " .. tostring(target_idx))
                        end

                        local target_type = module.types[target_def.type_idx + 1]
                        local num_params = #target_type.params

                        local call_args = {}
                        for i = num_params, 1, -1 do
                            call_args[i] = stack[sp]; sp = sp - 1
                        end

                        if target_def.import then
                            local import_fn = instance.import_funcs[target_idx]
                            if not import_fn then
                                fail(string.format("Unresolved import: %s.%s", target_def.module, target_def.name))
                            end

                            if type(import_fn) == "table" and import_fn.blocking then
                                state.sp = sp; state.pc = pc; state.locals = loc
                                state.code = code; state.block_stack = block_stack; state.block_sp = block_sp
                                local handler_result = import_fn.handler(unpack(call_args))
                                exec.waiting_input = true
                                exec.blocking_return_arity = #target_type.results
                                exec.state = state; exec.call_stack = call_stack
                                exec.call_sp = call_sp; exec.func_idx = func_idx
                                exec._blocking_result = handler_result
                                return
                            end

                            local result = import_fn(unpack(call_args))
                            if #target_type.results > 0 and result ~= nil then
                                sp = sp + 1; stack[sp] = result
                            end
                            mem_len = memory.byte_length
                        else
                            call_sp = call_sp + 1
                            if call_sp > 1000 then fail("call stack exhaustion") end
                            call_stack[call_sp] = {
                                locals = loc,
                                pc = pc,
                                code = code,
                                block_stack = block_stack,
                                block_sp = block_sp,
                                stack_base = sp,
                                return_arity = #target_type.results,
                                func_idx = func_idx,
                            }

                            func_idx = target_idx
                            loc = {}
                            for i = 1, num_params do
                                loc[i - 1] = call_args[i]
                            end
                            local new_local_offset = num_params
                            for _, decl in ipairs(target_def.code.locals) do
                                local def_val = default_value(decl.type)
                                for _ = 1, decl.count do
                                    loc[new_local_offset] = def_val
                                    new_local_offset = new_local_offset + 1
                                end
                            end

                            pc = 1
                            code = target_def.code.code
                            block_stack = {}
                            block_sp = 1
                            block_stack[1] = {
                                opcode = 0x02,
                                arity = #target_type.results,
                                stack_height = sp,
                                continuation_pc = nil,
                            }
                        end
                    end
                end
            end -- while running

            -- Function ended (running became false)
            if call_sp > 0 then
                -- Restore caller frame
                local frame = call_stack[call_sp]
                call_stack[call_sp] = nil -- allow GC
                call_sp = call_sp - 1

                local return_arity = frame.return_arity
                local results = {}
                for i = return_arity, 1, -1 do
                    results[i] = stack[sp]; sp = sp - 1
                end

                sp = frame.stack_base
                loc = frame.locals
                pc = frame.pc
                code = frame.code
                block_stack = frame.block_stack
                block_sp = frame.block_sp
                func_idx = frame.func_idx
                running = true
                state.running = true

                for i = 1, return_arity do
                    sp = sp + 1; stack[sp] = results[i]
                end
            else
                -- Top-level function returned
                state.sp = sp; state.pc = pc; state.locals = loc
                state.code = code; state.block_stack = block_stack
                state.block_sp = block_sp; state.memory = memory
                state.globals = globals
                exec.call_stack = call_stack
                exec.call_sp = call_sp; exec.func_idx = func_idx
                exec.finished = true
                return -- exits pcall
            end
        end -- while true
    end) -- pcall

    -- State was flushed inside pcall before each return point
    exec.state = state

    if not ok then
        exec.finished = true
        return {status = "error", message = err}
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
        local st_sp = state.sp
        local st_stack = state.stack
        local num_results = #exec.top_type_info.results
        local results = {}
        for i = num_results, 1, -1 do
            results[i] = st_stack[st_sp]; st_sp = st_sp - 1
        end
        state.sp = st_sp
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
        local msg = result.message
        if type(msg) ~= "table" or not msg.msg then
            -- Wrap non-table errors for consistent handling
            msg = {msg = tostring(msg)}
        end
        error(msg)
    end
    return result.results or {}
end

return Interp
