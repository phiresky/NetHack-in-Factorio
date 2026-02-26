-- WASM Interpreter Core (Resumable State Machine)
-- No coroutines - designed for Factorio's Lua sandbox.
-- Execution can pause at blocking imports or instruction budget limits,
-- and resume later via run().

local Memory = require("scripts.wasm.memory")
local WasmParser = require("scripts.wasm.init")
local Compiler = require("scripts.wasm.compiler")
local Decode = require("scripts.wasm.decode")

local bit32 = bit32
local math_floor = math.floor
local math_abs = math.abs
local math_ceil = math.ceil
local math_sqrt = math.sqrt
local math_huge = math.huge
local unpack = table.unpack or unpack

local function fail(msg) error({msg = msg}) end

-- Cached bit32 functions for the hot loop
local bit32_band = bit32.band
local bit32_bor = bit32.bor
local bit32_bxor = bit32.bxor
local bit32_lshift = bit32.lshift
local bit32_rshift = bit32.rshift
local bit32_arshift = bit32.arshift
local bit32_btest = bit32.btest

local Interp = {}

-- Set to true to use compiled functions instead of interpreting bytecode.
Interp.use_compiler = true


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
-- Compiled function context (ctx object)
-- Provides all helper functions that compiled Lua code calls into.
---------------------------------------------------------------------------

local NAN = 0/0
local function isnan(v) return v ~= v or type(v) == "table" end

