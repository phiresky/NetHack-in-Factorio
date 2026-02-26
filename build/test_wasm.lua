#!/usr/bin/env luajit
-- WASM Interpreter Test Suite
-- Tests i32 arithmetic, memory load/store, control flow, function calls,
-- and the overall interpreter pipeline using hand-crafted WASM binaries.

-- bit32 compatibility shim for LuaJIT
if not bit32 then
    local bit = require("bit")
    local function to_u32(n) if n < 0 then return n + 4294967296 end; return n end
    bit32 = {
        band = function(...) return to_u32(bit.band(...)) end,
        bor = function(...) return to_u32(bit.bor(...)) end,
        bxor = function(...) return to_u32(bit.bxor(...)) end,
        bnot = function(a) return to_u32(bit.bnot(a)) end,
        lshift = function(a, b) return to_u32(bit.lshift(a, b)) end,
        rshift = function(a, b) return to_u32(bit.rshift(a, b)) end,
        arshift = function(a, b) return to_u32(bit.arshift(a, b)) end,
        lrotate = function(a, b) return to_u32(bit.rol(a, b)) end,
        rrotate = function(a, b) return to_u32(bit.ror(a, b)) end,
        btest = function(a, b) return bit.band(a, b) ~= 0 end,
    }
end

local unpack = table.unpack or unpack

-- WASM binary building helpers
local function u32le(n)
    return string.char(
        bit32.band(n, 0xFF),
        bit32.band(bit32.rshift(n, 8), 0xFF),
        bit32.band(bit32.rshift(n, 16), 0xFF),
        bit32.band(bit32.rshift(n, 24), 0xFF))
end

