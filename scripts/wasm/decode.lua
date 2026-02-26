-- Shared positional LEB128 decoders for WASM bytecode arrays.
-- All functions take (code, pos) and return (value, new_pos).
-- Used by compiler.lua and opcodes.lua (build_block_map / skip_operands_at).

local bit32 = bit32

local Decode = {}

-- Skip past a single LEB128 value without decoding it.
function Decode.skip_leb128(code, pos)
    while code[pos] >= 128 do pos = pos + 1 end
    return pos + 1
end

-- Read unsigned LEB128 from byte array at position pos.
function Decode.leb128_u(code, pos)
    local result = 0
    local shift = 0
    while true do
        local b = code[pos]
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        if b < 128 then return result, pos end
        shift = shift + 7
    end
end

-- Read signed LEB128 (i32) from byte array.
function Decode.leb128_s(code, pos)
    local result = 0
    local shift = 0
    local b
    while true do
        b = code[pos]
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then break end
    end
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    if bit32.btest(result, 0x80000000) then
        return result - 0x100000000, pos
    end
    return result, pos
end

-- Read signed LEB128 i64, returns {lo, hi}, new_pos.
function Decode.leb128_s64(code, pos)
    local lo = 0
    local hi = 0
    local shift = 0
    local b
    while true do
        b = code[pos]
        pos = pos + 1
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
        if bit32.band(b, 0x80) == 0 then break end
    end
    if bit32.btest(b, 0x40) then
        if shift < 32 then
            lo = bit32.bor(lo, bit32.lshift(0xFFFFFFFF, shift))
            hi = 0xFFFFFFFF
        elseif shift < 64 then
            hi = bit32.bor(hi, bit32.lshift(0xFFFFFFFF, shift - 32))
        end
    end
    return {lo, hi}, pos
end

return Decode
