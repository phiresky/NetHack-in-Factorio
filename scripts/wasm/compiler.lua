-- WASM-to-Lua Compiler
-- Translates WASM function bytecode into Lua source code, then uses load()
-- to compile it. The interpreter run loop calls compiled functions instead of
-- interpreting bytecode, giving a large speedup by eliminating per-instruction
-- dispatch, LEB128 decoding, and stack manipulation overhead.
--
-- Architecture: "interpreter-hosted" — the interpreter's run loop stays as the
-- outer execution engine. Each compiled function runs a segment of its body
-- (from entry/resume point to the next call instruction or function end), then
-- returns control to the interpreter which handles cross-function calls,
-- blocking imports, and instruction budget.

local bit32 = bit32
local math_floor = math.floor

local Decode = require("scripts.wasm.decode")

local Compiler = {}

-- Mask for i32 wrapping
local M32 = 0xFFFFFFFF

---------------------------------------------------------------------------
-- Bytecode decoder: pre-decode WASM bytecode into instruction list
---------------------------------------------------------------------------

-- Positional LEB128 decoders from shared module
local decode_leb128_u = Decode.leb128_u
local decode_leb128_s = Decode.leb128_s
local decode_leb128_s64 = Decode.leb128_s64

-- Read block type: signed LEB128. Returns (n_params, n_results, type_index_or_nil), new_pos
-- type_index is non-nil only for type index blocktypes
local function decode_blocktype(code, pos, module)
    local result, new_pos = decode_leb128_s(code, pos)
    if result == -64 then
        return 0, 0, nil, new_pos -- void
    elseif result < 0 then
        return 0, 1, nil, new_pos -- valtype: 0 params, 1 result
    else
        -- Type index
        local type_info = module.types[result + 1]
        if type_info then
            return #type_info.params, #type_info.results, result, new_pos
        end
        return 0, 1, nil, new_pos -- fallback
    end
end

-- Pre-decode all instructions in a function body into a flat list
-- Each instruction = {op=opcode, ...operands...}
local function decode_instructions(code, module)
    local instrs = {}
    local n = 0
    local pos = 1
    local len = #code

    while pos <= len do
        local op = code[pos]
        pos = pos + 1
        n = n + 1

        if op == 0x00 then -- unreachable
            instrs[n] = {op=0x00}
        elseif op == 0x01 then -- nop
            instrs[n] = {op=0x01}
        elseif op == 0x02 then -- block
            local np, nr, ti, new_pos = decode_blocktype(code, pos, module)
            pos = new_pos
            instrs[n] = {op=0x02, n_params=np, n_results=nr, type_idx=ti}
        elseif op == 0x03 then -- loop
            local np, nr, ti, new_pos = decode_blocktype(code, pos, module)
            pos = new_pos
            instrs[n] = {op=0x03, n_params=np, n_results=nr, type_idx=ti}
        elseif op == 0x04 then -- if
            local np, nr, ti, new_pos = decode_blocktype(code, pos, module)
            pos = new_pos
            instrs[n] = {op=0x04, n_params=np, n_results=nr, type_idx=ti}
        elseif op == 0x05 then -- else
            instrs[n] = {op=0x05}
        elseif op == 0x0B then -- end
            instrs[n] = {op=0x0B}
        elseif op == 0x0C then -- br
            local depth; depth, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x0C, depth=depth}
        elseif op == 0x0D then -- br_if
            local depth; depth, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x0D, depth=depth}
        elseif op == 0x0E then -- br_table
            local count; count, pos = decode_leb128_u(code, pos)
            local targets = {}
            for i = 0, count do
                targets[i], pos = decode_leb128_u(code, pos)
            end
            instrs[n] = {op=0x0E, targets=targets, count=count}
        elseif op == 0x0F then -- return
            instrs[n] = {op=0x0F}
        elseif op == 0x10 then -- call
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x10, func_idx=idx}
        elseif op == 0x11 then -- call_indirect
            local type_idx; type_idx, pos = decode_leb128_u(code, pos)
            local table_idx; table_idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x11, type_idx=type_idx, table_idx=table_idx}
        elseif op == 0x1A then -- drop
            instrs[n] = {op=0x1A}
        elseif op == 0x1B then -- select
            instrs[n] = {op=0x1B}
        elseif op == 0x1F then -- try_table
            local np, nr, ti, new_pos = decode_blocktype(code, pos, module)
            pos = new_pos
            local num_catches; num_catches, pos = decode_leb128_u(code, pos)
            local catches = {}
            for i = 1, num_catches do
                local kind = code[pos]; pos = pos + 1
                local tagidx
                if kind == 0 or kind == 2 then
                    tagidx, pos = decode_leb128_u(code, pos)
                end
                local depth; depth, pos = decode_leb128_u(code, pos)
                catches[i] = {kind=kind, tagidx=tagidx, depth=depth}
            end
            instrs[n] = {op=0x1F, n_params=np, n_results=nr, catches=catches}
        elseif op == 0x20 then -- local.get
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x20, idx=idx}
        elseif op == 0x21 then -- local.set
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x21, idx=idx}
        elseif op == 0x22 then -- local.tee
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x22, idx=idx}
        elseif op == 0x23 then -- global.get
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x23, idx=idx}
        elseif op == 0x24 then -- global.set
            local idx; idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x24, idx=idx}
        elseif op >= 0x28 and op <= 0x3E then -- memory load/store ops
            local align; align, pos = decode_leb128_u(code, pos)
            local offset; offset, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=op, align=align, offset=offset}
        elseif op == 0x3F then -- memory.size
            local mem_idx; mem_idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x3F, mem_idx=mem_idx}
        elseif op == 0x40 then -- memory.grow
            local mem_idx; mem_idx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x40, mem_idx=mem_idx}
        elseif op == 0x41 then -- i32.const
            local val; val, pos = decode_leb128_s(code, pos)
            if val < 0 then val = val + 0x100000000 end
            instrs[n] = {op=0x41, value=val}
        elseif op == 0x42 then -- i64.const
            local val; val, pos = decode_leb128_s64(code, pos)
            instrs[n] = {op=0x42, lo=val[1], hi=val[2]}
        elseif op == 0x43 then -- f32.const
            local b0, b1, b2, b3 = code[pos], code[pos+1], code[pos+2], code[pos+3]
            pos = pos + 4
            local bits = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
            instrs[n] = {op=0x43, bits=bits}
        elseif op == 0x44 then -- f64.const
            local b0,b1,b2,b3 = code[pos], code[pos+1], code[pos+2], code[pos+3]
            local b4,b5,b6,b7 = code[pos+4], code[pos+5], code[pos+6], code[pos+7]
            pos = pos + 8
            local lo = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
            local hi = bit32.bor(b4, bit32.lshift(b5, 8), bit32.lshift(b6, 16), bit32.lshift(b7, 24))
            instrs[n] = {op=0x44, lo=lo, hi=hi}
        elseif op == 0x08 then -- throw
            local tagidx; tagidx, pos = decode_leb128_u(code, pos)
            instrs[n] = {op=0x08, tagidx=tagidx}
        elseif op == 0x0A then -- throw_ref
            instrs[n] = {op=0x0A}
        elseif op == 0xFC then -- extended ops
            local sub_op; sub_op, pos = decode_leb128_u(code, pos)
            if sub_op >= 8 and sub_op <= 11 then
                -- memory.init/data.drop/memory.copy/memory.fill have extra immediates
                if sub_op == 8 then -- memory.init
                    local seg; seg, pos = decode_leb128_u(code, pos)
                    local mem; mem, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, seg=seg, mem=mem}
                elseif sub_op == 9 then -- data.drop
                    local seg; seg, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, seg=seg}
                elseif sub_op == 10 then -- memory.copy
                    local dst; dst, pos = decode_leb128_u(code, pos)
                    local src; src, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, dst=dst, src=src}
                elseif sub_op == 11 then -- memory.fill
                    local mem; mem, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, mem=mem}
                end
            elseif sub_op >= 12 and sub_op <= 17 then
                -- table ops
                if sub_op == 12 then -- table.init
                    local seg; seg, pos = decode_leb128_u(code, pos)
                    local tbl; tbl, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, seg=seg, tbl=tbl}
                elseif sub_op == 13 then -- elem.drop
                    local seg; seg, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, seg=seg}
                elseif sub_op == 14 then -- table.copy
                    local dst; dst, pos = decode_leb128_u(code, pos)
                    local src; src, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, dst=dst, src=src}
                elseif sub_op == 15 then -- table.grow
                    local tbl; tbl, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, tbl=tbl}
                elseif sub_op == 16 then -- table.size
                    local tbl; tbl, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, tbl=tbl}
                elseif sub_op == 17 then -- table.fill
                    local tbl; tbl, pos = decode_leb128_u(code, pos)
                    instrs[n] = {op=0xFC, sub_op=sub_op, tbl=tbl}
                end
            else
                instrs[n] = {op=0xFC, sub_op=sub_op}
            end
        else
            -- All other opcodes have no immediates (0x45-0xC4 etc)
            instrs[n] = {op=op}
        end
    end

    return instrs, n