local function leb128(n)
    local t = {}
    while true do
        local b = bit32.band(n, 0x7F)
        n = bit32.rshift(n, 7)
        if n > 0 then
            t[#t + 1] = string.char(bit32.bor(b, 0x80))
        else
            t[#t + 1] = string.char(b)
            break
        end
    end
    return table.concat(t)
end

local function sleb128(n)
    local t = {}
    while true do
        local b = bit32.band(n, 0x7F)
        n = math.floor(n / 128) -- arithmetic shift for signed
        if (n == 0 and bit32.band(b, 0x40) == 0) or (n == -1 and bit32.band(b, 0x40) ~= 0) then
            t[#t + 1] = string.char(b)
            break
        else
            t[#t + 1] = string.char(bit32.bor(b, 0x80))
        end
    end
    return table.concat(t)
end

local function section(id, body)
    return string.char(id) .. leb128(#body) .. body
end

local WASM_HEADER = u32le(0x6D736100) .. u32le(1)

-- Type constants
local I32 = 0x7F
local I64 = 0x7E
local F32 = 0x7D
local F64 = 0x7C
local VOID = 0x40

-- Build a functype
local function functype(params, results)
    local body = string.char(0x60)
    body = body .. leb128(#params)
    for _, p in ipairs(params) do body = body .. string.char(p) end
    body = body .. leb128(#results)
    for _, r in ipairs(results) do body = body .. string.char(r) end
    return body
end

-- Build a complete single-function module
local function make_module(opts)
    local types = opts.types or {functype(opts.params or {}, opts.results or {})}
    local type_sec = leb128(#types) .. table.concat(types)

    local imports = opts.imports or {}
    local import_sec = ""
    local num_import_funcs = 0
    if #imports > 0 then
        local ib = leb128(#imports)
        for _, imp in ipairs(imports) do
            ib = ib .. leb128(#imp.module) .. imp.module
                    .. leb128(#imp.name) .. imp.name
                    .. string.char(0x00) .. leb128(imp.type_idx)
            num_import_funcs = num_import_funcs + 1
        end
        import_sec = section(2, ib)
    end

    local func_type_indices = opts.func_types or {(opts.type_idx or 0)}
    local func_sec = leb128(#func_type_indices)
    for _, ti in ipairs(func_type_indices) do func_sec = func_sec .. leb128(ti) end

    local export_name = opts.name or "test"
    local export_idx = num_import_funcs + (opts.export_idx or 0)
    local export_sec = leb128(1) .. leb128(#export_name) .. export_name
        .. string.char(0x00) .. leb128(export_idx)

    -- Additional exports
    if opts.extra_exports then
        local count = 1 + #opts.extra_exports
        export_sec = leb128(count) .. leb128(#export_name) .. export_name
            .. string.char(0x00) .. leb128(export_idx)
        for _, e in ipairs(opts.extra_exports) do
            export_sec = export_sec .. leb128(#e.name) .. e.name
                .. string.char(e.kind or 0x00) .. leb128(e.index)
        end
    end

    local mem_sec = ""
    if opts.memory then
        mem_sec = section(5, leb128(1) .. string.char(0) .. leb128(opts.memory))
    end

    local data_sec = ""
    if opts.data then
        local db = leb128(#opts.data)
        for _, d in ipairs(opts.data) do
            db = db .. leb128(0) -- memory 0
                .. string.char(0x41) .. sleb128(d.offset) .. string.char(0x0B)
                .. leb128(#d.bytes) .. d.bytes
        end
        data_sec = section(11, db)
    end

    -- Build code bodies
    local code_bodies = opts.codes or {opts.code or ""}
    local locals_list = opts.locals_list or {opts.locals or leb128(0)}
    local cs = leb128(#code_bodies)
    for i, code in ipairs(code_bodies) do
        local loc = locals_list[i] or leb128(0)
        local fb = loc .. code .. string.char(0x0B)
        cs = cs .. leb128(#fb) .. fb
    end

    return WASM_HEADER
        .. section(1, type_sec)
        .. import_sec
        .. section(3, func_sec)
        .. mem_sec
        .. section(7, export_sec)
        .. data_sec
        .. section(10, cs)
end

-- Test runner
local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        errors[#errors + 1] = name .. ": " .. tostring(err)
    end
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            msg or "assertion", tostring(expected), tostring(actual)))
    end
end

local function assert_trap(fn, msg)
    local ok, err = pcall(fn)
    if ok then
        error((msg or "expected trap") .. ": no trap occurred")
    end
end

-- Load modules
local Parser = require("scripts.wasm.init")
local Interp = require("scripts.wasm.interp")
local Memory = require("scripts.wasm.memory")

local function instantiate(wasm_bytes, imports)
    local mod = Parser.parse(wasm_bytes)
    local inst = Interp.instantiate(mod, imports or {})
    -- Build convenience exports table that wraps the new call/run API
    inst.exports = {}
    for _, exp in ipairs(mod.exports) do
        if exp.kind == 0x00 then -- function export
            local fidx = exp.index
            inst.exports[exp.name] = function(...)
                local args = {...}
                local results = Interp.execute(inst, fidx, args)
                return unpack(results)
            end
        end
    end
    return inst
end

-- ====================================================================
-- i32 ARITHMETIC TESTS
-- ====================================================================
print("--- i32 Arithmetic ---")

-- Helper: single-op binary function (i32, i32) -> i32
local function i32_binop(opcode)
    return make_module({
        params = {I32, I32}, results = {I32},
        code = string.char(0x20, 0x00, 0x20, 0x01, opcode),
    })
end

-- Helper: single-op unary function (i32) -> i32
local function i32_unop(opcode)
    return make_module({
        params = {I32}, results = {I32},
        code = string.char(0x20, 0x00, opcode),
    })
end

test("i32.add", function()
    local inst = instantiate(i32_binop(0x6A))
    assert_eq(inst.exports.test(1, 1), 2)
    assert_eq(inst.exports.test(1, 0), 1)
    assert_eq(inst.exports.test(0xFFFFFFFF, 1), 0)
    assert_eq(inst.exports.test(0x80000000, 0x80000000), 0)
    assert_eq(inst.exports.test(0x7FFFFFFF, 1), 0x80000000)
end)

test("i32.sub", function()
    local inst = instantiate(i32_binop(0x6B))
    assert_eq(inst.exports.test(1, 1), 0)
    assert_eq(inst.exports.test(1, 0), 1)
    assert_eq(inst.exports.test(0, 1), 0xFFFFFFFF) -- -1
    assert_eq(inst.exports.test(0x80000000, 1), 0x7FFFFFFF)
end)

test("i32.mul", function()
    local inst = instantiate(i32_binop(0x6C))
    assert_eq(inst.exports.test(1, 1), 1)
    assert_eq(inst.exports.test(1, 0), 0)
    assert_eq(inst.exports.test(0xFFFFFFFF, 0xFFFFFFFF), 1) -- (-1)*(-1)
    assert_eq(inst.exports.test(0x10000, 0x10000), 0) -- overflow wraps
    assert_eq(inst.exports.test(7, 6), 42)
end)

test("i32.div_s", function()
    local inst = instantiate(i32_binop(0x6D))
    assert_eq(inst.exports.test(7, 3), 2)
    assert_eq(inst.exports.test(0xFFFFFFF9, 3), 0xFFFFFFFE) -- -7/3 = -2
    assert_trap(function() inst.exports.test(1, 0) end, "div by zero")
    assert_trap(function() inst.exports.test(0x80000000, 0xFFFFFFFF) end, "overflow")
end)

test("i32.div_u", function()
    local inst = instantiate(i32_binop(0x6E))
    assert_eq(inst.exports.test(7, 3), 2)
    assert_eq(inst.exports.test(0xFFFFFFFF, 3), 0x55555555)
    assert_trap(function() inst.exports.test(1, 0) end, "div by zero")
end)

test("i32.rem_s", function()
    local inst = instantiate(i32_binop(0x6F))
    assert_eq(inst.exports.test(7, 3), 1)
    assert_eq(inst.exports.test(0xFFFFFFF9, 3), 0xFFFFFFFF) -- -7%3 = -1
    assert_trap(function() inst.exports.test(1, 0) end, "rem by zero")
end)

test("i32.rem_u", function()
    local inst = instantiate(i32_binop(0x70))
    assert_eq(inst.exports.test(7, 3), 1)
    assert_eq(inst.exports.test(0xFFFFFFFF, 3), 0)
    assert_trap(function() inst.exports.test(1, 0) end, "rem by zero")
end)

test("i32.and", function()
    local inst = instantiate(i32_binop(0x71))
    assert_eq(inst.exports.test(0xFF00FF00, 0x0F0F0F0F), 0x0F000F00)
    assert_eq(inst.exports.test(0xFFFFFFFF, 0), 0)
end)

test("i32.or", function()
    local inst = instantiate(i32_binop(0x72))
    assert_eq(inst.exports.test(0xFF00FF00, 0x0F0F0F0F), 0xFF0FFF0F)
    assert_eq(inst.exports.test(0, 0), 0)
end)

test("i32.xor", function()
    local inst = instantiate(i32_binop(0x73))
    assert_eq(inst.exports.test(0xFF00FF00, 0x0F0F0F0F), 0xF00FF00F)
    assert_eq(inst.exports.test(0xFFFFFFFF, 0xFFFFFFFF), 0)
end)

test("i32.shl", function()
    local inst = instantiate(i32_binop(0x74))
    assert_eq(inst.exports.test(1, 1), 2)
    assert_eq(inst.exports.test(1, 31), 0x80000000)
    assert_eq(inst.exports.test(1, 32), 1) -- shift mod 32
end)

test("i32.shr_s", function()
    local inst = instantiate(i32_binop(0x75))
    assert_eq(inst.exports.test(0x80000000, 1), 0xC0000000) -- arithmetic
    assert_eq(inst.exports.test(0x7FFFFFFF, 1), 0x3FFFFFFF)
end)

test("i32.shr_u", function()
    local inst = instantiate(i32_binop(0x76))
    assert_eq(inst.exports.test(0x80000000, 1), 0x40000000) -- logical
    assert_eq(inst.exports.test(0xFFFFFFFF, 1), 0x7FFFFFFF)
end)

test("i32.rotl", function()
    local inst = instantiate(i32_binop(0x77))
    assert_eq(inst.exports.test(0x80000000, 1), 1)
    assert_eq(inst.exports.test(1, 1), 2)
end)

test("i32.rotr", function()
    local inst = instantiate(i32_binop(0x78))
    assert_eq(inst.exports.test(1, 1), 0x80000000)
    assert_eq(inst.exports.test(0x80000000, 1), 0x40000000)
end)

test("i32.clz", function()
    local inst = instantiate(i32_unop(0x67))
    assert_eq(inst.exports.test(0), 32)
    assert_eq(inst.exports.test(0x80000000), 0)
    assert_eq(inst.exports.test(1), 31)
    assert_eq(inst.exports.test(0x00008000), 16)
end)

test("i32.ctz", function()
    local inst = instantiate(i32_unop(0x68))
    assert_eq(inst.exports.test(0), 32)
    assert_eq(inst.exports.test(0x80000000), 31)
    assert_eq(inst.exports.test(1), 0)
    assert_eq(inst.exports.test(0x00010000), 16)
end)

test("i32.popcnt", function()
    local inst = instantiate(i32_unop(0x69))
    assert_eq(inst.exports.test(0), 0)
    assert_eq(inst.exports.test(0xFFFFFFFF), 32)
    assert_eq(inst.exports.test(0xAAAAAAAA), 16)
end)

test("i32.eqz", function()
    local inst = instantiate(i32_unop(0x45))
    assert_eq(inst.exports.test(0), 1)
    assert_eq(inst.exports.test(1), 0)
    assert_eq(inst.exports.test(0x80000000), 0)
end)

-- i32 comparisons: (i32, i32) -> i32
test("i32.eq", function()
    local inst = instantiate(i32_binop(0x46))
    assert_eq(inst.exports.test(0, 0), 1)
    assert_eq(inst.exports.test(1, 0), 0)
end)

test("i32.ne", function()
    local inst = instantiate(i32_binop(0x47))
    assert_eq(inst.exports.test(0, 0), 0)
    assert_eq(inst.exports.test(1, 0), 1)
end)

test("i32.lt_s", function()
    local inst = instantiate(i32_binop(0x48))
    assert_eq(inst.exports.test(0xFFFFFFFF, 0), 1) -- -1 < 0
    assert_eq(inst.exports.test(0, 0xFFFFFFFF), 0)
    assert_eq(inst.exports.test(0x80000000, 0x7FFFFFFF), 1)
end)

test("i32.lt_u", function()
    local inst = instantiate(i32_binop(0x49))
    assert_eq(inst.exports.test(0xFFFFFFFF, 0), 0) -- unsigned: big > 0
    assert_eq(inst.exports.test(0, 0xFFFFFFFF), 1)
end)

test("i32.gt_s", function()
    local inst = instantiate(i32_binop(0x4A))
    assert_eq(inst.exports.test(0, 0xFFFFFFFF), 1) -- 0 > -1
    assert_eq(inst.exports.test(0xFFFFFFFF, 0), 0)
end)

test("i32.le_s", function()
    local inst = instantiate(i32_binop(0x4C))
    assert_eq(inst.exports.test(0, 0), 1)
    assert_eq(inst.exports.test(0xFFFFFFFF, 0), 1) -- -1 <= 0
end)

test("i32.ge_s", function()
    local inst = instantiate(i32_binop(0x4E))
    assert_eq(inst.exports.test(0, 0), 1)
    assert_eq(inst.exports.test(0, 0xFFFFFFFF), 1) -- 0 >= -1
end)

test("i32.const", function()
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(0x41) .. sleb128(42),
    }))
    assert_eq(inst.exports.test(), 42)
end)

test("i32.const negative", function()
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(0x41) .. sleb128(-1),
    }))
    assert_eq(inst.exports.test(), 0xFFFFFFFF)
end)

-- ====================================================================
-- i32 SIGN EXTENSION TESTS
-- ====================================================================
print("--- i32 Sign Extension ---")

test("i32.extend8_s", function()
    local inst = instantiate(i32_unop(0xC0))
    assert_eq(inst.exports.test(0x80), 0xFFFFFF80)
    assert_eq(inst.exports.test(0x7F), 0x7F)
    assert_eq(inst.exports.test(0x100), 0) -- only low 8 bits matter
end)

test("i32.extend16_s", function()
    local inst = instantiate(i32_unop(0xC1))
    assert_eq(inst.exports.test(0x8000), 0xFFFF8000)
    assert_eq(inst.exports.test(0x7FFF), 0x7FFF)
end)

-- ====================================================================
-- MEMORY TESTS
-- ====================================================================
print("--- Memory ---")

test("memory store/load i32", function()
    local inst = instantiate(make_module({
        types = {
            functype({I32, I32}, {}),     -- store: (addr, val) -> ()
            functype({I32}, {I32}),       -- load: (addr) -> i32
        },
        func_types = {0, 1},
        memory = 1,
        name = "st",
        extra_exports = {{name = "ld", kind = 0x00, index = 1}},
        codes = {
            string.char(0x20, 0, 0x20, 1, 0x36, 0x02, 0x00), -- local.get 0, local.get 1, i32.store
            string.char(0x20, 0, 0x28, 0x02, 0x00),           -- local.get 0, i32.load
        },
        locals_list = {leb128(0), leb128(0)},
    }))
    inst.exports.st(0, 42)
    assert_eq(inst.exports.ld(0), 42)
    inst.exports.st(100, 0xDEADBEEF)
    assert_eq(inst.exports.ld(100), 0xDEADBEEF)
end)

test("memory store/load i32.store8 + i32.load8_u", function()
    local inst = instantiate(make_module({
        types = {
            functype({I32, I32}, {}),
            functype({I32}, {I32}),
        },
        func_types = {0, 1},
        memory = 1,
        name = "st8",
        extra_exports = {{name = "ld8u", kind = 0x00, index = 1}},
        codes = {
            string.char(0x20, 0, 0x20, 1, 0x3A, 0x00, 0x00), -- i32.store8
            string.char(0x20, 0, 0x2D, 0x00, 0x00),           -- i32.load8_u
        },
        locals_list = {leb128(0), leb128(0)},
    }))
    inst.exports.st8(0, 0xFF)
    assert_eq(inst.exports.ld8u(0), 0xFF)
    inst.exports.st8(1, 0x42)
    assert_eq(inst.exports.ld8u(1), 0x42)
end)

test("memory store/load i32.store16 + i32.load16_u", function()
    local inst = instantiate(make_module({
        types = {
            functype({I32, I32}, {}),
            functype({I32}, {I32}),
        },
        func_types = {0, 1},
        memory = 1,
        name = "st16",
        extra_exports = {{name = "ld16u", kind = 0x00, index = 1}},
        codes = {
            string.char(0x20, 0, 0x20, 1, 0x3B, 0x01, 0x00), -- i32.store16
            string.char(0x20, 0, 0x2F, 0x01, 0x00),           -- i32.load16_u
        },
        locals_list = {leb128(0), leb128(0)},
    }))
    inst.exports.st16(0, 0xABCD)
    assert_eq(inst.exports.ld16u(0), 0xABCD)
end)

test("memory.size and memory.grow", function()
    local inst = instantiate(make_module({
        types = {
            functype({}, {I32}),          -- size: () -> i32
            functype({I32}, {I32}),       -- grow: (pages) -> i32
        },
        func_types = {0, 1},
        memory = 1,
        name = "size",
        extra_exports = {{name = "grow", kind = 0x00, index = 1}},
        codes = {
            string.char(0x3F, 0x00),                     -- memory.size 0
            string.char(0x20, 0x00, 0x40, 0x00),         -- local.get 0, memory.grow 0
        },
        locals_list = {leb128(0), leb128(0)},
    }))
    assert_eq(inst.exports.size(), 1)
    assert_eq(inst.exports.grow(2), 1) -- returns old size
    assert_eq(inst.exports.size(), 3)
end)

test("data segments initialization", function()
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        memory = 1,
        data = {
            {offset = 1024, bytes = "Hello"},
        },
        code = string.char(0x20, 0, 0x2D, 0x00, 0x00), -- local.get 0, i32.load8_u
    }))
    assert_eq(inst.exports.test(1024), 72) -- 'H'
    assert_eq(inst.exports.test(1025), 101) -- 'e'
    assert_eq(inst.exports.test(1028), 111) -- 'o'
end)

-- ====================================================================
-- CONTROL FLOW TESTS
-- ====================================================================
print("--- Control Flow ---")

test("block + br", function()
    -- (block (br 0) (unreachable)) (i32.const 42)
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(
            0x02, 0x40,       -- block void
            0x0C, 0x00,       -- br 0
            0x00,             -- unreachable (should not reach)
            0x0B,             -- end block
            0x41, 0x2A),      -- i32.const 42
    }))
    assert_eq(inst.exports.test(), 42)
end)

test("block returning value", function()
    -- (block [i32] (i32.const 7) (br 0)) => 7
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(
            0x02, 0x7F,       -- block [i32]
            0x41, 0x07,       -- i32.const 7
            0x0C, 0x00,       -- br 0
            0x0B),            -- end block
    }))
    assert_eq(inst.exports.test(), 7)
end)

test("loop with br_if (sum 1..N)", function()
    -- sum(n): result = 0; if n==0 skip; loop { result += n; n -= 1; br_if 0 if n > 0 }; return result
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        locals = leb128(1) .. leb128(1) .. string.char(I32), -- 1 local i32
        code = string.char(
            0x41, 0x00, 0x21, 0x01,   -- result = 0
            0x02, 0x40,               -- block void
            0x20, 0x00, 0x45,         -- n == 0 (i32.eqz)
            0x0D, 0x00,               -- br_if 0 (exit block if n==0)
            0x03, 0x40,               -- loop void
            0x20, 0x01, 0x20, 0x00, 0x6A, 0x21, 0x01,  -- result += n
            0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,  -- n = n-1, tee
            0x0D, 0x00,               -- br_if 0 (loop)
            0x0B, 0x0B,               -- end loop, end block
            0x20, 0x01),              -- local.get result
    }))
    assert_eq(inst.exports.test(10), 55)
    assert_eq(inst.exports.test(100), 5050)
    assert_eq(inst.exports.test(0), 0)
end)

