-- WASM Binary Parser
-- Parses a WASM binary (as a Lua string of bytes) into a module object

local bit32 = bit32

local Parser = {}
Parser.__index = Parser

local function fail(msg) error({msg = msg}) end

-- Section IDs
local SECTION_TYPE     = 1
local SECTION_IMPORT   = 2
local SECTION_FUNCTION = 3
local SECTION_TABLE    = 4
local SECTION_MEMORY   = 5
local SECTION_GLOBAL   = 6
local SECTION_EXPORT   = 7
local SECTION_START    = 8
local SECTION_ELEMENT  = 9
local SECTION_CODE     = 10
local SECTION_DATA     = 11

-- Type constants
local TYPE_I32    = 0x7F
local TYPE_I64    = 0x7E
local TYPE_F32    = 0x7D
local TYPE_F64    = 0x7C
local TYPE_FUNCREF = 0x70

-- External kind
local EXT_FUNC   = 0
local EXT_TABLE  = 1
local EXT_MEMORY = 2
local EXT_GLOBAL = 3

local function new_parser(bytes)
    return setmetatable({
        bytes = bytes,
        pos = 1,
        len = #bytes,
    }, Parser)
end

function Parser:read_byte()
    local b = string.byte(self.bytes, self.pos)
    self.pos = self.pos + 1
    return b
end

