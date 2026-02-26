-- WASM Opcode dispatch table and handlers
-- Each handler receives (state) and operates on state.stack, state.locals, etc.
-- state = { stack, sp, locals, memory, globals, func_table, module, pc, code,
--           block_stack, block_sp, call_stack, call_sp, instance }

local bit32 = bit32
local math_floor = math.floor
local math_abs = math.abs
local math_ceil = math.ceil
local math_sqrt = math.sqrt
local math_min = math.min
local math_max = math.max
local math_huge = math.huge

local Decode = require("scripts.wasm.decode")

local Opcodes = {}

local function fail(msg) error({msg = msg}) end

-- Helper: read a byte from code at pc, advance pc
local function read_byte(state)
    local pc = state.pc
    local b = state.code[pc]
    state.pc = pc + 1
    return b
end

-- Read LEB128 unsigned from code stream
local function read_leb128_u(state)
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    while true do
        local b = code[pc]
        pc = pc + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        if bit32.band(b, 0x80) == 0 then
            break
        end
        shift = shift + 7
    end
    state.pc = pc
    return result
end

-- Read LEB128 signed from code stream
local function read_leb128_s(state)
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    local b
    while true do
        b = code[pc]
        pc = pc + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then
            break
        end
    end
    state.pc = pc
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    if bit32.btest(result, 0x80000000) then
        return result - 0x100000000
    end
    return result
end

-- Read LEB128 signed 64 from code stream, returns {lo, hi}
local function read_leb128_s64(state)
    local lo = 0
    local hi = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    local b
    while true do
        b = code[pc]
        pc = pc + 1
        local val = bit32.band(b, 0x7F)
        if shift < 32 then
            lo = bit32.bor(lo, bit32.lshift(val, shift))
            if shift + 7 > 32 then
                hi = bit32.bor(hi, bit32.rshift(val, 32 - shift))
            end
        elseif shift < 64 then
            hi = bit32.bor(hi, bit32.lshift(val, shift - 32))
        end
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then
            break
        end
    end
    state.pc = pc
    if bit32.btest(b, 0x40) then
        if shift < 32 then
            lo = bit32.bor(lo, bit32.lshift(0xFFFFFFFF, shift))
            hi = 0xFFFFFFFF
        elseif shift < 64 then
            hi = bit32.bor(hi, bit32.lshift(0xFFFFFFFF, shift - 32))
        end
    end
    return {lo, hi}
end

-- Read a memory alignment + offset (used by all memory ops)
local function read_memarg(state)
    local _align = read_leb128_u(state) -- alignment hint, ignored for correctness
    local offset = read_leb128_u(state)
    return offset
end

-- Stateless helpers for bytecode scanning (from shared decode module)
local skip_leb128_at = Decode.skip_leb128
local read_leb128_u_at = Decode.leb128_u

-- Skip operands of a single instruction at position pos in code array.
-- Returns new position after the operands.
-- Used by both build_block_map (stateless scanning) and skip_instruction_operands
-- (runtime scanning via state wrapper).
local function skip_operands_at(code, pos, op)
    if op == 0x08 then return skip_leb128_at(code, pos) -- throw
    elseif op == 0x0A then return pos -- throw_ref
    elseif op == 0x0C or op == 0x0D then return skip_leb128_at(code, pos) -- br, br_if
    elseif op == 0x0E then -- br_table
        local count
        count, pos = read_leb128_u_at(code, pos)
        for _ = 0, count do
            pos = skip_leb128_at(code, pos)
        end
        return pos
    elseif op == 0x0F then return pos -- return
    elseif op == 0x10 then return skip_leb128_at(code, pos) -- call
    elseif op == 0x11 then -- call_indirect
        pos = skip_leb128_at(code, pos)
        return skip_leb128_at(code, pos)
    elseif op == 0x1A or op == 0x1B then return pos -- drop, select
    elseif op == 0x1F then -- try_table
        pos = skip_leb128_at(code, pos) -- blocktype
        local num_catches
        num_catches, pos = read_leb128_u_at(code, pos)
        for _ = 1, num_catches do
            local kind = code[pos]; pos = pos + 1
            if kind == 0 or kind == 2 then -- catch / catch_ref have tagidx
                pos = skip_leb128_at(code, pos)
            end
            pos = skip_leb128_at(code, pos) -- label depth
        end
        return pos
    elseif op >= 0x20 and op <= 0x24 then return skip_leb128_at(code, pos)
    elseif op >= 0x28 and op <= 0x3E then -- memory load/store
        pos = skip_leb128_at(code, pos)
        return skip_leb128_at(code, pos)
    elseif op == 0x3F or op == 0x40 then return skip_leb128_at(code, pos)
    elseif op == 0x41 then return skip_leb128_at(code, pos) -- i32.const
    elseif op == 0x42 then return skip_leb128_at(code, pos) -- i64.const
    elseif op == 0x43 then return pos + 4 -- f32.const
    elseif op == 0x44 then return pos + 8 -- f64.const
    elseif op == 0xFC then return skip_leb128_at(code, pos) -- extended ops
    end
    return pos
end

-- Pre-compute block structure map for a function's bytecode.
-- Returns block_map[opcode_pc] = {end_pc=N, else_pc=M}
-- opcode_pc is the position of the 0x02/0x03/0x04/0x1F byte.
-- end_pc is the position after the matching 0x0B byte.
-- else_pc (if-only) is the position after the 0x05 byte.
function Opcodes.build_block_map(code)
    local block_map = {}
    local bstack = {}
    local top = 0
    local pos = 1
    local len = #code

    while pos <= len do
        local op = code[pos]
        local opcode_pc = pos
        pos = pos + 1

        if op == 0x02 or op == 0x03 or op == 0x04 then
            top = top + 1
            bstack[top] = opcode_pc
            block_map[opcode_pc] = {}
            pos = skip_leb128_at(code, pos) -- skip blocktype
        elseif op == 0x1F then -- try_table
            top = top + 1
            bstack[top] = opcode_pc
            block_map[opcode_pc] = {}
            pos = skip_leb128_at(code, pos) -- blocktype
            local num_catches
            num_catches, pos = read_leb128_u_at(code, pos)
            for _ = 1, num_catches do
                local kind = code[pos]; pos = pos + 1
                if kind == 0 or kind == 2 then
                    pos = skip_leb128_at(code, pos) -- tagidx
                end
                pos = skip_leb128_at(code, pos) -- depth
            end
        elseif op == 0x05 then -- else
            if top > 0 then
                block_map[bstack[top]].else_pc = pos
            end
        elseif op == 0x0B then -- end
            if top > 0 then
                block_map[bstack[top]].end_pc = pos
                top = top - 1
            end
        else
            pos = skip_operands_at(code, pos, op)
        end
    end

    return block_map
end

-- Read block type from code
-- Returns (n_params, n_results)
-- In multi-value extension, blocktype is a signed LEB128:
--   -64 (0x40) = void, negative = valtype (1 result), non-negative = type index
local function read_blocktype(state)
    -- Read as signed LEB128 to handle both single-byte and multi-byte type indices
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    local b
    while true do
        b = code[pc]
        pc = pc + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then break end
    end
    state.pc = pc
    -- Sign extend
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    if bit32.btest(result, 0x80000000) then
        result = result - 0x100000000
    end

    if result == -64 then
        return 0, 0 -- void
    elseif result < 0 then
        return 0, 1 -- valtype: 0 params, 1 result
    else
        -- Type index: look up params/results from module types
        local type_info = state.module and state.module.types[result + 1]
        if type_info then
            return #type_info.params, #type_info.results
        end
        return 0, 1 -- fallback
    end
end

-- Stack push/pop helpers (inlined for performance in hot paths)
local function push(state, val)
    local sp = state.sp + 1
    state.sp = sp
    state.stack[sp] = val
end

local function pop(state)
    local sp = state.sp
    local val = state.stack[sp]
    state.sp = sp - 1
    return val
end

-- Convert unsigned i32 to signed i32
local function to_signed32(v)
    if v >= 0x80000000 then
        return v - 0x100000000
    end
    return v
end

-- Ensure value is in u32 range
local function to_u32(v)
    return bit32.band(v, 0xFFFFFFFF)
end