-- f32 truncation helper (imported from opcodes concept, reimplemented here)
local function f32_trunc_val(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    local sign = 1
    if v < 0 then sign = -1; v = -v end
    local m, e = math.frexp(v)
    local prec
    if e >= -125 then prec = 24
    elseif e >= -149 then prec = e + 149
    else return sign == -1 and -0.0 or 0.0 end
    local scaled = math.ldexp(m, prec)
    local rounded = math_floor(scaled)
    local frac = scaled - rounded
    if frac > 0.5 or (frac == 0.5 and rounded % 2 == 1) then
        rounded = rounded + 1
    end
    local result = sign * math.ldexp(rounded, e - prec)
    if math_abs(result) > 3.4028234663852886e+38 then return sign * math_huge end
    return result
end

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

local function f32_reinterpret_i32(bits)
    local sign = bit32_btest(bits, 0x80000000) and -1 or 1
    local exp = bit32_band(bit32_rshift(bits, 23), 0xFF)
    local mant = bit32_band(bits, 0x7FFFFF)
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
        return 0x7FC00000
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
    if e <= 0 then m = m * math.ldexp(1, e + 23); e = 0
    else m = (m * 2 - 1) * math.ldexp(1, 23) end
    return bit32_bor(sign, bit32_lshift(bit32_band(e, 0xFF), 23), bit32_band(math_floor(m), 0x7FFFFF))
end

local function f64_reinterpret_i64(v)
    local lo, hi = v[1], v[2]
    local sign = bit32_btest(hi, 0x80000000) and -1 or 1
    local exp = bit32_band(bit32_rshift(hi, 20), 0x7FF)
    local mant_hi = bit32_band(hi, 0xFFFFF)
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
        return {0, 0x7FF80000}
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
    if e <= 0 then m = m * math.ldexp(1, e + 52); e = 0
    else m = (m * 2 - 1) * math.ldexp(1, 52) end
    local mant_hi = math_floor(m / 4294967296)
    local lo = m - mant_hi * 4294967296
    local hi = bit32_bor(sign, bit32_lshift(bit32_band(e, 0x7FF), 20), bit32_band(mant_hi, 0xFFFFF))
    return {lo, hi}
end

-- Convert unsigned i32 to signed i32
local function to_signed32(v) if v >= 0x80000000 then return v - 0x100000000 end; return v end

-- Ensure value is in u32 range
local function to_u32(v) return bit32_band(v, 0xFFFFFFFF) end

-- i64 helpers
local function i64_is_zero(v) return v[1] == 0 and v[2] == 0 end
local function i64_eq(a, b) return a[1] == b[1] and a[2] == b[2] end
local function i64_ne(a, b) return a[1] ~= b[1] or a[2] ~= b[2] end
local function i64_eqz(a) return a[1] == 0 and a[2] == 0 end
local function i64_is_neg(v) return bit32_btest(v[2], 0x80000000) end

local function i64_neg(v)
    local lo = bit32.bnot(v[1])
    local hi = bit32.bnot(v[2])
    local new_lo = lo + 1
    local carry = 0
    if new_lo > 0xFFFFFFFF then new_lo = bit32_band(new_lo, 0xFFFFFFFF); carry = 1 end
    return {new_lo, bit32_band(hi + carry, 0xFFFFFFFF)}
end

local function i64_add(a, b)
    local lo = a[1] + b[1]
    local carry = 0
    if lo > 0xFFFFFFFF then carry = 1; lo = bit32_band(lo, 0xFFFFFFFF) end
    return {lo, bit32_band(a[2] + b[2] + carry, 0xFFFFFFFF)}
end
local function i64_sub(a, b) return i64_add(a, i64_neg(b)) end
local function i64_and(a, b) return {bit32_band(a[1], b[1]), bit32_band(a[2], b[2])} end
local function i64_or(a, b) return {bit32_bor(a[1], b[1]), bit32_bor(a[2], b[2])} end
local function i64_xor(a, b) return {bit32_bxor(a[1], b[1]), bit32_bxor(a[2], b[2])} end

local function i64_shl(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then return {0, bit32_lshift(v[1], shift - 32)} end
    return {bit32_lshift(v[1], shift), bit32_bor(bit32_lshift(v[2], shift), bit32_rshift(v[1], 32 - shift))}
end
local function i64_shr_u(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then return {bit32_rshift(v[2], shift - 32), 0} end
    return {bit32_bor(bit32_rshift(v[1], shift), bit32_lshift(v[2], 32 - shift)), bit32_rshift(v[2], shift)}
end
local function i64_shr_s(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    if shift >= 32 then
        local hi_signed = to_signed32(v[2])
        if shift >= 64 then
            if hi_signed < 0 then return {0xFFFFFFFF, 0xFFFFFFFF} else return {0, 0} end
        end
        return {bit32_arshift(v[2], shift - 32), hi_signed < 0 and 0xFFFFFFFF or 0}
    end
    return {bit32_bor(bit32_rshift(v[1], shift), bit32_lshift(v[2], 32 - shift)), bit32_arshift(v[2], shift)}
end

local function i64_lt_u(a, b) if a[2] ~= b[2] then return a[2] < b[2] end; return a[1] < b[1] end
local function i64_lt_s(a, b)
    local a_neg = bit32_btest(a[2], 0x80000000)
    local b_neg = bit32_btest(b[2], 0x80000000)
    if a_neg ~= b_neg then return a_neg end
    return i64_lt_u(a, b)
end
local function i64_le_u(a, b) return not i64_lt_u(b, a) end
local function i64_le_s(a, b) return not i64_lt_s(b, a) end
local function i64_gt_u(a, b) return i64_lt_u(b, a) end
local function i64_gt_s(a, b) return i64_lt_s(b, a) end
local function i64_ge_u(a, b) return not i64_lt_u(a, b) end
local function i64_ge_s(a, b) return not i64_lt_s(a, b) end

local function i64_mul(a, b)
    local a0 = bit32_band(a[1], 0xFFFF); local a1 = bit32_rshift(a[1], 16)
    local a2 = bit32_band(a[2], 0xFFFF); local a3 = bit32_rshift(a[2], 16)
    local b0 = bit32_band(b[1], 0xFFFF); local b1 = bit32_rshift(b[1], 16)
    local c0 = a0 * b0
    local c1 = a1 * b0 + a0 * b1
    local c2 = a2 * b0 + a1 * b1 + a0 * bit32_band(b[2], 0xFFFF)
    local c3 = a3 * b0 + a2 * b1 + a1 * bit32_band(b[2], 0xFFFF) + a0 * bit32_rshift(b[2], 16)
    local lo = bit32_band(c0, 0xFFFF)
    c1 = c1 + math_floor(c0 / 65536)
    lo = bit32_bor(lo, bit32_lshift(bit32_band(c1, 0xFFFF), 16))
    c2 = c2 + math_floor(c1 / 65536)
    local hi = bit32_band(c2, 0xFFFF)
    c3 = c3 + math_floor(c2 / 65536)
    hi = bit32_bor(hi, bit32_lshift(bit32_band(c3, 0xFFFF), 16))
    return {lo, hi}
end

local function i64_div_u(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    if a[2] == 0 and b[2] == 0 then return {math_floor(a[1] / b[1]), 0} end
    local quotient = {0, 0}; local remainder = {0, 0}
    for ii = 63, 0, -1 do
        remainder = i64_shl(remainder, 1)
        local word = ii >= 32 and a[2] or a[1]
        local bit_pos = ii >= 32 and (ii - 32) or ii
        if bit32_btest(word, bit32_lshift(1, bit_pos)) then
            remainder[1] = bit32_bor(remainder[1], 1)
        end
        if not i64_lt_u(remainder, b) then
            remainder = i64_sub(remainder, b)
            local q_word = ii >= 32 and 2 or 1
            local q_bit = ii >= 32 and (ii - 32) or ii
            quotient[q_word] = bit32_bor(quotient[q_word], bit32_lshift(1, q_bit))
        end
    end
    return quotient
end

local function i64_rem_u(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    if a[2] == 0 and b[2] == 0 then return {a[1] % b[1], 0} end
    local q = i64_div_u(a, b); return i64_sub(a, i64_mul(q, b))
end

local function i64_div_s(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    if a[1] == 0 and a[2] == 0x80000000 and b[1] == 0xFFFFFFFF and b[2] == 0xFFFFFFFF then fail("integer overflow") end
    local a_neg = i64_is_neg(a); local b_neg = i64_is_neg(b)
    local ua = a_neg and i64_neg(a) or a; local ub = b_neg and i64_neg(b) or b
    local result = i64_div_u(ua, ub)
    if a_neg ~= b_neg then return i64_neg(result) end
    return result
end

local function i64_rem_s(a, b)
    if i64_is_zero(b) then fail("integer divide by zero") end
    local a_neg = i64_is_neg(a)
    local ua = a_neg and i64_neg(a) or a; local ub = i64_is_neg(b) and i64_neg(b) or b
    local result = i64_rem_u(ua, ub)
    if a_neg then return i64_neg(result) end
    return result
end

local function i64_clz(v)
    if v[2] ~= 0 then
        local n = 0; local x = v[2]
        if bit32_band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32_lshift(x, 16) end
        if bit32_band(x, 0xFF000000) == 0 then n = n + 8; x = bit32_lshift(x, 8) end
        if bit32_band(x, 0xF0000000) == 0 then n = n + 4; x = bit32_lshift(x, 4) end
        if bit32_band(x, 0xC0000000) == 0 then n = n + 2; x = bit32_lshift(x, 2) end
        if bit32_band(x, 0x80000000) == 0 then n = n + 1 end
        return {n, 0}
    elseif v[1] ~= 0 then
        local n = 32; local x = v[1]
        if bit32_band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32_lshift(x, 16) end
        if bit32_band(x, 0xFF000000) == 0 then n = n + 8; x = bit32_lshift(x, 8) end
        if bit32_band(x, 0xF0000000) == 0 then n = n + 4; x = bit32_lshift(x, 4) end
        if bit32_band(x, 0xC0000000) == 0 then n = n + 2; x = bit32_lshift(x, 2) end
        if bit32_band(x, 0x80000000) == 0 then n = n + 1 end
        return {n, 0}
    else return {64, 0} end
end

local function i64_ctz(v)
    if v[1] ~= 0 then
        local n = 0; local x = v[1]
        if bit32_band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32_rshift(x, 16) end
        if bit32_band(x, 0x000000FF) == 0 then n = n + 8; x = bit32_rshift(x, 8) end
        if bit32_band(x, 0x0000000F) == 0 then n = n + 4; x = bit32_rshift(x, 4) end
        if bit32_band(x, 0x00000003) == 0 then n = n + 2; x = bit32_rshift(x, 2) end
        if bit32_band(x, 0x00000001) == 0 then n = n + 1 end
        return {n, 0}
    elseif v[2] ~= 0 then
        local n = 32; local x = v[2]
        if bit32_band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32_rshift(x, 16) end
        if bit32_band(x, 0x000000FF) == 0 then n = n + 8; x = bit32_rshift(x, 8) end
        if bit32_band(x, 0x0000000F) == 0 then n = n + 4; x = bit32_rshift(x, 4) end
        if bit32_band(x, 0x00000003) == 0 then n = n + 2; x = bit32_rshift(x, 2) end
        if bit32_band(x, 0x00000001) == 0 then n = n + 1 end
        return {n, 0}
    else return {64, 0} end
end

local function popcnt32(x)
    x = x - bit32_band(bit32_rshift(x, 1), 0x55555555)
    x = bit32_band(x, 0x33333333) + bit32_band(bit32_rshift(x, 2), 0x33333333)
    x = bit32_band(x + bit32_rshift(x, 4), 0x0F0F0F0F)
    x = x + bit32_rshift(x, 8); x = x + bit32_rshift(x, 16)
    return bit32_band(x, 0x3F)
end
local function i64_popcnt(v) return {popcnt32(v[1]) + popcnt32(v[2]), 0} end

local function i64_rotl(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    return i64_or(i64_shl(v, shift), i64_shr_u(v, 64 - shift))
end
local function i64_rotr(v, shift)
    shift = shift % 64
    if shift == 0 then return {v[1], v[2]} end
    return i64_or(i64_shr_u(v, shift), i64_shl(v, 64 - shift))
end

local function i64_to_f64_u(v) return v[2] * 4294967296 + v[1] end
local function i64_to_f64_s(v)
    if i64_is_neg(v) then local pos = i64_neg(v); return -(pos[2] * 4294967296 + pos[1]) end
    return v[2] * 4294967296 + v[1]
end

local function f64_to_i64_u(v)
    if v < 0 or v ~= v then return {0, 0} end
    if v >= 18446744073709551616 then return {0xFFFFFFFF, 0xFFFFFFFF} end
    v = math_floor(v)
    local hi = math_floor(v / 4294967296)
    local lo = v - hi * 4294967296
    return {lo, bit32_band(hi, 0xFFFFFFFF)}
end
local function f64_to_i64_s(v)
    if v ~= v then return {0, 0} end
    local neg = v < 0; v = math_floor(math_abs(v))
    local hi = math_floor(v / 4294967296)
    local lo = v - hi * 4294967296
    local result = {lo, bit32_band(hi, 0xFFFFFFFF)}
    if neg then return i64_neg(result) end
    return result
end

-- i32 CLZ/CTZ/POPCNT
local function i32_clz(x)
    if x == 0 then return 32 end
    local n = 0
    if bit32_band(x, 0xFFFF0000) == 0 then n = n + 16; x = bit32_lshift(x, 16) end
    if bit32_band(x, 0xFF000000) == 0 then n = n + 8; x = bit32_lshift(x, 8) end
    if bit32_band(x, 0xF0000000) == 0 then n = n + 4; x = bit32_lshift(x, 4) end
    if bit32_band(x, 0xC0000000) == 0 then n = n + 2; x = bit32_lshift(x, 2) end
    if bit32_band(x, 0x80000000) == 0 then n = n + 1 end
    return n
end
local function i32_ctz(x)
    if x == 0 then return 32 end
    local n = 0
    if bit32_band(x, 0x0000FFFF) == 0 then n = n + 16; x = bit32_rshift(x, 16) end
    if bit32_band(x, 0x000000FF) == 0 then n = n + 8; x = bit32_rshift(x, 8) end
    if bit32_band(x, 0x0000000F) == 0 then n = n + 4; x = bit32_rshift(x, 4) end
    if bit32_band(x, 0x00000003) == 0 then n = n + 2; x = bit32_rshift(x, 2) end
    if bit32_band(x, 0x00000001) == 0 then n = n + 1 end
    return n
end
local function i32_popcnt(x) return popcnt32(x) end

-- Float helpers for ctx
local function f32_abs(v) if isnan(v) then if type(v) == "table" and v.nan32 then return setmetatable({nan32 = bit32_band(v.nan32, 0x7FFFFFFF)}, nan_mt) end; return NAN end; return math_abs(v) end
local function f32_neg(v) if isnan(v) then if type(v) == "table" and v.nan32 then return setmetatable({nan32 = bit32_bxor(v.nan32, 0x80000000)}, nan_mt) end; return NAN end; return -v end
local function f32_ceil(v) if isnan(v) then return NAN end; return f32_trunc_val(math_ceil(v)) end
local function f32_floor_fn(v) if isnan(v) then return NAN end; return f32_trunc_val(math_floor(v)) end
local function f32_nearest(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    if math_abs(v) >= 8388608 then return v end
    local r = math_floor(v + 0.5)
    if v + 0.5 == r and r % 2 ~= 0 then r = r - 1 end
    if r == 0 and v < 0 then return -0.0 end
    return f32_trunc_val(r)
end
local function f32_sqrt(v) if isnan(v) then return NAN end; return f32_trunc_val(math_sqrt(v)) end
local function f32_min(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then if (1/a < 0) or (1/b < 0) then return -0.0 end; return 0.0 end
    return a < b and a or b
end
local function f32_max(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then if (1/a > 0) or (1/b > 0) then return 0.0 end; return -0.0 end
    return a > b and a or b
end
local function f32_copysign(a, b)
    local b_neg
    if isnan(b) then b_neg = type(b) == "table" and b.nan32 and bit32_btest(b.nan32, 0x80000000) or false
    else b_neg = b < 0 or (b == 0 and 1/b < 0) end
    if isnan(a) then
        if type(a) == "table" and a.nan32 then
            local bits = b_neg and bit32_bor(a.nan32, 0x80000000) or bit32_band(a.nan32, 0x7FFFFFFF)
            return setmetatable({nan32 = bits}, nan_mt)
        end
        return NAN
    end
    a = math_abs(a); if b_neg then return -a end; return a
end

local function f64_abs(v) if isnan(v) then if type(v) == "table" and v.nan64 then return setmetatable({nan64 = {v.nan64[1], bit32_band(v.nan64[2], 0x7FFFFFFF)}}, nan_mt) end; return NAN end; return math_abs(v) end
local function f64_neg(v) if isnan(v) then if type(v) == "table" and v.nan64 then return setmetatable({nan64 = {v.nan64[1], bit32_bxor(v.nan64[2], 0x80000000)}}, nan_mt) end; return NAN end; return -v end
local function f64_ceil(v) if isnan(v) then return NAN end; return math_ceil(v) end
local function f64_floor_fn(v) if isnan(v) then return NAN end; return math_floor(v) end
local function f64_trunc_op(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge or v == 0 then return v end
    if v > 0 then return math_floor(v) end; return math_ceil(v)
end
local function f64_nearest(v)
    if isnan(v) then return NAN end
    if v == math_huge or v == -math_huge then return v end
    if v == 0 then return v end
    if math_abs(v) >= 4503599627370496 then return v end
    local r = math_floor(v + 0.5)
    if v + 0.5 == r and r % 2 ~= 0 then r = r - 1 end
    if r == 0 and v < 0 then return -0.0 end
    return r
end
local function f64_sqrt(v) if isnan(v) then return NAN end; return math_sqrt(v) end
local function f64_min(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then if (1/a < 0) or (1/b < 0) then return -0.0 end; return 0.0 end
    return a < b and a or b
end
local function f64_max(a, b)
    if isnan(a) or isnan(b) then return NAN end
    if a == 0 and b == 0 then if (1/a > 0) or (1/b > 0) then return 0.0 end; return -0.0 end
    return a > b and a or b
end
local function f64_copysign(a, b)
    local b_neg
    if isnan(b) then b_neg = type(b) == "table" and b.nan64 and bit32_btest(b.nan64[2], 0x80000000) or false
    else b_neg = b < 0 or (b == 0 and 1/b < 0) end
    if isnan(a) then
        if type(a) == "table" and a.nan64 then
            local bits_hi = b_neg and bit32_bor(a.nan64[2], 0x80000000) or bit32_band(a.nan64[2], 0x7FFFFFFF)
            return setmetatable({nan64 = {a.nan64[1], bits_hi}}, nan_mt)
        end
        return NAN
    end
    a = math_abs(a); if b_neg then return -a end; return a
end

-- f32 trunc op (truncates toward zero, then to f32)
local function f32_trunc_op(v) return f32_trunc_val(f64_trunc_op(v)) end

-- i64→f32 direct conversion (avoid double rounding)
local function i64_to_f32_u(v)
    local lo, hi = v[1], v[2]
    if hi == 0 then return f32_trunc_val(lo) end
    local msb_hi = 0; local tmp = hi
    if tmp >= 65536 then msb_hi = msb_hi + 16; tmp = bit32_rshift(tmp, 16) end
    if tmp >= 256 then msb_hi = msb_hi + 8; tmp = bit32_rshift(tmp, 8) end
    if tmp >= 16 then msb_hi = msb_hi + 4; tmp = bit32_rshift(tmp, 4) end
    if tmp >= 4 then msb_hi = msb_hi + 2; tmp = bit32_rshift(tmp, 2) end
    if tmp >= 2 then msb_hi = msb_hi + 1 end
    local msb = 32 + msb_hi
    local shift = msb - 23
    local mantissa
    if shift >= 32 then mantissa = bit32_rshift(hi, shift - 32)
    else mantissa = bit32_bor(bit32_rshift(lo, shift), bit32_lshift(hi, 32 - shift)) end
    mantissa = bit32_band(mantissa, 0xFFFFFF)
    local guard_pos = shift - 1
    local guard
    if guard_pos >= 32 then guard = bit32_band(bit32_rshift(hi, guard_pos - 32), 1)
    else guard = bit32_band(bit32_rshift(lo, guard_pos), 1) end
    local sticky = 0
    if guard_pos > 32 then
        if lo ~= 0 then sticky = 1 end
        if sticky == 0 then local hi_mask = bit32_lshift(1, guard_pos - 32) - 1; if bit32_band(hi, hi_mask) ~= 0 then sticky = 1 end end
    elseif guard_pos == 32 then if lo ~= 0 then sticky = 1 end
    elseif guard_pos > 0 then local lo_mask = bit32_lshift(1, guard_pos) - 1; if bit32_band(lo, lo_mask) ~= 0 then sticky = 1 end end
    if guard == 1 then
        if sticky == 1 or bit32_band(mantissa, 1) == 1 then
            mantissa = mantissa + 1
            if mantissa > 0xFFFFFF then mantissa = bit32_rshift(mantissa, 1); msb = msb + 1 end
        end
    end
    local result = math.ldexp(mantissa, msb - 23)
    if result > 3.4028234663852886e+38 then return math_huge end
    return result
end
local function i64_to_f32_s(v) if i64_is_neg(v) then return -i64_to_f32_u(i64_neg(v)) end; return i64_to_f32_u(v) end

-- Conversion helpers for ctx

local function i32_trunc_f32_s(val)
    if isnan(val) then fail("invalid conversion to integer") end
    val = val >= 0 and math_floor(val) or -math_floor(-val)
    if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end
    if val < 0 then val = val + 0x100000000 end; return val
end
local function i32_trunc_f32_u(val)
    if isnan(val) then fail("invalid conversion to integer") end
    val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0
    if val >= 4294967296 or val < 0 then fail("integer overflow") end; return val
end
local function i32_trunc_f64_s(val)
    if isnan(val) then fail("invalid conversion to integer") end
    val = val >= 0 and math_floor(val) or -math_floor(-val)
    if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end
    if val < 0 then val = val + 0x100000000 end; return val
end
local function i32_trunc_f64_u(val)
    if isnan(val) then fail("invalid conversion to integer") end
    val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0
    if val >= 4294967296 or val < 0 then fail("integer overflow") end; return val
end
local function i64_trunc_f32_s(val)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end
    return f64_to_i64_s(val)
end
local function i64_trunc_f32_u(val)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end
    return f64_to_i64_u(val)
end
local function i64_trunc_f64_s(val)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end
    return f64_to_i64_s(val)
end
local function i64_trunc_f64_u(val)
    if isnan(val) then fail("invalid conversion to integer") end
    if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end
    return f64_to_i64_u(val)
end

-- Saturating truncation (0xFC sub_ops 0-7)
local function trunc_sat(sub_op, val)
    if sub_op == 0 then -- i32.trunc_sat_f32_s
        if isnan(val) then return 0 end
        if val >= 2147483647 then return 0x7FFFFFFF end
        if val <= -2147483648 then return 0x80000000 end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end; return val
    elseif sub_op == 1 then -- i32.trunc_sat_f32_u
        if isnan(val) or val < 0 then return 0 end
        if val >= 4294967296 then return 0xFFFFFFFF end; return math_floor(val)
    elseif sub_op == 2 then -- i32.trunc_sat_f64_s
        if isnan(val) then return 0 end
        if val >= 2147483647 then return 0x7FFFFFFF end
        if val <= -2147483648 then return 0x80000000 end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end; return val
    elseif sub_op == 3 then -- i32.trunc_sat_f64_u
        if isnan(val) or val < 0 then return 0 end
        if val >= 4294967296 then return 0xFFFFFFFF end; return math_floor(val)
    elseif sub_op == 4 then -- i64.trunc_sat_f32_s
        if isnan(val) then return {0, 0} end
        if val >= 9223372036854775808 then return {0xFFFFFFFF, 0x7FFFFFFF} end
        if val < -9223372036854775808 then return {0, 0x80000000} end
        return f64_to_i64_s(val)
    elseif sub_op == 5 then -- i64.trunc_sat_f32_u
        if isnan(val) or val <= -1.0 then return {0, 0} end
        if val >= 18446744073709551616 then return {0xFFFFFFFF, 0xFFFFFFFF} end
        return f64_to_i64_u(val)
    elseif sub_op == 6 then -- i64.trunc_sat_f64_s
        if isnan(val) then return {0, 0} end
        if val >= 9223372036854775808 then return {0xFFFFFFFF, 0x7FFFFFFF} end
        if val < -9223372036854775808 then return {0, 0x80000000} end
        return f64_to_i64_s(val)
    elseif sub_op == 7 then -- i64.trunc_sat_f64_u
        if isnan(val) or val <= -1.0 then return {0, 0} end
        if val >= 18446744073709551616 then return {0xFFFFFFFF, 0xFFFFFFFF} end
        return f64_to_i64_u(val)
    end
    return 0
end

-- i64 sign extension helpers
local function i64_extend8_s(val)
    local lo = type(val) == "table" and val[1] or val
    lo = bit32_band(lo, 0xFF)
    if lo >= 0x80 then return {bit32_band(lo + 0xFFFFFF00, 0xFFFFFFFF), 0xFFFFFFFF}
    else return {lo, 0} end
end
local function i64_extend16_s(val)
    local lo = type(val) == "table" and val[1] or val
    lo = bit32_band(lo, 0xFFFF)
    if lo >= 0x8000 then return {bit32_band(lo + 0xFFFF0000, 0xFFFFFFFF), 0xFFFFFFFF}
    else return {lo, 0} end
end
local function i64_extend32_s(val)
    local lo = type(val) == "table" and val[1] or val
    return {lo, bit32_btest(lo, 0x80000000) and 0xFFFFFFFF or 0}
end

---------------------------------------------------------------------------
-- State-based reader functions (used by dispatch table handlers)
---------------------------------------------------------------------------

local function read_byte(state)
    local pc = state.pc
    local b = state.code[pc]
    state.pc = pc + 1
    return b
end

local function read_leb128_u(state)
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    while true do
        local b = code[pc]
        pc = pc + 1
        result = bit32_bor(result, bit32_lshift(bit32_band(b, 0x7F), shift))
        if bit32_band(b, 0x80) == 0 then
            break
        end
        shift = shift + 7
    end
    state.pc = pc
    return result
end

local function read_leb128_s(state)
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    local b
    while true do
        b = code[pc]
        pc = pc + 1
        result = bit32_bor(result, bit32_lshift(bit32_band(b, 0x7F), shift))
        shift = shift + 7
        if bit32_band(b, 0x80) == 0 then
            break
        end
    end
    state.pc = pc
    if shift < 32 and bit32_btest(b, 0x40) then
        result = bit32_bor(result, bit32_lshift(-1, shift))
    end
    if bit32_btest(result, 0x80000000) then
        return result - 0x100000000
    end
    return result
end

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
        local val = bit32_band(b, 0x7F)
        if shift < 32 then
            lo = bit32_bor(lo, bit32_lshift(val, shift))
            if shift + 7 > 32 then
                hi = bit32_bor(hi, bit32_rshift(val, 32 - shift))
            end
        elseif shift < 64 then
            hi = bit32_bor(hi, bit32_lshift(val, shift - 32))
        end
        shift = shift + 7
        if bit32_band(b, 0x80) == 0 then
            break
        end
    end
    state.pc = pc
    if bit32_btest(b, 0x40) then
        if shift < 32 then
            lo = bit32_bor(lo, bit32_lshift(0xFFFFFFFF, shift))
            hi = 0xFFFFFFFF
        elseif shift < 64 then
            hi = bit32_bor(hi, bit32_lshift(0xFFFFFFFF, shift - 32))
        end
    end
    return {lo, hi}
end

local function read_memarg(state)
    local _align = read_leb128_u(state)
    local offset = read_leb128_u(state)
    return offset
end

local function read_blocktype(state)
    local result = 0
    local shift = 0
    local code = state.code
    local pc = state.pc
    local b
    while true do
        b = code[pc]
        pc = pc + 1
        result = bit32_bor(result, bit32_lshift(bit32_band(b, 0x7F), shift))
        shift = shift + 7
        if bit32_band(b, 0x80) == 0 then break end
    end
    state.pc = pc
    if shift < 32 and bit32_btest(b, 0x40) then
        result = bit32_bor(result, bit32_lshift(-1, shift))
    end
    if bit32_btest(result, 0x80000000) then
        result = result - 0x100000000
    end

    if result == -64 then
        return 0, 0
    elseif result < 0 then
        return 0, 1
    else
        local type_info = state.module and state.module.types[result + 1]
        if type_info then
            return #type_info.params, #type_info.results
        end
        return 0, 1
    end
end

-- Stack push/pop helpers (state-based, used by dispatch table handlers)
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

local op_push = push
local op_pop = pop

---------------------------------------------------------------------------
-- Stateless bytecode scanning helpers (for build_block_map)
---------------------------------------------------------------------------

local skip_leb128_at = Decode.skip_leb128
local read_leb128_u_at = Decode.leb128_u

local function skip_operands_at(code, pos, op)
    if op == 0x08 then return skip_leb128_at(code, pos)
    elseif op == 0x0A then return pos
    elseif op == 0x0C or op == 0x0D then return skip_leb128_at(code, pos)
    elseif op == 0x0E then
        local count
        count, pos = read_leb128_u_at(code, pos)
        for _ = 0, count do
            pos = skip_leb128_at(code, pos)
        end
        return pos
    elseif op == 0x0F then return pos
    elseif op == 0x10 then return skip_leb128_at(code, pos)
    elseif op == 0x11 then
        pos = skip_leb128_at(code, pos)
        return skip_leb128_at(code, pos)
    elseif op == 0x1A or op == 0x1B then return pos
    elseif op == 0x1F then
        pos = skip_leb128_at(code, pos)
        local num_catches
        num_catches, pos = read_leb128_u_at(code, pos)
        for _ = 1, num_catches do
            local kind = code[pos]; pos = pos + 1
            if kind == 0 or kind == 2 then
                pos = skip_leb128_at(code, pos)
            end
            pos = skip_leb128_at(code, pos)
        end
        return pos
    elseif op >= 0x20 and op <= 0x24 then return skip_leb128_at(code, pos)
    elseif op >= 0x28 and op <= 0x3E then
        pos = skip_leb128_at(code, pos)
        return skip_leb128_at(code, pos)
    elseif op == 0x3F or op == 0x40 then return skip_leb128_at(code, pos)
    elseif op == 0x41 then return skip_leb128_at(code, pos)
    elseif op == 0x42 then return skip_leb128_at(code, pos)
    elseif op == 0x43 then return pos + 4
    elseif op == 0x44 then return pos + 8
    elseif op == 0xFC then return skip_leb128_at(code, pos)
    end
    return pos
end

local function build_block_map(code)
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
            pos = skip_leb128_at(code, pos)
        elseif op == 0x1F then
            top = top + 1
            bstack[top] = opcode_pc
            block_map[opcode_pc] = {}
            pos = skip_leb128_at(code, pos)
            local num_catches
            num_catches, pos = read_leb128_u_at(code, pos)
            for _ = 1, num_catches do
                local kind = code[pos]; pos = pos + 1
                if kind == 0 or kind == 2 then
                    pos = skip_leb128_at(code, pos)
                end
                pos = skip_leb128_at(code, pos)
            end
        elseif op == 0x05 then
            if top > 0 then
                block_map[bstack[top]].else_pc = pos
            end
        elseif op == 0x0B then
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

---------------------------------------------------------------------------
-- do_branch and handle_exception (used by dispatch table handlers)
---------------------------------------------------------------------------

local function do_branch(state, depth)
    local target_idx = state.block_sp - depth
    local target_block = state.block_stack[target_idx]
    local arity = target_block.arity
    local sp = state.sp
    local base = target_block.stack_height

    if target_block.opcode == 0x03 then
        if arity > 0 then
            for i = arity - 1, 0, -1 do
                state.stack[base + 1 + i] = state.stack[sp - (arity - 1 - i)]
            end
            state.sp = base + arity
        else
            state.sp = base
        end
        state.block_sp = target_idx
        state.pc = target_block.continuation_pc
    else
        if arity > 0 then
            for i = arity - 1, 0, -1 do
                state.stack[base + 1 + i] = state.stack[sp - (arity - 1 - i)]
            end
            state.sp = base + arity
        else
            state.sp = base
        end
        state.block_sp = target_idx - 1
        if state.block_sp <= 0 then
            state.running = false
        else
            state.pc = state.block_map[target_block.block_pc].end_pc
        end
    end
end

local function handle_exception(state, exception)
    local bsp = state.block_sp
    while bsp >= 1 do
        local block = state.block_stack[bsp]
        if block.opcode == 0x1F and block.catches then
            for _, clause in ipairs(block.catches) do
                local matched = false
                if clause.kind == 0 then
                    matched = (exception.tag == clause.tagidx)
                elseif clause.kind == 1 then
                    matched = true
                elseif clause.kind == 2 then
                    matched = (exception.tag == clause.tagidx)
                elseif clause.kind == 3 then
                    matched = true
                end
                if matched then
                    state.sp = block.stack_height
                    if clause.kind == 0 or clause.kind == 2 then
                        for _, v in ipairs(exception.values) do
                            push(state, v)
                        end
                    end
                    if clause.kind == 2 or clause.kind == 3 then
                        push(state, exception)
                    end
                    state.block_sp = bsp
                    state.exception = nil
                    do_branch(state, clause.depth)
                    return true
                end
            end
        end
        bsp = bsp - 1
    end
    return false
end

-- Aliases for dispatch table compatibility (opcodes.lua used different names)
local f32_trunc = f32_trunc_val
local f32_floor = f32_floor_fn
local f64_floor = f64_floor_fn

---------------------------------------------------------------------------
-- Dispatch table: opcode -> handler function
-- Handlers for opcodes already inlined in the run loop are omitted.
---------------------------------------------------------------------------
local dispatch = {}

-- 0x00: unreachable
dispatch[0x00] = function(state)
    fail("unreachable")
end

-- 0x01: nop
dispatch[0x01] = function(state) end

-- 0x02: block (also called from inlined non-void block path)
dispatch[0x02] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x02,
        arity = n_results,
        stack_height = state.sp - n_params,
        block_pc = block_pc,
    }
end

-- 0x04: if (also called from inlined non-void if path)
dispatch[0x04] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local cond = pop(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x04,
        arity = n_results,
        stack_height = state.sp - n_params,
        block_pc = block_pc,
    }
    if cond == 0 then
        local info = state.block_map[block_pc]
        if info.else_pc then
            state.pc = info.else_pc
        else
            state.block_sp = bsp - 1
            state.pc = info.end_pc
        end
    end
end

-- 0x05: else
dispatch[0x05] = function(state)
    local bsp = state.block_sp
    local block = state.block_stack[bsp]
    state.pc = state.block_map[block.block_pc].end_pc
    state.block_sp = bsp - 1
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
        state.running = false
        return
    end
    local block = state.block_stack[bsp]
    state.block_sp = bsp - 1
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
    if bsp - 1 <= 0 then
        state.running = false
    end
end

-- 0x0D: br_if
dispatch[0x0D] = function(state)
    local depth = read_leb128_u(state)
    local cond = pop(state)
    if cond ~= 0 then
        do_branch(state, depth)
    end
end

-- 0x10: call
dispatch[0x10] = function(state)
    local func_idx = read_leb128_u(state)
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

-- 0x28: i32.load
dispatch[0x28] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i32(base + offset))
end

-- 0x2D: i32.load8_u
dispatch[0x2D] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, state.memory:load_i8_u(base + offset))
end

-- 0x36: i32.store
dispatch[0x36] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i32(base + offset, val)
end

-- 0x3A: i32.store8
dispatch[0x3A] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    state.memory:store_i8(base + offset, val)
end

-- 0x41: i32.const
dispatch[0x41] = function(state)
    local val = read_leb128_s(state)
    if val < 0 then val = val + 0x100000000 end
    push(state, val)
end

-- 0x45: i32.eqz
dispatch[0x45] = function(state) local val = pop(state); push(state, val == 0 and 1 or 0) end
-- 0x46: i32.eq
dispatch[0x46] = function(state) local b = pop(state); local a = pop(state); push(state, a == b and 1 or 0) end
-- 0x47: i32.ne
dispatch[0x47] = function(state) local b = pop(state); local a = pop(state); push(state, a ~= b and 1 or 0) end
-- 0x48: i32.lt_s
dispatch[0x48] = function(state) local b = to_signed32(pop(state)); local a = to_signed32(pop(state)); push(state, a < b and 1 or 0) end
-- 0x49: i32.lt_u
dispatch[0x49] = function(state) local b = pop(state); local a = pop(state); push(state, a < b and 1 or 0) end
-- 0x4A: i32.gt_s
dispatch[0x4A] = function(state) local b = to_signed32(pop(state)); local a = to_signed32(pop(state)); push(state, a > b and 1 or 0) end
-- 0x4B: i32.gt_u
dispatch[0x4B] = function(state) local b = pop(state); local a = pop(state); push(state, a > b and 1 or 0) end
-- 0x4C: i32.le_s
dispatch[0x4C] = function(state) local b = to_signed32(pop(state)); local a = to_signed32(pop(state)); push(state, a <= b and 1 or 0) end
-- 0x4D: i32.le_u
dispatch[0x4D] = function(state) local b = pop(state); local a = pop(state); push(state, a <= b and 1 or 0) end
-- 0x4E: i32.ge_s
dispatch[0x4E] = function(state) local b = to_signed32(pop(state)); local a = to_signed32(pop(state)); push(state, a >= b and 1 or 0) end
-- 0x4F: i32.ge_u
dispatch[0x4F] = function(state) local b = pop(state); local a = pop(state); push(state, a >= b and 1 or 0) end

-- 0x6A: i32.add
dispatch[0x6A] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_band(a + b, 0xFFFFFFFF)) end
-- 0x6B: i32.sub
dispatch[0x6B] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_band(a - b + 0x100000000, 0xFFFFFFFF)) end
-- 0x6C: i32.mul
dispatch[0x6C] = function(state)
    local b = pop(state); local a = pop(state)
    local a_lo = bit32_band(a, 0xFFFF); local a_hi = bit32_rshift(a, 16)
    local b_lo = bit32_band(b, 0xFFFF); local b_hi = bit32_rshift(b, 16)
    push(state, bit32_band(a_lo * b_lo + (a_lo * b_hi + a_hi * b_lo) * 65536, 0xFFFFFFFF))
end
-- 0x71: i32.and
dispatch[0x71] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_band(a, b)) end
-- 0x72: i32.or
dispatch[0x72] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_bor(a, b)) end
-- 0x73: i32.xor
dispatch[0x73] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_bxor(a, b)) end
-- 0x74: i32.shl
dispatch[0x74] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_lshift(a, bit32_band(b, 31))) end
-- 0x75: i32.shr_s
dispatch[0x75] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_arshift(a, bit32_band(b, 31))) end
-- 0x76: i32.shr_u
dispatch[0x76] = function(state) local b = pop(state); local a = pop(state); push(state, bit32_rshift(a, bit32_band(b, 31))) end

-- 0x03: loop
dispatch[0x03] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x03,
        arity = n_params,
        result_arity = n_results,
        stack_height = state.sp - n_params,
        continuation_pc = state.pc,
        block_pc = block_pc,
    }
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

-- 0x0C: br
dispatch[0x0C] = function(state)
    local depth = read_leb128_u(state)
    do_branch(state, depth)
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

-- 0x1F: try_table
dispatch[0x1F] = function(state)
    local block_pc = state.pc - 1
    local n_params, n_results = read_blocktype(state)
    local num_catches = read_leb128_u(state)
    local catches = {}
    for i = 1, num_catches do
        local kind = read_byte(state)
        local tagidx = nil
        if kind == 0 or kind == 2 then
            tagidx = read_leb128_u(state)
        end
        local depth = read_leb128_u(state)
        catches[i] = {kind = kind, tagidx = tagidx, depth = depth}
    end
    local bsp = state.block_sp + 1
    state.block_sp = bsp
    state.block_stack[bsp] = {
        opcode = 0x1F,
        arity = n_results,
        stack_height = state.sp - n_params,
        catches = catches,
        block_pc = block_pc,
    }
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
        push(state, {bit32_band(val + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF})
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
        push(state, {bit32_band(val + 0x100000000, 0xFFFFFFFF), 0xFFFFFFFF})
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
    local hi = bit32_btest(val, 0x80000000) and 0xFFFFFFFF or 0
    push(state, {val, hi})
end

-- 0x35: i64.load32_u
dispatch[0x35] = function(state)
    local offset = read_memarg(state)
    local base = pop(state)
    push(state, {state.memory:load_i32(base + offset), 0})
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
    local short_val = type(val) == "table" and bit32_band(val[1], 0xFFFF) or bit32_band(val, 0xFFFF)
    state.memory:store_i16(base + offset, short_val)
end

-- 0x3E: i64.store32
dispatch[0x3E] = function(state)
    local offset = read_memarg(state)
    local val = pop(state)
    local base = pop(state)
    local word_val = type(val) == "table" and val[1] or bit32_band(val, 0xFFFFFFFF)
    state.memory:store_i32(base + offset, word_val)
end

-- 0x3F: memory.size
dispatch[0x3F] = function(state)
    read_leb128_u(state)
    push(state, state.memory:size())
end

-- 0x40: memory.grow
dispatch[0x40] = function(state)
    read_leb128_u(state)
    local pages = pop(state)
    push(state, state.memory:grow(pages))
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
    local bits = bit32_bor(b0, bit32_lshift(b1, 8), bit32_lshift(b2, 16), bit32_lshift(b3, 24))
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
    local lo = bit32_bor(b0, bit32_lshift(b1, 8), bit32_lshift(b2, 16), bit32_lshift(b3, 24))
    local hi = bit32_bor(b4, bit32_lshift(b5, 8), bit32_lshift(b6, 16), bit32_lshift(b7, 24))
    push(state, f64_reinterpret_i64({lo, hi}))
end

-- i64 comparison ops
dispatch[0x50] = function(state) local val = pop(state); push(state, i64_eqz(val) and 1 or 0) end
dispatch[0x51] = function(state) local b = pop(state); local a = pop(state); push(state, i64_eq(a, b) and 1 or 0) end
dispatch[0x52] = function(state) local b = pop(state); local a = pop(state); push(state, i64_ne(a, b) and 1 or 0) end
dispatch[0x53] = function(state) local b = pop(state); local a = pop(state); push(state, i64_lt_s(a, b) and 1 or 0) end
dispatch[0x54] = function(state) local b = pop(state); local a = pop(state); push(state, i64_lt_u(a, b) and 1 or 0) end
dispatch[0x55] = function(state) local b = pop(state); local a = pop(state); push(state, i64_gt_s(a, b) and 1 or 0) end
dispatch[0x56] = function(state) local b = pop(state); local a = pop(state); push(state, i64_gt_u(a, b) and 1 or 0) end
dispatch[0x57] = function(state) local b = pop(state); local a = pop(state); push(state, i64_le_s(a, b) and 1 or 0) end
dispatch[0x58] = function(state) local b = pop(state); local a = pop(state); push(state, i64_le_u(a, b) and 1 or 0) end
dispatch[0x59] = function(state) local b = pop(state); local a = pop(state); push(state, i64_ge_s(a, b) and 1 or 0) end
dispatch[0x5A] = function(state) local b = pop(state); local a = pop(state); push(state, i64_ge_u(a, b) and 1 or 0) end

-- f32 comparison ops
dispatch[0x5B] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a == b and 1 or 0) end
dispatch[0x5C] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 1); return end; push(state, a ~= b and 1 or 0) end
dispatch[0x5D] = function(state) local b = pop(state); local a = pop(state); push(state, a < b and 1 or 0) end
dispatch[0x5E] = function(state) local b = pop(state); local a = pop(state); push(state, a > b and 1 or 0) end
dispatch[0x5F] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a <= b and 1 or 0) end
dispatch[0x60] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a >= b and 1 or 0) end