test("if/else", function()
    -- max(a, b): if a > b then a else b
    local inst = instantiate(make_module({
        params = {I32, I32}, results = {I32},
        code = string.char(
            0x20, 0x00, 0x20, 0x01, 0x4A,  -- a > b (gt_s)
            0x04, 0x7F,                     -- if [i32]
            0x20, 0x00,                     -- a
            0x05,                           -- else
            0x20, 0x01,                     -- b
            0x0B),                          -- end
    }))
    assert_eq(inst.exports.test(5, 3), 5)
    assert_eq(inst.exports.test(3, 5), 5)
    assert_eq(inst.exports.test(5, 5), 5)
end)

test("if without else (void)", function()
    -- if (param != 0) then result = 99
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        locals = leb128(1) .. leb128(1) .. string.char(I32),
        code = string.char(
            0x41, 0x00, 0x21, 0x01,    -- local 1 = 0
            0x20, 0x00,                 -- local.get 0
            0x04, 0x40,                 -- if void
            0x41) .. sleb128(99) .. string.char(0x21, 0x01,     -- local 1 = 99
            0x0B,                       -- end if
            0x20, 0x01),                -- return local 1
    }))
    assert_eq(inst.exports.test(1), 99)
    assert_eq(inst.exports.test(0), 0)