-- NaN boxing: Lua normalizes all NaN values to a single canonical bit pattern,
-- losing the payload bits. But WASM non-arithmetic ops (neg, abs, copysign) must
-- preserve NaN payloads, and reinterpret must round-trip exact bit patterns.
-- We box NaN as tables: f32 NaN = {nan32 = <u32 bits>}, f64 NaN = {nan64 = {lo, hi}}.
-- The metatable makes boxed NaN behave correctly in Lua arithmetic (+, -, *, / all
-- return canonical NaN) and ordered comparisons (< and <= return false).
local NAN = 0/0
local nan_mt = {
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

-- Check if a float value is NaN (either Lua NaN or boxed NaN table)
local function isnan(v) return v ~= v or type(v) == "table" end

-- f32 truncation: round a Lua double to single precision (round-to-nearest, ties-to-even)
local function f32_trunc(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    local sign = 1
    if v < 0 then sign = -1; v = -v end
    local m, e = math.frexp(v) -- m in [0.5, 1.0), v = m * 2^e
    -- Determine mantissa precision based on f32 exponent range
    local prec
    if e >= -125 then
        prec = 24 -- normal: 24 mantissa bits (including implicit 1)
    elseif e >= -149 then
        prec = e + 149 -- denormal: fewer bits
    else
        return sign == -1 and -0.0 or 0.0 -- underflow to zero
    end
    -- Scale mantissa and round to integer (round-to-nearest, ties-to-even)
    local scaled = math.ldexp(m, prec)
    local rounded = math_floor(scaled)
    local frac = scaled - rounded
    if frac > 0.5 or (frac == 0.5 and rounded % 2 == 1) then
        rounded = rounded + 1
    end
    local result = sign * math.ldexp(rounded, e - prec)
    -- Check overflow to infinity
    if math_abs(result) > 3.4028234663852886e+38 then return sign * math_huge end
    return result
end

-- i64 helpers: {lo, hi} pair operations
local function i64_zero() return {0, 0} end

local function i64_is_zero(v)
    return v[1] == 0 and v[2] == 0
end

local function i64_eq(a, b) return a[1] == b[1] and a[2] == b[2] end

local function i64_ne(a, b) return a[1] ~= b[1] or a[2] ~= b[2] end

local function i64_eqz(a) return a[1] == 0 and a[2] == 0 end

-- i64 to signed: returns sign (-1 or 1) and absolute {lo, hi}
local function i64_is_neg(v)
    return bit32.btest(v[2], 0x80000000)
end

-- i64 negate (two's complement)
local function i64_neg(v)
    local lo = bit32.bnot(v[1])
    local hi = bit32.bnot(v[2])
    -- add 1
    local new_lo = lo + 1
    local carry = 0
    if new_lo > 0xFFFFFFFF then
        new_lo = bit32.band(new_lo, 0xFFFFFFFF)
        carry = 1
    end
    return {new_lo, bit32.band(hi + carry, 0xFFFFFFFF)}
end

local function i64_add(a, b)
    local lo = a[1] + b[1]
    local carry = 0
    if lo > 0xFFFFFFFF then
        carry = 1
        lo = bit32.band(lo, 0xFFFFFFFF)
    end
    local hi = bit32.band(a[2] + b[2] + carry, 0xFFFFFFFF)
    return {lo, hi}
end

local function i64_sub(a, b)
    return i64_add(a, i64_neg(b))
end

local function i64_and(a, b)
    return {bit32.band(a[1], b[1]), bit32.band(a[2], b[2])}
end

local function i64_or(a, b)
    return {bit32.bor(a[1], b[1]), bit32.bor(a[2], b[2])}
end

local function i64_xor(a, b)
    return {bit32.bxor(a[1], b[1]), bit32.bxor(a[2], b[2])}
end

local function i64_shl(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then
        return {0, bit32.lshift(v[1], shift - 32)}
    end
    local lo = bit32.lshift(v[1], shift)
    local hi = bit32.bor(bit32.lshift(v[2], shift), bit32.rshift(v[1], 32 - shift))
    return {lo, hi}
end

local function i64_shr_u(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then
        return {bit32.rshift(v[2], shift - 32), 0}
    end
    local hi = bit32.rshift(v[2], shift)
    local lo = bit32.bor(bit32.rshift(v[1], shift), bit32.lshift(v[2], 32 - shift))
    return {lo, hi}
end

local function i64_shr_s(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then
        local hi_signed = to_signed32(v[2])
        local new_lo
        if shift >= 64 then
            -- All bits from arithmetic shift
            if hi_signed < 0 then
                return {0xFFFFFFFF, 0xFFFFFFFF}
            else
                return {0, 0}
            end
        end
        new_lo = bit32.arshift(v[2], shift - 32)
        local new_hi = hi_signed < 0 and 0xFFFFFFFF or 0
        return {new_lo, new_hi}
    end
    local hi = bit32.arshift(v[2], shift)
    local lo = bit32.bor(bit32.rshift(v[1], shift), bit32.lshift(v[2], 32 - shift))
    return {lo, hi}
end

local function i64_lt_u(a, b)
    if a[2] ~= b[2] then
        return a[2] < b[2]
    end
    return a[1] < b[1]
end

local function i64_lt_s(a, b)
    local a_neg = bit32.btest(a[2], 0x80000000)
    local b_neg = bit32.btest(b[2], 0x80000000)
    if a_neg ~= b_neg then return a_neg end
    return i64_lt_u(a, b)
end

local function i64_le_u(a, b) return not i64_lt_u(b, a) end
local function i64_le_s(a, b) return not i64_lt_s(b, a) end
local function i64_gt_u(a, b) return i64_lt_u(b, a) end
local function i64_gt_s(a, b) return i64_lt_s(b, a) end
local function i64_ge_u(a, b) return not i64_lt_u(a, b) end
local function i64_ge_s(a, b) return not i64_lt_s(a, b) end

-- i64 multiply using double precision where possible, falling back to decomposition
local function i64_mul(a, b)
    -- Decompose into 16-bit chunks to avoid precision loss
    local a0 = bit32.band(a[1], 0xFFFF)
    local a1 = bit32.rshift(a[1], 16)
    local a2 = bit32.band(a[2], 0xFFFF)
    local a3 = bit32.rshift(a[2], 16)
    local b0 = bit32.band(b[1], 0xFFFF)
    local b1 = bit32.rshift(b[1], 16)

    -- Only need low 64 bits of result
    local c0 = a0 * b0
    local c1 = a1 * b0 + a0 * b1
    local c2 = a2 * b0 + a1 * b1 + a0 * bit32.band(b[2], 0xFFFF)
    local c3 = a3 * b0 + a2 * b1 + a1 * bit32.band(b[2], 0xFFFF) + a0 * bit32.rshift(b[2], 16)

    -- Combine
    local lo = bit32.band(c0, 0xFFFF)
    c1 = c1 + math_floor(c0 / 65536)
    lo = bit32.bor(lo, bit32.lshift(bit32.band(c1, 0xFFFF), 16))
    c2 = c2 + math_floor(c1 / 65536)
    local hi = bit32.band(c2, 0xFFFF)
    c3 = c3 + math_floor(c2 / 65536)
    hi = bit32.bor(hi, bit32.lshift(bit32.band(c3, 0xFFFF), 16))

    return {lo, hi}
end

-- i64 div/rem - unsigned
local function i64_div_u(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    -- Simple case: both fit in Lua doubles (< 2^53)
    if a[2] == 0 and b[2] == 0 then
        return {math_floor(a[1] / b[1]), 0}
    end
    -- Long division using bit-by-bit approach
    local quotient = {0, 0}
    local remainder = {0, 0}
    for i = 63, 0, -1 do
        -- Shift remainder left by 1
        remainder = i64_shl(remainder, 1)
        -- Get bit i of a
        local word = i >= 32 and a[2] or a[1]
        local bit_pos = i >= 32 and (i - 32) or i
        if bit32.btest(word, bit32.lshift(1, bit_pos)) then
            remainder[1] = bit32.bor(remainder[1], 1)
        end
        -- If remainder >= b, subtract
        if not i64_lt_u(remainder, b) then
            remainder = i64_sub(remainder, b)
            local q_word = i >= 32 and 2 or 1
            local q_bit = i >= 32 and (i - 32) or i
            quotient[q_word] = bit32.bor(quotient[q_word], bit32.lshift(1, q_bit))
        end
    end
    return quotient
end

local function i64_rem_u(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    if a[2] == 0 and b[2] == 0 then
        return {a[1] % b[1], 0}
    end
    -- Compute a - (a/b)*b
    local q = i64_div_u(a, b)
    local qb = i64_mul(q, b)
    return i64_sub(a, qb)
end

local function i64_div_s(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    -- Overflow: INT64_MIN / -1
    if a[1] == 0 and a[2] == 0x80000000 and b[1] == 0xFFFFFFFF and b[2] == 0xFFFFFFFF then
        fail("integer overflow")
    end
    local a_neg = i64_is_neg(a)
    local b_neg = i64_is_neg(b)
    local ua = a_neg and i64_neg(a) or a
    local ub = b_neg and i64_neg(b) or b
    local result = i64_div_u(ua, ub)
    if a_neg ~= b_neg then
        return i64_neg(result)
    end
    return result
end

local function i64_rem_s(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    local a_neg = i64_is_neg(a)
    local ua = a_neg and i64_neg(a) or a
    local ub = i64_is_neg(b) and i64_neg(b) or b
    local result = i64_rem_u(ua, ub)
    if a_neg then
        return i64_neg(result)
    end
    return result
end

local function i64_clz(v)
    if v[2] ~= 0 then
        -- Count leading zeros in high word
        local n = 0
        local x = v[2]
        if bit32.band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32.lshift(x, 16) end
        if bit32.band(x, 0xFF000000) == 0 then n = n + 8; x = bit32.lshift(x, 8) end
        if bit32.band(x, 0xF0000000) == 0 then n = n + 4; x = bit32.lshift(x, 4) end
        if bit32.band(x, 0xC0000000) == 0 then n = n + 2; x = bit32.lshift(x, 2) end
        if bit32.band(x, 0x80000000) == 0 then n = n + 1 end
        return {n, 0}
    elseif v[1] ~= 0 then
        local n = 32
        local x = v[1]
        if bit32.band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32.lshift(x, 16) end
        if bit32.band(x, 0xFF000000) == 0 then n = n + 8; x = bit32.lshift(x, 8) end
        if bit32.band(x, 0xF0000000) == 0 then n = n + 4; x = bit32.lshift(x, 4) end
        if bit32.band(x, 0xC0000000) == 0 then n = n + 2; x = bit32.lshift(x, 2) end
        if bit32.band(x, 0x80000000) == 0 then n = n + 1 end
        return {n, 0}
    else
        return {64, 0}
    end
end

local function i64_ctz(v)
    if v[1] ~= 0 then
        local n = 0
        local x = v[1]
        if bit32.band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32.rshift(x, 16) end
        if bit32.band(x, 0x000000FF) == 0 then n = n + 8; x = bit32.rshift(x, 8) end
        if bit32.band(x, 0x0000000F) == 0 then n = n + 4; x = bit32.rshift(x, 4) end
        if bit32.band(x, 0x00000003) == 0 then n = n + 2; x = bit32.rshift(x, 2) end
        if bit32.band(x, 0x00000001) == 0 then n = n + 1 end
        return {n, 0}
    elseif v[2] ~= 0 then
        local n = 32
        local x = v[2]
        if bit32.band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32.rshift(x, 16) end
        if bit32.band(x, 0x000000FF) == 0 then n = n + 8; x = bit32.rshift(x, 8) end
        if bit32.band(x, 0x0000000F) == 0 then n = n + 4; x = bit32.rshift(x, 4) end
        if bit32.band(x, 0x00000003) == 0 then n = n + 2; x = bit32.rshift(x, 2) end
        if bit32.band(x, 0x00000001) == 0 then n = n + 1 end
        return {n, 0}
    else
        return {64, 0}
    end
end

local function i64_popcnt(v)
    -- Count bits in both words
    local function popcnt32(x)
        x = x - bit32.band(bit32.rshift(x, 1), 0x55555555)
        x = bit32.band(x, 0x33333333) + bit32.band(bit32.rshift(x, 2), 0x33333333)
        x = bit32.band(x + bit32.rshift(x, 4), 0x0F0F0F0F)
        x = x + bit32.rshift(x, 8)
        x = x + bit32.rshift(x, 16)
        return bit32.band(x, 0x3F)
    end
    return {popcnt32(v[1]) + popcnt32(v[2]), 0}
end

local function i64_rotl(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    local left = i64_shl(v, shift)
    local right = i64_shr_u(v, 64 - shift)
    return i64_or(left, right)
end

local function i64_rotr(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    local right = i64_shr_u(v, shift)
    local left = i64_shl(v, 64 - shift)
    return i64_or(left, right)
end

-- Convert i64 {lo,hi} to Lua number (f64), preserving sign for signed interpretation
local function i64_to_f64_u(v)
    return v[2] * 4294967296 + v[1]
end

local function i64_to_f64_s(v)
    if i64_is_neg(v) then
        local pos = i64_neg(v)
        return -(pos[2] * 4294967296 + pos[1])
    end
    return v[2] * 4294967296 + v[1]
end

-- Direct i64 to f32 conversion, avoiding double-rounding through f64.
-- When i64 has >53 significant bits, the f64 intermediate loses precision
-- and f32_trunc(f64) can give a different result than direct i64→f32 rounding.
local function i64_to_f32_u(v)
    local lo, hi = v[1], v[2]
    if hi == 0 then return f32_trunc(lo) end
    -- Find MSB position in hi (0-indexed)
    local msb_hi = 0
    local tmp = hi
    if tmp >= 65536 then msb_hi = msb_hi + 16; tmp = bit32.rshift(tmp, 16) end
    if tmp >= 256 then msb_hi = msb_hi + 8; tmp = bit32.rshift(tmp, 8) end
    if tmp >= 16 then msb_hi = msb_hi + 4; tmp = bit32.rshift(tmp, 4) end
    if tmp >= 4 then msb_hi = msb_hi + 2; tmp = bit32.rshift(tmp, 2) end
    if tmp >= 2 then msb_hi = msb_hi + 1 end
    local msb = 32 + msb_hi  -- MSB position in the full 64-bit value
    local shift = msb - 23   -- bits to shift right to get 24-bit mantissa
    -- Extract 24-bit mantissa
    local mantissa
    if shift >= 32 then
        mantissa = bit32.rshift(hi, shift - 32)
    else
        mantissa = bit32.bor(bit32.rshift(lo, shift), bit32.lshift(hi, 32 - shift))
    end
    mantissa = bit32.band(mantissa, 0xFFFFFF)
    -- Guard bit (bit just below mantissa)
    local guard_pos = shift - 1
    local guard
    if guard_pos >= 32 then
        guard = bit32.band(bit32.rshift(hi, guard_pos - 32), 1)
    else
        guard = bit32.band(bit32.rshift(lo, guard_pos), 1)
    end
    -- Sticky bit (OR of all bits below guard)
    local sticky = 0
    if guard_pos > 32 then
        if lo ~= 0 then sticky = 1 end
        if sticky == 0 then
            local hi_mask = bit32.lshift(1, guard_pos - 32) - 1
            if bit32.band(hi, hi_mask) ~= 0 then sticky = 1 end
        end
    elseif guard_pos == 32 then
        if lo ~= 0 then sticky = 1 end
    elseif guard_pos > 0 then
        local lo_mask = bit32.lshift(1, guard_pos) - 1
        if bit32.band(lo, lo_mask) ~= 0 then sticky = 1 end
    end
    -- Round to nearest even
    if guard == 1 then
        if sticky == 1 or bit32.band(mantissa, 1) == 1 then
            mantissa = mantissa + 1
            if mantissa > 0xFFFFFF then
                mantissa = bit32.rshift(mantissa, 1)
                msb = msb + 1
            end
        end
    end
    local result = math.ldexp(mantissa, msb - 23)
    if result > 3.4028234663852886e+38 then return math_huge end
    return result
end

local function i64_to_f32_s(v)
    if i64_is_neg(v) then
        return -i64_to_f32_u(i64_neg(v))
    end
    return i64_to_f32_u(v)
end

-- Convert f64 to i64
local function f64_to_i64_u(v)
    if v < 0 or v ~= v then return {0, 0} end
    if v >= 18446744073709551616 then return {0xFFFFFFFF, 0xFFFFFFFF} end
    v = math_floor(v)
    local hi = math_floor(v / 4294967296)
    local lo = v - hi * 4294967296
    return {lo, bit32.band(hi, 0xFFFFFFFF)}
end

local function f64_to_i64_s(v)
    if v ~= v then return {0, 0} end
    local neg = v < 0
    v = math_floor(math_abs(v))
    local hi = math_floor(v / 4294967296)
    local lo = v - hi * 4294967296
    local result = {lo, bit32.band(hi, 0xFFFFFFFF)}
    if neg then
        return i64_neg(result)
    end
    return result
end

-- i32 CLZ/CTZ/POPCNT
local function i32_clz(x)
    if x == 0 then return 32 end
    local n = 0
    if bit32.band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32.lshift(x, 16) end
    if bit32.band(x, 0xFF000000) == 0 then n = n + 8; x = bit32.lshift(x, 8) end
    if bit32.band(x, 0xF0000000) == 0 then n = n + 4; x = bit32.lshift(x, 4) end
    if bit32.band(x, 0xC0000000) == 0 then n = n + 2; x = bit32.lshift(x, 2) end
    if bit32.band(x, 0x80000000) == 0 then n = n + 1 end
    return n
end

local function i32_ctz(x)
    if x == 0 then return 32 end
    local n = 0
    if bit32.band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32.rshift(x, 16) end
    if bit32.band(x, 0x000000FF) == 0 then n = n + 8; x = bit32.rshift(x, 8) end
    if bit32.band(x, 0x0000000F) == 0 then n = n + 4; x = bit32.rshift(x, 4) end
    if bit32.band(x, 0x00000003) == 0 then n = n + 2; x = bit32.rshift(x, 2) end
    if bit32.band(x, 0x00000001) == 0 then n = n + 1 end
    return n
end

local function i32_popcnt(x)
    x = x - bit32.band(bit32.rshift(x, 1), 0x55555555)
    x = bit32.band(x, 0x33333333) + bit32.band(bit32.rshift(x, 2), 0x33333333)
    x = bit32.band(x + bit32.rshift(x, 4), 0x0F0F0F0F)
    x = x + bit32.rshift(x, 8)
    x = x + bit32.rshift(x, 16)
    return bit32.band(x, 0x3F)
end

-- Reinterpret helpers
local function f32_reinterpret_i32(bits)
    -- Decode IEEE 754 single from u32
    local sign = bit32.btest(bits, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(bits, 23), 0xFF)
    local mant = bit32.band(bits, 0x7FFFFF)
    if exp == 0xFF then
        if mant == 0 then return sign * math_huge end
        return setmetatable({nan32 = bits}, nan_mt)
    elseif exp == 0 then
        if mant == 0 then return sign == -1 and -0.0 or 0.0 end
        return sign * math.ldexp(mant, -149)
    end
    return sign * math.ldexp(mant + 8388608, exp - 150)
end

local function i32_reinterpret_f32(v)
    if isnan(v) then
        if type(v) == "table" and v.nan32 then return v.nan32 end
        return 0x7FC00000 -- canonical NaN
    end
    if v == 0 then
        if 1 / v < 0 then return 0x80000000 end
        return 0
    end
    if v == math_huge then return 0x7F800000 end
    if v == -math_huge then return 0xFF800000 end
    local sign = 0
    if v < 0 then sign = 0x80000000; v = -v end
    local m, e = math.frexp(v)
    e = e + 126
    if e <= 0 then
        m = m * math.ldexp(1, e + 23)
        e = 0
    else
        m = (m * 2 - 1) * math.ldexp(1, 23)
    end
    return bit32.bor(sign, bit32.lshift(bit32.band(e, 0xFF), 23), bit32.band(math_floor(m), 0x7FFFFF))
end

local function f64_reinterpret_i64(v)
    -- v is {lo, hi}
    local lo, hi = v[1], v[2]
    local sign = bit32.btest(hi, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(hi, 20), 0x7FF)
    local mant_hi = bit32.band(hi, 0xFFFFF)
    local mant = mant_hi * 4294967296 + lo
    if exp == 0x7FF then
        if mant == 0 then return sign * math_huge end
        return setmetatable({nan64 = {lo, hi}}, nan_mt)
    elseif exp == 0 then
        if mant == 0 then return sign == -1 and -0.0 or 0.0 end
        return sign * math.ldexp(mant, -1074)
    end
    return sign * math.ldexp(mant + 4503599627370496, exp - 1075)
end

local function i64_reinterpret_f64(v)
    if isnan(v) then
        if type(v) == "table" and v.nan64 then return {v.nan64[1], v.nan64[2]} end
        return {0, 0x7FF80000} -- canonical f64 NaN
    end
    if v == 0 then
        if 1 / v < 0 then return {0, 0x80000000} end
        return {0, 0}
    end
    if v == math_huge then return {0, 0x7FF00000} end
    if v == -math_huge then return {0, 0xFFF00000} end
    local sign = 0
    if v < 0 then sign = 0x80000000; v = -v end
    local m, e = math.frexp(v)
    e = e + 1022
    if e <= 0 then
        m = m * math.ldexp(1, e + 52)
        e = 0
    else
        m = (m * 2 - 1) * math.ldexp(1, 52)
    end
    local mant_hi = math_floor(m / 4294967296)
    local lo = m - mant_hi * 4294967296
    local hi = bit32.bor(sign, bit32.lshift(bit32.band(e, 0x7FF), 20), bit32.band(mant_hi, 0xFFFFF))
    return {lo, hi}
end

-- f32 math helpers
local function f32_abs(v)
    if isnan(v) then
        if type(v) == "table" and v.nan32 then return setmetatable({nan32 = bit32.band(v.nan32, 0x7FFFFFFF)}, nan_mt) end
        return NAN
    end
    return math_abs(v)
end
local function f32_neg(v)
    if isnan(v) then
        if type(v) == "table" and v.nan32 then return setmetatable({nan32 = bit32.bxor(v.nan32, 0x80000000)}, nan_mt) end
        return NAN
    end
    return -v
end
local function f32_ceil(v)
    if isnan(v) then return NAN end
    return f32_trunc(math_ceil(v))
end
local function f32_floor(v)
    if isnan(v) then return NAN end
    return f32_trunc(math_floor(v))
end
local function f32_nearest(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    -- Values >= 2^23 are already integers in f32
    if math_abs(v) >= 8388608 then return v end
    local r = math_floor(v + 0.5)
    -- Banker's rounding: if exactly halfway, round to even
    if v + 0.5 == r and r % 2 ~= 0 then r = r - 1 end
    -- Preserve negative zero: if input was negative and result is 0
    if r == 0 and v < 0 then return -0.0 end
    return f32_trunc(r)
end
local function f32_sqrt(v)
    if isnan(v) then return NAN end
    return f32_trunc(math_sqrt(v))
end
local function f32_min(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then
        -- -0 < +0
        if (1/a < 0) or (1/b < 0) then return -0.0 end
        return 0.0
    end
    return a < b and a or b
end
local function f32_max(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then
        if (1/a > 0) or (1/b > 0) then return 0.0 end
        return -0.0
    end
    return a > b and a or b
end
local function f32_copysign(a, b)
    local b_neg
    if isnan(b) then
        b_neg = type(b) == "table" and b.nan32 and bit32.btest(b.nan32, 0x80000000) or false
    else
        b_neg = b < 0 or (b == 0 and 1/b < 0)
    end
    if isnan(a) then
        if type(a) == "table" and a.nan32 then
            local bits = b_neg and bit32.bor(a.nan32, 0x80000000) or bit32.band(a.nan32, 0x7FFFFFFF)
            return setmetatable({nan32 = bits}, nan_mt)
        end
        return NAN
    end
    a = math_abs(a)
    if b_neg then return -a end
    return a
end

-- f64 math helpers
local function f64_abs(v)
    if isnan(v) then
        if type(v) == "table" and v.nan64 then return setmetatable({nan64 = {v.nan64[1], bit32.band(v.nan64[2], 0x7FFFFFFF)}}, nan_mt) end
        return NAN
    end
    return math_abs(v)
end
local function f64_neg(v)
    if isnan(v) then
        if type(v) == "table" and v.nan64 then return setmetatable({nan64 = {v.nan64[1], bit32.bxor(v.nan64[2], 0x80000000)}}, nan_mt) end
        return NAN
    end
    return -v
end
local function f64_ceil(v)
    if isnan(v) then return NAN end
    return math_ceil(v)
end
local function f64_floor(v)
    if isnan(v) then return NAN end
    return math_floor(v)
end
local function f64_nearest(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    -- Values >= 2^52 are already integers in double precision
    if math_abs(v) >= 4503599627370496 then return v end
    local r = math_floor(v + 0.5)
    -- Banker's rounding: ties to even
    if v + 0.5 == r and r % 2 ~= 0 then r = r - 1 end
    -- Preserve negative zero
    if r == 0 and v < 0 then return -0.0 end
    return r
end
local function f64_sqrt(v)
    if isnan(v) then return NAN end
    return math_sqrt(v)
end
local function f64_min(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then
        if (1/a < 0) or (1/b < 0) then return -0.0 end
        return 0.0
    end
    return a < b and a or b
end
local function f64_max(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then
        if (1/a > 0) or (1/b > 0) then return 0.0 end
        return -0.0
    end
    return a > b and a or b
end
local function f64_copysign(a, b)
    local b_neg
    if isnan(b) then
        b_neg = type(b) == "table" and b.nan64 and bit32.btest(b.nan64[2], 0x80000000) or false
    else
        b_neg = b < 0 or (b == 0 and 1/b < 0)
    end
    if isnan(a) then
        if type(a) == "table" and a.nan64 then
            local bits_hi = b_neg and bit32.bor(a.nan64[2], 0x80000000) or bit32.band(a.nan64[2], 0x7FFFFFFF)
            return setmetatable({nan64 = {a.nan64[1], bits_hi}}, nan_mt)
        end
        return NAN
    end
    a = math_abs(a)
    if b_neg then return -a end
    return a
end

local function f64_trunc_op(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge or v == 0 then return v end
    if v > 0 then return math_floor(v) end
    return math_ceil(v)
end

local function f32_trunc_op(v)
    return f32_trunc(f64_trunc_op(v))
end

---------------------------------------------------------------------------
-- Dispatch table: opcode -> handler function
---------------------------------------------------------------------------
local dispatch = {}

-- 0x00: unreachable
dispatch[0x00] = function(state)
    fail("unreachable")
end

-- 0x01: nop
dispatch[0x01] = function(state) end

-- Helper: unwind block stack looking for a try_table with matching catch clause.
-- If found, sets up the branch and returns true. If not found, returns false
-- (exception must propagate to caller).
local function handle_exception(state, exception)
    local bsp = state.block_sp
    while bsp >= 1 do
        local block = state.block_stack[bsp]
        if block.opcode == 0x1F and block.catches then
            -- try_table block: check catch clauses
            for _, clause in ipairs(block.catches) do
                local matched = false
                if clause.kind == 0 then -- catch tagidx
                    matched = (exception.tag == clause.tagidx)
                elseif clause.kind == 1 then -- catch_all
                    matched = true
                elseif clause.kind == 2 then -- catch_ref tagidx
                    matched = (exception.tag == clause.tagidx)
                elseif clause.kind == 3 then -- catch_all_ref
                    matched = true
                end
                if matched then
                    -- Restore stack to block height
                    state.sp = block.stack_height

                    -- Push exception values for catch/catch_ref
                    if clause.kind == 0 or clause.kind == 2 then
                        for _, v in ipairs(exception.values) do
                            push(state, v)
                        end
                    end

                    -- Push exnref for catch_ref/catch_all_ref
                    if clause.kind == 2 or clause.kind == 3 then
                        push(state, exception) -- the exception object itself serves as exnref
                    end

                    -- Branch to the label (clause.depth is relative to the try_table's position)
                    state.block_sp = bsp
                    state.exception = nil
                    do_branch(state, clause.depth)
                    return true
                end
            end
        end
        bsp = bsp - 1
    end
    -- No handler found in current function
    return false
end

-- 0x08: throw
dispatch[0x08] = function(state)
    local tagidx = read_leb128_u(state)
    local module = state.module or (state.instance and state.instance.module)
    local tags = state.instance and state.instance.tags
    local tag = tags and tags[tagidx]
    local values = {}
    if tag then
        local type_info = module.types[tag.type_idx + 1]
        if type_info then
            for i = #type_info.params, 1, -1 do
                values[i] = pop(state)
            end
        end
    end
    local exception = {tag = tagidx, values = values}
    if not handle_exception(state, exception) then
        state.exception = exception
        state.running = false
    end
end

-- 0x0A: throw_ref
dispatch[0x0A] = function(state)
    local exnref = pop(state)
    if type(exnref) ~= "table" or exnref.tag == nil then
        fail("throw_ref: invalid exnref")
    end
    if not handle_exception(state, exnref) then
        state.exception = exnref
        state.running = false
    end
end

-- 0x02: block
dispatch[0x02] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x02,
        arity = n_results, -- branch arity = results for block
        stack_height = state.sp - n_params,
        block_pc = block_pc,
    }
end

-- 0x03: loop
dispatch[0x03] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x03,
        arity = n_params, -- branch arity: loops branch to start, passing params
        result_arity = n_results, -- result arity: used when falling through end
        stack_height = state.sp - n_params,
        continuation_pc = state.pc,
        block_pc = block_pc,
    }
end

-- 0x04: if
dispatch[0x04] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local cond = pop(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x04,
        arity = n_results, -- branch arity = results for if
        stack_height = state.sp - n_params,
        block_pc = block_pc,
    }
    if cond == 0 then
        -- Use block_map for O(1) skip to else or end
        local info = state.block_map[block_pc]
        if info.else_pc then
            state.pc = info.else_pc
        else
            -- No else branch, block is done
            state.block_sp = bsp - 1
            state.pc = info.end_pc
        end
    end
    -- cond is true, execute the if body
end

-- 0x05: else
dispatch[0x05] = function(state)
    -- We reached else from the 'then' branch, jump to end using block_map
    local bsp = state.block_sp
    local block = state.block_stack[bsp]
    state.pc = state.block_map[block.block_pc].end_pc
    state.block_sp = bsp - 1
    -- Keep result values on stack
    local n_results = block.result_arity or block.arity
    if n_results > 0 then
        local sp = state.sp
        local base = block.stack_height
        for i = n_results - 1, 0, -1 do
            state.stack[base + 1 + i] = state.stack[sp - (n_results - 1 - i)]
        end
        state.sp = base + n_results
    else
        state.sp = block.stack_height
    end
end

-- 0x0B: end
dispatch[0x0B] = function(state)
    local bsp = state.block_sp
    if bsp <= 0 then
        -- End of function
        state.running = false
        return
    end
    local block = state.block_stack[bsp]
    state.block_sp = bsp - 1
    -- Restore stack to block height + result values
    -- For loops, result_arity differs from branch arity
    local n_results = block.result_arity or block.arity
    if n_results > 0 then
        local sp = state.sp
        local base = block.stack_height
        -- Copy n_results values from top of stack to base
        for i = n_results - 1, 0, -1 do
            state.stack[base + 1 + i] = state.stack[sp - (n_results - 1 - i)]
        end
        state.sp = base + n_results
    else
        state.sp = block.stack_height
    end
    -- If we just popped the function-level block, we're done
    if bsp - 1 <= 0 then
        state.running = false
    end
end

-- 0x1F: try_table
dispatch[0x1F] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local num_catches = read_leb128_u(state)
    local catches = {}
    for i = 1, num_catches do
        local kind = read_byte(state) -- 0=catch, 1=catch_all, 2=catch_ref, 3=catch_all_ref
        local tagidx = nil
        if kind == 0 or kind == 2 then
            tagidx = read_leb128_u(state)
        end
        local depth = read_leb128_u(state) -- label index (branch depth)
        catches[i] = {kind = kind, tagidx = tagidx, depth = depth}
    end
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x1F,
        arity = n_results, -- branch arity = results for try_table (like block)
        stack_height = state.sp - n_params,
        catches = catches,
        block_pc = block_pc,
    }
end

-- Helper: skip instruction operands for code scanning
-- Wrapper: skip operands using the stateless skip_operands_at on state.code/state.pc
function skip_instruction_operands(state, op)
    state.pc = skip_operands_at(state.code, state.pc, op)
end

-- Helper: branch to depth N
local function do_branch(state, depth)
    -- Target block is at block_sp - depth
    local target_idx = state.block_sp - depth
    local target_block = state.block_stack[target_idx]
    local arity = target_block.arity
    local sp = state.sp
    local base = target_block.stack_height

    if target_block.opcode == 0x03 then
        -- Loop: branch to start, pass arity values (loop params)
        if arity > 0 then
            for i = arity - 1, 0, -1 do
                state.stack[base + 1 + i] = state.stack[sp - (arity - 1 - i)]
            end
            state.sp = base + arity
        else
            state.sp = base
        end
        state.block_sp = target_idx -- keep the loop block on the stack
        state.pc = target_block.continuation_pc
    else
        -- Block/if/try_table: branch to end, pass arity values (block results)
        if arity > 0 then
            for i = arity - 1, 0, -1 do
                state.stack[base + 1 + i] = state.stack[sp - (arity - 1 - i)]
            end
            state.sp = base + arity
        else
            state.sp = base
        end
        state.block_sp = target_idx - 1 -- pop the target block too
        if state.block_sp <= 0 then
            state.running = false
        else
            state.pc = state.block_map[target_block.block_pc].end_pc
        end
    end
end

-- 0x0C: br
dispatch[0x0C] = function(state)
    local depth = read_leb128_u(state)
    do_branch(state, depth)
end

-- 0x0D: br_if
dispatch[0x0D] = function(state)
    local depth = read_leb128_u(state)
    local cond = pop(state)
    if cond ~= 0 then
        do_branch(state, depth)
    end
end

-- 0x0E: br_table
dispatch[0x0E] = function(state)
    local count = read_leb128_u(state)
    local targets = {}
    for i = 0, count - 1 do
        targets[i] = read_leb128_u(state)
    end
    local default = read_leb128_u(state)
    local idx = pop(state)
    local depth
    if idx >= 0 and idx < count then
        depth = targets[idx]
    else
        depth = default
    end
    do_branch(state, depth)
end

-- 0x0F: return
dispatch[0x0F] = function(state)
    state.do_return = true
    state.running = false
end

-- 0x10: call
dispatch[0x10] = function(state)
    local func_idx = read_leb128_u(state)
    state.call_func = func_idx
end

-- 0x11: call_indirect
dispatch[0x11] = function(state)
    local type_idx = read_leb128_u(state)
    local table_idx = read_leb128_u(state)
    local elem_idx = pop(state)
    local tbl = state.instance.tables[table_idx]
    if elem_idx < 0 or elem_idx >= (state.instance.table_sizes[table_idx] or 0) then
        fail("undefined element")
    end
    if not tbl[elem_idx] then
        fail("uninitialized element")
    end
    local func_idx = tbl[elem_idx]
    -- Type check: must match param and result types exactly
    local expected_type = state.instance.module.types[type_idx + 1]
    local actual_type = state.instance.module.types[state.instance.module.funcs[func_idx].type_idx + 1]
    if expected_type and actual_type then
        if #expected_type.params ~= #actual_type.params or #expected_type.results ~= #actual_type.results then
            fail("indirect call type mismatch")
        end
        for i = 1, #expected_type.params do
            if expected_type.params[i] ~= actual_type.params[i] then
                fail("indirect call type mismatch")
            end
        end
        for i = 1, #expected_type.results do
            if expected_type.results[i] ~= actual_type.results[i] then
                fail("indirect call type mismatch")
            end
        end
    end
    state.call_func = func_idx
end

-- 0x1A: drop
dispatch[0x1A] = function(state)
    state.sp = state.sp - 1
end

-- 0x1B: select
dispatch[0x1B] = function(state)
    local cond = pop(state)
    local val2 = pop(state)
    local val1 = pop(state)
    if cond ~= 0 then
        push(state, val1)
    else
        push(state, val2)
    end
end

-- 0x20: local.get
dispatch[0x20] = function(state)
    local idx = read_leb128_u(state)
    push(state, state.locals[idx])
end

-- 0x21: local.set
dispatch[0x21] = function(state)
    local idx = read_leb128_u(state)
    state.locals[idx] = pop(state)
end

-- 0x22: local.tee
dispatch[0x22] = function(state)
    local idx = read_leb128_u(state)
    state.locals[idx] = state.stack[state.sp]
end

-- 0x23: global.get
dispatch[0x23] = function(state)
    local idx = read_leb128_u(state)
    push(state, state.instance.globals[idx])
end

-- 0x24: global.set
dispatch[0x24] = function(state)
    local idx = read_leb128_u(state)
    state.instance.globals[idx] = pop(state)
end

-- Memory load ops
-- 0x28: i32.load
dispatch[0x28] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i32(base + offset))
end

-- 0x29: i64.load
dispatch[0x29] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i64(base + offset))
end

-- 0x2A: f32.load
dispatch[0x2A] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_f32(base + offset))
end

-- 0x2B: f64.load
dispatch[0x2B] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_f64(base + offset))
end

-- 0x2C: i32.load8_s
dispatch[0x2C] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    local val = state.memory:load_i8_s(base + offset)
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0x2D: i32.load8_u
dispatch[0x2D] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i8_u(base + offset))
end

-- 0x2E: i32.load16_s
dispatch[0x2E] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    local val = state.memory:load_i16_s(base + offset)
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0x2F: i32.load16_u
dispatch[0x2F] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i16_u(base + offset))
end

-- 0x30: i64.load8_s
dispatch[0x30] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    local val = state.memory:load_i8_s(base + offset)
    if val < 0 then
        push(state, {bit32.band(val + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF})
    else
        push(state, {val, 0})
    end
end

-- 0x31: i64.load8_u
dispatch[0x31] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, {state.memory:load_i8_u(base + offset), 0})
end

-- 0x32: i64.load16_s
dispatch[0x32] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    local val = state.memory:load_i16_s(base + offset)
    if val < 0 then
        push(state, {bit32.band(val + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF})
    else
        push(state, {val, 0})
    end
end

-- 0x33: i64.load16_u
dispatch[0x33] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, {state.memory:load_i16_u(base + offset), 0})
end

-- 0x34: i64.load32_s
dispatch[0x34] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    local val = state.memory:load_i32(base + offset)
    local hi = bit32.btest(val, 0x80000000) and 0xFFFFFFFF or 0
    push(state, {val, hi})
end

-- 0x35: i64.load32_u
dispatch[0x35] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, {state.memory:load_i32(base + offset), 0})
end

-- Memory store ops
-- 0x36: i32.store
dispatch[0x36] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i32(base + offset, val)
end

-- 0x37: i64.store
dispatch[0x37] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i64(base + offset, val)
end

-- 0x38: f32.store
dispatch[0x38] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_f32(base + offset, val)
end

-- 0x39: f64.store
dispatch[0x39] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_f64(base + offset, val)
end

-- 0x3A: i32.store8
dispatch[0x3A] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i8(base + offset, val)
end

-- 0x3B: i32.store16
dispatch[0x3B] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i16(base + offset, val)
end

-- 0x3C: i64.store8
dispatch[0x3C] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    local byte_val = type(val) == "table" and val[1] or val
    state.memory:store_i8(base + offset, byte_val)
end

-- 0x3D: i64.store16
dispatch[0x3D] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    local short_val = type(val) == "table" and bit32.band(val[1], 0xFFFF) or bit32.band(val, 0xFFFF)
    state.memory:store_i16(base + offset, short_val)
end

-- 0x3E: i64.store32
dispatch[0x3E] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    local word_val = type(val) == "table" and val[1] or bit32.band(val, 0xFFFFFFFF)
    state.memory:store_i32(base + offset, word_val)
end

-- 0x3F: memory.size
dispatch[0x3F] = function(state)
    read_leb128_u(state) -- reserved
    push(state, state.memory:size())
end

-- 0x40: memory.grow
dispatch[0x40] = function(state)
    read_leb128_u(state) -- reserved
    local pages = pop(state)
    push(state, state.memory:grow(pages))
end

-- Constants
-- 0x41: i32.const
dispatch[0x41] = function(state)
    local val = read_leb128_s(state)
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0x42: i64.const
dispatch[0x42] = function(state)
    push(state, read_leb128_s64(state))
end

-- 0x43: f32.const
dispatch[0x43] = function(state)
    local pc = state.pc
    local code = state.code
    local b0 = code[pc]
    local b1 = code[pc + 1]
    local b2 = code[pc + 2]
    local b3 = code[pc + 3]
    state.pc = pc + 4
    local bits = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
    push(state, f32_reinterpret_i32(bits))
end

-- 0x44: f64.const
dispatch[0x44] = function(state)
    local pc = state.pc
    local code = state.code
    local b0 = code[pc]
    local b1 = code[pc + 1]
    local b2 = code[pc + 2]
    local b3 = code[pc + 3]
    local b4 = code[pc + 4]
    local b5 = code[pc + 5]
    local b6 = code[pc + 6]
    local b7 = code[pc + 7]
    state.pc = pc + 8
    local lo = bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
    local hi = bit32.bor(b4, bit32.lshift(b5, 8), bit32.lshift(b6, 16), bit32.lshift(b7, 24))
    push(state, f64_reinterpret_i64({lo, hi}))
end

-- i32 comparison ops
-- 0x45: i32.eqz
dispatch[0x45] = function(state)
    local val = pop(state)
    push(state, val == 0 and 1 or 0)
end

-- 0x46: i32.eq
dispatch[0x46] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a == b and 1 or 0)
end

-- 0x47: i32.ne
dispatch[0x47] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a ~= b and 1 or 0)
end

-- 0x48: i32.lt_s
dispatch[0x48] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    push(state, a < b and 1 or 0)
end

-- 0x49: i32.lt_u
dispatch[0x49] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a < b and 1 or 0)
end

-- 0x4A: i32.gt_s
dispatch[0x4A] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    push(state, a > b and 1 or 0)
end

-- 0x4B: i32.gt_u
dispatch[0x4B] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a > b and 1 or 0)
end

-- 0x4C: i32.le_s
dispatch[0x4C] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    push(state, a <= b and 1 or 0)
end

-- 0x4D: i32.le_u
dispatch[0x4D] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a <= b and 1 or 0)
end

-- 0x4E: i32.ge_s
dispatch[0x4E] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    push(state, a >= b and 1 or 0)
end

-- 0x4F: i32.ge_u
dispatch[0x4F] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a >= b and 1 or 0)
end

-- i64 comparison ops
-- 0x50: i64.eqz
dispatch[0x50] = function(state)
    local val = pop(state)
    push(state, i64_eqz(val) and 1 or 0)
end

-- 0x51: i64.eq
dispatch[0x51] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_eq(a, b) and 1 or 0)
end

-- 0x52: i64.ne
dispatch[0x52] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_ne(a, b) and 1 or 0)
end

-- 0x53: i64.lt_s
dispatch[0x53] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_lt_s(a, b) and 1 or 0)
end

-- 0x54: i64.lt_u
dispatch[0x54] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_lt_u(a, b) and 1 or 0)
end