-- f64 comparison ops
dispatch[0x61] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a == b and 1 or 0) end
dispatch[0x62] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 1); return end; push(state, a ~= b and 1 or 0) end
dispatch[0x63] = function(state) local b = pop(state); local a = pop(state); push(state, a < b and 1 or 0) end
dispatch[0x64] = function(state) local b = pop(state); local a = pop(state); push(state, a > b and 1 or 0) end
dispatch[0x65] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a <= b and 1 or 0) end
dispatch[0x66] = function(state) local b = pop(state); local a = pop(state); if isnan(a) or isnan(b) then push(state, 0); return end; push(state, a >= b and 1 or 0) end

-- i32 numeric ops
dispatch[0x67] = function(state) push(state, i32_clz(pop(state))) end
dispatch[0x68] = function(state) push(state, i32_ctz(pop(state))) end
dispatch[0x69] = function(state) push(state, i32_popcnt(pop(state))) end

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

-- 0x77: i32.rotl
dispatch[0x77] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.lrotate(a, bit32_band(b, 31)))
end

-- 0x78: i32.rotr
dispatch[0x78] = function(state)
    local b = pop(state); local a = pop(state)
    push(state, bit32.rrotate(a, bit32_band(b, 31)))
end

-- i64 numeric ops
dispatch[0x79] = function(state) push(state, i64_clz(pop(state))) end
dispatch[0x7A] = function(state) push(state, i64_ctz(pop(state))) end
dispatch[0x7B] = function(state) push(state, i64_popcnt(pop(state))) end
dispatch[0x7C] = function(state) local b = pop(state); local a = pop(state); push(state, i64_add(a, b)) end
dispatch[0x7D] = function(state) local b = pop(state); local a = pop(state); push(state, i64_sub(a, b)) end
dispatch[0x7E] = function(state) local b = pop(state); local a = pop(state); push(state, i64_mul(a, b)) end
dispatch[0x7F] = function(state) local b = pop(state); local a = pop(state); push(state, i64_div_s(a, b)) end
dispatch[0x80] = function(state) local b = pop(state); local a = pop(state); push(state, i64_div_u(a, b)) end
dispatch[0x81] = function(state) local b = pop(state); local a = pop(state); push(state, i64_rem_s(a, b)) end
dispatch[0x82] = function(state) local b = pop(state); local a = pop(state); push(state, i64_rem_u(a, b)) end
dispatch[0x83] = function(state) local b = pop(state); local a = pop(state); push(state, i64_and(a, b)) end
dispatch[0x84] = function(state) local b = pop(state); local a = pop(state); push(state, i64_or(a, b)) end
dispatch[0x85] = function(state) local b = pop(state); local a = pop(state); push(state, i64_xor(a, b)) end
dispatch[0x86] = function(state) local b = pop(state); local a = pop(state); push(state, i64_shl(a, type(b) == "table" and b[1] or b)) end
dispatch[0x87] = function(state) local b = pop(state); local a = pop(state); push(state, i64_shr_s(a, type(b) == "table" and b[1] or b)) end
dispatch[0x88] = function(state) local b = pop(state); local a = pop(state); push(state, i64_shr_u(a, type(b) == "table" and b[1] or b)) end
dispatch[0x89] = function(state) local b = pop(state); local a = pop(state); push(state, i64_rotl(a, type(b) == "table" and b[1] or b)) end
dispatch[0x8A] = function(state) local b = pop(state); local a = pop(state); push(state, i64_rotr(a, type(b) == "table" and b[1] or b)) end

