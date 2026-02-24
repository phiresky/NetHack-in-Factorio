-- WASM Module Validator
-- Performs static type checking and index validation per the WASM spec.
-- Called after parsing, before instantiation.

local WasmParser = require("scripts.wasm.init")
local bit32 = bit32

local I32 = WasmParser.TYPE_I32   -- 0x7F
local I64 = WasmParser.TYPE_I64   -- 0x7E
local F32 = WasmParser.TYPE_F32   -- 0x7D
local F64 = WasmParser.TYPE_F64   -- 0x7C

---------------------------------------------------------------------------
-- Bytecode Reader (lightweight, for validation only)
---------------------------------------------------------------------------

local function read_byte(r)
    local b = string.byte(r.code, r.pos)
    if not b then error("unexpected end of code") end
    r.pos = r.pos + 1
    return b
end

local function read_leb128_u(r)
    local result = 0
    local shift = 0
    local code = r.code
    local pos = r.pos
    while true do
        local b = string.byte(code, pos)
        if not b then error("unexpected end of code") end
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        if bit32.band(b, 0x80) == 0 then break end
        shift = shift + 7
    end
    r.pos = pos
    return result
end

local function read_leb128_s(r)
    local result = 0
    local shift = 0
    local code = r.code
    local pos = r.pos
    local b
    while true do
        b = string.byte(code, pos)
        if not b then error("unexpected end of code") end
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then break end
    end
    r.pos = pos
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    if bit32.btest(result, 0x80000000) then
        return result - 0x100000000
    end
    return result
end

local function read_leb128_s64(r)
    -- Just skip the bytes, validator doesn't need the value
    local code = r.code
    local pos = r.pos
    while true do
        local b = string.byte(code, pos)
        if not b then error("unexpected end of code") end
        pos = pos + 1
        if bit32.band(b, 0x80) == 0 then break end
    end
    r.pos = pos
end

local function read_memarg(r)
    read_leb128_u(r) -- align
    read_leb128_u(r) -- offset
end

-- Read block type, returns {params, results} arrays
local function read_blocktype(r, module)
    local result = 0
    local shift = 0
    local code = r.code
    local pos = r.pos
    local b
    while true do
        b = string.byte(code, pos)
        if not b then error("unexpected end of code") end
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then break end
    end
    r.pos = pos
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    if bit32.btest(result, 0x80000000) then
        result = result - 0x100000000
    end

    if result == -64 then
        return {}, {} -- void
    elseif result < 0 then
        -- Single value type encoded as negative
        local valtype = bit32.band(result, 0x7F)
        return {}, {valtype}
    else
        -- Type index
        local type_info = module.types[result + 1]
        if not type_info then
            error("type mismatch") -- unknown type index in block
        end
        return type_info.params, type_info.results
    end
end

---------------------------------------------------------------------------
-- Opcode type signatures: {pops, pushes}
-- Built once, reused for all validations
---------------------------------------------------------------------------

local op_sig = {}

-- i32 test
op_sig[0x45] = {{I32}, {I32}} -- i32.eqz

-- i32 comparison
for _, op in ipairs({0x46,0x47,0x48,0x49,0x4A,0x4B,0x4C,0x4D,0x4E,0x4F}) do
    op_sig[op] = {{I32, I32}, {I32}}
end

-- i64 test
op_sig[0x50] = {{I64}, {I32}} -- i64.eqz

-- i64 comparison
for _, op in ipairs({0x51,0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A}) do
    op_sig[op] = {{I64, I64}, {I32}}
end

-- f32 comparison
for _, op in ipairs({0x5B,0x5C,0x5D,0x5E,0x5F,0x60}) do
    op_sig[op] = {{F32, F32}, {I32}}
end

-- f64 comparison
for _, op in ipairs({0x61,0x62,0x63,0x64,0x65,0x66}) do
    op_sig[op] = {{F64, F64}, {I32}}
end

-- i32 unary
for _, op in ipairs({0x67, 0x68, 0x69}) do -- clz, ctz, popcnt
    op_sig[op] = {{I32}, {I32}}