-- 0x55: i64.gt_s
dispatch[0x55] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_gt_s(a, b) and 1 or 0)
end

-- 0x56: i64.gt_u
dispatch[0x56] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_gt_u(a, b) and 1 or 0)
end

-- 0x57: i64.le_s
dispatch[0x57] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_le_s(a, b) and 1 or 0)
end

-- 0x58: i64.le_u
dispatch[0x58] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_le_u(a, b) and 1 or 0)
end

-- 0x59: i64.ge_s
dispatch[0x59] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_ge_s(a, b) and 1 or 0)
end

-- 0x5A: i64.ge_u
dispatch[0x5A] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_ge_u(a, b) and 1 or 0)
end

-- f32 comparison ops
-- 0x5B: f32.eq
dispatch[0x5B] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a == b and 1 or 0)
end

-- 0x5C: f32.ne
dispatch[0x5C] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 1); return end
    push(state, a ~= b and 1 or 0)
end

-- 0x5D: f32.lt
dispatch[0x5D] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a < b and 1 or 0)
end

-- 0x5E: f32.gt
dispatch[0x5E] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a > b and 1 or 0)
end

-- 0x5F: f32.le
dispatch[0x5F] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a <= b and 1 or 0)
end

-- 0x60: f32.ge
dispatch[0x60] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a >= b and 1 or 0)
end