end)

test("nested blocks with br", function()
    -- (block $outer (block $inner (br 1)) (unreachable)) (i32.const 1)
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(
            0x02, 0x40,       -- block $outer void
            0x02, 0x40,       -- block $inner void
            0x0C, 0x01,       -- br 1 (to $outer)
            0x00,             -- unreachable
            0x0B,             -- end $inner
            0x00,             -- unreachable
            0x0B,             -- end $outer
            0x41, 0x01),      -- i32.const 1
    }))
    assert_eq(inst.exports.test(), 1)
end)

test("br_table", function()
    -- switch(n): br_table [0, 1, 2] default=2
    -- case 0: return 10; case 1: return 20; default: return 30
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        code = string.char(
            0x02, 0x7F,       -- block [i32] $b2
            0x02, 0x7F,       -- block [i32] $b1
            0x02, 0x7F,       -- block [i32] $b0
            0x20, 0x00,       -- local.get 0 (n)
            0x0E, 0x02,       -- br_table count=2
            0x00, 0x01, 0x02, -- targets: 0, 1, default=2
            0x0B,             -- end $b0 (case 0)
            0x41, 0x0A,       -- i32.const 10
            0x0C, 0x02,       -- br 2 (out)
            0x0B,             -- end $b1 (case 1)
            0x41, 0x14,       -- i32.const 20
            0x0C, 0x01,       -- br 1 (out)
            0x0B,             -- end $b2 (default)
            0x41, 0x1E),      -- i32.const 30
    }))
    assert_eq(inst.exports.test(0), 10)
    assert_eq(inst.exports.test(1), 20)
    assert_eq(inst.exports.test(2), 30)
    assert_eq(inst.exports.test(99), 30) -- default