-- f32 numeric ops
dispatch[0x8B] = function(state) push(state, f32_abs(pop(state))) end
dispatch[0x8C] = function(state) push(state, f32_neg(pop(state))) end
dispatch[0x8D] = function(state) push(state, f32_ceil(pop(state))) end
dispatch[0x8E] = function(state) push(state, f32_floor(pop(state))) end
dispatch[0x8F] = function(state) push(state, f32_trunc_op(pop(state))) end
dispatch[0x90] = function(state) push(state, f32_nearest(pop(state))) end
dispatch[0x91] = function(state) push(state, f32_sqrt(pop(state))) end
dispatch[0x92] = function(state) local b = pop(state); local a = pop(state); push(state, f32_trunc(a + b)) end
dispatch[0x93] = function(state) local b = pop(state); local a = pop(state); push(state, f32_trunc(a - b)) end
dispatch[0x94] = function(state) local b = pop(state); local a = pop(state); push(state, f32_trunc(a * b)) end
dispatch[0x95] = function(state) local b = pop(state); local a = pop(state); push(state, f32_trunc(a / b)) end
dispatch[0x96] = function(state) local b = pop(state); local a = pop(state); push(state, f32_min(a, b)) end
dispatch[0x97] = function(state) local b = pop(state); local a = pop(state); push(state, f32_max(a, b)) end
dispatch[0x98] = function(state) local b = pop(state); local a = pop(state); push(state, f32_copysign(a, b)) end