-- f64 comparison ops
-- 0x61: f64.eq
dispatch[0x61] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a == b and 1 or 0)
end

-- 0x62: f64.ne
dispatch[0x62] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 1); return end
    push(state, a ~= b and 1 or 0)
end

-- 0x63: f64.lt
dispatch[0x63] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a < b and 1 or 0)
end

-- 0x64: f64.gt
dispatch[0x64] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a > b and 1 or 0)
end

-- 0x65: f64.le
dispatch[0x65] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a <= b and 1 or 0)
end

-- 0x66: f64.ge
dispatch[0x66] = function(state)
    local b = pop(state); local a = pop(state)
    if isnan(a) or isnan(b) then push(state, 0); return end
    push(state, a >= b and 1 or 0)
end

-- i32 numeric ops
-- 0x67: i32.clz
dispatch[0x67] = function(state)
    push(state, i32_clz(pop(state)))
end

-- 0x68: i32.ctz
dispatch[0x68] = function(state)
    push(state, i32_ctz(pop(state)))
end

-- 0x69: i32.popcnt
dispatch[0x69] = function(state)
    push(state, i32_popcnt(pop(state)))
end

-- 0x6A: i32.add
dispatch[0x6A] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.band(a + b, 0xFFFFFFFF))
end

-- 0x6B: i32.sub
dispatch[0x6B] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.band(a - b + 0x100000000, 0xFFFFFFFF))
end

