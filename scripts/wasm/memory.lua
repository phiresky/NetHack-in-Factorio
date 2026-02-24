-- WASM Linear Memory implementation
-- Each table entry stores 4 bytes packed into a single Lua number
-- Uses bit32 for byte-level access

local bit32 = bit32

local Memory = {}
Memory.__index = Memory

local PAGE_SIZE = 65536
local MAX_PAGES = 256 -- 16MB max

function Memory.new(initial_pages)
    initial_pages = initial_pages or 64
    local self = setmetatable({}, Memory)
    self.page_count = initial_pages
    self.data = {}
    -- Pre-fill with zeros: each entry = 4 bytes, total entries = pages * 16384
    local total_entries = initial_pages * (PAGE_SIZE / 4)
    for i = 0, total_entries - 1 do
        self.data[i] = 0
    end
    return self
end

function Memory:size()
    return self.page_count
end

function Memory:grow(delta_pages)
    local old_pages = self.page_count
    local new_pages = old_pages + delta_pages
    if new_pages > MAX_PAGES then
        return 0xFFFFFFFF -- -1 as u32, failure
    end
    local old_entries = old_pages * (PAGE_SIZE / 4)
    local new_entries = new_pages * (PAGE_SIZE / 4)
    for i = old_entries, new_entries - 1 do
        self.data[i] = 0
    end
    self.page_count = new_pages
    return old_pages
end

function Memory:load_byte(addr)
    local word_idx = bit32.rshift(addr, 2)
    local byte_off = bit32.band(addr, 3)
    local word = self.data[word_idx] or 0
    return bit32.band(bit32.rshift(word, byte_off * 8), 0xFF)
end

function Memory:store_byte(addr, val)
    local word_idx = bit32.rshift(addr, 2)
    local byte_off = bit32.band(addr, 3)
    local shift = byte_off * 8
    local mask = bit32.bnot(bit32.lshift(0xFF, shift))
    local word = self.data[word_idx] or 0
    self.data[word_idx] = bit32.bor(bit32.band(word, mask), bit32.lshift(bit32.band(val, 0xFF), shift))
end