end

---------------------------------------------------------------------------
-- Code generator: walk decoded instructions, emit Lua source
---------------------------------------------------------------------------

-- Format u32 as hex if large, else decimal
local function u32_lit(v)
    if v == 0 then return "0"
    elseif v > 0xFFFF then return string.format("0x%X", v)
    else return tostring(v)
    end
end

---------------------------------------------------------------------------
-- Peephole: i32.const C + op → fold constant into single emit
---------------------------------------------------------------------------
local function nop0_u32(C) if C == 0 then return nil end; return u32_lit(C) end
local function always_u32(C) return u32_lit(C) end
local function shift31(C) local s = bit32.band(C, 31); if s == 0 then return nil end; return s end
local function always_shift31(C) return bit32.band(C, 31) end
local function signed_i32_lit(C)
    local Cu = bit32.band(C, 0xFFFFFFFF)
    if Cu >= 0x80000000 then return tostring(Cu - 0x100000000)
    else return u32_lit(Cu) end
end

local const_fold = {
    [0x6A] = {"stack[sp] = band(stack[sp] + %s, 0xFFFFFFFF)", nop0_u32},   -- i32.add
    [0x6B] = {"stack[sp] = band(stack[sp] - %s, 0xFFFFFFFF)", nop0_u32},   -- i32.sub
    [0x71] = {"stack[sp] = band(stack[sp], %s)", always_u32},               -- i32.and
    [0x72] = {"stack[sp] = bor(stack[sp], %s)", nop0_u32},                  -- i32.or
    [0x73] = {"stack[sp] = bxor(stack[sp], %s)", nop0_u32},                 -- i32.xor
    [0x74] = {"stack[sp] = lshift(stack[sp], %d)", shift31},                -- i32.shl
    [0x75] = {"stack[sp] = arshift(stack[sp], %d)", shift31},               -- i32.shr_s
    [0x76] = {"stack[sp] = rshift(stack[sp], %d)", shift31},                -- i32.shr_u
    [0x46] = {"stack[sp] = stack[sp] == %s and 1 or 0", always_u32},       -- i32.eq
    [0x47] = {"stack[sp] = stack[sp] ~= %s and 1 or 0", always_u32},       -- i32.ne
    [0x49] = {"stack[sp] = stack[sp] < %s and 1 or 0", always_u32},        -- i32.lt_u
    [0x4B] = {"stack[sp] = stack[sp] > %s and 1 or 0", always_u32},        -- i32.gt_u
    [0x4D] = {"stack[sp] = stack[sp] <= %s and 1 or 0", always_u32},       -- i32.le_u
    [0x4F] = {"stack[sp] = stack[sp] >= %s and 1 or 0", always_u32},       -- i32.ge_u
    [0x48] = {"do local __a = stack[sp]; stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) < %s) and 1 or 0 end", signed_i32_lit},   -- i32.lt_s
    [0x4A] = {"do local __a = stack[sp]; stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) > %s) and 1 or 0 end", signed_i32_lit},   -- i32.gt_s
    [0x4C] = {"do local __a = stack[sp]; stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) <= %s) and 1 or 0 end", signed_i32_lit},  -- i32.le_s
    [0x4E] = {"do local __a = stack[sp]; stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) >= %s) and 1 or 0 end", signed_i32_lit},  -- i32.ge_s
}

-- Group 2: local.get X + i32.const C + binary op → fold into single push
local local_const_fold = {
    [0x6A] = {"sp = sp + 1; stack[sp] = band(loc[%d] + %s, 0xFFFFFFFF)", always_u32},   -- i32.add
    [0x6B] = {"sp = sp + 1; stack[sp] = band(loc[%d] - %s, 0xFFFFFFFF)", always_u32},   -- i32.sub
    [0x71] = {"sp = sp + 1; stack[sp] = band(loc[%d], %s)", always_u32},                 -- i32.and
    [0x72] = {"sp = sp + 1; stack[sp] = bor(loc[%d], %s)", always_u32},                  -- i32.or
    [0x74] = {"sp = sp + 1; stack[sp] = lshift(loc[%d], %d)", always_shift31},            -- i32.shl
    [0x76] = {"sp = sp + 1; stack[sp] = rshift(loc[%d], %d)", always_shift31},            -- i32.shr_u
    [0x46] = {"sp = sp + 1; stack[sp] = loc[%d] == %s and 1 or 0", always_u32},          -- i32.eq
    [0x47] = {"sp = sp + 1; stack[sp] = loc[%d] ~= %s and 1 or 0", always_u32},          -- i32.ne
}

-- Group 4: i32.const C + cmp + br_if → fused conditional branch
local cmp_branch_fold = {
    [0x46] = {"__c == %s", always_u32},   -- i32.eq
    [0x47] = {"__c ~= %s", always_u32},   -- i32.ne
    [0x49] = {"__c < %s", always_u32},    -- i32.lt_u
    [0x4B] = {"__c > %s", always_u32},    -- i32.gt_u
    [0x4D] = {"__c <= %s", always_u32},   -- i32.le_u
    [0x4F] = {"__c >= %s", always_u32},   -- i32.ge_u
    [0x48] = {"((__c >= 0x80000000 and __c - 0x100000000 or __c) < %s)", signed_i32_lit},   -- i32.lt_s
    [0x4A] = {"((__c >= 0x80000000 and __c - 0x100000000 or __c) > %s)", signed_i32_lit},   -- i32.gt_s
    [0x4C] = {"((__c >= 0x80000000 and __c - 0x100000000 or __c) <= %s)", signed_i32_lit},  -- i32.le_s
    [0x4E] = {"((__c >= 0x80000000 and __c - 0x100000000 or __c) >= %s)", signed_i32_lit},  -- i32.ge_s
}

-- Group 5: local.get A + local.get B + binary op → single push with locals
local get_get_fold = {
    [0x6A] = "sp = sp + 1; stack[sp] = band(loc[%d] + loc[%d], 0xFFFFFFFF)",             -- i32.add
    [0x6B] = "sp = sp + 1; stack[sp] = band(loc[%d] - loc[%d] + 0x100000000, 0xFFFFFFFF)", -- i32.sub
    [0x46] = "sp = sp + 1; stack[sp] = loc[%d] == loc[%d] and 1 or 0",                    -- i32.eq
    [0x47] = "sp = sp + 1; stack[sp] = loc[%d] ~= loc[%d] and 1 or 0",                    -- i32.ne
    [0x71] = "sp = sp + 1; stack[sp] = band(loc[%d], loc[%d])",                            -- i32.and
    [0x72] = "sp = sp + 1; stack[sp] = bor(loc[%d], loc[%d])",                             -- i32.or
    [0x73] = "sp = sp + 1; stack[sp] = bxor(loc[%d], loc[%d])",                            -- i32.xor
    [0x49] = "sp = sp + 1; stack[sp] = loc[%d] < loc[%d] and 1 or 0",                     -- i32.lt_u
    [0x4B] = "sp = sp + 1; stack[sp] = loc[%d] > loc[%d] and 1 or 0",                     -- i32.gt_u
    [0x4D] = "sp = sp + 1; stack[sp] = loc[%d] <= loc[%d] and 1 or 0",                    -- i32.le_u
    [0x4F] = "sp = sp + 1; stack[sp] = loc[%d] >= loc[%d] and 1 or 0",                    -- i32.ge_u
}

---------------------------------------------------------------------------
-- Table-driven opcode emission
-- One flat map: opcode -> {type, param}, plus emitters: type -> function.
-- Single lookup dispatches ~100 formulaic opcodes; the rest use custom logic.
---------------------------------------------------------------------------