-- f64 numeric ops
dispatch[0x99] = function(state) push(state, f64_abs(pop(state))) end
dispatch[0x9A] = function(state) push(state, f64_neg(pop(state))) end
dispatch[0x9B] = function(state) push(state, f64_ceil(pop(state))) end
dispatch[0x9C] = function(state) push(state, f64_floor(pop(state))) end
dispatch[0x9D] = function(state) push(state, f64_trunc_op(pop(state))) end
dispatch[0x9E] = function(state) push(state, f64_nearest(pop(state))) end
dispatch[0x9F] = function(state) push(state, f64_sqrt(pop(state))) end
dispatch[0xA0] = function(state) local b = pop(state); local a = pop(state); push(state, a + b) end
dispatch[0xA1] = function(state) local b = pop(state); local a = pop(state); push(state, a - b) end
dispatch[0xA2] = function(state) local b = pop(state); local a = pop(state); push(state, a * b) end
dispatch[0xA3] = function(state) local b = pop(state); local a = pop(state); push(state, a / b) end
dispatch[0xA4] = function(state) local b = pop(state); local a = pop(state); push(state, f64_min(a, b)) end
dispatch[0xA5] = function(state) local b = pop(state); local a = pop(state); push(state, f64_max(a, b)) end
dispatch[0xA6] = function(state) local b = pop(state); local a = pop(state); push(state, f64_copysign(a, b)) end

-- Conversion ops
dispatch[0xA7] = function(state) local val = pop(state); push(state, type(val) == "table" and val[1] or bit32_band(val, 0xFFFFFFFF)) end
dispatch[0xA8] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; val = val >= 0 and math_floor(val) or -math_floor(-val); if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end; if val < 0 then val = val + 0x100000000 end; push(state, val) end
dispatch[0xA9] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0; if val >= 4294967296 or val < 0 then fail("integer overflow") end; push(state, val) end
dispatch[0xAA] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; val = val >= 0 and math_floor(val) or -math_floor(-val); if val >= 2147483648 or val < -2147483648 then fail("integer overflow") end; if val < 0 then val = val + 0x100000000 end; push(state, val) end
dispatch[0xAB] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; val = (val >= 0 and math_floor(val) or -math_floor(-val)) + 0; if val >= 4294967296 or val < 0 then fail("integer overflow") end; push(state, val) end
dispatch[0xAC] = function(state) local val = pop(state); val = type(val) == "table" and val[1] or val; push(state, {val, bit32_btest(val, 0x80000000) and 0xFFFFFFFF or 0}) end
dispatch[0xAD] = function(state) local val = pop(state); val = type(val) == "table" and val[1] or val; push(state, {val, 0}) end
dispatch[0xAE] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end; push(state, f64_to_i64_s(val)) end
dispatch[0xAF] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end; push(state, f64_to_i64_u(val)) end
dispatch[0xB0] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; if val >= 9223372036854775808 or val < -9223372036854775808 then fail("integer overflow") end; push(state, f64_to_i64_s(val)) end
dispatch[0xB1] = function(state) local val = pop(state); if isnan(val) then fail("invalid conversion to integer") end; if val >= 18446744073709551616 or val <= -1.0 then fail("integer overflow") end; push(state, f64_to_i64_u(val)) end
dispatch[0xB2] = function(state) push(state, f32_trunc(to_signed32(pop(state)))) end
dispatch[0xB3] = function(state) push(state, f32_trunc(pop(state))) end
dispatch[0xB4] = function(state) push(state, i64_to_f32_s(pop(state))) end
dispatch[0xB5] = function(state) push(state, i64_to_f32_u(pop(state))) end
dispatch[0xB6] = function(state) push(state, f32_trunc(pop(state))) end
dispatch[0xB7] = function(state) push(state, to_signed32(pop(state)) + 0.0) end
dispatch[0xB8] = function(state) push(state, pop(state) + 0.0) end
dispatch[0xB9] = function(state) push(state, i64_to_f64_s(pop(state))) end
dispatch[0xBA] = function(state) push(state, i64_to_f64_u(pop(state))) end
dispatch[0xBB] = function(state) local v = state.stack[state.sp]; if isnan(v) then state.stack[state.sp] = NAN end end
dispatch[0xBC] = function(state) push(state, i32_reinterpret_f32(pop(state))) end
dispatch[0xBD] = function(state) push(state, i64_reinterpret_f64(pop(state))) end
dispatch[0xBE] = function(state) push(state, f32_reinterpret_i32(pop(state))) end
dispatch[0xBF] = function(state) push(state, f64_reinterpret_i64(pop(state))) end

-- Sign extension ops
dispatch[0xC0] = function(state) local val = bit32_band(pop(state), 0xFF); if val >= 0x80 then val = val - 0x100 end; if val < 0 then val = val + 0x100000000 end; push(state, val) end
dispatch[0xC1] = function(state) local val = bit32_band(pop(state), 0xFFFF); if val >= 0x8000 then val = val - 0x10000 end; if val < 0 then val = val + 0x100000000 end; push(state, val) end
dispatch[0xC2] = function(state) local val = pop(state); local lo = type(val) == "table" and val[1] or val; lo = bit32_band(lo, 0xFF); if lo >= 0x80 then push(state, {bit32_band(lo + 0xFFFFFF00, 0xFFFFFFFF), 0xFFFFFFFF}) else push(state, {lo, 0}) end end
dispatch[0xC3] = function(state) local val = pop(state); local lo = type(val) == "table" and val[1] or val; lo = bit32_band(lo, 0xFFFF); if lo >= 0x8000 then push(state, {bit32_band(lo + 0xFFFF0000, 0xFFFFFFFF), 0xFFFFFFFF}) else push(state, {lo, 0}) end end
dispatch[0xC4] = function(state) local val = pop(state); local lo = type(val) == "table" and val[1] or val; push(state, {lo, bit32_btest(lo, 0x80000000) and 0xFFFFFFFF or 0}) end

-- 0xFC: extended ops
dispatch[0xFC] = function(state)
    local sub_op = read_leb128_u(state)
    if sub_op == 0 then
        local val = pop(state); if isnan(val) then push(state, 0); return end
        if val >= 2147483647 then push(state, 0x7FFFFFFF); return end
        if val <= -2147483648 then push(state, 0x80000000); return end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end; push(state, val)
    elseif sub_op == 1 then
        local val = pop(state); if isnan(val) or val < 0 then push(state, 0); return end
        if val >= 4294967296 then push(state, 0xFFFFFFFF); return end; push(state, math_floor(val))
    elseif sub_op == 2 then
        local val = pop(state); if isnan(val) then push(state, 0); return end
        if val >= 2147483647 then push(state, 0x7FFFFFFF); return end
        if val <= -2147483648 then push(state, 0x80000000); return end
        val = val >= 0 and math_floor(val) or math_ceil(val)
        if val < 0 then val = val + 0x100000000 end; push(state, val)
    elseif sub_op == 3 then
        local val = pop(state); if isnan(val) or val < 0 then push(state, 0); return end
        if val >= 4294967296 then push(state, 0xFFFFFFFF); return end; push(state, math_floor(val))
    elseif sub_op == 4 then
        local val = pop(state); if isnan(val) then push(state, {0, 0}); return end
        if val >= 9223372036854775808 then push(state, {0xFFFFFFFF, 0x7FFFFFFF}); return end
        if val < -9223372036854775808 then push(state, {0, 0x80000000}); return end
        push(state, f64_to_i64_s(val))
    elseif sub_op == 5 then
        local val = pop(state); if isnan(val) or val <= -1.0 then push(state, {0, 0}); return end
        if val >= 18446744073709551616 then push(state, {0xFFFFFFFF, 0xFFFFFFFF}); return end
        push(state, f64_to_i64_u(val))
    elseif sub_op == 6 then
        local val = pop(state); if isnan(val) then push(state, {0, 0}); return end
        if val >= 9223372036854775808 then push(state, {0xFFFFFFFF, 0x7FFFFFFF}); return end
        if val < -9223372036854775808 then push(state, {0, 0x80000000}); return end
        push(state, f64_to_i64_s(val))
    elseif sub_op == 7 then
        local val = pop(state); if isnan(val) or val <= -1.0 then push(state, {0, 0}); return end
        if val >= 18446744073709551616 then push(state, {0xFFFFFFFF, 0xFFFFFFFF}); return end
        push(state, f64_to_i64_u(val))
    elseif sub_op == 8 then
        local seg_idx = read_leb128_u(state); read_leb128_u(state)
        local n = pop(state); local s = pop(state); local d = pop(state)
        local seg_data = state.instance.data_segments_raw[seg_idx + 1]
        if seg_data then for i = 0, n - 1 do state.memory:store_byte(d + i, string.byte(seg_data, s + i + 1)) end end
    elseif sub_op == 9 then
        local seg_idx = read_leb128_u(state)
        if state.instance.data_segments_raw then state.instance.data_segments_raw[seg_idx + 1] = nil end
    elseif sub_op == 10 then
        read_leb128_u(state); read_leb128_u(state)
        local n = pop(state); local s = pop(state); local d = pop(state)
        if d <= s then for i = 0, n - 1 do state.memory:store_byte(d + i, state.memory:load_byte(s + i)) end
        else for i = n - 1, 0, -1 do state.memory:store_byte(d + i, state.memory:load_byte(s + i)) end end
    elseif sub_op == 11 then
        read_leb128_u(state)
        local n = pop(state); local val = pop(state); local d = pop(state)
        val = bit32_band(val, 0xFF)
        for i = 0, n - 1 do state.memory:store_byte(d + i, val) end
    elseif sub_op == 12 then
        local seg_idx = read_leb128_u(state); local tbl_idx = read_leb128_u(state)
        local n = pop(state); local s = pop(state); local d = pop(state)
        local seg = state.instance.element_segments_raw and state.instance.element_segments_raw[seg_idx + 1]
        local tbl = state.instance.tables[tbl_idx]
        if seg and tbl then for i = 0, n - 1 do tbl[d + i] = seg[s + i + 1] end end
    elseif sub_op == 13 then
        local seg_idx = read_leb128_u(state)
        if state.instance.element_segments_raw then state.instance.element_segments_raw[seg_idx + 1] = nil end
    elseif sub_op == 14 then
        local dst_idx = read_leb128_u(state); local src_idx = read_leb128_u(state)
        local n = pop(state); local s = pop(state); local d = pop(state)
        local dst_tbl = state.instance.tables[dst_idx]; local src_tbl = state.instance.tables[src_idx]
        if dst_tbl and src_tbl then
            if d <= s then for i = 0, n - 1 do dst_tbl[d + i] = src_tbl[s + i] end
            else for i = n - 1, 0, -1 do dst_tbl[d + i] = src_tbl[s + i] end end
        end
    elseif sub_op == 15 then
        read_leb128_u(state); local n = pop(state); local _init = pop(state)
        push(state, 0xFFFFFFFF)
    elseif sub_op == 16 then
        local tbl_idx = read_leb128_u(state)
        push(state, state.instance.table_sizes[tbl_idx] or 0)
    elseif sub_op == 17 then
        local tbl_idx = read_leb128_u(state)
        local n = pop(state); local val = pop(state); local d = pop(state)
        local tbl = state.instance.tables[tbl_idx]
        if tbl then for i = 0, n - 1 do tbl[d + i] = val end end
    else
        fail(string.format("unknown opcode 0xFC %d", sub_op))
    end