-- 0x6C: i32.mul
dispatch[0x6C] = function(state)
    local b = pop(state); local a = pop(state)
    -- Split both operands into 16-bit halves to stay within double precision (2^53).
    -- a*b mod 2^32 = (a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo)*65536) mod 2^32
    -- Max intermediate: ~5.6e14 < 2^53, so all values are exact.
    local a_lo = bit32.band(a, 0xFFFF)
    local a_hi = bit32.rshift(a, 16)
    local b_lo = bit32.band(b, 0xFFFF)
    local b_hi = bit32.rshift(b, 16)
    local result = a_lo * b_lo + (a_lo * b_hi + a_hi * b_lo) * 65536
    push(state, bit32.band(result, 0xFFFFFFFF))
end

-- 0x6D: i32.div_s
dispatch[0x6D] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    if b == 0 then fail("integer divide by zero") end
    if a == -2147483648 and b == -1 then fail("integer overflow") end
    local result = a / b
    if result >= 0 then result = math_floor(result) else result = math_ceil(result) end
    if result < 0 then result = result + 0x100000000 end
    push(state, result)
end

-- 0x6E: i32.div_u
dispatch[0x6E] = function(state)
    local b = pop(state); local a = pop(state)
    if b == 0 then fail("integer divide by zero") end
    push(state, math_floor(a / b))
