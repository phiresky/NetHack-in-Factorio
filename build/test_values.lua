-- Spec test value conversion helpers
-- Converts between wast2json string representations and Lua WASM interpreter values.

local bit32 = bit32
local Opcodes = require("scripts.wasm.opcodes")
local nan_mt = Opcodes.nan_mt

local M = {}

local NAN = 0/0

-- Convert string decimal to unsigned 32-bit number
function M.str_to_u32(s)
    local n = tonumber(s)
    if not n then return 0 end
    if n < 0 then n = n + 4294967296 end
    return n % 4294967296
end

-- Convert string decimal to i64 {lo, hi} pair
-- Uses string-based long division for values that exceed double precision
function M.str_to_i64(s)
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
function M.bits_to_f32(s)
    local bits = M.str_to_u32(s)
    if bits == 0 then return 0.0 end
    if bits == 0x80000000 then return -0.0 end
    local sign = bit32.btest(bits, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(bits, 23), 0xFF)
    local mant = bit32.band(bits, 0x7FFFFF)
    if exp == 0xFF then
        if mant == 0 then return sign * math.huge end
        return setmetatable({nan32 = bits}, nan_mt) -- boxed NaN preserves bit pattern
    elseif exp == 0 then
        return sign * math.ldexp(mant, -149) -- denormal
    end
    return sign * math.ldexp(mant + 0x800000, exp - 150)
end

-- Convert bit pattern string to f64 value
-- The bit pattern is a decimal string representing a 64-bit unsigned integer
function M.bits_to_f64(s)
    if not s or s == "" then return 0.0 end
    -- Use str_to_i64 to accurately parse the 64-bit bit pattern
    local pair = M.str_to_i64(s)
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
        return setmetatable({nan64 = {lo, hi}}, nan_mt) -- boxed NaN preserves bit pattern
    elseif exp == 0 then
        if mant == 0 then return 0.0 * sign end
        return sign * math.ldexp(mant, -1074)
    end
    return sign * math.ldexp(mant + 4503599627370496, exp - 1075)
end

-- Convert f64 value back to bit pattern (for comparison)
function M.f64_to_bits(v)
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
function M.convert_arg(arg)
    if arg.type == "i32" then
        return M.str_to_u32(arg.value)
    elseif arg.type == "i64" then
        return M.str_to_i64(arg.value)
    elseif arg.type == "f32" then
        return M.bits_to_f32(arg.value)
    elseif arg.type == "f64" then
        return M.bits_to_f64(arg.value)
    end
    return tonumber(arg.value) or 0
end

-- Check if a result value is NaN (either Lua NaN or boxed NaN from interpreter)
function M.is_nan_value(v)
    if type(v) == "number" then return v ~= v end
    if type(v) == "table" then return v.nan32 ~= nil or v.nan64 ~= nil end
    return false
end

-- Compare a result value against expected
function M.compare_result(got, expected)
    if not expected then return true end -- no expected value

    local etype = expected.type
    local evalue = expected.value

    -- Handle NaN expectations
    if evalue == "nan:canonical" or evalue == "nan:arithmetic" then
        return M.is_nan_value(got)
    end

    if etype == "i32" then
        local exp_val = M.str_to_u32(evalue)
        if type(got) ~= "number" then return false end
        return bit32.band(got, 0xFFFFFFFF) == exp_val
    elseif etype == "i64" then
        local exp_pair = M.str_to_i64(evalue)
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
            exp_val = M.bits_to_f32(evalue)
        else
            exp_val = M.bits_to_f64(evalue)
        end
        -- Handle NaN: both got and expected can be boxed NaN tables
        if M.is_nan_value(got) then
            return M.is_nan_value(exp_val)
        end
        if type(got) ~= "number" then return false end
        if M.is_nan_value(exp_val) then return false end -- expected NaN but got isn't
        -- Exact comparison (including +0 vs -0)
        if exp_val == 0 and got == 0 then
            return (1/exp_val > 0) == (1/got > 0)
        end
        return got == exp_val
    end
    return false
end

return M