end)

test("return early", function()
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        code = string.char(
            0x41, 0x2A,       -- i32.const 42
            0x0F,             -- return
            0x41, 0x00),      -- i32.const 0 (should not reach)
    }))
    assert_eq(inst.exports.test(0), 42)
end)

-- ====================================================================
-- FUNCTION CALL TESTS
-- ====================================================================
print("--- Function Calls ---")

test("call internal function", function()
    -- func 0: double(x) = x + x
    -- func 1 (exported): test(x) = double(x) + 1
    local inst = instantiate(make_module({
        types = {functype({I32}, {I32})},
        func_types = {0, 0},
        name = "test",
        export_idx = 1,
        codes = {
            string.char(0x20, 0x00, 0x20, 0x00, 0x6A),           -- double: x + x
            string.char(0x20, 0x00, 0x10, 0x00, 0x41, 0x01, 0x6A), -- test: call double, +1
        },
        locals_list = {leb128(0), leb128(0)},
    }))
    assert_eq(inst.exports.test(5), 11)
    assert_eq(inst.exports.test(0), 1)
end)

test("call imported function", function()
    local inst = instantiate(make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get42", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(0x10, 0x00), -- call import 0
    }), {env = {get42 = function() return 42 end}})
    assert_eq(inst.exports.test(), 42)