local op_templates = {
    unary     = "stack[sp] = %s(stack[sp])",
    cmp_u     = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] %s __b and 1 or 0 end",
    cmp_s     = "do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) %s (__b >= 0x80000000 and __b - 0x100000000 or __b)) and 1 or 0 end",
    i64_cmp   = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.%s(stack[sp], __b) and 1 or 0 end",
    float_eq  = "do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a == __b and 1 or 0) end",
    float_ne  = "do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 1 or (__a ~= __b and 1 or 0) end",
    float_ord = "do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a %s __b and 1 or 0) end",
    binop_ctx = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.%s(stack[sp], __b) end",
    f32_arith = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_trunc_val(stack[sp] %s __b) end",
    f64_arith = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] %s __b end",
    i32_bit   = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = %s(stack[sp], __b) end",
    i32_shift = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = %s(stack[sp], band(__b, 31)) end",
    i64_bit   = "do local __b = stack[sp]; sp = sp - 1; stack[sp] = {%s(stack[sp][1], __b[1]), %s(stack[sp][2], __b[2])} end",
    i64_shift = "do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.%s(stack[sp], __s) end",
    -- Locals/globals (param from instruction)
    local_get  = "sp = sp + 1; stack[sp] = loc[%d]",
    local_set  = "loc[%d] = stack[sp]; sp = sp - 1",
    local_tee  = "loc[%d] = stack[sp]",
    global_get = "sp = sp + 1; stack[sp] = globals[%d]",
    global_set = "globals[%d] = stack[sp]; sp = sp - 1",
    -- Constants (param from instruction)
    i32_const  = "sp = sp + 1; stack[sp] = %s",
    i64_const  = "sp = sp + 1; stack[sp] = {%s, %s}",
    f32_const  = "sp = sp + 1; stack[sp] = ctx.f32_reinterpret(%s)",
    f64_const  = "sp = sp + 1; stack[sp] = ctx.f64_reinterpret({%s, %s})",
    -- Stack/misc (no param)
    drop       = "sp = sp - 1",
    select_op  = "do local __c = stack[sp]; sp = sp - 1; local __b = stack[sp]; sp = sp - 1; if __c == 0 then stack[sp] = __b end end",
    i32_eqz    = "stack[sp] = stack[sp] == 0 and 1 or 0",
    i64_eqz    = "stack[sp] = ctx.i64_eqz(stack[sp]) and 1 or 0",
    mem_size   = "sp = sp + 1; stack[sp] = mem:size()",
    mem_grow   = "stack[sp] = mem:grow(stack[sp])",
    -- Conversions (no param, unique patterns)
    i32_wrap      = "do local __v = stack[sp]; stack[sp] = type(__v) == 'table' and __v[1] or band(__v, 0xFFFFFFFF) end",
    i64_extend_s  = "do local __v = stack[sp]; __v = type(__v) == 'table' and __v[1] or __v; stack[sp] = {__v, bit32.btest(__v, 0x80000000) and 0xFFFFFFFF or 0} end",
    i64_extend_u  = "do local __v = stack[sp]; __v = type(__v) == 'table' and __v[1] or __v; stack[sp] = {__v, 0} end",
    f64_conv_s    = "do local __v = stack[sp]; __v = __v >= 0x80000000 and __v - 0x100000000 or __v; stack[sp] = __v + 0.0 end",
    f64_conv_u    = "stack[sp] = stack[sp] + 0.0",
    f64_promote   = "do local __v = stack[sp]; if ctx.isnan(__v) then stack[sp] = 0/0 end end",
    i32_ext8_s    = "do local __v = band(stack[sp], 0xFF); if __v >= 0x80 then __v = __v - 0x100 end; if __v < 0 then __v = __v + 0x100000000 end; stack[sp] = __v end",
    i32_ext16_s   = "do local __v = band(stack[sp], 0xFFFF); if __v >= 0x8000 then __v = __v - 0x10000 end; if __v < 0 then __v = __v + 0x100000000 end; stack[sp] = __v end",
}

local op_table = {
    -- Locals/globals (param from instruction)
    [0x20] = {"local_get", function(i) return i.idx end},
    [0x21] = {"local_set", function(i) return i.idx end},
    [0x22] = {"local_tee", function(i) return i.idx end},
    [0x23] = {"global_get", function(i) return i.idx end},
    [0x24] = {"global_set", function(i) return i.idx end},
    -- Constants (param from instruction)
    [0x41] = {"i32_const", function(i) return u32_lit(i.value) end},
    [0x42] = {"i64_const", function(i) return u32_lit(i.lo), u32_lit(i.hi) end},
    [0x43] = {"f32_const", function(i) return u32_lit(i.bits) end},
    [0x44] = {"f64_const", function(i) return u32_lit(i.lo), u32_lit(i.hi) end},
    -- Stack/misc
    [0x1A] = {"drop"}, [0x1B] = {"select_op"},
    [0x45] = {"i32_eqz"}, [0x50] = {"i64_eqz"},
    [0x3F] = {"mem_size"}, [0x40] = {"mem_grow"},
    -- Conversions (unique patterns, no param)
    [0xA7] = {"i32_wrap"},
    [0xAC] = {"i64_extend_s"}, [0xAD] = {"i64_extend_u"},
    [0xB7] = {"f64_conv_s"}, [0xB8] = {"f64_conv_u"},
    [0xBB] = {"f64_promote"},
    [0xC0] = {"i32_ext8_s"}, [0xC1] = {"i32_ext16_s"},
    -- i32 comparison
    [0x46] = {"cmp_u", "=="}, [0x47] = {"cmp_u", "~="},
    [0x48] = {"cmp_s", "<"},  [0x49] = {"cmp_u", "<"},
    [0x4A] = {"cmp_s", ">"},  [0x4B] = {"cmp_u", ">"},
    [0x4C] = {"cmp_s", "<="}, [0x4D] = {"cmp_u", "<="},
    [0x4E] = {"cmp_s", ">="}, [0x4F] = {"cmp_u", ">="},
    -- i64 comparison
    [0x51] = {"i64_cmp", "i64_eq"},   [0x52] = {"i64_cmp", "i64_ne"},
    [0x53] = {"i64_cmp", "i64_lt_s"}, [0x54] = {"i64_cmp", "i64_lt_u"},
    [0x55] = {"i64_cmp", "i64_gt_s"}, [0x56] = {"i64_cmp", "i64_gt_u"},
    [0x57] = {"i64_cmp", "i64_le_s"}, [0x58] = {"i64_cmp", "i64_le_u"},
    [0x59] = {"i64_cmp", "i64_ge_s"}, [0x5A] = {"i64_cmp", "i64_ge_u"},
    -- f32 comparison
    [0x5B] = {"float_eq"}, [0x5C] = {"float_ne"},
    [0x5D] = {"cmp_u", "<"},          [0x5E] = {"cmp_u", ">"},
    [0x5F] = {"float_ord", "<="},     [0x60] = {"float_ord", ">="},
    -- f64 comparison
    [0x61] = {"float_eq"}, [0x62] = {"float_ne"},
    [0x63] = {"cmp_u", "<"},          [0x64] = {"cmp_u", ">"},
    [0x65] = {"float_ord", "<="},     [0x66] = {"float_ord", ">="},
    -- i32 unary
    [0x67] = {"unary", "ctx.i32_clz"}, [0x68] = {"unary", "ctx.i32_ctz"},
    [0x69] = {"unary", "ctx.i32_popcnt"},
    -- i32 bitwise / shift
    [0x71] = {"i32_bit", "band"}, [0x72] = {"i32_bit", "bor"}, [0x73] = {"i32_bit", "bxor"},
    [0x74] = {"i32_shift", "lshift"}, [0x75] = {"i32_shift", "arshift"},
    [0x76] = {"i32_shift", "rshift"},
    [0x77] = {"i32_shift", "bit32.lrotate"}, [0x78] = {"i32_shift", "bit32.rrotate"},
    -- i64 unary
    [0x79] = {"unary", "ctx.i64_clz"}, [0x7A] = {"unary", "ctx.i64_ctz"},
    [0x7B] = {"unary", "ctx.i64_popcnt"},
    -- i64 arithmetic
    [0x7C] = {"binop_ctx", "i64_add"}, [0x7D] = {"binop_ctx", "i64_sub"},
    [0x7E] = {"binop_ctx", "i64_mul"}, [0x7F] = {"binop_ctx", "i64_div_s"},
    [0x80] = {"binop_ctx", "i64_div_u"}, [0x81] = {"binop_ctx", "i64_rem_s"},
    [0x82] = {"binop_ctx", "i64_rem_u"},
    -- i64 bitwise / shift
    [0x83] = {"i64_bit", "band"}, [0x84] = {"i64_bit", "bor"}, [0x85] = {"i64_bit", "bxor"},
    [0x86] = {"i64_shift", "i64_shl"}, [0x87] = {"i64_shift", "i64_shr_s"},
    [0x88] = {"i64_shift", "i64_shr_u"},
    [0x89] = {"i64_shift", "i64_rotl"}, [0x8A] = {"i64_shift", "i64_rotr"},
    -- f32 unary
    [0x8B] = {"unary", "ctx.f32_abs"},  [0x8C] = {"unary", "ctx.f32_neg"},
    [0x8D] = {"unary", "ctx.f32_ceil"}, [0x8E] = {"unary", "ctx.f32_floor"},
    [0x8F] = {"unary", "ctx.f32_trunc"}, [0x90] = {"unary", "ctx.f32_nearest"},
    [0x91] = {"unary", "ctx.f32_sqrt"},
    -- f32 arithmetic
    [0x92] = {"f32_arith", "+"}, [0x93] = {"f32_arith", "-"},
    [0x94] = {"f32_arith", "*"}, [0x95] = {"f32_arith", "/"},
    [0x96] = {"binop_ctx", "f32_min"}, [0x97] = {"binop_ctx", "f32_max"},
    [0x98] = {"binop_ctx", "f32_copysign"},
    -- f64 unary
    [0x99] = {"unary", "ctx.f64_abs"},  [0x9A] = {"unary", "ctx.f64_neg"},
    [0x9B] = {"unary", "ctx.f64_ceil"}, [0x9C] = {"unary", "ctx.f64_floor"},
    [0x9D] = {"unary", "ctx.f64_trunc"}, [0x9E] = {"unary", "ctx.f64_nearest"},
    [0x9F] = {"unary", "ctx.f64_sqrt"},
    -- f64 arithmetic
    [0xA0] = {"f64_arith", "+"}, [0xA1] = {"f64_arith", "-"},
    [0xA2] = {"f64_arith", "*"}, [0xA3] = {"f64_arith", "/"},
    [0xA4] = {"binop_ctx", "f64_min"}, [0xA5] = {"binop_ctx", "f64_max"},
    [0xA6] = {"binop_ctx", "f64_copysign"},
    -- conversions (simple delegates)
    [0xA8] = {"unary", "ctx.i32_trunc_f32_s"}, [0xA9] = {"unary", "ctx.i32_trunc_f32_u"},
    [0xAA] = {"unary", "ctx.i32_trunc_f64_s"}, [0xAB] = {"unary", "ctx.i32_trunc_f64_u"},
    [0xAE] = {"unary", "ctx.i64_trunc_f32_s"}, [0xAF] = {"unary", "ctx.i64_trunc_f32_u"},
    [0xB0] = {"unary", "ctx.i64_trunc_f64_s"}, [0xB1] = {"unary", "ctx.i64_trunc_f64_u"},
    [0xB2] = {"unary", "ctx.f32_convert_i32_s"}, [0xB3] = {"unary", "ctx.f32_convert_i32_u"},
    [0xB4] = {"unary", "ctx.f32_convert_i64_s"}, [0xB5] = {"unary", "ctx.f32_convert_i64_u"},
    [0xB6] = {"unary", "ctx.f32_demote_f64"},
    [0xB9] = {"unary", "ctx.f64_convert_i64_s"}, [0xBA] = {"unary", "ctx.f64_convert_i64_u"},
    [0xBC] = {"unary", "ctx.i32_reinterpret_f32"}, [0xBD] = {"unary", "ctx.i64_reinterpret_f64"},
    [0xBE] = {"unary", "ctx.f32_reinterpret"}, [0xBF] = {"unary", "ctx.f64_reinterpret"},
    -- sign extension (i64 delegates)
    [0xC2] = {"unary", "ctx.i64_extend8_s"}, [0xC3] = {"unary", "ctx.i64_extend16_s"},
    [0xC4] = {"unary", "ctx.i64_extend32_s"},
}