end

-- Create the ctx object for compiled functions
local function create_ctx(instance)
    local ctx = {
        -- Call protocol fields (set by compiled code, read by run loop)
        call_target = nil,
        resume_point = 0,
        call_indirect_type = nil,
        call_indirect_table = nil,

        -- Helpers called from compiled code
        isnan = isnan,
        f32_reinterpret = f32_reinterpret_i32,
        f64_reinterpret = f64_reinterpret_i64,
        i32_reinterpret_f32 = i32_reinterpret_f32,
        i64_reinterpret_f64 = i64_reinterpret_f64,
        f32_trunc_val = f32_trunc_val,

        -- i32 helpers
        i32_clz = i32_clz,
        i32_ctz = i32_ctz,
        i32_popcnt = i32_popcnt,

        -- i64 helpers
        i64_eqz = i64_eqz,
        i64_eq = i64_eq,
        i64_ne = i64_ne,
        i64_lt_s = i64_lt_s,
        i64_lt_u = i64_lt_u,
        i64_gt_s = i64_gt_s,
        i64_gt_u = i64_gt_u,
        i64_le_s = i64_le_s,
        i64_le_u = i64_le_u,
        i64_ge_s = i64_ge_s,
        i64_ge_u = i64_ge_u,
        i64_add = i64_add,
        i64_sub = i64_sub,
        i64_mul = i64_mul,
        i64_div_s = i64_div_s,
        i64_div_u = i64_div_u,
        i64_rem_s = i64_rem_s,
        i64_rem_u = i64_rem_u,
        i64_shl = i64_shl,
        i64_shr_s = i64_shr_s,
        i64_shr_u = i64_shr_u,
        i64_rotl = i64_rotl,
        i64_rotr = i64_rotr,
        i64_clz = i64_clz,
        i64_ctz = i64_ctz,
        i64_popcnt = i64_popcnt,

        -- Float helpers
        f32_abs = f32_abs,
        f32_neg = f32_neg,
        f32_ceil = f32_ceil,
        f32_floor = f32_floor_fn,
        f32_trunc = f32_trunc_op,
        f32_nearest = f32_nearest,
        f32_sqrt = f32_sqrt,
        f32_min = f32_min,
        f32_max = f32_max,
        f32_copysign = f32_copysign,
        f64_abs = f64_abs,
        f64_neg = f64_neg,
        f64_ceil = f64_ceil,
        f64_floor = f64_floor_fn,
        f64_trunc = f64_trunc_op,
        f64_nearest = f64_nearest,
        f64_sqrt = f64_sqrt,
        f64_min = f64_min,
        f64_max = f64_max,
        f64_copysign = f64_copysign,

        -- Conversion helpers
        i32_trunc_f32_s = i32_trunc_f32_s,
        i32_trunc_f32_u = i32_trunc_f32_u,
        i32_trunc_f64_s = i32_trunc_f64_s,
        i32_trunc_f64_u = i32_trunc_f64_u,
        i64_trunc_f32_s = i64_trunc_f32_s,
        i64_trunc_f32_u = i64_trunc_f32_u,
        i64_trunc_f64_s = i64_trunc_f64_s,
        i64_trunc_f64_u = i64_trunc_f64_u,
        f32_convert_i32_s = function(v) return f32_trunc_val(to_signed32(v)) end,
        f32_convert_i32_u = function(v) return f32_trunc_val(v) end,
        f32_convert_i64_s = i64_to_f32_s,
        f32_convert_i64_u = i64_to_f32_u,
        f32_demote_f64 = f32_trunc_val,
        f64_convert_i64_s = i64_to_f64_s,
        f64_convert_i64_u = i64_to_f64_u,

        -- Saturating truncation
        trunc_sat = trunc_sat,

        -- i64 sign extension
        i64_extend8_s = i64_extend8_s,
        i64_extend16_s = i64_extend16_s,
        i64_extend32_s = i64_extend32_s,
    }

    -- Memory/table operations that need instance access
    ctx.memory_init = function(seg_idx, stack, sp, mem)
        local n = stack[sp]; local s = stack[sp-1]; local d = stack[sp-2]
        local seg_data = instance.data_segments_raw[seg_idx + 1]
        if seg_data then
            for ii = 0, n - 1 do mem:store_byte(d + ii, string.byte(seg_data, s + ii + 1)) end
        end
    end
    ctx.data_drop = function(seg_idx)
        if instance.data_segments_raw then instance.data_segments_raw[seg_idx + 1] = nil end
    end
    ctx.memory_copy = function(stack, sp, mem)
        local n = stack[sp]; local s = stack[sp-1]; local d = stack[sp-2]
        if d <= s then for ii = 0, n-1 do mem:store_byte(d+ii, mem:load_byte(s+ii)) end
        else for ii = n-1, 0, -1 do mem:store_byte(d+ii, mem:load_byte(s+ii)) end end
    end
    ctx.memory_fill = function(stack, sp, mem)
        local n = stack[sp]; local val = bit32_band(stack[sp-1], 0xFF); local d = stack[sp-2]
        for ii = 0, n-1 do mem:store_byte(d+ii, val) end
    end
    ctx.table_init = function(seg_idx, tbl_idx, stack, sp)
        local n = stack[sp]; local s = stack[sp-1]; local d = stack[sp-2]
        local seg = instance.element_segments_raw and instance.element_segments_raw[seg_idx + 1]
        local tbl = instance.tables[tbl_idx]
        if seg and tbl then for ii = 0, n-1 do tbl[d+ii] = seg[s+ii+1] end end
    end
    ctx.elem_drop = function(seg_idx)
        if instance.element_segments_raw then instance.element_segments_raw[seg_idx + 1] = nil end
    end
    ctx.table_copy = function(dst_idx, src_idx, stack, sp)
        local n = stack[sp]; local s = stack[sp-1]; local d = stack[sp-2]
        local dst = instance.tables[dst_idx]; local src = instance.tables[src_idx]
        if dst and src then
            if d <= s then for ii = 0, n-1 do dst[d+ii] = src[s+ii] end
            else for ii = n-1, 0, -1 do dst[d+ii] = src[s+ii] end end
        end
    end
    ctx.table_size = function(tbl_idx)
        return instance.table_sizes[tbl_idx] or 0
    end
    ctx.table_fill = function(tbl_idx, stack, sp)
        local n = stack[sp]; local val = stack[sp-1]; local d = stack[sp-2]
        local tbl = instance.tables[tbl_idx]
        if tbl then for ii = 0, n-1 do tbl[d+ii] = val end end
    end

    return ctx
end

---------------------------------------------------------------------------
-- Instantiation
---------------------------------------------------------------------------

function Interp.instantiate(module, imports, compiled_sources, restore_state)
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
        total_instructions = 0, -- accumulates across ALL run() calls (incl. nested)
    }

    if restore_state then
        -- Restore mode: use saved memory/globals/tables from storage
        instance.memory = Memory.wrap(
            restore_state.memory_data,
            restore_state.memory_pages,
            restore_state.memory_max_pages
        )
        instance.globals = restore_state.globals
        instance.tables = restore_state.tables
        instance.table_sizes = restore_state.table_sizes
        instance.data_segments_raw = restore_state.dropped_data_segs or {}
        instance.element_segments_raw = restore_state.dropped_elem_segs or {}
        instance.total_instructions = restore_state.total_instructions or 0
    else
        -- Normal mode: allocate fresh memory
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
    end

    -- Initialize tags (imported + module-defined)
    instance.tags = {} -- 0-indexed
    local tag_idx = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == WasmParser.EXT_TAG then
            instance.tags[tag_idx] = {type_idx = imp.desc.type_idx}
            tag_idx = tag_idx + 1
        end
    end
    for _, tag in ipairs(module.tags) do
        instance.tags[tag_idx] = {type_idx = tag.type_idx}
        tag_idx = tag_idx + 1
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

    if not restore_state then
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

    -- Pre-compute block maps for O(1) branching
    for idx, func_def in pairs(module.funcs) do
        if type(idx) == "number" and not func_def.import and func_def.code then
            func_def.code.block_map = build_block_map(func_def.code.code)
        end
    end

    -- Load compiled functions (AOT or JIT)
    if Interp.use_compiler then
        local compiled = {}
        local count = 0

        -- Try AOT-compiled sources first (from build step)
        local aot_sources = compiled_sources
        if aot_sources then
            for idx, source in pairs(aot_sources) do
                local fn = Compiler.load_source(source, idx)
                if fn then
                    compiled[idx] = fn
                    count = count + 1
                end
            end
        else
            -- Fall back to JIT compilation
            compiled = Compiler.compile_module(module, instance)
            for _ in pairs(compiled) do count = count + 1 end
        end

        instance.compiled_funcs = compiled
    end

    instance.ctx = create_ctx(instance)

    -- Save/restore for reentrant WASM calls (e.g. describe_pos)
    function instance:save_state()
        return {
            exec = self.exec,
            sp = self.globals[0],
            sbs = self.ctx and self.ctx.__sbs,
        }
    end
    function instance:restore_state(saved)
        self.exec = saved.exec
        self.globals[0] = saved.sp
        if self.ctx then self.ctx.__sbs = saved.sbs end
    end

    -- Run start function if present (skip on restore — already ran)
    if not restore_state and module.start_func then
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
-- Exec state snapshot (for Factorio save/load)
-- Creates a serializable copy of execution state, stripping non-serializable
-- references (code, block_map, memory, globals, instance, module).
---------------------------------------------------------------------------

function Interp.snapshot_exec(instance)
    if not instance or not instance.exec then return nil end
    local exec = instance.exec
    local s = exec.state

    local snap = {
        func_idx = exec.func_idx,
        pc = s.pc,
        sp = s.sp,
        locals = s.locals,
        block_sp = s.block_sp,
        running = s.running,
        exception = s.exception,
        call_sp = exec.call_sp,
        waiting_input = exec.waiting_input,
        blocking_return_arity = exec.blocking_return_arity,
        finished = exec.finished,
        compiled_entry_point = exec.compiled_entry_point,
    }

    -- Copy stack (1-indexed, up to sp)
    local stack_copy = {}
    for i = 1, s.sp do stack_copy[i] = s.stack[i] end
    snap.stack = stack_copy

    -- Copy block_stack (1-indexed, up to block_sp)
    local bs_copy = {}
    for i = 1, s.block_sp do bs_copy[i] = s.block_stack[i] end
    snap.block_stack = bs_copy

    -- Copy call stack frames (strip code/block_map, keep func_idx)
    local frames = {}
    for i = 1, exec.call_sp do
        local f = exec.call_stack[i]
        frames[i] = {
            func_idx = f.func_idx,
            pc = f.pc,
            locals = f.locals,
            block_stack = f.block_stack,
            block_sp = f.block_sp,
            stack_base = f.stack_base,
            return_arity = f.return_arity,
            compiled_resume = f.compiled_resume,
            __sbs = f.__sbs,
        }
    end
    snap.frames = frames

    snap.ctx_sbs = instance.ctx and instance.ctx.__sbs
    snap.total_instructions = instance.total_instructions

    return snap
end

---------------------------------------------------------------------------
-- Exec state restoration (for Factorio save/load)
-- Reconstructs execution state from a snapshot, re-linking code/block_map
-- references from the re-parsed module.
---------------------------------------------------------------------------