end

-- 0x6F: i32.rem_s
dispatch[0x6F] = function(state)
    local b = to_signed32(pop(state)); local a = to_signed32(pop(state))
    if b == 0 then fail("integer divide by zero") end
    local result
    if b == -1 then
        result = 0
    else
        result = a - math_floor(a / b) * b
        -- WASM rem_s: result has same sign as dividend
        -- Lua's % might differ, so compute manually
        if a / b >= 0 then
            result = a - math_floor(a / b) * b
        else
            result = a - math_ceil(a / b) * b
        end
    end
    if result < 0 then result = result + 0x100000000 end
    push(state, result)
end

-- 0x70: i32.rem_u
dispatch[0x70] = function(state)
    local b = pop(state); local a = pop(state)
    if b == 0 then fail("integer divide by zero") end
    push(state, a % b)
end

-- 0x71: i32.and
dispatch[0x71] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.band(a, b))
end

-- 0x72: i32.or
dispatch[0x72] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.bor(a, b))
end

-- 0x73: i32.xor
dispatch[0x73] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.bxor(a, b))
end

-- 0x74: i32.shl
dispatch[0x74] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.lshift(a, bit32.band(b, 31)))
end

-- 0x75: i32.shr_s
dispatch[0x75] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.arshift(a, bit32.band(b, 31)))
end