-- The source generator
-- Emits Lua source code for a single WASM function.
-- Returns: source string, number of call sites
local function generate_source(func_idx, func_def, module)
    local instrs, n_instrs = decode_instructions(func_def.code.code, module)

    local type_info = module.types[func_def.type_idx + 1]
    local n_params = #type_info.params
    local n_results = #type_info.results
    local param_types = type_info.params
    local result_types = type_info.results

    -- Count total locals
    local n_locals = n_params
    for _, decl in ipairs(func_def.code.locals) do
        n_locals = n_locals + decl.count
    end

    -- Collect local types for i64 default detection
    local local_types = {}
    for i = 1, n_params do
        local_types[i-1] = param_types[i]
    end
    local offset = n_params
    for _, decl in ipairs(func_def.code.locals) do
        for _ = 1, decl.count do
            local_types[offset] = decl.type
            offset = offset + 1
        end
    end

    -- First pass: identify call sites to assign resume points
    local call_sites = {}  -- list of instruction indices that are calls
    local n_calls = 0
    for i = 1, n_instrs do
        local instr = instrs[i]
        if instr.op == 0x10 or instr.op == 0x11 then -- call, call_indirect
            n_calls = n_calls + 1
            call_sites[n_calls] = i
            instr.call_site_id = n_calls
        end
    end

    -- Output buffer
    local out = {}
    local out_n = 0
    local indent_level = 1

    local function emit(s)
        out_n = out_n + 1
        out[out_n] = string.rep("  ", indent_level) .. s
    end

    local function emit_raw(s)
        out_n = out_n + 1
        out[out_n] = s
    end

    local skip_bc = Compiler.no_bounds_check ~= false
    local function emit_bc(size)
        if not skip_bc then
            emit(string.format("  if __addr + %d > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end", size))
        end
    end

    -- Block tracking for control flow
    local block_stack = {}  -- {type="block"|"loop"|"if"|"try_table", label_id=N, ...}
    local block_sp = 0
    local next_label_id = 0

    local function new_label()
        next_label_id = next_label_id + 1
        return next_label_id
    end

    -- Stack tracking (compile-time symbolic stack)
    -- We use a simple approach: materialize everything to the runtime stack.
    -- The stack pointer (sp) is the primary state variable.
    -- Expression folding would add complexity; we'll rely on Lua's optimizer
    -- and the fact that eliminating LEB128/dispatch is the big win.

    -- Emit the function header
    emit_raw("return function(stack, sp, loc, mem, globals, ctx, entry_point)")

    -- Pre-declare block-scope variables at function top level
    -- __sbs: table of stack base values per block (saved/restored via ctx.__sbs)
    -- __cond: reused for if conditions
    emit("local __md = mem.data")
    emit("local __sbs, __cond")
    emit("if entry_point > 0 then __sbs = ctx.__sbs else __sbs = {}; ctx.__sbs = __sbs end")

    -- Emit the entry point dispatcher for resume after calls
    if n_calls > 0 then
        emit("if entry_point > 0 then")
        indent_level = indent_level + 1
        for i = 1, n_calls do
            if i == 1 then
                emit("if entry_point == 1 then goto C_1")
            else
                emit(string.format("elseif entry_point == %d then goto C_%d", i, i))
            end
        end
        emit("end")
        indent_level = indent_level - 1
        emit("end")
    end

    -- Walk instructions and emit Lua code
    -- We use a block_stack to track nested WASM control flow structures
    -- and map them to Lua's goto/label system.

    -- The function-level block (arity = n_results) is implicit
    local func_block_label = new_label()
    block_sp = block_sp + 1
    block_stack[block_sp] = {
        type = "func",
        label_id = func_block_label,
        n_results = n_results,
        n_params = 0,
        -- Branch to func block = return from function
    }

    -- Helper to get the target block for a branch depth
    local function get_branch_target(depth)
        local idx = block_sp - depth
        if idx < 1 then return nil end
        return block_stack[idx]
    end

    -- Emit stack adjustment code for a branch
    -- base_var: the __sb_N variable name holding the block's stack base
    -- arity: number of values to keep on top
    local function emit_branch_adjust(base_var, arity)
        if arity == 0 then
            emit("sp = " .. base_var)
        elseif arity == 1 then
            emit("stack[" .. base_var .. " + 1] = stack[sp]; sp = " .. base_var .. " + 1")
        else
            emit("do local __base = " .. base_var)
            for ai = 0, arity - 1 do
                emit(string.format("  stack[__base + %d] = stack[sp - %d]", 1 + ai, arity - 1 - ai))
            end
            emit("  sp = __base + " .. arity)
            emit("end")
        end
    end

    -- Helper: emit the branch-to-target part (goto/return), shared by branch emitters
    -- cond_expr: Lua condition string, indent: prefix for lines inside the if
    local function emit_branch_body(target, cond_expr, indent)
        indent = indent or "  "
        if target.type == "func" then
            emit(indent .. "if " .. cond_expr .. " then return sp end")
        else
            local arity = target.branch_arity or target.n_results or 0
            emit(indent .. "if " .. cond_expr .. " then")
            if target.stack_base_var then
                emit_branch_adjust(target.stack_base_var, arity)
            end
            if target.type == "loop" then
                emit(indent .. "  goto L_" .. target.label_id)
            else
                emit(indent .. "  goto B_" .. target.label_id)
            end
            emit(indent .. "end")
        end
    end

    -- Helper: emit conditional branch that pops stack (br_if and peephole fusions)
    -- cond_expr: Lua expression string referencing __c (e.g. "__c ~= 0", "__c == 0")
    local function emit_cond_branch(depth, cond_expr)
        local target = get_branch_target(depth)
        if not target then return end
        emit("do local __c = stack[sp]; sp = sp - 1")
        emit_branch_body(target, cond_expr, "  ")
        emit("end")
    end

    -- Helper: emit conditional branch WITHOUT popping stack (for fused patterns
    -- where push+pop cancel out, e.g. local.get + eqz + br_if)
    local function emit_cond_branch_nopop(depth, cond_expr)
        local target = get_branch_target(depth)
        if not target then return end
        emit_branch_body(target, cond_expr, "")
    end

    -- Process each instruction
    local i = 1
    while i <= n_instrs do
        local instr = instrs[i]
        local op = instr.op

        -- === Peephole optimization: multi-instruction patterns ===
        -- Fuses common instruction sequences into single optimized Lua statements.
        -- Reduces stack[sp] read/write traffic and generated code size.

        -- Group 1: i32.const C + binary/cmp/load op → fold constant
        if op == 0x41 and i + 1 <= n_instrs then
            local C = instr.value
            local ni = instrs[i+1]
            local nop = ni.op

            local fold = const_fold[nop]
            if fold then
                local val = fold[2](C)
                if val ~= nil then emit(string.format(fold[1], val)) end
                i = i + 2; goto continue_loop
            elseif nop == 0x28 then -- i32.const C + i32.load [+ branch]
                local addr = C + ni.offset
                -- 4-instr: const + load + eqz + br_if → load, branch if zero
                if i + 3 <= n_instrs and instrs[i+2].op == 0x45 and instrs[i+3].op == 0x0D then
                    emit(string.format("do local __addr = %s", u32_lit(addr)))
                    emit_bc(4)
                    if bit32.band(addr, 3) == 0 then
                        emit(string.format("  local __v = __md[%d] or 0", bit32.rshift(addr, 2)))
                    else
                        emit("  local __v; if band(__addr, 3) == 0 then __v = __md[rshift(__addr, 2)] or 0 else __v = mem:load_i32(__addr) end")
                    end
                    emit_cond_branch_nopop(instrs[i+3].depth, "__v == 0")
                    emit("end")
                    i = i + 4; goto continue_loop
                end
                -- 3-instr: const + load + br_if → load, branch if nonzero
                if i + 2 <= n_instrs and instrs[i+2].op == 0x0D then
                    emit(string.format("do local __addr = %s", u32_lit(addr)))
                    emit_bc(4)
                    if bit32.band(addr, 3) == 0 then
                        emit(string.format("  local __v = __md[%d] or 0", bit32.rshift(addr, 2)))
                    else
                        emit("  local __v; if band(__addr, 3) == 0 then __v = __md[rshift(__addr, 2)] or 0 else __v = mem:load_i32(__addr) end")
                    end
                    emit_cond_branch_nopop(instrs[i+2].depth, "__v ~= 0")
                    emit("end")
                    i = i + 3; goto continue_loop
                end
                -- 2-instr: const + load → push to stack
                emit("sp = sp + 1")
                emit(string.format("do local __addr = %s", u32_lit(addr)))
                emit_bc(4)
                if bit32.band(addr, 3) == 0 then
                    emit(string.format("  stack[sp] = __md[%d] or 0 end", bit32.rshift(addr, 2)))
                else
                    emit("  if band(__addr, 3) == 0 then stack[sp] = __md[rshift(__addr, 2)] or 0")
                    emit("  else stack[sp] = mem:load_i32(__addr) end end")
                end
                i = i + 2; goto continue_loop
            elseif nop == 0x2D then -- i32.const C + i32.load8_u [+ branch]
                local addr = C + ni.offset
                -- 4-instr: const + load8_u + eqz + br_if → load byte, branch if zero
                if i + 3 <= n_instrs and instrs[i+2].op == 0x45 and instrs[i+3].op == 0x0D then
                    emit(string.format("do local __addr = %s", u32_lit(addr)))
                    emit_bc(1)
                    emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                    emit("  local __v = band(rshift(__md[__wi] or 0, __bo * 8), 0xFF)")
                    emit_cond_branch_nopop(instrs[i+3].depth, "__v == 0")
                    emit("end")
                    i = i + 4; goto continue_loop
                end
                -- 3-instr: const + load8_u + br_if → load byte, branch if nonzero
                if i + 2 <= n_instrs and instrs[i+2].op == 0x0D then
                    emit(string.format("do local __addr = %s", u32_lit(addr)))
                    emit_bc(1)
                    emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                    emit("  local __v = band(rshift(__md[__wi] or 0, __bo * 8), 0xFF)")
                    emit_cond_branch_nopop(instrs[i+2].depth, "__v ~= 0")
                    emit("end")
                    i = i + 3; goto continue_loop
                end
                -- 2-instr: const + load8_u → push to stack
                emit("sp = sp + 1")
                emit(string.format("do local __addr = %s", u32_lit(addr)))
                emit_bc(1)
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  stack[sp] = band(rshift(__md[__wi] or 0, __bo * 8), 0xFF) end")
                i = i + 2; goto continue_loop
            elseif nop == 0x2C then -- i32.const C + i32.load8_s
                local addr = C + ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = %s", u32_lit(addr)))
                emit_bc(1)
                emit("  local __v = mem:load_i8_s(__addr)")
                emit("  if __v < 0 then __v = __v + 0x100000000 end")
                emit("  stack[sp] = __v end")
                i = i + 2; goto continue_loop
            elseif nop == 0x6C then -- i32.const C + i32.mul
                local Cu = bit32.band(C, 0xFFFFFFFF)
                if Cu == 0 then
                    emit("stack[sp] = 0")
                elseif Cu <= 0xFFFF then
                    emit(string.format("stack[sp] = band(stack[sp] * %d, 0xFFFFFFFF)", Cu))
                else
                    local c_lo = bit32.band(Cu, 0xFFFF)
                    local c_hi = bit32.rshift(Cu, 16)
                    emit(string.format("do local __a = stack[sp]; local __al = band(__a, 0xFFFF); stack[sp] = band(__al * %d + (__al * %d + rshift(__a, 16) * %d) * 65536, 0xFFFFFFFF) end",
                        c_lo, c_hi, c_lo))
                end
                i = i + 2; goto continue_loop
            elseif nop == 0x36 then -- i32.const C + i32.store (store constant value)
                local off = ni.offset
                local Cv = bit32.band(C, 0xFFFFFFFF)
                emit(string.format("do local __addr = stack[sp]%s", off ~= 0 and (" + " .. off) or ""))
                emit("  sp = sp - 1")
                emit_bc(4)
                emit(string.format("  if band(__addr, 3) == 0 then __md[rshift(__addr, 2)] = %s", u32_lit(Cv)))
                emit(string.format("  else mem:store_i32(__addr, %s) end end", u32_lit(Cv)))
                i = i + 2; goto continue_loop
            elseif nop == 0x3A then -- i32.const C + i32.store8 (store constant byte)
                local off = ni.offset
                local byte_val = bit32.band(C, 0xFF)
                emit(string.format("do local __addr = stack[sp]%s", off ~= 0 and (" + " .. off) or ""))
                emit("  sp = sp - 1")
                emit_bc(1)
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  local __sh = __bo * 8; local __mask = bnot(lshift(0xFF, __sh))")
                emit("  local __w = __md[__wi] or 0")
                emit(string.format("  __md[__wi] = bor(band(__w, __mask), lshift(%d, __sh)) end", byte_val))
                i = i + 2; goto continue_loop
            elseif nop == 0x21 then -- i32.const C + local.set
                emit(string.format("loc[%d] = %s", ni.idx, u32_lit(bit32.band(C, 0xFFFFFFFF))))
                i = i + 2; goto continue_loop
            end
        end

        -- Group 2: local.get X + i32.const C + binary op
        if op == 0x20 and i + 2 <= n_instrs and instrs[i+1].op == 0x41 then
            local X = instr.idx
            local C = instrs[i+1].value
            local n2 = instrs[i+2]
            local nop2 = n2.op

            local fold = local_const_fold[nop2]
            if fold then
                emit(string.format(fold[1], X, fold[2](C)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x6C then -- local.get + i32.const + i32.mul
                local Cu = bit32.band(C, 0xFFFFFFFF)
                if Cu == 0 then
                    emit(string.format("sp = sp + 1; stack[sp] = 0"))
                elseif Cu <= 0xFFFF then
                    emit(string.format("sp = sp + 1; stack[sp] = band(loc[%d] * %d, 0xFFFFFFFF)", X, Cu))
                else
                    local c_lo = bit32.band(Cu, 0xFFFF)
                    local c_hi = bit32.rshift(Cu, 16)
                    emit(string.format("do sp = sp + 1; local __a = loc[%d]; local __al = band(__a, 0xFFFF); stack[sp] = band(__al * %d + (__al * %d + rshift(__a, 16) * %d) * 65536, 0xFFFFFFFF) end",
                        X, c_lo, c_hi, c_lo))
                end
                i = i + 3; goto continue_loop
            end
        end

        -- Group 3: local.get X + ...
        if op == 0x20 and i + 1 <= n_instrs then
            local X = instr.idx
            local ni = instrs[i+1]
            local nop = ni.op

            -- 3-instruction: local.get X + i32.eqz + br_if → direct branch on local
            if nop == 0x45 and i + 2 <= n_instrs and instrs[i+2].op == 0x0D then
                emit_cond_branch_nopop(instrs[i+2].depth, string.format("loc[%d] == 0", X))
                i = i + 3; goto continue_loop
            end

            -- 2-instruction: local.get X + if → use loc[X] directly as condition
            if nop == 0x04 then
                local label_id = new_label()
                local sb_var = "__sbs[" .. label_id .. "]"
                block_sp = block_sp + 1
                block_stack[block_sp] = {
                    type = "if", label_id = label_id,
                    n_results = ni.n_results, n_params = ni.n_params,
                    has_else = false, stack_base_var = sb_var,
                }
                if ni.n_params > 0 then
                    emit(sb_var .. " = sp - " .. ni.n_params)
                else
                    emit(sb_var .. " = sp")
                end
                emit(string.format("if loc[%d] == 0 then goto __else_%d end", X, label_id))
                i = i + 2; goto continue_loop
            end

            -- 3-instruction: local.get X + i32.eqz + if → branch to else when nonzero
            if nop == 0x45 and i + 2 <= n_instrs and instrs[i+2].op == 0x04 then
                local if_instr = instrs[i+2]
                local label_id = new_label()
                local sb_var = "__sbs[" .. label_id .. "]"
                block_sp = block_sp + 1
                block_stack[block_sp] = {
                    type = "if", label_id = label_id,
                    n_results = if_instr.n_results, n_params = if_instr.n_params,
                    has_else = false, stack_base_var = sb_var,
                }
                if if_instr.n_params > 0 then
                    emit(sb_var .. " = sp - " .. if_instr.n_params)
                else
                    emit(sb_var .. " = sp")
                end
                emit(string.format("if loc[%d] ~= 0 then goto __else_%d end", X, label_id))
                i = i + 3; goto continue_loop
            end

            -- 3-instruction: local.get A + local.get B + i32.store → direct store
            if nop == 0x20 and i + 2 <= n_instrs and instrs[i+2].op == 0x36 then
                local B = ni.idx
                local off = instrs[i+2].offset
                if off == 0 then
                    emit(string.format("do local __addr = loc[%d]", X))
                else
                    emit(string.format("do local __addr = loc[%d] + %d", X, off))
                end
                emit_bc(4)
                emit(string.format("  local __v = band(loc[%d], 0xFFFFFFFF)", B))
                emit("  if band(__addr, 3) == 0 then __md[rshift(__addr, 2)] = __v")
                emit("  else mem:store_i32(__addr, __v) end end")
                i = i + 3; goto continue_loop
            end

            -- local.get X + local.set Y → direct copy
            if nop == 0x21 then
                emit(string.format("loc[%d] = loc[%d]", ni.idx, X))
                i = i + 2; goto continue_loop
            end

            if nop == 0x28 then -- local.get + i32.load
                local off = ni.offset
                emit("sp = sp + 1")
                if off == 0 then
                    emit(string.format("do local __addr = loc[%d]", X))
                else
                    emit(string.format("do local __addr = loc[%d] + %d", X, off))
                end
                emit_bc(4)
                emit("  if band(__addr, 3) == 0 then stack[sp] = __md[rshift(__addr, 2)] or 0")
                emit("  else stack[sp] = mem:load_i32(__addr) end end")
                i = i + 2; goto continue_loop
            elseif nop == 0x2D then -- local.get + i32.load8_u
                local off = ni.offset
                emit("sp = sp + 1")
                if off == 0 then
                    emit(string.format("do local __addr = loc[%d]", X))
                else
                    emit(string.format("do local __addr = loc[%d] + %d", X, off))
                end
                emit_bc(1)
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  stack[sp] = band(rshift(__md[__wi] or 0, __bo * 8), 0xFF) end")
                i = i + 2; goto continue_loop
            elseif nop == 0x2C then -- local.get + i32.load8_s
                local off = ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = loc[%d] + %d", X, off))
                emit("  local __v = mem:load_i8_s(__addr)")
                emit("  if __v < 0 then __v = __v + 0x100000000 end")
                emit("  stack[sp] = __v end")
                i = i + 2; goto continue_loop
            elseif nop == 0x2E then -- local.get + i32.load16_s
                local off = ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = loc[%d] + %d", X, off))
                emit("  local __v = mem:load_i16_s(__addr)")
                emit("  if __v < 0 then __v = __v + 0x100000000 end")
                emit("  stack[sp] = __v end")
                i = i + 2; goto continue_loop
            elseif nop == 0x2F then -- local.get + i32.load16_u
                local off = ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = loc[%d] + %d; stack[sp] = mem:load_i16_u(__addr) end", X, off))
                i = i + 2; goto continue_loop
            elseif nop == 0x36 then -- local.get + i32.store (value from local)
                local off = ni.offset
                if off == 0 then
                    emit(string.format("do local __addr = stack[sp]; sp = sp - 1"))
                else
                    emit(string.format("do local __addr = stack[sp] + %d; sp = sp - 1", off))
                end
                emit_bc(4)
                emit(string.format("  local __v = band(loc[%d], 0xFFFFFFFF)", X))
                emit("  if band(__addr, 3) == 0 then __md[rshift(__addr, 2)] = __v")
                emit("  else mem:store_i32(__addr, __v) end end")
                i = i + 2; goto continue_loop
            elseif nop == 0x3A then -- local.get + i32.store8 (value from local)
                local off = ni.offset
                if off == 0 then
                    emit("do local __addr = stack[sp]; sp = sp - 1")
                else
                    emit(string.format("do local __addr = stack[sp] + %d; sp = sp - 1", off))
                end
                emit_bc(1)
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  local __sh = __bo * 8; local __mask = bnot(lshift(0xFF, __sh))")
                emit("  local __w = __md[__wi] or 0")
                emit(string.format("  __md[__wi] = bor(band(__w, __mask), lshift(band(loc[%d], 0xFF), __sh)) end", X))
                i = i + 2; goto continue_loop
            end
        end

        -- Group 4: Comparison + branch fusion
        if op == 0x45 and i + 1 <= n_instrs and instrs[i+1].op == 0x0D then
            -- i32.eqz + br_if → branch if value == 0
            emit_cond_branch(instrs[i+1].depth, "__c == 0")
            i = i + 2; goto continue_loop
        end

        if op == 0x45 and i + 1 <= n_instrs and instrs[i+1].op == 0x04 then
            -- i32.eqz + if → branch to else when original value != 0
            local if_instr = instrs[i+1]
            local label_id = new_label()
            local sb_var = "__sbs[" .. label_id .. "]"
            block_sp = block_sp + 1
            block_stack[block_sp] = {
                type = "if", label_id = label_id,
                n_results = if_instr.n_results, n_params = if_instr.n_params,
                has_else = false, stack_base_var = sb_var,
            }
            emit("__cond = stack[sp]; sp = sp - 1")
            if if_instr.n_params > 0 then
                emit(sb_var .. " = sp - " .. if_instr.n_params)
            else
                emit(sb_var .. " = sp")
            end
            emit(string.format("if __cond ~= 0 then goto __else_%d end", label_id))
            i = i + 2; goto continue_loop
        end

        if op == 0x41 and i + 2 <= n_instrs then
            local C = instr.value
            local ni1 = instrs[i+1]
            local ni2 = instrs[i+2]
            if ni2.op == 0x0D then -- ... + br_if
                local fold = cmp_branch_fold[ni1.op]
                if fold then
                    emit_cond_branch(ni2.depth, string.format(fold[1], fold[2](C)))
                    i = i + 3; goto continue_loop
                end
            end
        end

        -- Group 5: local.get A + local.get B + binary op → single push
        if op == 0x20 and i + 2 <= n_instrs and instrs[i+1].op == 0x20 then
            local fold = get_get_fold[instrs[i+2].op]
            if fold then
                emit(string.format(fold, instr.idx, instrs[i+1].idx))
                i = i + 3; goto continue_loop
            end
        end

        -- === End peephole, fall through to single-instruction codegen ===

        -- Control flow
        if op == 0x00 then -- unreachable
            emit("error({msg='unreachable'})")

        elseif op == 0x01 then -- nop
            -- nothing

        elseif op == 0x02 then -- block
            local label_id = new_label()
            local sb_var = "__sbs[" .. label_id .. "]"
            block_sp = block_sp + 1
            block_stack[block_sp] = {
                type = "block",
                label_id = label_id,
                n_results = instr.n_results,
                n_params = instr.n_params,
                stack_base_var = sb_var,
            }
            if instr.n_params > 0 then
                emit(sb_var .. " = sp - " .. instr.n_params)
            else
                emit(sb_var .. " = sp")
            end

        elseif op == 0x03 then -- loop
            local label_id = new_label()
            local sb_var = "__sbs[" .. label_id .. "]"
            block_sp = block_sp + 1
            block_stack[block_sp] = {
                type = "loop",
                label_id = label_id,
                n_results = instr.n_results,
                n_params = instr.n_params,
                branch_arity = instr.n_params,  -- loops branch to start with params
                stack_base_var = sb_var,
            }
            if instr.n_params > 0 then
                emit(sb_var .. " = sp - " .. instr.n_params)
            else
                emit(sb_var .. " = sp")
            end
            emit("::L_" .. label_id .. "::")

        elseif op == 0x04 then -- if
            local label_id = new_label()
            local sb_var = "__sbs[" .. label_id .. "]"
            block_sp = block_sp + 1
            block_stack[block_sp] = {
                type = "if",
                label_id = label_id,
                n_results = instr.n_results,
                n_params = instr.n_params,
                has_else = false,
                stack_base_var = sb_var,
            }
            emit("__cond = stack[sp]; sp = sp - 1")
            if instr.n_params > 0 then
                emit(sb_var .. " = sp - " .. instr.n_params)
            else
                emit(sb_var .. " = sp")
            end
            emit("if __cond == 0 then goto __else_" .. label_id .. " end")

        elseif op == 0x05 then -- else
            local blk = block_stack[block_sp]
            blk.has_else = true
            emit("goto B_" .. blk.label_id)
            emit("::__else_" .. blk.label_id .. "::")

        elseif op == 0x0B then -- end
            if block_sp <= 1 then
                -- End of function — return sp only (no call_target = done)
                emit("do return sp end")
            else
                local blk = block_stack[block_sp]
                block_sp = block_sp - 1

                if blk.type == "if" then
                    if not blk.has_else then
                        emit("::__else_" .. blk.label_id .. "::")
                    end
                    emit("::B_" .. blk.label_id .. "::")
                elseif blk.type == "loop" then
                    -- loop body falls through naturally
                elseif blk.type == "block" then
                    emit("::B_" .. blk.label_id .. "::")
                elseif blk.type == "try_table" then
                    emit("::B_" .. blk.label_id .. "::")
                end
            end

        elseif op == 0x0C then -- br
            local target = get_branch_target(instr.depth)
            if target then
                if target.type == "func" then
                    emit("do return sp end")
                else
                    local arity = target.branch_arity or target.n_results or 0
                    if arity > 0 and target.stack_base_var then
                        emit_branch_adjust(target.stack_base_var, arity)
                    elseif arity == 0 and target.stack_base_var then
                        emit("sp = " .. target.stack_base_var)
                    end
                    if target.type == "loop" then
                        emit("goto L_" .. target.label_id)
                    else
                        emit("goto B_" .. target.label_id)
                    end
                end
            end

        elseif op == 0x0D then -- br_if
            emit_cond_branch(instr.depth, "__c ~= 0")

        elseif op == 0x0E then -- br_table
            emit("do")
            indent_level = indent_level + 1
            emit("local __idx = stack[sp]; sp = sp - 1")
            for j = 0, instr.count - 1 do
                local target = get_branch_target(instr.targets[j])
                if target then
                    local cmp = j == 0 and "if" or "elseif"
                    if target.type == "func" then
                        emit(string.format("%s __idx == %d then return sp", cmp, j))
                    else
                        local arity = target.branch_arity or target.n_results or 0
                        local label = target.type == "loop"
                            and ("L_" .. target.label_id) or ("B_" .. target.label_id)
                        if arity == 0 and target.stack_base_var then
                            emit(string.format("%s __idx == %d then sp = %s; goto %s",
                                cmp, j, target.stack_base_var, label))
                        elseif arity == 1 and target.stack_base_var then
                            emit(string.format("%s __idx == %d then stack[%s + 1] = stack[sp]; sp = %s + 1; goto %s",
                                cmp, j, target.stack_base_var, target.stack_base_var, label))
                        else
                            emit(string.format("%s __idx == %d then goto %s", cmp, j, label))
                        end
                    end
                end
            end
            -- Default target
            local def_target = get_branch_target(instr.targets[instr.count])
            if def_target then
                emit("else")
                indent_level = indent_level + 1
                if def_target.type == "func" then
                    emit("return sp")
                else
                    local arity = def_target.branch_arity or def_target.n_results or 0
                    if arity > 0 and def_target.stack_base_var then
                        emit_branch_adjust(def_target.stack_base_var, arity)
                    elseif arity == 0 and def_target.stack_base_var then
                        emit("sp = " .. def_target.stack_base_var)
                    end
                    if def_target.type == "loop" then
                        emit("goto L_" .. def_target.label_id)
                    else
                        emit("goto B_" .. def_target.label_id)
                    end
                end
                indent_level = indent_level - 1
            end
            emit("end")
            indent_level = indent_level - 1
            emit("end")

        elseif op == 0x0F then -- return
            emit("do return sp end")

        -- Calls: return sp, target, resume_point to interpreter
        elseif op == 0x10 then -- call
            local csid = instr.call_site_id
            emit(string.format("do return sp, %d, %d end", instr.func_idx, csid))
            emit(string.format("::C_%d::", csid))

        elseif op == 0x11 then -- call_indirect
            local csid = instr.call_site_id
            emit(string.format("ctx.call_indirect_type = %d; ctx.call_indirect_table = %d", instr.type_idx, instr.table_idx))
            emit(string.format("do return sp, -2, %d end", csid))
            emit(string.format("::C_%d::", csid))

        -- Exception handling: fall back to interpreter for these
        elseif op == 0x08 then -- throw
            emit(string.format("ctx.throw_tag = %d; return sp, -3", instr.tagidx))

        elseif op == 0x0A then -- throw_ref
            emit("return sp, -4")

        elseif op == 0x1F then -- try_table
            -- For now, fall back to interpreter for try_table
            local label_id = new_label()
            local sb_var = "__sbs[" .. label_id .. "]"
            block_sp = block_sp + 1
            block_stack[block_sp] = {
                type = "try_table",
                label_id = label_id,
                n_results = instr.n_results,
                n_params = instr.n_params,
                stack_base_var = sb_var,
            }
            if instr.n_params > 0 then
                emit(sb_var .. " = sp - " .. instr.n_params)
            else
                emit(sb_var .. " = sp")
            end

        -- Table-driven opcode emission
        elseif op_table[op] then
            local entry = op_table[op]
            local tmpl = op_templates[entry[1]]
            local p = entry[2]
            if not p then emit(tmpl)
            elseif type(p) == "function" then emit(string.format(tmpl, p(instr)))
            else emit(string.format(tmpl, p, p)) end

        -- Custom opcodes (unique logic, not table-drivable)
        elseif op == 0x6A then -- i32.add
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = band(stack[sp] + __b, 0xFFFFFFFF) end")

        elseif op == 0x6B then -- i32.sub
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = band(stack[sp] - __b + 0x100000000, 0xFFFFFFFF) end")

        elseif op == 0x6C then -- i32.mul
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  local __al = band(__a, 0xFFFF); local __ah = rshift(__a, 16)")
            emit("  stack[sp] = band(__al * band(__b, 0xFFFF) + (__al * rshift(__b, 16) + __ah * band(__b, 0xFFFF)) * 65536, 0xFFFFFFFF) end")

        elseif op == 0x6D then -- i32.div_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  __a = __a >= 0x80000000 and __a - 0x100000000 or __a")
            emit("  __b = __b >= 0x80000000 and __b - 0x100000000 or __b")
            emit("  if __b == 0 then error({msg='integer divide by zero'}) end")
            emit("  if __a == -2147483648 and __b == -1 then error({msg='integer overflow'}) end")
            emit("  local __r = __a / __b; __r = __r >= 0 and floor(__r) or -floor(-__r)")
            emit("  if __r < 0 then __r = __r + 0x100000000 end")
            emit("  stack[sp] = __r end")

        elseif op == 0x6E then -- i32.div_u
            emit("do local __b = stack[sp]; sp = sp - 1")
            emit("  if __b == 0 then error({msg='integer divide by zero'}) end")
            emit("  stack[sp] = floor(stack[sp] / __b) end")

        elseif op == 0x6F then -- i32.rem_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  __a = __a >= 0x80000000 and __a - 0x100000000 or __a")
            emit("  __b = __b >= 0x80000000 and __b - 0x100000000 or __b")
            emit("  if __b == 0 then error({msg='integer divide by zero'}) end")
            emit("  local __r; if __b == -1 then __r = 0")
            emit("  else local __q = __a / __b; __q = __q >= 0 and floor(__q) or -floor(-__q)")
            emit("    __r = __a - __q * __b end")
            emit("  if __r < 0 then __r = __r + 0x100000000 end")
            emit("  stack[sp] = __r end")

        elseif op == 0x70 then -- i32.rem_u
            emit("do local __b = stack[sp]; sp = sp - 1")
            emit("  if __b == 0 then error({msg='integer divide by zero'}) end")
            emit("  stack[sp] = stack[sp] % __b end")

        -- Memory load ops
        elseif op == 0x28 then -- i32.load
            local off = instr.offset
            if off == 0 then
                emit("do local __addr = stack[sp]")
            else
                emit(string.format("do local __addr = stack[sp] + %d", off))
            end
            emit_bc(4)
            emit("  if band(__addr, 3) == 0 then stack[sp] = __md[rshift(__addr, 2)] or 0")
            emit("  else stack[sp] = mem:load_i32(__addr) end end")

        elseif op == 0x29 then -- i64.load
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = mem:load_i64(__addr) end", instr.offset))

        elseif op == 0x2A then -- f32.load
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = mem:load_f32(__addr) end", instr.offset))

        elseif op == 0x2B then -- f64.load
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = mem:load_f64(__addr) end", instr.offset))

        elseif op == 0x2C then -- i32.load8_s
            emit(string.format("do local __addr = stack[sp] + %d", instr.offset))
            emit("  local __v = mem:load_i8_s(__addr)")
            emit("  if __v < 0 then __v = __v + 0x100000000 end")
            emit("  stack[sp] = __v end")

        elseif op == 0x2D then -- i32.load8_u
            local off = instr.offset
            if off == 0 then
                emit("do local __addr = stack[sp]")
            else
                emit(string.format("do local __addr = stack[sp] + %d", off))
            end
            emit_bc(1)
            emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
            emit("  stack[sp] = band(rshift(__md[__wi] or 0, __bo * 8), 0xFF) end")

        elseif op == 0x2E then -- i32.load16_s
            emit(string.format("do local __addr = stack[sp] + %d", instr.offset))
            emit("  local __v = mem:load_i16_s(__addr)")
            emit("  if __v < 0 then __v = __v + 0x100000000 end")
            emit("  stack[sp] = __v end")

        elseif op == 0x2F then -- i32.load16_u
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = mem:load_i16_u(__addr) end", instr.offset))

        -- i64 load ops
        elseif op == 0x30 then -- i64.load8_s
            emit(string.format("do local __addr = stack[sp] + %d", instr.offset))
            emit("  local __v = mem:load_i8_s(__addr)")
            emit("  if __v < 0 then stack[sp] = {band(__v + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF}")
            emit("  else stack[sp] = {__v, 0} end end")

        elseif op == 0x31 then -- i64.load8_u
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = {mem:load_i8_u(__addr), 0} end", instr.offset))

        elseif op == 0x32 then -- i64.load16_s
            emit(string.format("do local __addr = stack[sp] + %d", instr.offset))
            emit("  local __v = mem:load_i16_s(__addr)")
            emit("  if __v < 0 then stack[sp] = {band(__v + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF}")
            emit("  else stack[sp] = {__v, 0} end end")

        elseif op == 0x33 then -- i64.load16_u
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = {mem:load_i16_u(__addr), 0} end", instr.offset))

        elseif op == 0x34 then -- i64.load32_s
            emit(string.format("do local __addr = stack[sp] + %d", instr.offset))
            emit("  local __v = mem:load_i32(__addr)")
            emit("  stack[sp] = {__v, btest(__v, 0x80000000) and 0xFFFFFFFF or 0} end")

        elseif op == 0x35 then -- i64.load32_u
            emit(string.format("do local __addr = stack[sp] + %d; stack[sp] = {mem:load_i32(__addr), 0} end", instr.offset))

        -- Memory store ops
        elseif op == 0x36 then -- i32.store
            local off = instr.offset
            emit("do local __v = stack[sp]; sp = sp - 1")
            if off == 0 then
                emit("  local __addr = stack[sp]; sp = sp - 1")
            else
                emit(string.format("  local __addr = stack[sp] + %d; sp = sp - 1", off))
            end
            emit_bc(4)
            emit("  __v = band(__v, 0xFFFFFFFF)")
            emit("  if band(__addr, 3) == 0 then __md[rshift(__addr, 2)] = __v")
            emit("  else mem:store_i32(__addr, __v) end end")

        elseif op == 0x37 then -- i64.store
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1; mem:store_i64(__addr, __v) end", instr.offset))

        elseif op == 0x38 then -- f32.store
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1; mem:store_f32(__addr, __v) end", instr.offset))

        elseif op == 0x39 then -- f64.store
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1; mem:store_f64(__addr, __v) end", instr.offset))

        elseif op == 0x3A then -- i32.store8
            local off = instr.offset
            emit("do local __v = stack[sp]; sp = sp - 1")
            if off == 0 then
                emit("  local __addr = stack[sp]; sp = sp - 1")
            else
                emit(string.format("  local __addr = stack[sp] + %d; sp = sp - 1", off))
            end
            emit_bc(1)
            emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
            emit("  local __sh = __bo * 8; local __mask = bnot(lshift(0xFF, __sh))")
            emit("  local __w = __md[__wi] or 0")
            emit("  __md[__wi] = bor(band(__w, __mask), lshift(band(__v, 0xFF), __sh)) end")

        elseif op == 0x3B then -- i32.store16
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1; mem:store_i16(__addr, __v) end", instr.offset))

        -- i64 store ops
        elseif op == 0x3C then -- i64.store8
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1", instr.offset))
            emit("  local __bv = type(__v) == 'table' and __v[1] or __v; mem:store_i8(__addr, __bv) end")

        elseif op == 0x3D then -- i64.store16
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1", instr.offset))
            emit("  local __sv = type(__v) == 'table' and band(__v[1], 0xFFFF) or band(__v, 0xFFFF); mem:store_i16(__addr, __sv) end")

        elseif op == 0x3E then -- i64.store32
            emit(string.format("do local __v = stack[sp]; sp = sp - 1; local __addr = stack[sp] + %d; sp = sp - 1", instr.offset))
            emit("  local __wv = type(__v) == 'table' and __v[1] or band(__v, 0xFFFFFFFF); mem:store_i32(__addr, __wv) end")

        -- Extended ops (0xFC prefix)
        elseif op == 0xFC then
            -- Delegate all 0xFC ops to ctx helpers
            local sub = instr.sub_op
            if sub >= 0 and sub <= 7 then
                -- Saturating truncation ops
                emit(string.format("stack[sp] = ctx.trunc_sat(%d, stack[sp])", sub))
            elseif sub == 8 then -- memory.init
                emit(string.format("ctx.memory_init(%d, stack, sp, mem); sp = sp - 3", instr.seg))
            elseif sub == 9 then -- data.drop
                emit(string.format("ctx.data_drop(%d)", instr.seg))
            elseif sub == 10 then -- memory.copy
                emit("ctx.memory_copy(stack, sp, mem); sp = sp - 3")
            elseif sub == 11 then -- memory.fill
                emit("ctx.memory_fill(stack, sp, mem); sp = sp - 3")
            elseif sub == 12 then -- table.init
                emit(string.format("ctx.table_init(%d, %d, stack, sp); sp = sp - 3", instr.seg, instr.tbl))
            elseif sub == 13 then -- elem.drop
                emit(string.format("ctx.elem_drop(%d)", instr.seg))
            elseif sub == 14 then -- table.copy
                emit(string.format("ctx.table_copy(%d, %d, stack, sp); sp = sp - 3", instr.dst, instr.src))
            elseif sub == 15 then -- table.grow
                emit("do local __n = stack[sp]; sp = sp - 1; sp = sp - 1; sp = sp + 1; stack[sp] = 0xFFFFFFFF end")
            elseif sub == 16 then -- table.size
                emit(string.format("sp = sp + 1; stack[sp] = ctx.table_size(%d)", instr.tbl))
            elseif sub == 17 then -- table.fill
                emit(string.format("ctx.table_fill(%d, stack, sp); sp = sp - 3", instr.tbl))
            else
                emit(string.format("error({msg='unknown opcode 0xFC %d'})", sub))
            end

        else
            -- Unknown opcode: emit error
            emit(string.format("error({msg='compiled: unknown opcode 0x%02X'})", op))
        end

        i = i + 1
        ::continue_loop::
    end

    -- Close the function
    emit_raw("end")

    return table.concat(out, "\n"), n_calls
end

---------------------------------------------------------------------------
-- Compile a single function
---------------------------------------------------------------------------

-- Preamble prepended to every compiled function source
Compiler.preamble = [[
local bit32 = bit32
local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local arshift = bit32.arshift
local bnot = bit32.bnot
local btest = bit32.btest
local floor = math.floor
]]

-- Generate source string for a function without calling load().
-- Returns full_source or nil on failure.
function Compiler.compile_function_source(func_def, func_idx, module)
    if func_def.import then return nil end
    if not func_def.code or not func_def.code.code then return nil end

    local code = func_def.code.code
    if type(code) ~= "table" then return nil end -- needs byte array
    if #code == 0 then return nil end

    local ok, source_or_err, n_calls = pcall(generate_source, func_idx, func_def, module)
    if not ok then
        if Compiler.debug then
            log(string.format("Source gen error in func %d: %s\n", func_idx, tostring(source_or_err)))
        end
        return nil
    end

    return Compiler.preamble .. source_or_err
end

-- Compile a function: generate source, load(), return Lua function.
function Compiler.compile_function(func_def, func_idx, module)
    local full_source = Compiler.compile_function_source(func_def, func_idx, module)
    if not full_source then return nil end

    local fn, err = load(full_source, "=wasm_func_" .. func_idx)
    if not fn then
        if Compiler.debug then
            log(string.format("Compile error in func %d: %s\n", func_idx, tostring(err)))
            local f = io.open(string.format("/tmp/claude-1000/wasm_func_%d.lua", func_idx), "w")
            if f then f:write(full_source); f:close() end
        end
        return nil
    end

    return fn()
end

-- Load a pre-compiled source string (from AOT). Returns Lua function or nil.
function Compiler.load_source(source, func_idx)
    local fn, err = load(source, "=wasm_func_" .. func_idx)
    if not fn then
        return nil
    end
    return fn()
end

---------------------------------------------------------------------------
-- Compile all functions in a module
---------------------------------------------------------------------------

function Compiler.compile_module(module, instance)
    local compiled = {}
    local count = 0
    local failed = 0

    for idx, func_def in pairs(module.funcs) do
        if type(idx) == "number" and not func_def.import then
            local fn = Compiler.compile_function(func_def, idx, module)
            if fn then
                compiled[idx] = fn
                count = count + 1
            else
                failed = failed + 1
            end
        end
    end

    if Compiler.debug then
        log(string.format("Compiled %d functions (%d failed)\n", count, failed))
    end

    return compiled
end

-- Debug flag: set to true to dump failed compilations
Compiler.debug = false

return Compiler