end

-- i32 binary
for _, op in ipairs({0x6A,0x6B,0x6C,0x6D,0x6E,0x6F,0x70,0x71,0x72,0x73,0x74,0x75,0x76,0x77,0x78}) do
    op_sig[op] = {{I32, I32}, {I32}}
end

-- i64 unary
for _, op in ipairs({0x79, 0x7A, 0x7B}) do -- clz, ctz, popcnt
    op_sig[op] = {{I64}, {I64}}
end

-- i64 binary
for _, op in ipairs({0x7C,0x7D,0x7E,0x7F,0x80,0x81,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8A}) do
    op_sig[op] = {{I64, I64}, {I64}}
end

-- f32 unary
for _, op in ipairs({0x8B,0x8C,0x8D,0x8E,0x8F,0x90,0x91}) do
    op_sig[op] = {{F32}, {F32}}
end

-- f32 binary
for _, op in ipairs({0x92,0x93,0x94,0x95,0x96,0x97,0x98}) do
    op_sig[op] = {{F32, F32}, {F32}}
end

-- f64 unary
for _, op in ipairs({0x99,0x9A,0x9B,0x9C,0x9D,0x9E,0x9F}) do
    op_sig[op] = {{F64}, {F64}}
end

-- f64 binary
for _, op in ipairs({0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6}) do
    op_sig[op] = {{F64, F64}, {F64}}
end

-- Conversions
op_sig[0xA7] = {{I64}, {I32}}    -- i32.wrap_i64
op_sig[0xA8] = {{F32}, {I32}}    -- i32.trunc_f32_s
op_sig[0xA9] = {{F32}, {I32}}    -- i32.trunc_f32_u
op_sig[0xAA] = {{F64}, {I32}}    -- i32.trunc_f64_s
op_sig[0xAB] = {{F64}, {I32}}    -- i32.trunc_f64_u
op_sig[0xAC] = {{I32}, {I64}}    -- i64.extend_i32_s
op_sig[0xAD] = {{I32}, {I64}}    -- i64.extend_i32_u
op_sig[0xAE] = {{F32}, {I64}}    -- i64.trunc_f32_s
op_sig[0xAF] = {{F32}, {I64}}    -- i64.trunc_f32_u
op_sig[0xB0] = {{F64}, {I64}}    -- i64.trunc_f64_s
op_sig[0xB1] = {{F64}, {I64}}    -- i64.trunc_f64_u
op_sig[0xB2] = {{I32}, {F32}}    -- f32.convert_i32_s
op_sig[0xB3] = {{I32}, {F32}}    -- f32.convert_i32_u
op_sig[0xB4] = {{I64}, {F32}}    -- f32.convert_i64_s
op_sig[0xB5] = {{I64}, {F32}}    -- f32.convert_i64_u
op_sig[0xB6] = {{F64}, {F32}}    -- f32.demote_f64
op_sig[0xB7] = {{I32}, {F64}}    -- f64.convert_i32_s
op_sig[0xB8] = {{I32}, {F64}}    -- f64.convert_i32_u
op_sig[0xB9] = {{I64}, {F64}}    -- f64.convert_i64_s
op_sig[0xBA] = {{I64}, {F64}}    -- f64.convert_i64_u
op_sig[0xBB] = {{F32}, {F64}}    -- f64.promote_f32
op_sig[0xBC] = {{F32}, {I32}}    -- i32.reinterpret_f32
op_sig[0xBD] = {{F64}, {I64}}    -- i64.reinterpret_f64
op_sig[0xBE] = {{I32}, {F32}}    -- f32.reinterpret_i32
op_sig[0xBF] = {{I64}, {F64}}    -- f64.reinterpret_i64

-- i32 extend (sign extension proposal, but included in recent spec)
op_sig[0xC0] = {{I32}, {I32}}    -- i32.extend8_s
op_sig[0xC1] = {{I32}, {I32}}    -- i32.extend16_s
op_sig[0xC2] = {{I64}, {I64}}    -- i64.extend8_s
op_sig[0xC3] = {{I64}, {I64}}    -- i64.extend16_s
op_sig[0xC4] = {{I64}, {I64}}    -- i64.extend32_s