function Interp.restore_exec(instance, snapshot)
    if not snapshot then return end
    local module = instance.module

    -- Get current function's code/block_map
    local func_def = module.funcs[snapshot.func_idx]
    local state = {
        stack = snapshot.stack,
        sp = snapshot.sp,
        locals = snapshot.locals,
        memory = instance.memory,
        globals = instance.globals,
        instance = instance,
        module = module,
        pc = snapshot.pc,
        code = func_def.code.code,
        block_map = func_def.code.block_map,
        block_stack = snapshot.block_stack,
        block_sp = snapshot.block_sp,
        running = snapshot.running,
        do_return = false,
        call_func = nil,
        exception = snapshot.exception,
    }

    -- Rebuild call stack frames with code/block_map references
    local call_stack = {}
    for i = 1, snapshot.call_sp do
        local sf = snapshot.frames[i]
        local frame_func = module.funcs[sf.func_idx]
        call_stack[i] = {
            locals = sf.locals,
            pc = sf.pc,
            code = frame_func.code.code,
            block_map = frame_func.code.block_map,
            block_stack = sf.block_stack,
            block_sp = sf.block_sp,
            stack_base = sf.stack_base,
            return_arity = sf.return_arity,
            func_idx = sf.func_idx,
            compiled_resume = sf.compiled_resume,
            __sbs = sf.__sbs,
        }
    end

    -- Determine top-level function type (original function passed to Interp.call)
    local top_func_idx = snapshot.call_sp > 0
        and snapshot.frames[1].func_idx
        or snapshot.func_idx
    local top_func_def = module.funcs[top_func_idx]
    local top_type_info = module.types[top_func_def.type_idx + 1]

    instance.exec = {
        state = state,
        call_stack = call_stack,
        call_sp = snapshot.call_sp,
        func_idx = snapshot.func_idx,
        top_type_info = top_type_info,
        waiting_input = snapshot.waiting_input,
        blocking_return_arity = snapshot.blocking_return_arity,
        finished = snapshot.finished,
        compiled_entry_point = snapshot.compiled_entry_point,
    }

    instance.total_instructions = snapshot.total_instructions or 0

    -- Restore ctx.__sbs for compiled code
    if instance.ctx and snapshot.ctx_sbs ~= nil then
        instance.ctx.__sbs = snapshot.ctx_sbs
    end
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
        block_map = (not func_def.import and func_def.code) and func_def.code.block_map or {},
        block_stack = block_stack,
        block_sp = 1,
        running = true,
        do_return = false,
        call_func = nil,
    }

    -- Function-level block (block_pc not needed - function-level exit uses running=false)
    block_stack[1] = {
        opcode = 0x02,
        arity = #type_info.results,
        stack_height = 0,
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
    local instructions = 0

    -- Debug counters (upvalues so they survive pcall)
    local dbg_segments = 0
    local dbg_calls = 0
    local dbg_interp_instrs = 0

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
        local block_map = state.block_map
        local globals = state.globals
        local running = true
        local max_instr = max_instructions or 50000
        -- Cache bit32 functions as locals
        local bit32_band = bit32_band
        local bit32_bor = bit32_bor
        local bit32_bxor = bit32_bxor
        local bit32_lshift = bit32_lshift
        local bit32_rshift = bit32_rshift
        local bit32_arshift = bit32_arshift
        local bit32_btest = bit32_btest

        -- Compiled function state
        local compiled_funcs = instance.compiled_funcs
        local ctx = instance.ctx
        local entry_point = exec.compiled_entry_point or 0
        exec.compiled_entry_point = nil

        while true do
            -- Check if current function has a compiled version
            -- Skip compiled path if mid-interpretation (pc > 1 with no compiled resume)
            -- to avoid restarting from the beginning with corrupted locals/stack
            local compiled_fn = compiled_funcs and compiled_funcs[func_idx]
            if compiled_fn and (entry_point > 0 or pc <= 1) then
                -- === Compiled function execution ===
                while true do
                    -- Rough instruction cost per segment (~50 instrs between calls)
                    instructions = instructions + 50
                    dbg_segments = dbg_segments + 1
                    if instructions >= max_instr then
                        state.sp = sp; state.pc = pc; state.locals = loc
                        state.code = code; state.block_stack = block_stack
                        state.block_sp = block_sp; state.block_map = block_map
                        state.memory = memory; state.globals = globals
                        state.running = true
                        exec.call_stack = call_stack
                        exec.call_sp = call_sp; exec.func_idx = func_idx
                        exec.compiled_entry_point = entry_point
                        return
                    end

                    sp = compiled_fn(stack, sp, loc, memory, globals, ctx, entry_point)
                    entry_point = 0

                    local target = ctx.call_target
                    if target == nil then
                        -- Function completed normally
                        running = false
                        break
                    end

                    -- Resolve call_indirect target
                    local target_idx
                    if target == -2 then
                        local type_idx = ctx.call_indirect_type
                        local table_idx = ctx.call_indirect_table
                        local elem_idx = stack[sp]; sp = sp - 1
                        local tbl = instance.tables[table_idx]
                        local tbl_size = instance.table_sizes[table_idx] or 0
                        if elem_idx < 0 or elem_idx >= tbl_size then
                            fail("undefined element")
                        end
                        target_idx = tbl[elem_idx]
                        if target_idx == nil then
                            fail("uninitialized element " .. tostring(elem_idx))
                        end
                        local target_def_ci = module.funcs[target_idx]
                        if not target_def_ci then fail("Unknown function index") end
                        if target_def_ci.type_idx ~= type_idx then
                            -- Structural type check
                            local expected = module.types[type_idx + 1]
                            local actual = module.types[target_def_ci.type_idx + 1]
                            if not expected or not actual
                                or #expected.params ~= #actual.params
                                or #expected.results ~= #actual.results then
                                fail("indirect call type mismatch")
                            end
                            for ci = 1, #expected.params do
                                if expected.params[ci] ~= actual.params[ci] then
                                    fail("indirect call type mismatch")
                                end
                            end
                            for ci = 1, #expected.results do
                                if expected.results[ci] ~= actual.results[ci] then
                                    fail("indirect call type mismatch")
                                end
                            end
                        end
                    elseif target == -3 then
                        -- throw: create exception and propagate
                        local tagidx = ctx.throw_tag
                        local tag_info = instance.tags[tagidx]
                        local tag_type = module.types[tag_info.type_idx + 1]
                        local nargs = #tag_type.params
                        local values = {}
                        for i = nargs, 1, -1 do
                            values[i] = stack[sp]; sp = sp - 1
                        end
                        state.exception = {tag = tagidx, values = values}
                        running = false
                        break
                    elseif target == -4 then
                        -- throw_ref: re-throw exception from stack
                        local exnref = stack[sp]; sp = sp - 1
                        if type(exnref) ~= "table" or exnref.tag == nil then
                            fail("throw_ref: invalid exnref")
                        end
                        state.exception = exnref
                        running = false
                        break
                    else
                        target_idx = target
                    end

                    dbg_calls = dbg_calls + 1
                    -- Handle the call (common path for direct and indirect)
                    local target_def = module.funcs[target_idx]
                    if not target_def then
                        fail("Unknown function index: " .. tostring(target_idx))
                    end
                    local target_type = module.types[target_def.type_idx + 1]
                    local num_params = #target_type.params

                    if target_def.import then
                        local import_fn = instance.import_funcs[target_idx]
                        if not import_fn then
                            fail(string.format("Unresolved import: %s.%s",
                                target_def.module, target_def.name))
                        end

                        if type(import_fn) == "table" and import_fn.blocking then
                            local args_start = sp - num_params + 1
                            state.sp = sp - num_params; state.locals = loc
                            state.memory = memory; state.globals = globals
                            local handler_result = import_fn.handler(unpack(stack, args_start, sp))
                            sp = sp - num_params
                            exec.waiting_input = true
                            exec.blocking_return_arity = #target_type.results
                            exec.state = state; exec.call_stack = call_stack
                            exec.call_sp = call_sp; exec.func_idx = func_idx
                            exec.compiled_entry_point = ctx.resume_point
                            exec._blocking_result = handler_result
                            return
                        end

                        local args_start = sp - num_params + 1
                        local result = import_fn(unpack(stack, args_start, sp))
                        sp = sp - num_params
                        if #target_type.results > 0 and result ~= nil then
                            sp = sp + 1; stack[sp] = result
                        end
                        mem_len = memory.byte_length
                        -- Continue compiled loop at resume point
                        entry_point = ctx.resume_point
                    else
                        -- WASM-to-WASM call: push frame, set up callee
                        local args_base = sp - num_params
                        call_sp = call_sp + 1
                        if call_sp > 1000 then fail("call stack exhaustion") end
                        local frame = call_stack[call_sp]
                        if not frame then frame = {}; call_stack[call_sp] = frame end
                        frame.locals = loc; frame.pc = pc; frame.code = code
                        frame.block_stack = block_stack; frame.block_sp = block_sp
                        frame.block_map = block_map; frame.stack_base = args_base
                        frame.return_arity = #target_type.results
                        frame.func_idx = func_idx
                        frame.compiled_resume = ctx.resume_point
                        frame.__sbs = ctx.__sbs

                        func_idx = target_idx
                        loc = {}
                        for i = 0, num_params - 1 do
                            loc[i] = stack[args_base + 1 + i]
                        end
                        sp = args_base
                        local new_local_offset = num_params
                        for _, decl in ipairs(target_def.code.locals) do
                            local def_val = default_value(decl.type)
                            for _ = 1, decl.count do
                                loc[new_local_offset] = def_val
                                new_local_offset = new_local_offset + 1
                            end
                        end

                        entry_point = 0
                        pc = 1
                        code = target_def.code.code
                        block_map = target_def.code.block_map
                        block_stack = {}
                        block_sp = 1
                        block_stack[1] = {
                            opcode = 0x02,
                            arity = #target_type.results,
                            stack_height = sp,
                        }
                        running = true
                        break  -- Exit compiled loop, re-enter outer loop for callee
                    end
                end -- compiled inner loop
            else
            -- Inner execution loop with inlined hot opcodes
            while running do
                if instructions >= max_instr then
                    -- Save state before exiting
                    state.sp = sp; state.pc = pc; state.locals = loc
                    state.code = code; state.block_stack = block_stack
                    state.block_sp = block_sp; state.block_map = block_map
                    state.memory = memory; state.globals = globals
                    exec.call_stack = call_stack
                    exec.call_sp = call_sp; exec.func_idx = func_idx
                    return
                end

                local op = code[pc]
                pc = pc + 1
                instructions = instructions + 1
                dbg_interp_instrs = dbg_interp_instrs + 1

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
                        -- Inlined do_branch using cached locals (no flush/refresh)
                        local target_idx = block_sp - depth
                        local target_block = block_stack[target_idx]
                        local arity = target_block.arity
                        if target_block.opcode == 0x03 then
                            -- Loop: branch to start
                            if arity > 0 then
                                local base = target_block.stack_height
                                for i = arity - 1, 0, -1 do
                                    stack[base + 1 + i] = stack[sp - (arity - 1 - i)]
                                end
                                sp = base + arity
                            else
                                sp = target_block.stack_height
                            end
                            block_sp = target_idx
                            pc = target_block.continuation_pc
                        else
                            -- Block/if/try_table: branch to end
                            if arity > 0 then
                                local base = target_block.stack_height
                                for i = arity - 1, 0, -1 do
                                    stack[base + 1 + i] = stack[sp - (arity - 1 - i)]
                                end
                                sp = base + arity
                            else
                                sp = target_block.stack_height
                            end
                            block_sp = target_idx - 1
                            if block_sp <= 0 then
                                running = false
                            else
                                pc = block_map[target_block.block_pc].end_pc
                            end
                        end
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
                            block_pc = pc - 2, -- position of 0x02 byte
                        }
                    else
                        -- Non-void blocktype: dispatch
                        state.sp = sp; state.pc = pc; state.locals = loc
                        state.code = code; state.block_stack = block_stack
                        state.block_sp = block_sp; state.block_map = block_map
                        dispatch[0x02](state)
                        sp = state.sp; pc = state.pc
                        block_stack = state.block_stack; block_sp = state.block_sp
                    end

                elseif op == 0x04 then -- if
                    local opcode_pc = pc - 1
                    local bt = code[pc]
                    if bt == 0x40 then
                        -- Void if (most common)
                        pc = pc + 1
                        local cond = stack[sp]; sp = sp - 1
                        if cond ~= 0 then
                            -- True: execute then branch
                            block_sp = block_sp + 1
                            block_stack[block_sp] = {
                                opcode = 0x04,
                                arity = 0,
                                stack_height = sp,
                                block_pc = opcode_pc,
                            }
                        else
                            -- False: use block_map to skip
                            local info = block_map[opcode_pc]
                            if info.else_pc then
                                -- Has else branch
                                block_sp = block_sp + 1
                                block_stack[block_sp] = {
                                    opcode = 0x04,
                                    arity = 0,
                                    stack_height = sp,
                                    block_pc = opcode_pc,
                                }
                                pc = info.else_pc
                            else
                                -- No else, skip entirely
                                pc = info.end_pc
                            end
                        end
                    else
                        -- Non-void: dispatch
                        state.sp = sp; state.pc = pc; state.locals = loc
                        state.code = code; state.block_stack = block_stack
                        state.block_sp = block_sp; state.block_map = block_map
                        dispatch[0x04](state)
                        sp = state.sp; pc = state.pc
                        block_stack = state.block_stack; block_sp = state.block_sp
                    end

                elseif op == 0x05 then -- else
                    -- Reached from then-branch: jump to end using block_map
                    local block = block_stack[block_sp]
                    pc = block_map[block.block_pc].end_pc
                    local n_results = block.result_arity or block.arity
                    block_sp = block_sp - 1
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

                    if target_def.import then
                        local import_fn = instance.import_funcs[target_idx]
                        if not import_fn then
                            fail(string.format("Unresolved import: %s.%s", target_def.module, target_def.name))
                        end

                        if type(import_fn) == "table" and import_fn.blocking then
                            local args_start = sp - num_params + 1
                            state.sp = sp - num_params; state.pc = pc; state.locals = loc
                            state.code = code; state.block_stack = block_stack
                            state.block_sp = block_sp; state.block_map = block_map
                            local handler_result = import_fn.handler(unpack(stack, args_start, sp))
                            sp = sp - num_params
                            exec.waiting_input = true
                            exec.blocking_return_arity = #target_type.results
                            exec.state = state; exec.call_stack = call_stack
                            exec.call_sp = call_sp; exec.func_idx = func_idx
                            exec._blocking_result = handler_result
                            return
                        end

                        local args_start = sp - num_params + 1
                        local result = import_fn(unpack(stack, args_start, sp))
                        sp = sp - num_params
                        if #target_type.results > 0 and result ~= nil then
                            sp = sp + 1; stack[sp] = result
                        end
                        mem_len = memory.byte_length
                    else
                        -- WASM-to-WASM call: read args directly from stack into locals
                        local args_base = sp - num_params
                        call_sp = call_sp + 1
                        if call_sp > 1000 then fail("call stack exhaustion") end
                        local frame = call_stack[call_sp]
                        if not frame then frame = {}; call_stack[call_sp] = frame end
                        frame.locals = loc; frame.pc = pc; frame.code = code
                        frame.block_stack = block_stack; frame.block_sp = block_sp
                        frame.block_map = block_map; frame.stack_base = args_base
                        frame.return_arity = #target_type.results
                        frame.func_idx = func_idx
                        frame.compiled_resume = nil
                        frame.__sbs = ctx.__sbs

                        func_idx = target_idx
                        loc = {}
                        for i = 0, num_params - 1 do
                            loc[i] = stack[args_base + 1 + i]
                        end
                        sp = args_base
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
                        block_map = target_def.code.block_map
                        block_stack = {}
                        block_sp = 1
                        block_stack[1] = {
                            opcode = 0x02,
                            arity = #target_type.results,
                            stack_height = sp,
                        }
                        entry_point = 0
                        break -- exit inner loop to check compiled version
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
                    state.code = code; state.block_stack = block_stack
                    state.block_sp = block_sp; state.block_map = block_map
                    local handler = dispatch[op]
                    if not handler then
                        fail(string.format("Unknown opcode: 0x%02X at pc=%d in func %d", op, pc - 1, func_idx))
                    end
                    handler(state)
                    -- Refresh all cached locals from state
                    sp = state.sp; pc = state.pc; loc = state.locals
                    code = state.code; block_stack = state.block_stack
                    block_sp = state.block_sp; block_map = state.block_map
                    running = state.running
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

                        local args_base = sp - num_params

                        if target_def.import then
                            local import_fn = instance.import_funcs[target_idx]
                            if not import_fn then
                                fail(string.format("Unresolved import: %s.%s", target_def.module, target_def.name))
                            end

                            local args_start = args_base + 1
                            if type(import_fn) == "table" and import_fn.blocking then
                                sp = args_base
                                state.sp = sp; state.pc = pc; state.locals = loc
                                state.code = code; state.block_stack = block_stack
                                state.block_sp = block_sp; state.block_map = block_map
                                local handler_result = import_fn.handler(unpack(stack, args_start, args_start + num_params - 1))
                                exec.waiting_input = true
                                exec.blocking_return_arity = #target_type.results
                                exec.state = state; exec.call_stack = call_stack
                                exec.call_sp = call_sp; exec.func_idx = func_idx
                                exec._blocking_result = handler_result
                                return
                            end

                            local result = import_fn(unpack(stack, args_start, args_start + num_params - 1))
                            sp = args_base
                            if #target_type.results > 0 and result ~= nil then
                                sp = sp + 1; stack[sp] = result
                            end
                            mem_len = memory.byte_length
                        else
                            call_sp = call_sp + 1
                            if call_sp > 1000 then fail("call stack exhaustion") end
                            local frame = call_stack[call_sp]
                            if not frame then frame = {}; call_stack[call_sp] = frame end
                            frame.locals = loc; frame.pc = pc; frame.code = code
                            frame.block_stack = block_stack; frame.block_sp = block_sp
                            frame.block_map = block_map; frame.stack_base = args_base
                            frame.return_arity = #target_type.results
                            frame.func_idx = func_idx
                            frame.compiled_resume = nil
                            frame.__sbs = ctx.__sbs

                            func_idx = target_idx
                            loc = {}
                            for i = 0, num_params - 1 do
                                loc[i] = stack[args_base + 1 + i]
                            end
                            sp = args_base
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
                            block_map = target_def.code.block_map
                            block_stack = {}
                            block_sp = 1
                            block_stack[1] = {
                                opcode = 0x02,
                                arity = #target_type.results,
                                stack_height = sp,
                            }
                            entry_point = 0
                            break -- exit inner loop to check compiled version
                        end
                    end
                end
            end -- while running
            end -- if compiled_fn then ... else

            -- If running is still true, a callee was set up — loop back
            -- to check if the callee has a compiled version
            if running then -- luacheck: ignore
                -- Continue outer while-true loop
            else
            -- Function ended (running became false)
            if state.exception then
                -- Exception propagation: unwind call frames until handled
                while call_sp > 0 do
                    local frame = call_stack[call_sp]
                    call_sp = call_sp - 1

                    -- Restore caller frame
                    state.sp = frame.stack_base
                    state.locals = frame.locals
                    state.pc = frame.pc
                    state.code = frame.code
                    state.block_stack = frame.block_stack
                    state.block_sp = frame.block_sp
                    state.block_map = frame.block_map
                    state.running = true
                    state.do_return = false
                    state.call_func = nil
                    func_idx = frame.func_idx
                    local f_compiled_resume_ex = frame.compiled_resume
                    local f_sbs_ex = frame.__sbs
                    -- Nil out large references for GC but keep the table
                    frame.locals = nil; frame.block_stack = nil
                    frame.code = nil; frame.block_map = nil; frame.__sbs = nil

                    -- Try to handle exception in this frame
                    if handle_exception(state, state.exception) then
                        state.exception = nil
                        -- Refresh cached locals from state
                        sp = state.sp; loc = state.locals; pc = state.pc
                        code = state.code; block_stack = state.block_stack
                        block_sp = state.block_sp; block_map = state.block_map
                        running = true
                        memory = state.memory; mem_data = memory.data
                        mem_len = memory.byte_length; globals = state.globals
                        entry_point = f_compiled_resume_ex or 0
                        ctx.__sbs = f_sbs_ex
                        break
                    end
                    -- Not handled, keep unwinding
                    state.running = false
                end

                if state.exception then
                    -- Unhandled exception at top level
                    exec.finished = true
                    exec.state = state
                    exec.call_sp = call_sp
                    exec.func_idx = func_idx
                    fail("unhandled exception (tag=" .. tostring(state.exception.tag) .. ")")
                end
            elseif call_sp > 0 then
                -- Restore caller frame (keep table for reuse)
                local frame = call_stack[call_sp]
                call_sp = call_sp - 1

                local return_arity = frame.return_arity
                local f_locals = frame.locals; local f_pc = frame.pc
                local f_code = frame.code; local f_block_stack = frame.block_stack
                local f_block_sp = frame.block_sp; local f_block_map = frame.block_map
                local f_func_idx = frame.func_idx
                local f_compiled_resume = frame.compiled_resume
                local f_sbs = frame.__sbs
                -- Nil out large references for GC but keep the table
                frame.locals = nil; frame.block_stack = nil; frame.code = nil
                frame.block_map = nil; frame.__sbs = nil

                if return_arity == 1 then
                    -- Single return (most common): no temp table needed
                    local result = stack[sp]
                    sp = frame.stack_base
                    loc = f_locals; pc = f_pc; code = f_code
                    block_stack = f_block_stack; block_sp = f_block_sp
                    block_map = f_block_map; func_idx = f_func_idx
                    running = true; state.running = true
                    entry_point = f_compiled_resume or 0
                    ctx.__sbs = f_sbs
                    mem_data = memory.data; mem_len = memory.byte_length
                    sp = sp + 1; stack[sp] = result
                elseif return_arity == 0 then
                    sp = frame.stack_base
                    loc = f_locals; pc = f_pc; code = f_code
                    block_stack = f_block_stack; block_sp = f_block_sp
                    block_map = f_block_map; func_idx = f_func_idx
                    running = true; state.running = true
                    entry_point = f_compiled_resume or 0
                    ctx.__sbs = f_sbs
                    mem_data = memory.data; mem_len = memory.byte_length
                else
                    -- Multi-return (rare)
                    local results = {}
                    for i = return_arity, 1, -1 do
                        results[i] = stack[sp]; sp = sp - 1
                    end
                    sp = frame.stack_base
                    loc = f_locals; pc = f_pc; code = f_code
                    block_stack = f_block_stack; block_sp = f_block_sp
                    block_map = f_block_map; func_idx = f_func_idx
                    running = true; state.running = true
                    entry_point = f_compiled_resume or 0
                    ctx.__sbs = f_sbs
                    mem_data = memory.data; mem_len = memory.byte_length
                    for i = 1, return_arity do
                        sp = sp + 1; stack[sp] = results[i]
                    end
                end
            else
                -- Top-level function returned
                state.sp = sp; state.pc = pc; state.locals = loc
                state.code = code; state.block_stack = block_stack
                state.block_sp = block_sp; state.block_map = block_map
                state.memory = memory; state.globals = globals
                exec.call_stack = call_stack
                exec.call_sp = call_sp; exec.func_idx = func_idx
                exec.finished = true
                return -- exits pcall
            end
            end -- if running then ... else (function ended)
        end -- while true
    end) -- pcall

    -- State was flushed inside pcall before each return point
    exec.state = state

    -- Accumulate instructions into instance-level counter
    instance.total_instructions = instance.total_instructions + instructions
    -- Debug: accumulate counters
    instance._dbg_segments = (instance._dbg_segments or 0) + dbg_segments
    instance._dbg_calls = (instance._dbg_calls or 0) + dbg_calls
    instance._dbg_interp_instrs = (instance._dbg_interp_instrs or 0) + dbg_interp_instrs

    if not ok then
        exec.finished = true
        -- WASI proc_exit throws {exit=true, status=N} — treat as clean finish
        if type(err) == "table" and err.exit then
            return {status = "finished", results = {}, exit_code = err.status}
        end
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