-- 0x76: i32.shr_u
dispatch[0x76] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.rshift(a, bit32.band(b, 31)))
end

-- 0x77: i32.rotl
dispatch[0x77] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.lrotate(a, bit32.band(b, 31)))
end

-- 0x78: i32.rotr
dispatch[0x78] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.rrotate(a, bit32.band(b, 31)))
end

-- i64 numeric ops
-- 0x79: i64.clz
dispatch[0x79] = function(state)
    push(state, i64_clz(pop(state)))
end

-- 0x7A: i64.ctz
dispatch[0x7A] = function(state)
    push(state, i64_ctz(pop(state)))
end

-- 0x7B: i64.popcnt
dispatch[0x7B] = function(state)
    push(state, i64_popcnt(pop(state)))
end

-- 0x7C: i64.add
dispatch[0x7C] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_add(a, b))
end

-- 0x7D: i64.sub
dispatch[0x7D] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_sub(a, b))
end

-- 0x7E: i64.mul
dispatch[0x7E] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_mul(a, b))
end

-- 0x7F: i64.div_s
dispatch[0x7F] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_div_s(a, b))
end

-- 0x80: i64.div_u
dispatch[0x80] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_div_u(a, b))
end

-- 0x81: i64.rem_s
dispatch[0x81] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_rem_s(a, b))
end

-- 0x82: i64.rem_u
dispatch[0x82] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_rem_u(a, b))
end

-- 0x83: i64.and
dispatch[0x83] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_and(a, b))
end

-- 0x84: i64.or
dispatch[0x84] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_or(a, b))
end

-- 0x85: i64.xor
dispatch[0x85] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, i64_xor(a, b))
end

-- 0x86: i64.shl
dispatch[0x86] = function(state)
    local b = pop(state); local a = pop(state)
    local shift = type(b) == "table" and b[1] or b
    push(state, i64_shl(a, shift))
end

-- 0x87: i64.shr_s
dispatch[0x87] = function(state)
    local b = pop(state); local a = pop(state)
    local shift = type(b) == "table" and b[1] or b
    push(state, i64_shr_s(a, shift))
end

-- 0x88: i64.shr_u
dispatch[0x88] = function(state)
    local b = pop(state); local a = pop(state)
    local shift = type(b) == "table" and b[1] or b
    push(state, i64_shr_u(a, shift))
end

-- 0x89: i64.rotl
dispatch[0x89] = function(state)
    local b = pop(state); local a = pop(state)
    local shift = type(b) == "table" and b[1] or b
    push(state, i64_rotl(a, shift))
end

-- 0x8A: i64.rotr
dispatch[0x8A] = function(state)
    local b = pop(state); local a = pop(state)
    local shift = type(b) == "table" and b[1] or b
    push(state, i64_rotr(a, shift))
end

-- f32 numeric ops
-- 0x8B: f32.abs
dispatch[0x8B] = function(state) push(state, f32_abs(pop(state))) end
-- 0x8C: f32.neg
dispatch[0x8C] = function(state) push(state, f32_neg(pop(state))) end
-- 0x8D: f32.ceil
dispatch[0x8D] = function(state) push(state, f32_ceil(pop(state))) end
-- 0x8E: f32.floor
dispatch[0x8E] = function(state) push(state, f32_floor(pop(state))) end
-- 0x8F: f32.trunc
dispatch[0x8F] = function(state) push(state, f32_trunc_op(pop(state))) end
-- 0x90: f32.nearest
dispatch[0x90] = function(state) push(state, f32_nearest(pop(state))) end
-- 0x91: f32.sqrt
dispatch[0x91] = function(state) push(state, f32_sqrt(pop(state))) end

-- 0x92: f32.add
dispatch[0x92] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_trunc(a + b))
end
-- 0x93: f32.sub
dispatch[0x93] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_trunc(a - b))
end
-- 0x94: f32.mul
dispatch[0x94] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_trunc(a * b))
end
-- 0x95: f32.div
dispatch[0x95] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_trunc(a / b))
end
-- 0x96: f32.min
dispatch[0x96] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_min(a, b))
end
-- 0x97: f32.max
dispatch[0x97] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_max(a, b))
end
-- 0x98: f32.copysign
dispatch[0x98] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f32_copysign(a, b))
end

-- f64 numeric ops
-- 0x99: f64.abs
dispatch[0x99] = function(state) push(state, f64_abs(pop(state))) end
-- 0x9A: f64.neg
dispatch[0x9A] = function(state) push(state, f64_neg(pop(state))) end
-- 0x9B: f64.ceil
dispatch[0x9B] = function(state) push(state, f64_ceil(pop(state))) end
-- 0x9C: f64.floor
dispatch[0x9C] = function(state) push(state, f64_floor(pop(state))) end
-- 0x9D: f64.trunc
dispatch[0x9D] = function(state) push(state, f64_trunc_op(pop(state))) end
-- 0x9E: f64.nearest
dispatch[0x9E] = function(state) push(state, f64_nearest(pop(state))) end
-- 0x9F: f64.sqrt
dispatch[0x9F] = function(state) push(state, f64_sqrt(pop(state))) end

-- 0xA0: f64.add
dispatch[0xA0] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a + b)
end
-- 0xA1: f64.sub
dispatch[0xA1] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a - b)
end
-- 0xA2: f64.mul
dispatch[0xA2] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a * b)
end
-- 0xA3: f64.div
dispatch[0xA3] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, a / b)
end
-- 0xA4: f64.min
dispatch[0xA4] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f64_min(a, b))
end
-- 0xA5: f64.max
dispatch[0xA5] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f64_max(a, b))
end
-- 0xA6: f64.copysign
dispatch[0xA6] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, f64_copysign(a, b))
end

-- Conversion ops
-- 0xA7: i32.wrap_i64
dispatch[0xA7] = function(state)
    local val = pop(state)
    push(state, type(val) == "table" and val[1] or bit32.band(val, 0xFFFFFFFF))
end

-- 0xA8: i32.trunc_f32_s
dispatch[0xA8] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    -- Truncate toward zero, then check range [-2^31, 2^31-1]
    val = val >= 0 and math_floor(val) or -math_floor(-val)
    if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0xA9: i32.trunc_f32_u
dispatch[0xA9] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    -- Truncate toward zero, then check range [0, 2^32-1]
    val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0 -- +0 converts -0 to +0
    if val >= 4294967296 or val < 0 then fail("integer overflow") end
    push(state, val)
end

-- 0xAA: i32.trunc_f64_s
dispatch[0xAA] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    val = val >= 0 and math_floor(val) or -math_floor(-val)
    if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0xAB: i32.trunc_f64_u
dispatch[0xAB] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0 -- +0 converts -0 to +0
    if val >= 4294967296 or val < 0 then fail("integer overflow") end
    push(state, val)
end

-- 0xAC: i64.extend_i32_s
dispatch[0xAC] = function(state)
    local val = pop(state)
    val = type(val) == "table" and val[1] or val
    local hi = bit32.btest(val, 0x80000000) and 0xFFFFFFFF or 0
    push(state, {val, hi})
end

-- 0xAD: i64.extend_i32_u
dispatch[0xAD] = function(state)
    local val = pop(state)
    val = type(val) == "table" and val[1] or val
    push(state, {val, 0})
end

-- 0xAE: i64.trunc_f32_s
dispatch[0xAE] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    -- Trap if trunc(val) not in [-2^63, 2^63-1]
    if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end
    push(state, f64_to_i64_s(val))
end

-- 0xAF: i64.trunc_f32_u
dispatch[0xAF] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    -- Truncate toward zero, then check range [0, 2^64-1]
    if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end
    push(state, f64_to_i64_u(val))
end

-- 0xB0: i64.trunc_f64_s
dispatch[0xB0] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end
    push(state, f64_to_i64_s(val))
end

-- 0xB1: i64.trunc_f64_u
dispatch[0xB1] = function(state)
    local val = pop(state)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end
    push(state, f64_to_i64_u(val))
end

-- 0xB2: f32.convert_i32_s
dispatch[0xB2] = function(state)
    local val = to_signed32(pop(state))
    push(state, f32_trunc(val))
end

-- 0xB3: f32.convert_i32_u
dispatch[0xB3] = function(state)
    push(state, f32_trunc(pop(state)))
end

-- 0xB4: f32.convert_i64_s
dispatch[0xB4] = function(state)
    push(state, i64_to_f32_s(pop(state)))
end

-- 0xB5: f32.convert_i64_u
dispatch[0xB5] = function(state)
    push(state, i64_to_f32_u(pop(state)))
end

-- 0xB6: f32.demote_f64
dispatch[0xB6] = function(state)
    push(state, f32_trunc(pop(state)))
end

-- 0xB7: f64.convert_i32_s
dispatch[0xB7] = function(state)
    push(state, to_signed32(pop(state)) + 0.0)
end

-- 0xB8: f64.convert_i32_u
dispatch[0xB8] = function(state)
    push(state, pop(state) + 0.0)
end

-- 0xB9: f64.convert_i64_s
dispatch[0xB9] = function(state)
    push(state, i64_to_f64_s(pop(state)))
end

-- 0xBA: f64.convert_i64_u
dispatch[0xBA] = function(state)
    push(state, i64_to_f64_u(pop(state)))
end