-- Memory load ops: pop i32 addr, push result type
op_sig[0x28] = {{I32}, {I32}}    -- i32.load
op_sig[0x29] = {{I32}, {I64}}    -- i64.load
op_sig[0x2A] = {{I32}, {F32}}    -- f32.load
op_sig[0x2B] = {{I32}, {F64}}    -- f64.load
op_sig[0x2C] = {{I32}, {I32}}    -- i32.load8_s
op_sig[0x2D] = {{I32}, {I32}}    -- i32.load8_u
op_sig[0x2E] = {{I32}, {I32}}    -- i32.load16_s
op_sig[0x2F] = {{I32}, {I32}}    -- i32.load16_u
op_sig[0x30] = {{I32}, {I64}}    -- i64.load8_s
op_sig[0x31] = {{I32}, {I64}}    -- i64.load8_u
op_sig[0x32] = {{I32}, {I64}}    -- i64.load16_s
op_sig[0x33] = {{I32}, {I64}}    -- i64.load16_u
op_sig[0x34] = {{I32}, {I64}}    -- i64.load32_s
op_sig[0x35] = {{I32}, {I64}}    -- i64.load32_u

-- Memory store ops: pop value + i32 addr
op_sig[0x36] = {{I32, I32}, {}}  -- i32.store
op_sig[0x37] = {{I32, I64}, {}}  -- i64.store
op_sig[0x38] = {{I32, F32}, {}}  -- f32.store
op_sig[0x39] = {{I32, F64}, {}}  -- f64.store
op_sig[0x3A] = {{I32, I32}, {}}  -- i32.store8
op_sig[0x3B] = {{I32, I32}, {}}  -- i32.store16
op_sig[0x3C] = {{I32, I64}, {}}  -- i64.store8
op_sig[0x3D] = {{I32, I64}, {}}  -- i64.store16
op_sig[0x3E] = {{I32, I64}, {}}  -- i64.store32

-- Extended ops (0xFC prefix) - saturating truncations
local fc_sig = {}
fc_sig[0] = {{F32}, {I32}}    -- i32.trunc_sat_f32_s
fc_sig[1] = {{F32}, {I32}}    -- i32.trunc_sat_f32_u
fc_sig[2] = {{F64}, {I32}}    -- i32.trunc_sat_f64_s
fc_sig[3] = {{F64}, {I32}}    -- i32.trunc_sat_f64_u
fc_sig[4] = {{F32}, {I64}}    -- i64.trunc_sat_f32_s
fc_sig[5] = {{F32}, {I64}}    -- i64.trunc_sat_f32_u
fc_sig[6] = {{F64}, {I64}}    -- i64.trunc_sat_f64_s
fc_sig[7] = {{F64}, {I64}}    -- i64.trunc_sat_f64_u

---------------------------------------------------------------------------
-- Type Stack + Control Frame operations
---------------------------------------------------------------------------

local UNKNOWN = "unknown" -- sentinel for polymorphic stack

local function type_name(t)
    if t == I32 then return "i32"
    elseif t == I64 then return "i64"
    elseif t == F32 then return "f32"
    elseif t == F64 then return "f64"
    elseif t == UNKNOWN then return "unknown"
    else return string.format("0x%02X", t or 0)
    end
end