end)

test("recursive fibonacci", function()
    -- fib(n): if n <= 1 then n else fib(n-1) + fib(n-2)
    local inst = instantiate(make_module({
        params = {I32}, results = {I32},
        code = string.char(
            0x20, 0x00, 0x41, 0x01, 0x4C,   -- n <= 1 (le_s)
            0x04, 0x7F,                       -- if [i32]
            0x20, 0x00,                       -- return n
            0x05,                             -- else
            0x20, 0x00, 0x41, 0x01, 0x6B, 0x10, 0x00,  -- fib(n-1)
            0x20, 0x00, 0x41, 0x02, 0x6B, 0x10, 0x00,  -- fib(n-2)
            0x6A,                             -- add
            0x0B),                            -- end if
    }))
    assert_eq(inst.exports.test(0), 0)
    assert_eq(inst.exports.test(1), 1)
    assert_eq(inst.exports.test(5), 5)
    assert_eq(inst.exports.test(10), 55)
end)

-- ====================================================================
-- PARAMETRIC TESTS
-- ====================================================================
print("--- Parametric ---")

test("drop", function()
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(0x41, 0x01, 0x41, 0x02, 0x1A), -- const 1, const 2, drop => 1
    }))
    assert_eq(inst.exports.test(), 1)
end)

test("select (true)", function()
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(0x41, 0x0A, 0x41, 0x14, 0x41, 0x01, 0x1B), -- 10, 20, 1(true), select => 10
    }))
    assert_eq(inst.exports.test(), 10)
end)

test("select (false)", function()
    local inst = instantiate(make_module({
        params = {}, results = {I32},
        code = string.char(0x41, 0x0A, 0x41, 0x14, 0x41, 0x00, 0x1B), -- 10, 20, 0(false), select => 20
    }))
    assert_eq(inst.exports.test(), 20)
end)

-- ====================================================================
-- GLOBAL TESTS
-- ====================================================================
print("--- Globals ---")

test("global.get and global.set", function()
    -- Module with 1 mutable global initialized to 0
    local type_sec = leb128(1) .. functype({I32}, {I32})
    local func_sec = leb128(1) .. leb128(0)
    local global_sec = leb128(1) .. string.char(I32, 0x01, 0x41, 0x00, 0x0B) -- mutable i32, init=0
    local export_sec = leb128(1) .. leb128(4) .. "test" .. string.char(0x00) .. leb128(0)

    -- code: global.set 0 param; global.get 0 + 1
    local code = string.char(
        0x20, 0x00, 0x24, 0x00,         -- global.set 0 = param
        0x23, 0x00, 0x41, 0x01, 0x6A)   -- global.get 0 + 1
    local fb = leb128(0) .. code .. string.char(0x0B)
    local code_sec = leb128(1) .. leb128(#fb) .. fb

    local w = WASM_HEADER
        .. section(1, type_sec)
        .. section(3, func_sec)
        .. section(6, global_sec)
        .. section(7, export_sec)
        .. section(10, code_sec)

    local inst = instantiate(w)
    assert_eq(inst.exports.test(41), 42)
    assert_eq(inst.exports.test(99), 100)
end)

-- ====================================================================
-- BLOCKING IMPORT TEST (Resumable State Machine)
-- ====================================================================
print("--- Blocking Imports ---")

test("blocking import pause and resume", function()
    -- Module calls a blocking import (get_input), then adds 1 to result
    local mod = Parser.parse(make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get_input", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(0x10, 0x00, 0x41, 0x01, 0x6A), -- call get_input, add 1
    }))

    -- Use blocking import pattern (no coroutines)
    local inst = Interp.instantiate(mod, {
        ["env.get_input"] = {
            blocking = true,
            handler = function()
                return {input_type = "getch"}
            end,
        },
    })

    -- Start execution
    local func_idx = Interp.get_export(inst, "test")
    assert(func_idx, "should find test export")
    Interp.call(inst, func_idx, {})

    -- Run until it hits the blocking import
    local result = Interp.run(inst, 50000)
    assert_eq(result.status, "waiting_input", "should be waiting")
    assert_eq(result.input_type, "getch", "should want getch")

    -- Provide input and resume
    Interp.provide_input(inst, 41)
    result = Interp.run(inst, 50000)
    assert_eq(result.status, "finished", "should be finished")
    assert_eq(result.results[1], 42, "41 + 1 = 42")
end)