function Parser:read_bytes(n)
    local s = string.sub(self.bytes, self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return s
end

function Parser:read_u32_raw()
    local b0 = string.byte(self.bytes, self.pos)
    local b1 = string.byte(self.bytes, self.pos + 1)
    local b2 = string.byte(self.bytes, self.pos + 2)
    local b3 = string.byte(self.bytes, self.pos + 3)
    self.pos = self.pos + 4
    return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

-- LEB128 unsigned
function Parser:read_leb128_u()
    local result = 0
    local shift = 0
    while true do
        local b = self:read_byte()
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        if bit32.band(b, 0x80) == 0 then
            break
        end
        shift = shift + 7
    end
    return result
end

-- LEB128 signed (returns i32 range)
function Parser:read_leb128_s()
    local result = 0
    local shift = 0
    local b
    while true do
        b = self:read_byte()
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then
            break
        end
    end
    -- Sign extend
    if shift < 32 and bit32.btest(b, 0x40) then
        result = bit32.bor(result, bit32.lshift(-1, shift))
    end
    -- Convert to signed
    if bit32.btest(result, 0x80000000) then
        return result - 0x100000000
    end
    return result
end

-- LEB128 signed 64-bit: returns {lo, hi} pair
function Parser:read_leb128_s64()
    local lo = 0
    local hi = 0
    local shift = 0
    local b
    while true do
        b = self:read_byte()
        local val = bit32.band(b, 0x7F)
        if shift < 32 then
            lo = bit32.bor(lo, bit32.lshift(val, shift))
            if shift + 7 > 32 then
                -- Some bits spill into hi
                hi = bit32.bor(hi, bit32.rshift(val, 32 - shift))
            end
        else
            hi = bit32.bor(hi, bit32.lshift(val, shift - 32))
        end
        shift = shift + 7
        if bit32.band(b, 0x80) == 0 then
            break
        end
    end
    -- Sign extend
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

function Parser:read_name()
    local len = self:read_leb128_u()
    return self:read_bytes(len)
end

-- Read a value type byte
function Parser:read_valtype()
    return self:read_byte()
end

-- Read a block type: either 0x40 (void) or a valtype
function Parser:read_blocktype()
    local b = self:read_byte()
    if b == 0x40 then
        return nil -- void
    end
    return b
end

-- Read limits: flags + initial [+ maximum]
function Parser:read_limits()
    local flags = self:read_leb128_u()
    local initial = self:read_leb128_u()
    local maximum = nil
    if bit32.band(flags, 1) ~= 0 then
        maximum = self:read_leb128_u()
    end
    return {initial = initial, maximum = maximum}
end

-- Skip forward until 0x0B (end marker) is found
function Parser:skip_to_end()
    while self.pos <= self.len do
        if self:read_byte() == 0x0B then return end
    end
end

-- Parse an init expression (constant expression)
-- Returns the value (for i32.const, i64.const, f64.const, f32.const, global.get)
-- For unrecognized expressions, returns a sentinel so validation can report type mismatch.
function Parser:read_init_expr()
    local opcode = self:read_byte()
    local val
    if opcode == 0x41 then -- i32.const
        val = self:read_leb128_s()
        if val < 0 then val = val + 0x100000000 end -- store as unsigned
    elseif opcode == 0x42 then -- i64.const
        val = self:read_leb128_s64()
    elseif opcode == 0x43 then -- f32.const
        val = self:read_bytes(4) -- keep raw, decode later
    elseif opcode == 0x44 then -- f64.const
        val = self:read_bytes(8)
    elseif opcode == 0x23 then -- global.get
        val = {global_idx = self:read_leb128_u()}
    elseif opcode == 0x0B then
        -- Empty init expression (just end marker) - valid syntax, wrong type
        return {invalid_expr = "type"}, opcode
    elseif opcode == 0xD0 or opcode == 0xD2 then
        -- ref.null / ref.func - valid const expr, but produces ref type
        self:skip_to_end()
        return {invalid_expr = "type"}, opcode
    else
        -- Non-constant opcode (nop, arithmetic, etc.)
        self:skip_to_end()
        return {invalid_expr = "const"}, opcode
    end
    local end_byte = self:read_byte()
    if end_byte ~= 0x0B then
        -- Multi-instruction - check if next byte is a valid const opcode
        local next_op = end_byte
        local is_const = (next_op >= 0x41 and next_op <= 0x44) or next_op == 0x23
                      or next_op == 0xD0 or next_op == 0xD2
        self:skip_to_end()
        return {invalid_expr = is_const and "type" or "const"}, opcode
    end
    return val, opcode
end

-- Parse type section
function Parser:parse_type_section(size)
    local count = self:read_leb128_u()
    local types = {}
    for i = 1, count do
        local form = self:read_byte() -- should be 0x60
        if form ~= 0x60 then
            fail("Expected functype 0x60, got 0x" .. string.format("%02X", form))
        end
        local param_count = self:read_leb128_u()
        local params = {}
        for j = 1, param_count do
            params[j] = self:read_valtype()
        end
        local result_count = self:read_leb128_u()
        local results = {}
        for j = 1, result_count do
            results[j] = self:read_valtype()
        end
        types[i] = {params = params, results = results}
    end
    return types
end

-- Parse import section
function Parser:parse_import_section(size)
    local count = self:read_leb128_u()
    local imports = {}
    for i = 1, count do
        local mod = self:read_name()
        local name = self:read_name()
        local kind = self:read_byte()
        local desc
        if kind == EXT_FUNC then
            desc = {type_idx = self:read_leb128_u()}
        elseif kind == EXT_TABLE then
            local elem_type = self:read_byte()
            local limits = self:read_limits()
            desc = {elem_type = elem_type, limits = limits}
        elseif kind == EXT_MEMORY then
            desc = {limits = self:read_limits()}
        elseif kind == EXT_GLOBAL then
            local valtype = self:read_valtype()
            local mutability = self:read_byte()
            desc = {valtype = valtype, mutable = mutability == 1}
        else
            fail("Unknown import kind: " .. kind)
        end
        imports[i] = {module = mod, name = name, kind = kind, desc = desc}
    end
    return imports
end

-- Parse function section (just type indices)
function Parser:parse_function_section(size)
    local count = self:read_leb128_u()
    local type_indices = {}
    for i = 1, count do
        type_indices[i] = self:read_leb128_u()
    end
    return type_indices
end

-- Parse table section
function Parser:parse_table_section(size)
    local count = self:read_leb128_u()
    local tables = {}
    for i = 1, count do
        local elem_type = self:read_byte()
        local limits = self:read_limits()
        tables[i] = {elem_type = elem_type, limits = limits}
    end
    return tables
end

-- Parse memory section
function Parser:parse_memory_section(size)
    local count = self:read_leb128_u()
    local memories = {}
    for i = 1, count do
        memories[i] = self:read_limits()
    end
    return memories
end

-- Parse global section
function Parser:parse_global_section(size)
    local count = self:read_leb128_u()
    local globals = {}
    for i = 1, count do
        local valtype = self:read_valtype()
        local mutability = self:read_byte()
        local init_val, init_op = self:read_init_expr()
        globals[i] = {
            valtype = valtype,
            mutable = mutability == 1,
            init = init_val,
            init_opcode = init_op,
        }
    end
    return globals
end

-- Parse export section
function Parser:parse_export_section(size)
    local count = self:read_leb128_u()
    local exports = {}
    for i = 1, count do
        local name = self:read_name()
        local kind = self:read_byte()
        local index = self:read_leb128_u()
        exports[i] = {name = name, kind = kind, index = index}
    end
    return exports
end

-- Parse start section
function Parser:parse_start_section(size)
    return self:read_leb128_u()
end

-- Parse element section
function Parser:parse_element_section(size)
    local count = self:read_leb128_u()
    local elements = {}
    for i = 1, count do
        local table_idx = self:read_leb128_u()
        local offset_val, offset_op = self:read_init_expr()
        local num_elems = self:read_leb128_u()
        local func_indices = {}
        for j = 1, num_elems do
            func_indices[j] = self:read_leb128_u()
        end
        elements[i] = {
            table_idx = table_idx,
            offset = offset_val,
            offset_opcode = offset_op,
            func_indices = func_indices,
        }
    end
    return elements
end

-- Parse code section
function Parser:parse_code_section(size)
    local count = self:read_leb128_u()
    local bodies = {}
    for i = 1, count do
        local body_size = self:read_leb128_u()
        local body_start = self.pos
        -- Parse locals
        local local_decl_count = self:read_leb128_u()
        local locals = {}
        local total_locals = 0
        for j = 1, local_decl_count do
            local n = self:read_leb128_u()
            local t = self:read_valtype()
            locals[j] = {count = n, type = t}
            total_locals = total_locals + n
        end
        -- The rest is the bytecode body
        local code_start = self.pos
        local code_end = body_start + body_size
        local code = self:read_bytes(code_end - code_start)
        bodies[i] = {
            locals = locals,
            total_locals = total_locals,
            code = code,
        }
    end
    return bodies
end

-- Parse data section
function Parser:parse_data_section(size)
    local count = self:read_leb128_u()
    local segments = {}
    for i = 1, count do
        local flags = self:read_leb128_u()
        if flags == 0 then
            -- Active segment, implicit memory 0
            local offset_val, offset_op = self:read_init_expr()
            local data_len = self:read_leb128_u()
            local data = self:read_bytes(data_len)
            segments[i] = {
                memory_idx = 0,
                offset = offset_val,
                offset_opcode = offset_op,
                data = data,
            }
        elseif flags == 1 then
            -- Passive segment (no memory/offset)
            local data_len = self:read_leb128_u()
            local data = self:read_bytes(data_len)
            segments[i] = {
                passive = true,
                data = data,
            }
        elseif flags == 2 then
            -- Active segment with explicit memory index
            local mem_idx = self:read_leb128_u()
            local offset_val, offset_op = self:read_init_expr()
            local data_len = self:read_leb128_u()
            local data = self:read_bytes(data_len)
            segments[i] = {
                memory_idx = mem_idx,
                offset = offset_val,
                offset_opcode = offset_op,
                data = data,
            }
        else
            fail("invalid data segment flags: " .. flags)
        end
    end
    return segments
end

-- Main parse function
local function parse(bytes)
    local p = new_parser(bytes)

    -- Read and verify magic number: \0asm
    local magic = p:read_u32_raw()
    if magic ~= 0x6D736100 then
        fail("magic header not detected")
    end

    -- Read and verify version
    local version = p:read_u32_raw()
    if version ~= 1 then
        fail("unknown binary version")
    end

    local module = {
        types = {},
        imports = {},
        func_type_indices = {},
        tables = {},
        memory_def = nil,
        globals = {},
        exports = {},
        start_func = nil,
        element_segments = {},
        code_bodies = {},
        data_segments = {},
    }

    -- Parse sections
    while p.pos <= p.len do
        local section_id = p:read_byte()
        local section_size = p:read_leb128_u()
        local section_end = p.pos + section_size

        if section_id == SECTION_TYPE then
            module.types = p:parse_type_section(section_size)
        elseif section_id == SECTION_IMPORT then
            module.imports = p:parse_import_section(section_size)
        elseif section_id == SECTION_FUNCTION then
            module.func_type_indices = p:parse_function_section(section_size)
        elseif section_id == SECTION_TABLE then
            module.tables = p:parse_table_section(section_size)
        elseif section_id == SECTION_MEMORY then
            local mems = p:parse_memory_section(section_size)
            if #mems > 0 then
                module.memory_def = mems[1]
            end
        elseif section_id == SECTION_GLOBAL then
            module.globals = p:parse_global_section(section_size)
        elseif section_id == SECTION_EXPORT then
            module.exports = p:parse_export_section(section_size)
        elseif section_id == SECTION_START then
            module.start_func = p:parse_start_section(section_size)
        elseif section_id == SECTION_ELEMENT then
            module.element_segments = p:parse_element_section(section_size)
        elseif section_id == SECTION_CODE then
            module.code_bodies = p:parse_code_section(section_size)
        elseif section_id == SECTION_DATA then
            module.data_segments = p:parse_data_section(section_size)
        else
            -- Skip unknown/custom section
            p.pos = section_end
        end

        -- Ensure we're at the expected position
        if p.pos ~= section_end then
            p.pos = section_end
        end
    end

    -- Build funcs array combining imports and module functions
    module.num_import_funcs = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == EXT_FUNC then
            module.num_import_funcs = module.num_import_funcs + 1
        end
    end

    -- Build a combined function list: imports first, then module funcs
    module.funcs = {}
    local func_idx = 0
    for _, imp in ipairs(module.imports) do
        if imp.kind == EXT_FUNC then
            module.funcs[func_idx] = {
                type_idx = imp.desc.type_idx,
                import = true,
                module = imp.module,
                name = imp.name,
            }
            func_idx = func_idx + 1
        end
    end
    for i, type_idx in ipairs(module.func_type_indices) do
        module.funcs[func_idx] = {
            type_idx = type_idx,
            import = false,
            code = module.code_bodies[i],
        }
        func_idx = func_idx + 1
    end

    -- Build export lookup
    module.export_map = {}
    for _, exp in ipairs(module.exports) do
        module.export_map[exp.name] = exp
    end

    return module
end

return {
    parse = parse,
    TYPE_I32 = TYPE_I32,
    TYPE_I64 = TYPE_I64,
    TYPE_F32 = TYPE_F32,
    TYPE_F64 = TYPE_F64,
    EXT_FUNC = EXT_FUNC,
    EXT_TABLE = EXT_TABLE,
    EXT_MEMORY = EXT_MEMORY,
    EXT_GLOBAL = EXT_GLOBAL,
}