-- 0xBB: f64.promote_f32
dispatch[0xBB] = function(state)
    -- f32 is already a Lua double, just pass through
    -- Unbox f32 NaN to canonical f64 NaN (promotion is arithmetic)
    local v = state.stack[state.sp]
    if isnan(v) then state.stack[state.sp] = NAN end
end

-- 0xBC: i32.reinterpret_f32
dispatch[0xBC] = function(state)
    push(state, i32_reinterpret_f32(pop(state)))
end

-- 0xBD: i64.reinterpret_f64
dispatch[0xBD] = function(state)
    push(state, i64_reinterpret_f64(pop(state)))
end

-- 0xBE: f32.reinterpret_i32
dispatch[0xBE] = function(state)
    push(state, f32_reinterpret_i32(pop(state)))
end

-- 0xBF: f64.reinterpret_i64
dispatch[0xBF] = function(state)
    push(state, f64_reinterpret_i64(pop(state)))
end

-- Sign extension ops (0xC0-0xC4)
-- 0xC0: i32.extend8_s
dispatch[0xC0] = function(state)
    local val = bit32.band(pop(state), 0xFF)
    if val >= 0x80 then val = val - 0x100 end
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0xC1: i32.extend16_s
dispatch[0xC1] = function(state)
    local val = bit32.band(pop(state), 0xFFFF)
    if val >= 0x8000 then val = val - 0x10000 end
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0xC2: i64.extend8_s
dispatch[0xC2] = function(state)
    local val = pop(state)
    local lo = type(val) == "table" and val[1] or val
    lo = bit32.band(lo, 0xFF)
    if lo >= 0x80 then
        push(state, {bit32.band(lo + 0xFFFFFF00, 0xFFFFFFFF), 0xFFFFFFFF})
    else
        push(state, {lo, 0})
    end
end

-- 0xC3: i64.extend16_s
dispatch[0xC3] = function(state)
    local val = pop(state)
    local lo = type(val) == "table" and val[1] or val
    lo = bit32.band(lo, 0xFFFF)
    if lo >= 0x8000 then
        push(state, {bit32.band(lo + 0xFFFF0000, 0xFFFFFFFF), 0xFFFFFFFF})
    else
        push(state, {lo, 0})
    end
end

-- 0xC4: i64.extend32_s
dispatch[0xC4] = function(state)
    local val = pop(state)
    local lo = type(val) == "table" and val[1] or val
    local hi = bit32.btest(lo, 0x80000000) and 0xFFFFFFFF or 0
    push(state, {lo, hi})
end

-- 0xFC: prefix for saturating truncation and other extended ops
dispatch[0xFC] = function(state)
    local sub_op = read_leb128_u(state)
    if sub_op == 0 then -- i32.trunc_sat_f32_s
        local val = pop(state)
        if isnan(val) then push(state, 0); return end
        if val >= 2147483647 then push(state, 0x7FFFFFFF); return end
        if val <= -2147483648 then push(state, 0x80000000); return end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end
        push(state, val)
    elseif sub_op == 1 then -- i32.trunc_sat_f32_u
        local val = pop(state)
        if isnan(val) or val < 0 then push(state, 0); return end
        if val >= 4294967296 then push(state, 0xFFFFFFFF); return end
        push(state, math_floor(val))
    elseif sub_op == 2 then -- i32.trunc_sat_f64_s
        local val = pop(state)
        if isnan(val) then push(state, 0); return end
        if val >= 2147483647 then push(state, 0x7FFFFFFF); return end
        if val <= -2147483648 then push(state, 0x80000000); return end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end
        push(state, val)
    elseif sub_op == 3 then -- i32.trunc_sat_f64_u
        local val = pop(state)
        if isnan(val) or val < 0 then push(state, 0); return end
        if val >= 4294967296 then push(state, 0xFFFFFFFF); return end
        push(state, math_floor(val))
    elseif sub_op == 4 then -- i64.trunc_sat_f32_s
        local val = pop(state)
        if isnan(val) then push(state, {0, 0}); return end
        if val >= 9223372036854775808 then push(state, {0xFFFFFFFF, 0x7FFFFFFF}); return end
        if val < -9223372036854775808 then push(state, {0, 0x80000000}); return end
        push(state, f64_to_i64_s(val))
    elseif sub_op == 5 then -- i64.trunc_sat_f32_u
        local val = pop(state)
        if isnan(val) or val <= -1.0 then push(state, {0, 0}); return end
        if val >= 18446744073709551616 then push(state, {0xFFFFFFFF, 0xFFFFFFFF}); return end
        push(state, f64_to_i64_u(val))
    elseif sub_op == 6 then -- i64.trunc_sat_f64_s
        local val = pop(state)
        if isnan(val) then push(state, {0, 0}); return end
        if val >= 9223372036854775808 then push(state, {0xFFFFFFFF, 0x7FFFFFFF}); return end
        if val < -9223372036854775808 then push(state, {0, 0x80000000}); return end
        push(state, f64_to_i64_s(val))
    elseif sub_op == 7 then -- i64.trunc_sat_f64_u
        local val = pop(state)
        if isnan(val) or val <= -1.0 then push(state, {0, 0}); return end
        if val >= 18446744073709551616 then push(state, {0xFFFFFFFF, 0xFFFFFFFF}); return end
        push(state, f64_to_i64_u(val))
    elseif sub_op == 8 then -- memory.init
        local seg_idx = read_leb128_u(state)
        read_leb128_u(state) -- reserved 0
        local n = pop(state)
        local s = pop(state)
        local d = pop(state)
        local seg_data = state.instance.data_segments_raw[seg_idx + 1]
        if seg_data then
            for i = 0, n - 1 do
                state.memory:store_byte(d + i, string.byte(seg_data, s + i + 1))
            end
        end
    elseif sub_op == 9 then -- data.drop
        local seg_idx = read_leb128_u(state)
        if state.instance.data_segments_raw then
            state.instance.data_segments_raw[seg_idx + 1] = nil
        end
    elseif sub_op == 10 then -- memory.copy
        read_leb128_u(state) -- dest mem
        read_leb128_u(state) -- src mem
        local n = pop(state)
        local s = pop(state)
        local d = pop(state)
        if d <= s then
            for i = 0, n - 1 do
                state.memory:store_byte(d + i, state.memory:load_byte(s + i))
            end
        else
            for i = n - 1, 0, -1 do
                state.memory:store_byte(d + i, state.memory:load_byte(s + i))
            end
        end
    elseif sub_op == 11 then -- memory.fill
        read_leb128_u(state) -- reserved 0
        local n = pop(state)
        local val = pop(state)
        local d = pop(state)
        val = bit32.band(val, 0xFF)
        for i = 0, n - 1 do
            state.memory:store_byte(d + i, val)
        end
    elseif sub_op == 12 then -- table.init
        local seg_idx = read_leb128_u(state)
        local tbl_idx = read_leb128_u(state)
        local n = pop(state)
        local s = pop(state)
        local d = pop(state)
        local seg = state.instance.element_segments_raw and state.instance.element_segments_raw[seg_idx + 1]
        local tbl = state.instance.tables[tbl_idx]
        if seg and tbl then
            for i = 0, n - 1 do
                tbl[d + i] = seg[s + i + 1]
            end
        end
    elseif sub_op == 13 then -- elem.drop
        local seg_idx = read_leb128_u(state)
        if state.instance.element_segments_raw then
            state.instance.element_segments_raw[seg_idx + 1] = nil
        end
    elseif sub_op == 14 then -- table.copy
        local dst_idx = read_leb128_u(state)
        local src_idx = read_leb128_u(state)
        local n = pop(state)
        local s = pop(state)
        local d = pop(state)
        local dst_tbl = state.instance.tables[dst_idx]
        local src_tbl = state.instance.tables[src_idx]
        if dst_tbl and src_tbl then
            if d <= s then
                for i = 0, n - 1 do
                    dst_tbl[d + i] = src_tbl[s + i]
                end
            else
                for i = n - 1, 0, -1 do
                    dst_tbl[d + i] = src_tbl[s + i]
                end
            end
        end
    elseif sub_op == 15 then -- table.grow
        read_leb128_u(state) -- table idx
        local n = pop(state)
        local _init = pop(state)
        -- Simplified: just return -1 (failure) for now
        push(state, 0xFFFFFFFF)
    elseif sub_op == 16 then -- table.size
        local tbl_idx = read_leb128_u(state)
        push(state, state.instance.table_sizes[tbl_idx] or 0)
    elseif sub_op == 17 then -- table.fill
        local tbl_idx = read_leb128_u(state)
        local n = pop(state)
        local val = pop(state)
        local d = pop(state)
        local tbl = state.instance.tables[tbl_idx]
        if tbl then
            for i = 0, n - 1 do
                tbl[d + i] = val
            end
        end
    else
        fail(string.format("unknown opcode 0xFC %d", sub_op))
    end
end

Opcodes.handle_exception = handle_exception
Opcodes.nan_mt = nan_mt
Opcodes.dispatch = dispatch
Opcodes.do_branch = do_branch
Opcodes.read_byte = read_byte
Opcodes.read_leb128_u = read_leb128_u
Opcodes.read_leb128_s = read_leb128_s
Opcodes.read_leb128_s64 = read_leb128_s64
Opcodes.read_memarg = read_memarg
Opcodes.read_blocktype = read_blocktype
Opcodes.skip_instruction_operands = skip_instruction_operands
Opcodes.push = push
Opcodes.pop = pop
Opcodes.to_signed32 = to_signed32
Opcodes.to_u32 = to_u32

return Opcodes