local function make_validator(module, func_type, local_types, num_locals, code)
    local v = {}
    v.module = module
    v.func_type = func_type
    v.local_types = local_types
    v.num_locals = num_locals

    -- Operand type stack
    v.types = {}
    v.tsp = 0

    -- Control frame stack
    v.ctrls = {}
    v.ctrl_sp = 0

    -- Count total functions and globals for index validation
    v.num_funcs = 0
    for _ in pairs(module.funcs) do v.num_funcs = v.num_funcs + 1 end
    v.num_globals = 0
    -- Count imported globals
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_GLOBAL then
            v.num_globals = v.num_globals + 1
        end
    end
    v.num_globals = v.num_globals + #module.globals

    v.has_memory = (module.memory_def ~= nil)
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_MEMORY then
            v.has_memory = true
        end
    end

    v.has_table = (#module.tables > 0)
    v.table_elem_type = nil
    if #module.tables > 0 then
        v.table_elem_type = module.tables[1].elem_type
    end
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_TABLE then
            v.has_table = true
            if imp.desc then v.table_elem_type = imp.desc.elem_type end
        end
    end

    -- Build global types array (imports first, then module globals)
    v.global_types = {}
    v.global_mutable = {}
    local gidx = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_GLOBAL then
            v.global_types[gidx] = imp.desc.valtype
            v.global_mutable[gidx] = imp.desc.mutable
            gidx = gidx + 1
        end
    end
    for _, g in ipairs(module.globals) do
        v.global_types[gidx] = g.valtype
        v.global_mutable[gidx] = g.mutable
        gidx = gidx + 1
    end

    return v
end

local function push_operand(v, t)
    v.tsp = v.tsp + 1
    v.types[v.tsp] = t
end

local function pop_operand(v, expected)
    local frame = v.ctrls[v.ctrl_sp]
    if v.tsp <= frame.height then
        -- At or below frame height
        if frame.unreachable then
            return expected or UNKNOWN -- polymorphic
        end
        error("type mismatch") -- underflow
    end
    local actual = v.types[v.tsp]
    v.tsp = v.tsp - 1
    if expected and actual ~= UNKNOWN and expected ~= UNKNOWN and actual ~= expected then
        error("type mismatch")
    end
    return actual == UNKNOWN and (expected or UNKNOWN) or actual
end

local function push_operands(v, types)
    for i = 1, #types do
        push_operand(v, types[i])
    end
end

local function pop_operands(v, types)
    -- Pop in reverse order (last type is on top of stack)
    for i = #types, 1, -1 do
        pop_operand(v, types[i])
    end
end

local function push_ctrl(v, opcode, start_types, end_types)
    local sp = v.ctrl_sp + 1
    v.ctrl_sp = sp
    v.ctrls[sp] = {
        opcode = opcode,
        start_types = start_types,
        end_types = end_types,
        height = v.tsp,
        unreachable = false,
    }
end

local function pop_ctrl(v)
    if v.ctrl_sp < 1 then error("type mismatch") end
    local frame = v.ctrls[v.ctrl_sp]
    pop_operands(v, frame.end_types)
    if v.tsp ~= frame.height then
        error("type mismatch") -- extra values on stack
    end
    v.ctrl_sp = v.ctrl_sp - 1
    return frame
end

local function set_unreachable(v)
    local frame = v.ctrls[v.ctrl_sp]
    v.tsp = frame.height
    frame.unreachable = true
end

-- Get the label types for a branch target at depth
local function label_types(v, depth)
    if depth >= v.ctrl_sp then
        error("unknown label")
    end
    local frame = v.ctrls[v.ctrl_sp - depth]
    if frame.opcode == 0x03 then -- loop
        return frame.start_types
    else
        return frame.end_types
    end
end

---------------------------------------------------------------------------
-- Validate a single function body
---------------------------------------------------------------------------

local function validate_function_body(module, func_idx, func_def)
    local type_info = module.types[func_def.type_idx + 1]
    if not type_info then error("unknown type") end
    local code = func_def.code.code

    -- Build local types: params + declared locals
    local local_types = {}
    local offset = 0
    for i = 1, #type_info.params do
        local_types[offset] = type_info.params[i]
        offset = offset + 1
    end
    for _, decl in ipairs(func_def.code.locals) do
        for _ = 1, decl.count do
            local_types[offset] = decl.type
            offset = offset + 1
        end
    end
    local num_locals = offset

    local v = make_validator(module, type_info, local_types, num_locals, code)
    local r = {code = code, pos = 1}

    -- Push function-level control frame
    push_ctrl(v, 0x02, type_info.params, type_info.results)
    -- Note: function params are already "on the stack" conceptually,
    -- but we handle this by setting height=0 and the params are in locals

    while r.pos <= #code do
        local op = read_byte(r)

        if op == 0x00 then -- unreachable
            set_unreachable(v)

        elseif op == 0x01 then -- nop
            -- nothing

        elseif op == 0x02 then -- block
            local bt_params, bt_results = read_blocktype(r, module)
            pop_operands(v, bt_params)
            push_ctrl(v, 0x02, bt_params, bt_results)
            push_operands(v, bt_params)

        elseif op == 0x03 then -- loop
            local bt_params, bt_results = read_blocktype(r, module)
            pop_operands(v, bt_params)
            push_ctrl(v, 0x03, bt_params, bt_results)
            push_operands(v, bt_params)

        elseif op == 0x04 then -- if
            local bt_params, bt_results = read_blocktype(r, module)
            pop_operand(v, I32) -- condition
            pop_operands(v, bt_params)
            push_ctrl(v, 0x04, bt_params, bt_results)
            push_operands(v, bt_params)

        elseif op == 0x05 then -- else
            local frame = pop_ctrl(v)
            if frame.opcode ~= 0x04 then error("type mismatch") end
            push_ctrl(v, 0x05, frame.start_types, frame.end_types)
            push_operands(v, frame.start_types)

        elseif op == 0x0B then -- end
            local frame = pop_ctrl(v)
            -- Check: if without else must have matching start/end types
            if frame.opcode == 0x04 then
                -- if without else: end_types must equal start_types
                if #frame.end_types ~= #frame.start_types then
                    error("type mismatch")
                end
                for i = 1, #frame.end_types do
                    if frame.end_types[i] ~= frame.start_types[i] then
                        error("type mismatch")
                    end
                end
            end
            push_operands(v, frame.end_types)

        elseif op == 0x0C then -- br
            local depth = read_leb128_u(r)
            local ltypes = label_types(v, depth)
            pop_operands(v, ltypes)
            set_unreachable(v)

        elseif op == 0x0D then -- br_if
            local depth = read_leb128_u(r)
            local ltypes = label_types(v, depth)
            pop_operand(v, I32)
            pop_operands(v, ltypes)
            push_operands(v, ltypes)

        elseif op == 0x0E then -- br_table
            local count = read_leb128_u(r)
            local targets = {}
            for i = 0, count - 1 do
                targets[i] = read_leb128_u(r)
            end
            local default_depth = read_leb128_u(r)
            pop_operand(v, I32) -- index
            local default_types = label_types(v, default_depth)
            -- All targets must have same arity as default
            for i = 0, count - 1 do
                local ttypes = label_types(v, targets[i])
                if #ttypes ~= #default_types then
                    error("type mismatch")
                end
                for j = 1, #ttypes do
                    if ttypes[j] ~= default_types[j] then
                        error("type mismatch")
                    end
                end
            end
            pop_operands(v, default_types)
            set_unreachable(v)

        elseif op == 0x0F then -- return
            pop_operands(v, v.func_type.results)
            set_unreachable(v)

        elseif op == 0x10 then -- call
            local fidx = read_leb128_u(r)
            local fdef = module.funcs[fidx]
            if not fdef then error("unknown function") end
            local ftype = module.types[fdef.type_idx + 1]
            if not ftype then error("unknown type") end
            pop_operands(v, ftype.params)
            push_operands(v, ftype.results)

        elseif op == 0x11 then -- call_indirect
            local type_idx = read_leb128_u(r)
            local table_idx = read_leb128_u(r)
            if not v.has_table then error("unknown table") end
            -- Table must be funcref type (0x70)
            local tbl_type = v.table_elem_type
            if tbl_type and tbl_type ~= 0x70 then error("type mismatch") end
            if type_idx >= #module.types then error("unknown type") end
            local ftype = module.types[type_idx + 1]
            pop_operand(v, I32) -- table index
            pop_operands(v, ftype.params)
            push_operands(v, ftype.results)

        elseif op == 0x1A then -- drop
            pop_operand(v, nil)

        elseif op == 0x1B then -- select
            pop_operand(v, I32) -- condition
            local t2 = pop_operand(v, nil)
            local t1 = pop_operand(v, (t2 ~= UNKNOWN) and t2 or nil)
            if t1 ~= UNKNOWN and t2 ~= UNKNOWN and t1 ~= t2 then
                error("type mismatch")
            end
            push_operand(v, t1 ~= UNKNOWN and t1 or t2)

        elseif op == 0x20 then -- local.get
            local idx = read_leb128_u(r)
            if idx >= v.num_locals then error("unknown local") end
            push_operand(v, v.local_types[idx])

        elseif op == 0x21 then -- local.set
            local idx = read_leb128_u(r)
            if idx >= v.num_locals then error("unknown local") end
            pop_operand(v, v.local_types[idx])

        elseif op == 0x22 then -- local.tee
            local idx = read_leb128_u(r)
            if idx >= v.num_locals then error("unknown local") end
            local t = v.local_types[idx]
            pop_operand(v, t)
            push_operand(v, t)

        elseif op == 0x23 then -- global.get
            local idx = read_leb128_u(r)
            if v.global_types[idx] == nil then error("unknown global") end
            push_operand(v, v.global_types[idx])

        elseif op == 0x24 then -- global.set
            local idx = read_leb128_u(r)
            if v.global_types[idx] == nil then error("unknown global") end
            if not v.global_mutable[idx] then error("global is immutable") end
            pop_operand(v, v.global_types[idx])

        elseif op == 0x3F then -- memory.size
            read_leb128_u(r) -- reserved
            if not v.has_memory then error("unknown memory") end
            push_operand(v, I32)

        elseif op == 0x40 then -- memory.grow
            read_leb128_u(r) -- reserved
            if not v.has_memory then error("unknown memory") end
            pop_operand(v, I32)
            push_operand(v, I32)

        elseif op == 0x41 then -- i32.const
            read_leb128_s(r)
            push_operand(v, I32)

        elseif op == 0x42 then -- i64.const
            read_leb128_s64(r)
            push_operand(v, I64)

        elseif op == 0x43 then -- f32.const
            r.pos = r.pos + 4
            push_operand(v, F32)

        elseif op == 0x44 then -- f64.const
            r.pos = r.pos + 8
            push_operand(v, F64)

        elseif op >= 0x28 and op <= 0x3E then
            -- Memory load/store - read memarg, then use signature table
            read_memarg(r)
            if not v.has_memory then error("unknown memory") end
            local sig = op_sig[op]
            if sig then
                pop_operands(v, sig[1])
                push_operands(v, sig[2])
            else
                error(string.format("unknown opcode 0x%02X", op))
            end

        elseif op == 0xFC then -- extended opcodes
            local sub_op = read_leb128_u(r)
            local sig = fc_sig[sub_op]
            if sig then
                pop_operands(v, sig[1])
                push_operands(v, sig[2])
            else
                -- Unknown extended op, skip
            end

        else
            -- Check signature table for arithmetic/comparison/conversion ops
            local sig = op_sig[op]
            if sig then
                pop_operands(v, sig[1])
                push_operands(v, sig[2])
            else
                error(string.format("unknown opcode 0x%02X", op))
            end
        end
    end

    -- After processing all bytecode, control stack should be empty
    if v.ctrl_sp ~= 0 then
        error("type mismatch") -- unclosed blocks
    end
end

---------------------------------------------------------------------------
-- Module-level validation
---------------------------------------------------------------------------

local function validate_module(module)
    -- Count total functions
    local total_funcs = 0
    for _ in pairs(module.funcs) do total_funcs = total_funcs + 1 end

    -- Count total globals
    local num_import_globals = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_GLOBAL then
            num_import_globals = num_import_globals + 1
        end
    end
    local total_globals = num_import_globals + #module.globals

    -- Count memories and tables
    local num_memories = module.memory_def and 1 or 0
    local num_tables = #module.tables
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_MEMORY then num_memories = num_memories + 1 end
        if imp.kind == WasmParser.EXT_TABLE then num_tables = num_tables + 1 end
    end

    -- Validate: at most 1 memory and 1 table (MVP)
    if num_memories > 1 then error("multiple memories") end
    if num_tables > 1 then error("multiple tables") end

    -- Validate import type indices
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_FUNC then
            if not imp.desc or imp.desc.type_idx >= #module.types then
                error("unknown type")
            end
        end
    end

    -- Validate function type indices
    for _, type_idx in ipairs(module.func_type_indices) do
        if type_idx >= #module.types then
            error("unknown type")
        end
    end

    -- Validate export indices
    for _, exp in ipairs(module.exports) do
        if exp.kind == WasmParser.EXT_FUNC then
            if not module.funcs[exp.index] then error("unknown function") end
        elseif exp.kind == WasmParser.EXT_GLOBAL then
            if exp.index >= total_globals then error("unknown global") end
        elseif exp.kind == WasmParser.EXT_MEMORY then
            if num_memories == 0 or exp.index >= num_memories then error("unknown memory") end
        elseif exp.kind == WasmParser.EXT_TABLE then
            if num_tables == 0 or exp.index >= num_tables then error("unknown table") end
        end
    end

    -- Validate start function
    if module.start_func then
        local fdef = module.funcs[module.start_func]
        if not fdef then error("unknown function") end
        local ftype = module.types[fdef.type_idx + 1]
        if not ftype then error("unknown type") end
        if #ftype.params ~= 0 or #ftype.results ~= 0 then
            error("start function")
        end
    end

    -- Helper: validate an init expression's global.get reference
    local function validate_init_global_ref(init_opcode, init_val)
        if init_opcode == 0x23 then -- global.get
            local ref_idx = init_val.global_idx
            if ref_idx >= num_import_globals then
                error("unknown global")
            end
            local found_idx = 0
            for _, imp in ipairs(module.imports) do
                if imp.kind == WasmParser.EXT_GLOBAL then
                    if found_idx == ref_idx then
                        if imp.desc.mutable then
                            error("constant expression required")
                        end
                        return imp.desc.valtype
                    end
                    found_idx = found_idx + 1
                end
            end
        end
        -- Return the type produced by the init expression
        if init_opcode == 0x41 then return I32
        elseif init_opcode == 0x42 then return I64
        elseif init_opcode == 0x43 then return F32
        elseif init_opcode == 0x44 then return F64
        end
        return nil
    end

    -- Validate element segments
    for _, seg in ipairs(module.element_segments) do
        if num_tables == 0 then error("unknown table") end
        for _, fidx in ipairs(seg.func_indices) do
            if not module.funcs[fidx] then error("unknown function") end
        end
        -- Offset must be i32
        local init_type = validate_init_global_ref(seg.offset_opcode, seg.offset)
        if init_type and init_type ~= I32 then error("type mismatch") end
    end

    -- Validate data segments
    for _, seg in ipairs(module.data_segments) do
        if num_memories == 0 then error("unknown memory") end
        -- Offset must be i32
        local init_type = validate_init_global_ref(seg.offset_opcode, seg.offset)
        if init_type and init_type ~= I32 then error("type mismatch") end
    end

    -- Validate global init expressions
    for i, g in ipairs(module.globals) do
        local init_type = validate_init_global_ref(g.init_opcode, g.init)
        if init_type and init_type ~= g.valtype then
            error("type mismatch")
        end
    end

    -- Validate duplicate export names
    local export_names = {}
    for _, exp in ipairs(module.exports) do
        if export_names[exp.name] then
            error("duplicate export name")
        end
        export_names[exp.name] = true
    end

    -- Validate each function body
    for idx, fdef in pairs(module.funcs) do
        if not fdef.import and fdef.code then
            local ok, err = pcall(validate_function_body, module, idx, fdef)
            if not ok then
                error(err)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

local Validator = {}

function Validator.validate(module)
    validate_module(module)
end

return Validator