test("blocking import with multiple pauses", function()
    -- Module calls blocking import twice and sums the results
    local mod = Parser.parse(make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get_input", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(
            0x10, 0x00,           -- call get_input (first)
            0x10, 0x00,           -- call get_input (second)
            0x6A),                -- i32.add
    }))

    local inst = Interp.instantiate(mod, {
        ["env.get_input"] = {
            blocking = true,
            handler = function()
                return {input_type = "getch"}
            end,
        },
    })

    local func_idx = Interp.get_export(inst, "test")
    Interp.call(inst, func_idx, {})

    -- First blocking call
    local result = Interp.run(inst, 50000)
    assert_eq(result.status, "waiting_input", "first wait")
    Interp.provide_input(inst, 10)

    -- Second blocking call
    result = Interp.run(inst, 50000)
    assert_eq(result.status, "waiting_input", "second wait")
    Interp.provide_input(inst, 32)

    -- Should finish with 10 + 32 = 42
    result = Interp.run(inst, 50000)
    assert_eq(result.status, "finished", "should finish")
    assert_eq(result.results[1], 42, "10 + 32 = 42")
end)

test("instruction budget pause and resume", function()
    -- Loop that needs more than budget allows
    local mod = Parser.parse(make_module({
        params = {I32}, results = {I32},
        locals = leb128(1) .. leb128(1) .. string.char(I32),
        code = string.char(
            0x41, 0x00, 0x21, 0x01,   -- result = 0
            0x02, 0x40,               -- block void
            0x03, 0x40,               -- loop void
            0x20, 0x01, 0x20, 0x00, 0x6A, 0x21, 0x01,  -- result += n
            0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,  -- n = n-1, tee
            0x0D, 0x00,               -- br_if 0 (loop)
            0x0B, 0x0B,               -- end loop, end block
            0x20, 0x01),              -- local.get result
    }))

    local inst = Interp.instantiate(mod, {})
    local func_idx = Interp.get_export(inst, "test")
    Interp.call(inst, func_idx, {100})

    -- Run with tiny budget
    local result = Interp.run(inst, 50)
    assert_eq(result.status, "running", "should still be running")

    -- Resume with large budget to finish
    result = Interp.run(inst, 50000)
    assert_eq(result.status, "finished", "should finish")
    assert_eq(result.results[1], 5050, "sum 1..100 = 5050")
end)

print("--- Save/Restore ---")

test("snapshot and restore exec at blocking import", function()
    -- Module: calls blocking import twice and sums results. Tests that
    -- snapshot/restore preserves stack and exec state across a simulated save/load.
    local mod = Parser.parse(make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get_input", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(
            0x10, 0x00,                     -- call get_input -> first value
            0x10, 0x00,                     -- call get_input -> second value
            0x6A),                          -- i32.add
    }))

    local blocking_import = {
        blocking = true,
        handler = function() return {input_type = "getch"} end,
    }

    -- First instance: run to first blocking point
    local inst1 = Interp.instantiate(mod, {["env.get_input"] = blocking_import})
    local func_idx = Interp.get_export(inst1, "test")
    Interp.call(inst1, func_idx, {})
    local result = Interp.run(inst1, 50000)
    assert_eq(result.status, "waiting_input", "should pause at first import")

    -- Provide first input
    Interp.provide_input(inst1, 10)
    result = Interp.run(inst1, 50000)
    assert_eq(result.status, "waiting_input", "should pause at second import")

    -- SNAPSHOT the exec state
    local snapshot = Interp.snapshot_exec(inst1)
    assert(snapshot, "snapshot should be non-nil")
    assert_eq(snapshot.waiting_input, true, "snapshot should be waiting")

    -- Create a NEW instance in restore mode, simulating save/load
    local restore_state = {
        memory_data = inst1.memory.data,
        memory_pages = inst1.memory.page_count,
        memory_max_pages = inst1.memory.max_pages,
        globals = inst1.globals,
        tables = inst1.tables,
        table_sizes = inst1.table_sizes,
        dropped_data_segs = inst1.data_segments_raw,
        dropped_elem_segs = inst1.element_segments_raw,
        total_instructions = inst1.total_instructions,
    }
    local mod2 = Parser.parse(make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get_input", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(
            0x10, 0x00,
            0x10, 0x00,
            0x6A),
    }))
    local inst2 = Interp.instantiate(mod2, {["env.get_input"] = blocking_import}, nil, restore_state)

    -- Restore exec from snapshot
    Interp.restore_exec(inst2, snapshot)

    -- Provide second input on the RESTORED instance
    Interp.provide_input(inst2, 32)
    result = Interp.run(inst2, 50000)
    assert_eq(result.status, "finished", "restored should finish")
    assert_eq(result.results[1], 42, "10 + 32 = 42 after restore")
end)