function Memory:load_i32(addr)
    local align = bit32.band(addr, 3)
    if align == 0 then
        -- Aligned access
        return self.data[bit32.rshift(addr, 2)] or 0
    end
    -- Unaligned: read byte by byte
    local b0 = self:load_byte(addr)
    local b1 = self:load_byte(addr + 1)
    local b2 = self:load_byte(addr + 2)
    local b3 = self:load_byte(addr + 3)
    return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function Memory:store_i32(addr, val)
    val = bit32.band(val, 0xFFFFFFFF)
    local align = bit32.band(addr, 3)
    if align == 0 then
        -- Aligned access
        self.data[bit32.rshift(addr, 2)] = val
        return
    end
    -- Unaligned: write byte by byte
    self:store_byte(addr, bit32.band(val, 0xFF))
    self:store_byte(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
    self:store_byte(addr + 2, bit32.band(bit32.rshift(val, 16), 0xFF))
    self:store_byte(addr + 3, bit32.band(bit32.rshift(val, 24), 0xFF))
end

function Memory:load_i16_u(addr)
    local b0 = self:load_byte(addr)
    local b1 = self:load_byte(addr + 1)
    return bit32.bor(b0, bit32.lshift(b1, 8))
end

function Memory:load_i16_s(addr)
    local val = self:load_i16_u(addr)
    if val >= 0x8000 then
        val = val - 0x10000
    end
    return val
end

function Memory:store_i16(addr, val)
    val = bit32.band(val, 0xFFFF)
    self:store_byte(addr, bit32.band(val, 0xFF))
    self:store_byte(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
end

function Memory:load_i8_u(addr)
    return self:load_byte(addr)
end

function Memory:load_i8_s(addr)
    local val = self:load_byte(addr)
    if val >= 0x80 then
        val = val - 0x100
    end
    return val
end

function Memory:store_i8(addr, val)
    self:store_byte(addr, bit32.band(val, 0xFF))
end

-- Load/store for i64 as {lo, hi} pair
function Memory:load_i64(addr)
    local lo = self:load_i32(addr)
    local hi = self:load_i32(addr + 4)
    return {lo, hi}
end

function Memory:store_i64(addr, val)
    if type(val) == "number" then
        -- Convert single number to lo/hi
        self:store_i32(addr, bit32.band(val, 0xFFFFFFFF))
        self:store_i32(addr + 4, 0)
    else
        self:store_i32(addr, val[1])
        self:store_i32(addr + 4, val[2])
    end
end

-- f64: use Lua string packing to convert double to 8 bytes and back
-- Factorio Lua 5.2 has string.pack/unpack? No, that's 5.3.
-- We use math tricks instead.

local math_frexp = math.frexp
local math_ldexp = math.ldexp
local math_floor = math.floor
local math_abs = math.abs
local math_huge = math.huge

-- Store a Lua number (f64) into memory as IEEE 754 double
function Memory:store_f64(addr, val)
    local lo, hi
    if val == 0 then
        if 1 / val < 0 then -- negative zero
            lo, hi = 0, 0x80000000
        else
            lo, hi = 0, 0
        end
    elseif val ~= val then -- NaN
        lo, hi = 0, 0x7FF80000
    elseif val == math_huge then
        lo, hi = 0, 0x7FF00000
    elseif val == -math_huge then
        lo, hi = 0, 0xFFF00000
    else
        local sign = 0
        if val < 0 then
            sign = 0x80000000
            val = -val
        end
        local mant, exp = math_frexp(val)
        exp = exp + 1022
        if exp <= 0 then
            -- Denormalized
            mant = mant * math_ldexp(1, exp + 51)
            exp = 0
        else
            mant = (mant * 2 - 1) * math_ldexp(1, 52)
        end
        -- Extract lo/hi using float math (bit32 only handles 32-bit)
        local mant_hi = math_floor(mant / 4294967296)
        lo = mant - mant_hi * 4294967296
        hi = bit32.bor(sign, bit32.lshift(bit32.band(exp, 0x7FF), 20), bit32.band(mant_hi, 0xFFFFF))
    end
    self:store_i32(addr, lo)
    self:store_i32(addr + 4, hi)
end

-- Load a Lua number (f64) from memory as IEEE 754 double
function Memory:load_f64(addr)
    local lo = self:load_i32(addr)
    local hi = self:load_i32(addr + 4)
    local sign = bit32.btest(hi, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(hi, 20), 0x7FF)
    local mant_hi = bit32.band(hi, 0xFFFFF)
    local mant = mant_hi * 4294967296 + lo
    if exp == 0x7FF then
        if mant == 0 then
            return sign * math_huge
        else
            return 0 / 0 -- NaN
        end
    elseif exp == 0 then
        if mant == 0 then
            return sign == -1 and -0.0 or 0.0
        end
        -- Denormalized
        return sign * math_ldexp(mant, -1074)
    else
        return sign * math_ldexp(mant + 4503599627370496, exp - 1075) -- 4503599627370496 = 2^52
    end
end

-- f32 store/load using IEEE 754 single precision
function Memory:store_f32(addr, val)
    local bits
    if val == 0 then
        if 1 / val < 0 then
            bits = 0x80000000
        else
            bits = 0
        end
    elseif val ~= val then
        bits = 0x7FC00000
    elseif val == math_huge then
        bits = 0x7F800000
    elseif val == -math_huge then
        bits = 0xFF800000
    else
        local sign = 0
        if val < 0 then
            sign = 0x80000000
            val = -val
        end
        local mant, exp = math_frexp(val)
        exp = exp + 126
        if exp <= 0 then
            mant = mant * math_ldexp(1, exp + 22)
            exp = 0
        else
            mant = (mant * 2 - 1) * math_ldexp(1, 23)
        end
        bits = bit32.bor(sign, bit32.lshift(bit32.band(exp, 0xFF), 23), bit32.band(math_floor(mant), 0x7FFFFF))
    end
    self:store_i32(addr, bits)
end

function Memory:load_f32(addr)
    local bits = self:load_i32(addr)
    local sign = bit32.btest(bits, 0x80000000) and -1 or 1
    local exp = bit32.band(bit32.rshift(bits, 23), 0xFF)
    local mant = bit32.band(bits, 0x7FFFFF)
    if exp == 0xFF then
        if mant == 0 then
            return sign * math_huge
        else
            return 0 / 0
        end
    elseif exp == 0 then
        if mant == 0 then
            return sign == -1 and -0.0 or 0.0
        end
        return sign * math_ldexp(mant, -149)
    else
        return sign * math_ldexp(mant + 8388608, exp - 150) -- 8388608 = 2^23
    end
end

-- Bulk copy from a byte string into memory
function Memory:write_bytes(addr, bytes)
    for i = 1, #bytes do
        self:store_byte(addr + i - 1, string.byte(bytes, i))
    end
end

-- Read bytes from memory into a string
function Memory:read_bytes(addr, len)
    local t = {}
    for i = 0, len - 1 do
        t[i + 1] = string.char(self:load_byte(addr + i))
    end
    return table.concat(t)
end

return Memory