test("snapshot and restore exec at instruction budget", function()
    -- Loop summing 1..100. Pause mid-loop via budget, snapshot, restore, finish.
    local mod_bytes = make_module({
        params = {I32}, results = {I32},
        locals = leb128(1) .. leb128(1) .. string.char(I32),
        code = string.char(
            0x41, 0x00, 0x21, 0x01,   -- result = 0
            0x02, 0x40,               -- block void
            0x03, 0x40,               -- loop void
            0x20, 0x01, 0x20, 0x00, 0x6A, 0x21, 0x01,  -- result += n
            0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,  -- n = n-1, tee
            0x0D, 0x00,               -- br_if 0 (loop)
            0x0B, 0x0B,               -- end loop, end block
            0x20, 0x01),              -- local.get result
    })

    local mod = Parser.parse(mod_bytes)
    local inst = Interp.instantiate(mod, {})
    local func_idx = Interp.get_export(inst, "test")
    Interp.call(inst, func_idx, {100})

    -- Run with tiny budget to pause mid-loop
    local result = Interp.run(inst, 50)
    assert_eq(result.status, "running", "should still be running")

    -- Snapshot
    local snapshot = Interp.snapshot_exec(inst)
    assert(snapshot, "snapshot should be non-nil")

    -- Restore into a new instance
    local restore_state = {
        memory_data = inst.memory.data,
        memory_pages = inst.memory.page_count,
        memory_max_pages = inst.memory.max_pages,
        globals = inst.globals,
        tables = inst.tables,
        table_sizes = inst.table_sizes,
        dropped_data_segs = inst.data_segments_raw,
        dropped_elem_segs = inst.element_segments_raw,
        total_instructions = inst.total_instructions,
    }
    local mod2 = Parser.parse(mod_bytes)
    local inst2 = Interp.instantiate(mod2, {}, nil, restore_state)
    Interp.restore_exec(inst2, snapshot)

    -- Resume on restored instance
    result = Interp.run(inst2, 50000)
    assert_eq(result.status, "finished", "restored should finish")
    assert_eq(result.results[1], 5050, "sum 1..100 = 5050 after restore")
end)

test("snapshot and restore with memory writes", function()
    -- Write a value to memory, pause at blocking import, restore, read it back
    local mod_bytes = make_module({
        types = {functype({}, {I32}), functype({}, {I32})},
        imports = {{module = "env", name = "get_input", type_idx = 0}},
        func_types = {1},
        name = "test",
        code = string.char(
            -- store 0xDEAD at memory[0]
            0x41, 0x00,                     -- i32.const 0 (addr)
            0x41, 0xAD, 0xBD, 0x03,        -- i32.const 0xDEAD (leb128)
            0x36, 0x02, 0x00,              -- i32.store align=2 offset=0
            -- call blocking import
            0x10, 0x00,                     -- call get_input
            -- load memory[0] and add to input
            0x41, 0x00,                     -- i32.const 0 (addr)
            0x28, 0x02, 0x00,              -- i32.load align=2 offset=0
            0x6A),                          -- i32.add
    })

    local blocking_import = {
        blocking = true,
        handler = function() return {input_type = "getch"} end,
    }

    local mod = Parser.parse(mod_bytes)
    local inst = Interp.instantiate(mod, {["env.get_input"] = blocking_import})
    local func_idx = Interp.get_export(inst, "test")
    Interp.call(inst, func_idx, {})

    -- Run to blocking point (after memory write)
    local result = Interp.run(inst, 50000)
    assert_eq(result.status, "waiting_input", "should pause")

    -- Snapshot
    local snapshot = Interp.snapshot_exec(inst)

    -- Restore into new instance (sharing memory data table)
    local restore_state = {
        memory_data = inst.memory.data,
        memory_pages = inst.memory.page_count,
        memory_max_pages = inst.memory.max_pages,
        globals = inst.globals,
        tables = inst.tables,
        table_sizes = inst.table_sizes,
        dropped_data_segs = inst.data_segments_raw,
        dropped_elem_segs = inst.element_segments_raw,
        total_instructions = inst.total_instructions,
    }
    local mod2 = Parser.parse(mod_bytes)
    local inst2 = Interp.instantiate(mod2, {["env.get_input"] = blocking_import}, nil, restore_state)
    Interp.restore_exec(inst2, snapshot)

    -- Provide input on restored instance
    Interp.provide_input(inst2, 1)
    result = Interp.run(inst2, 50000)
    assert_eq(result.status, "finished", "should finish")
    assert_eq(result.results[1], 0xDEAD + 1, "memory survives restore")
end)

-- ====================================================================
-- LOAD .wasm FILES FROM DISK (if available)
-- ====================================================================
local function load_wasm_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Try loading spec test .wasm files from build/tests/
local test_dir = "build/tests/"
local spec_files = {
    "i32.wasm", "memory.wasm", "block.wasm", "loop.wasm",
    "call.wasm", "br.wasm", "br_if.wasm",
}

for _, filename in ipairs(spec_files) do
    local data = load_wasm_file(test_dir .. filename)
    if data then
        test("spec: " .. filename, function()
            local mod = Parser.parse(data)
            local inst = Interp.instantiate(mod, {
                spectest = {
                    print_i32 = function(v) end,
                    print_f32 = function(v) end,
                    print_f64 = function(v) end,
                    print = function() end,
                    global_i32 = 666,
                    global_f32 = 0.0,
                    global_f64 = 0.0,
                    table = {},
                    memory = Memory.new(1),
                },
            })
            -- Just verify it instantiates without error
            assert(inst, "module should instantiate")
        end)
    end
end

-- ====================================================================
-- SUMMARY
-- ====================================================================
print("")
print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
if #errors > 0 then
    print("")
    print("FAILURES:")
    for _, e in ipairs(errors) do
        print("  " .. e)
    end
    os.exit(1)
else
    print("ALL TESTS PASSED")
end
