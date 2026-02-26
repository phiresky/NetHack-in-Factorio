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

local Compiler = {}

-- Mask for i32 wrapping
local M32 = 0xFFFFFFFF

---------------------------------------------------------------------------
-- Bytecode decoder: pre-decode WASM bytecode into instruction list
---------------------------------------------------------------------------

-- Read unsigned LEB128 from byte array at position pos
-- Returns value, new_pos
local function decode_leb128_u(code, pos)
    local result = 0
    local shift = 0
    while true do
        local b = code[pos]
        pos = pos + 1
        result = bit32.bor(result, bit32.lshift(bit32.band(b, 0x7F), shift))
        if bit32.band(b, 0x80) == 0 then
            return result, pos
        end
        shift = shift + 7
    end
end

-- Read signed LEB128 (i32) from byte array
local function decode_leb128_s(code, pos)
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

-- Read signed LEB128 i64, returns {lo, hi}, new_pos
local function decode_leb128_s64(code, pos)
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

-- Format a number literal for Lua source
local function num_lit(v)
    if v == 0 then return "0"
    elseif v < 0 then return string.format("(%d)", v)
    else return tostring(v)
    end
end

-- Format u32 as hex if large, else decimal
local function u32_lit(v)
    if v == 0 then return "0"
    elseif v > 0xFFFF then return string.format("0x%X", v)
    else return tostring(v)
    end
end

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

    -- Helper: emit conditional branch (shared by br_if and peephole fusions)
    -- cond_expr: Lua expression string referencing __c (e.g. "__c ~= 0", "__c == 0")
    local function emit_cond_branch(depth, cond_expr)
        local target = get_branch_target(depth)
        if not target then return end
        emit("do local __c = stack[sp]; sp = sp - 1")
        if target.type == "func" then
            emit("  if " .. cond_expr .. " then ctx.call_target = nil; return sp end")
        else
            local arity = target.branch_arity or target.n_results or 0
            emit("  if " .. cond_expr .. " then")
            if target.stack_base_var then
                emit_branch_adjust(target.stack_base_var, arity)
            end
            if target.type == "loop" then
                emit("    goto L_" .. target.label_id)
            else
                emit("    goto B_" .. target.label_id)
            end
            emit("  end")
        end
        emit("end")
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

            if nop == 0x6A then -- i32.const C + i32.add
                if C ~= 0 then emit(string.format("stack[sp] = band(stack[sp] + %s, 0xFFFFFFFF)", u32_lit(C))) end
                i = i + 2; goto continue_loop
            elseif nop == 0x6B then -- i32.const C + i32.sub (A - C)
                if C ~= 0 then emit(string.format("stack[sp] = band(stack[sp] - %s, 0xFFFFFFFF)", u32_lit(C))) end
                i = i + 2; goto continue_loop
            elseif nop == 0x71 then -- i32.const C + i32.and
                emit(string.format("stack[sp] = band(stack[sp], %s)", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x72 then -- i32.const C + i32.or
                if C ~= 0 then emit(string.format("stack[sp] = bor(stack[sp], %s)", u32_lit(C))) end
                i = i + 2; goto continue_loop
            elseif nop == 0x73 then -- i32.const C + i32.xor
                if C ~= 0 then emit(string.format("stack[sp] = bxor(stack[sp], %s)", u32_lit(C))) end
                i = i + 2; goto continue_loop
            elseif nop == 0x74 then -- i32.const C + i32.shl
                local s = bit32.band(C, 31)
                if s ~= 0 then emit(string.format("stack[sp] = lshift(stack[sp], %d)", s)) end
                i = i + 2; goto continue_loop
            elseif nop == 0x75 then -- i32.const C + i32.shr_s
                local s = bit32.band(C, 31)
                if s ~= 0 then emit(string.format("stack[sp] = arshift(stack[sp], %d)", s)) end
                i = i + 2; goto continue_loop
            elseif nop == 0x76 then -- i32.const C + i32.shr_u
                local s = bit32.band(C, 31)
                if s ~= 0 then emit(string.format("stack[sp] = rshift(stack[sp], %d)", s)) end
                i = i + 2; goto continue_loop
            elseif nop == 0x46 then -- i32.const C + i32.eq
                emit(string.format("stack[sp] = stack[sp] == %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x47 then -- i32.const C + i32.ne
                emit(string.format("stack[sp] = stack[sp] ~= %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x49 then -- i32.const C + i32.lt_u
                emit(string.format("stack[sp] = stack[sp] < %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x4B then -- i32.const C + i32.gt_u
                emit(string.format("stack[sp] = stack[sp] > %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x4D then -- i32.const C + i32.le_u
                emit(string.format("stack[sp] = stack[sp] <= %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x4F then -- i32.const C + i32.ge_u
                emit(string.format("stack[sp] = stack[sp] >= %s and 1 or 0", u32_lit(C)))
                i = i + 2; goto continue_loop
            elseif nop == 0x28 then -- i32.const C + i32.load
                local addr = C + ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = %s", u32_lit(addr)))
                emit("  if __addr + 4 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                if bit32.band(addr, 3) == 0 then
                    emit(string.format("  stack[sp] = mem.data[%d] or 0 end", bit32.rshift(addr, 2)))
                else
                    emit("  if band(__addr, 3) == 0 then stack[sp] = mem.data[rshift(__addr, 2)] or 0")
                    emit("  else stack[sp] = mem:load_i32(__addr) end end")
                end
                i = i + 2; goto continue_loop
            elseif nop == 0x2D then -- i32.const C + i32.load8_u
                local addr = C + ni.offset
                emit("sp = sp + 1")
                emit(string.format("do local __addr = %s", u32_lit(addr)))
                emit("  if __addr + 1 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  stack[sp] = band(rshift(mem.data[__wi] or 0, __bo * 8), 0xFF) end")
                i = i + 2; goto continue_loop
            end
        end

        -- Group 2: local.get X + i32.const C + binary op
        if op == 0x20 and i + 2 <= n_instrs and instrs[i+1].op == 0x41 then
            local X = instr.idx
            local C = instrs[i+1].value
            local n2 = instrs[i+2]
            local nop2 = n2.op

            if nop2 == 0x6A then -- local.get + i32.const + i32.add
                emit(string.format("sp = sp + 1; stack[sp] = band(loc[%d] + %s, 0xFFFFFFFF)", X, u32_lit(C)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x6B then -- local.get + i32.const + i32.sub
                emit(string.format("sp = sp + 1; stack[sp] = band(loc[%d] - %s, 0xFFFFFFFF)", X, u32_lit(C)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x71 then -- local.get + i32.const + i32.and
                emit(string.format("sp = sp + 1; stack[sp] = band(loc[%d], %s)", X, u32_lit(C)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x72 then -- local.get + i32.const + i32.or
                emit(string.format("sp = sp + 1; stack[sp] = bor(loc[%d], %s)", X, u32_lit(C)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x74 then -- local.get + i32.const + i32.shl
                emit(string.format("sp = sp + 1; stack[sp] = lshift(loc[%d], %d)", X, bit32.band(C, 31)))
                i = i + 3; goto continue_loop
            elseif nop2 == 0x76 then -- local.get + i32.const + i32.shr_u
                emit(string.format("sp = sp + 1; stack[sp] = rshift(loc[%d], %d)", X, bit32.band(C, 31)))
                i = i + 3; goto continue_loop
            end
        end

        -- Group 3: local.get X + memory load → direct load from local
        if op == 0x20 and i + 1 <= n_instrs then
            local X = instr.idx
            local ni = instrs[i+1]
            local nop = ni.op

            if nop == 0x28 then -- local.get + i32.load
                local off = ni.offset
                emit("sp = sp + 1")
                if off == 0 then
                    emit(string.format("do local __addr = loc[%d]", X))
                else
                    emit(string.format("do local __addr = loc[%d] + %d", X, off))
                end
                emit("  if __addr + 4 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                emit("  if band(__addr, 3) == 0 then stack[sp] = mem.data[rshift(__addr, 2)] or 0")
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
                emit("  if __addr + 1 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  stack[sp] = band(rshift(mem.data[__wi] or 0, __bo * 8), 0xFF) end")
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
                emit("  if __addr + 4 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                emit(string.format("  local __v = band(loc[%d], 0xFFFFFFFF)", X))
                emit("  if band(__addr, 3) == 0 then mem.data[rshift(__addr, 2)] = __v")
                emit("  else mem:store_i32(__addr, __v) end end")
                i = i + 2; goto continue_loop
            elseif nop == 0x3A then -- local.get + i32.store8 (value from local)
                local off = ni.offset
                if off == 0 then
                    emit("do local __addr = stack[sp]; sp = sp - 1")
                else
                    emit(string.format("do local __addr = stack[sp] + %d; sp = sp - 1", off))
                end
                emit("  if __addr + 1 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
                emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
                emit("  local __sh = __bo * 8; local __mask = bnot(lshift(0xFF, __sh))")
                emit("  local __w = mem.data[__wi] or 0")
                emit(string.format("  mem.data[__wi] = bor(band(__w, __mask), lshift(band(loc[%d], 0xFF), __sh)) end", X))
                i = i + 2; goto continue_loop
            end
        end

        -- Group 4: Comparison + branch fusion
        if op == 0x45 and i + 1 <= n_instrs and instrs[i+1].op == 0x0D then
            -- i32.eqz + br_if → branch if value == 0
            emit_cond_branch(instrs[i+1].depth, "__c == 0")
            i = i + 2; goto continue_loop
        end

        if op == 0x41 and i + 2 <= n_instrs then
            local C = instr.value
            local ni1 = instrs[i+1]
            local ni2 = instrs[i+2]
            if ni2.op == 0x0D then -- ... + br_if
                if ni1.op == 0x47 then -- i32.const C + i32.ne + br_if
                    emit_cond_branch(ni2.depth, string.format("__c ~= %s", u32_lit(C)))
                    i = i + 3; goto continue_loop
                elseif ni1.op == 0x46 then -- i32.const C + i32.eq + br_if
                    emit_cond_branch(ni2.depth, string.format("__c == %s", u32_lit(C)))
                    i = i + 3; goto continue_loop
                end
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
                -- End of function
                -- Results are on stack. Signal completion.
                emit("ctx.call_target = nil")
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
                    emit("ctx.call_target = nil")
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
                        emit(string.format("%s __idx == %d then ctx.call_target = nil; return sp", cmp, j))
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
                    emit("ctx.call_target = nil; return sp")
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
            emit("ctx.call_target = nil")
            emit("do return sp end")

        -- Calls: return to interpreter
        elseif op == 0x10 then -- call
            local csid = instr.call_site_id
            emit(string.format("ctx.call_target = %d; ctx.resume_point = %d", instr.func_idx, csid))
            emit("do return sp end")
            emit(string.format("::C_%d::", csid))

        elseif op == 0x11 then -- call_indirect
            local csid = instr.call_site_id
            emit(string.format("ctx.call_indirect_type = %d; ctx.call_indirect_table = %d", instr.type_idx, instr.table_idx))
            emit(string.format("ctx.call_target = -2; ctx.resume_point = %d", csid))
            emit("do return sp end")
            emit(string.format("::C_%d::", csid))

        -- Exception handling: fall back to interpreter for these
        elseif op == 0x08 then -- throw
            emit(string.format("ctx.throw_tag = %d; ctx.call_target = -3; return sp", instr.tagidx))

        elseif op == 0x0A then -- throw_ref
            emit("ctx.call_target = -4; return sp")

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

        -- Locals
        elseif op == 0x20 then -- local.get
            emit(string.format("sp = sp + 1; stack[sp] = loc[%d]", instr.idx))

        elseif op == 0x21 then -- local.set
            emit(string.format("loc[%d] = stack[sp]; sp = sp - 1", instr.idx))

        elseif op == 0x22 then -- local.tee
            emit(string.format("loc[%d] = stack[sp]", instr.idx))

        -- Globals
        elseif op == 0x23 then -- global.get
            emit(string.format("sp = sp + 1; stack[sp] = globals[%d]", instr.idx))

        elseif op == 0x24 then -- global.set
            emit(string.format("globals[%d] = stack[sp]; sp = sp - 1", instr.idx))

        -- Constants
        elseif op == 0x41 then -- i32.const
            emit(string.format("sp = sp + 1; stack[sp] = %s", u32_lit(instr.value)))

        elseif op == 0x42 then -- i64.const
            emit(string.format("sp = sp + 1; stack[sp] = {%s, %s}", u32_lit(instr.lo), u32_lit(instr.hi)))

        elseif op == 0x43 then -- f32.const
            emit(string.format("sp = sp + 1; stack[sp] = ctx.f32_reinterpret(%s)", u32_lit(instr.bits)))

        elseif op == 0x44 then -- f64.const
            emit(string.format("sp = sp + 1; stack[sp] = ctx.f64_reinterpret({%s, %s})", u32_lit(instr.lo), u32_lit(instr.hi)))

        -- Stack ops
        elseif op == 0x1A then -- drop
            emit("sp = sp - 1")

        elseif op == 0x1B then -- select
            emit("do local __c = stack[sp]; sp = sp - 1; local __b = stack[sp]; sp = sp - 1")
            emit("  if __c == 0 then stack[sp] = __b end")
            emit("end")

        -- i32 comparison
        elseif op == 0x45 then -- i32.eqz
            emit("stack[sp] = stack[sp] == 0 and 1 or 0")

        elseif op == 0x46 then -- i32.eq
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] == __b and 1 or 0 end")

        elseif op == 0x47 then -- i32.ne
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] ~= __b and 1 or 0 end")

        elseif op == 0x48 then -- i32.lt_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) < (__b >= 0x80000000 and __b - 0x100000000 or __b)) and 1 or 0 end")

        elseif op == 0x49 then -- i32.lt_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] < __b and 1 or 0 end")

        elseif op == 0x4A then -- i32.gt_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) > (__b >= 0x80000000 and __b - 0x100000000 or __b)) and 1 or 0 end")

        elseif op == 0x4B then -- i32.gt_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] > __b and 1 or 0 end")

        elseif op == 0x4C then -- i32.le_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) <= (__b >= 0x80000000 and __b - 0x100000000 or __b)) and 1 or 0 end")

        elseif op == 0x4D then -- i32.le_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] <= __b and 1 or 0 end")

        elseif op == 0x4E then -- i32.ge_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]")
            emit("  stack[sp] = ((__a >= 0x80000000 and __a - 0x100000000 or __a) >= (__b >= 0x80000000 and __b - 0x100000000 or __b)) and 1 or 0 end")

        elseif op == 0x4F then -- i32.ge_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] >= __b and 1 or 0 end")

        -- i32 arithmetic
        elseif op == 0x67 then -- i32.clz
            emit("stack[sp] = ctx.i32_clz(stack[sp])")

        elseif op == 0x68 then -- i32.ctz
            emit("stack[sp] = ctx.i32_ctz(stack[sp])")

        elseif op == 0x69 then -- i32.popcnt
            emit("stack[sp] = ctx.i32_popcnt(stack[sp])")

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

        elseif op == 0x71 then -- i32.and
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = band(stack[sp], __b) end")

        elseif op == 0x72 then -- i32.or
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = bor(stack[sp], __b) end")

        elseif op == 0x73 then -- i32.xor
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = bxor(stack[sp], __b) end")

        elseif op == 0x74 then -- i32.shl
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = lshift(stack[sp], band(__b, 31)) end")

        elseif op == 0x75 then -- i32.shr_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = arshift(stack[sp], band(__b, 31)) end")

        elseif op == 0x76 then -- i32.shr_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = rshift(stack[sp], band(__b, 31)) end")

        elseif op == 0x77 then -- i32.rotl
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = bit32.lrotate(stack[sp], band(__b, 31)) end")

        elseif op == 0x78 then -- i32.rotr
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = bit32.rrotate(stack[sp], band(__b, 31)) end")

        -- Memory load ops
        elseif op == 0x28 then -- i32.load
            local off = instr.offset
            if off == 0 then
                emit("do local __addr = stack[sp]")
            else
                emit(string.format("do local __addr = stack[sp] + %d", off))
            end
            emit("  if __addr + 4 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
            emit("  if band(__addr, 3) == 0 then stack[sp] = mem.data[rshift(__addr, 2)] or 0")
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
            emit("  if __addr + 1 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
            emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
            emit("  stack[sp] = band(rshift(mem.data[__wi] or 0, __bo * 8), 0xFF) end")

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
            emit("  stack[sp] = {__v, bit32.btest(__v, 0x80000000) and 0xFFFFFFFF or 0} end")

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
            emit("  if __addr + 4 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
            emit("  __v = band(__v, 0xFFFFFFFF)")
            emit("  if band(__addr, 3) == 0 then mem.data[rshift(__addr, 2)] = __v")
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
            emit("  if __addr + 1 > mem.byte_length or __addr < 0 then error({msg='out of bounds memory access'}) end")
            emit("  local __wi = rshift(__addr, 2); local __bo = band(__addr, 3)")
            emit("  local __sh = __bo * 8; local __mask = bnot(lshift(0xFF, __sh))")
            emit("  local __w = mem.data[__wi] or 0")
            emit("  mem.data[__wi] = bor(band(__w, __mask), lshift(band(__v, 0xFF), __sh)) end")

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

        -- Memory size/grow
        elseif op == 0x3F then -- memory.size
            emit("sp = sp + 1; stack[sp] = mem:size()")

        elseif op == 0x40 then -- memory.grow
            emit("stack[sp] = mem:grow(stack[sp])")

        -- i64 comparison ops (delegate to ctx helpers)
        elseif op == 0x50 then -- i64.eqz
            emit("stack[sp] = ctx.i64_eqz(stack[sp]) and 1 or 0")
        elseif op == 0x51 then -- i64.eq
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_eq(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x52 then -- i64.ne
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_ne(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x53 then -- i64.lt_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_lt_s(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x54 then -- i64.lt_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_lt_u(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x55 then -- i64.gt_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_gt_s(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x56 then -- i64.gt_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_gt_u(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x57 then -- i64.le_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_le_s(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x58 then -- i64.le_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_le_u(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x59 then -- i64.ge_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_ge_s(stack[sp], __b) and 1 or 0 end")
        elseif op == 0x5A then -- i64.ge_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_ge_u(stack[sp], __b) and 1 or 0 end")

        -- i64 arithmetic (delegate to ctx helpers)
        elseif op == 0x79 then emit("stack[sp] = ctx.i64_clz(stack[sp])")
        elseif op == 0x7A then emit("stack[sp] = ctx.i64_ctz(stack[sp])")
        elseif op == 0x7B then emit("stack[sp] = ctx.i64_popcnt(stack[sp])")
        elseif op == 0x7C then -- i64.add
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_add(stack[sp], __b) end")
        elseif op == 0x7D then -- i64.sub
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_sub(stack[sp], __b) end")
        elseif op == 0x7E then -- i64.mul
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_mul(stack[sp], __b) end")
        elseif op == 0x7F then -- i64.div_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_div_s(stack[sp], __b) end")
        elseif op == 0x80 then -- i64.div_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_div_u(stack[sp], __b) end")
        elseif op == 0x81 then -- i64.rem_s
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_rem_s(stack[sp], __b) end")
        elseif op == 0x82 then -- i64.rem_u
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.i64_rem_u(stack[sp], __b) end")
        elseif op == 0x83 then -- i64.and
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = {band(stack[sp][1], __b[1]), band(stack[sp][2], __b[2])} end")
        elseif op == 0x84 then -- i64.or
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = {bor(stack[sp][1], __b[1]), bor(stack[sp][2], __b[2])} end")
        elseif op == 0x85 then -- i64.xor
            emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = {bxor(stack[sp][1], __b[1]), bxor(stack[sp][2], __b[2])} end")
        elseif op == 0x86 then -- i64.shl
            emit("do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.i64_shl(stack[sp], __s) end")
        elseif op == 0x87 then -- i64.shr_s
            emit("do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.i64_shr_s(stack[sp], __s) end")
        elseif op == 0x88 then -- i64.shr_u
            emit("do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.i64_shr_u(stack[sp], __s) end")
        elseif op == 0x89 then -- i64.rotl
            emit("do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.i64_rotl(stack[sp], __s) end")
        elseif op == 0x8A then -- i64.rotr
            emit("do local __b = stack[sp]; sp = sp - 1; local __s = type(__b) == 'table' and __b[1] or __b; stack[sp] = ctx.i64_rotr(stack[sp], __s) end")

        -- f32 comparison ops
        elseif op == 0x5B then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a == __b and 1 or 0) end")
        elseif op == 0x5C then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 1 or (__a ~= __b and 1 or 0) end")
        elseif op == 0x5D then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] < __b and 1 or 0 end")
        elseif op == 0x5E then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] > __b and 1 or 0 end")
        elseif op == 0x5F then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a <= __b and 1 or 0) end")
        elseif op == 0x60 then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a >= __b and 1 or 0) end")

        -- f64 comparison ops
        elseif op == 0x61 then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a == __b and 1 or 0) end")
        elseif op == 0x62 then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 1 or (__a ~= __b and 1 or 0) end")
        elseif op == 0x63 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] < __b and 1 or 0 end")
        elseif op == 0x64 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] > __b and 1 or 0 end")
        elseif op == 0x65 then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a <= __b and 1 or 0) end")
        elseif op == 0x66 then emit("do local __b = stack[sp]; sp = sp - 1; local __a = stack[sp]; stack[sp] = (ctx.isnan(__a) or ctx.isnan(__b)) and 0 or (__a >= __b and 1 or 0) end")

        -- f32 arithmetic (delegate to ctx helpers)
        elseif op == 0x8B then emit("stack[sp] = ctx.f32_abs(stack[sp])")
        elseif op == 0x8C then emit("stack[sp] = ctx.f32_neg(stack[sp])")
        elseif op == 0x8D then emit("stack[sp] = ctx.f32_ceil(stack[sp])")
        elseif op == 0x8E then emit("stack[sp] = ctx.f32_floor(stack[sp])")
        elseif op == 0x8F then emit("stack[sp] = ctx.f32_trunc(stack[sp])")
        elseif op == 0x90 then emit("stack[sp] = ctx.f32_nearest(stack[sp])")
        elseif op == 0x91 then emit("stack[sp] = ctx.f32_sqrt(stack[sp])")
        elseif op == 0x92 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_trunc_val(stack[sp] + __b) end")
        elseif op == 0x93 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_trunc_val(stack[sp] - __b) end")
        elseif op == 0x94 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_trunc_val(stack[sp] * __b) end")
        elseif op == 0x95 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_trunc_val(stack[sp] / __b) end")
        elseif op == 0x96 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_min(stack[sp], __b) end")
        elseif op == 0x97 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_max(stack[sp], __b) end")
        elseif op == 0x98 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f32_copysign(stack[sp], __b) end")

        -- f64 arithmetic (delegate to ctx helpers)
        elseif op == 0x99 then emit("stack[sp] = ctx.f64_abs(stack[sp])")
        elseif op == 0x9A then emit("stack[sp] = ctx.f64_neg(stack[sp])")
        elseif op == 0x9B then emit("stack[sp] = ctx.f64_ceil(stack[sp])")
        elseif op == 0x9C then emit("stack[sp] = ctx.f64_floor(stack[sp])")
        elseif op == 0x9D then emit("stack[sp] = ctx.f64_trunc(stack[sp])")
        elseif op == 0x9E then emit("stack[sp] = ctx.f64_nearest(stack[sp])")
        elseif op == 0x9F then emit("stack[sp] = ctx.f64_sqrt(stack[sp])")
        elseif op == 0xA0 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] + __b end")
        elseif op == 0xA1 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] - __b end")
        elseif op == 0xA2 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] * __b end")
        elseif op == 0xA3 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = stack[sp] / __b end")
        elseif op == 0xA4 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f64_min(stack[sp], __b) end")
        elseif op == 0xA5 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f64_max(stack[sp], __b) end")
        elseif op == 0xA6 then emit("do local __b = stack[sp]; sp = sp - 1; stack[sp] = ctx.f64_copysign(stack[sp], __b) end")

        -- Conversion ops (delegate to ctx helpers)
        elseif op == 0xA7 then -- i32.wrap_i64
            emit("do local __v = stack[sp]; stack[sp] = type(__v) == 'table' and __v[1] or band(__v, 0xFFFFFFFF) end")
        elseif op == 0xA8 then emit("stack[sp] = ctx.i32_trunc_f32_s(stack[sp])")
        elseif op == 0xA9 then emit("stack[sp] = ctx.i32_trunc_f32_u(stack[sp])")
        elseif op == 0xAA then emit("stack[sp] = ctx.i32_trunc_f64_s(stack[sp])")
        elseif op == 0xAB then emit("stack[sp] = ctx.i32_trunc_f64_u(stack[sp])")
        elseif op == 0xAC then -- i64.extend_i32_s
            emit("do local __v = stack[sp]; __v = type(__v) == 'table' and __v[1] or __v")
            emit("  stack[sp] = {__v, bit32.btest(__v, 0x80000000) and 0xFFFFFFFF or 0} end")
        elseif op == 0xAD then -- i64.extend_i32_u
            emit("do local __v = stack[sp]; __v = type(__v) == 'table' and __v[1] or __v")
            emit("  stack[sp] = {__v, 0} end")
        elseif op == 0xAE then emit("stack[sp] = ctx.i64_trunc_f32_s(stack[sp])")
        elseif op == 0xAF then emit("stack[sp] = ctx.i64_trunc_f32_u(stack[sp])")
        elseif op == 0xB0 then emit("stack[sp] = ctx.i64_trunc_f64_s(stack[sp])")
        elseif op == 0xB1 then emit("stack[sp] = ctx.i64_trunc_f64_u(stack[sp])")
        elseif op == 0xB2 then emit("stack[sp] = ctx.f32_convert_i32_s(stack[sp])")
        elseif op == 0xB3 then emit("stack[sp] = ctx.f32_convert_i32_u(stack[sp])")
        elseif op == 0xB4 then emit("stack[sp] = ctx.f32_convert_i64_s(stack[sp])")
        elseif op == 0xB5 then emit("stack[sp] = ctx.f32_convert_i64_u(stack[sp])")
        elseif op == 0xB6 then emit("stack[sp] = ctx.f32_demote_f64(stack[sp])")
        elseif op == 0xB7 then -- f64.convert_i32_s
            emit("do local __v = stack[sp]; __v = __v >= 0x80000000 and __v - 0x100000000 or __v; stack[sp] = __v + 0.0 end")
        elseif op == 0xB8 then -- f64.convert_i32_u
            emit("stack[sp] = stack[sp] + 0.0")
        elseif op == 0xB9 then emit("stack[sp] = ctx.f64_convert_i64_s(stack[sp])")
        elseif op == 0xBA then emit("stack[sp] = ctx.f64_convert_i64_u(stack[sp])")
        elseif op == 0xBB then -- f64.promote_f32
            emit("do local __v = stack[sp]; if ctx.isnan(__v) then stack[sp] = 0/0 end end")
        elseif op == 0xBC then emit("stack[sp] = ctx.i32_reinterpret_f32(stack[sp])")
        elseif op == 0xBD then emit("stack[sp] = ctx.i64_reinterpret_f64(stack[sp])")
        elseif op == 0xBE then emit("stack[sp] = ctx.f32_reinterpret(stack[sp])")
        elseif op == 0xBF then emit("stack[sp] = ctx.f64_reinterpret(stack[sp])")

        -- Sign extension ops
        elseif op == 0xC0 then -- i32.extend8_s
            emit("do local __v = band(stack[sp], 0xFF); if __v >= 0x80 then __v = __v - 0x100 end")
            emit("  if __v < 0 then __v = __v + 0x100000000 end; stack[sp] = __v end")
        elseif op == 0xC1 then -- i32.extend16_s
            emit("do local __v = band(stack[sp], 0xFFFF); if __v >= 0x8000 then __v = __v - 0x10000 end")
            emit("  if __v < 0 then __v = __v + 0x100000000 end; stack[sp] = __v end")
        elseif op == 0xC2 then emit("stack[sp] = ctx.i64_extend8_s(stack[sp])")
        elseif op == 0xC3 then emit("stack[sp] = ctx.i64_extend16_s(stack[sp])")
        elseif op == 0xC4 then emit("stack[sp] = ctx.i64_extend32_s(stack[sp])")

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
        log(string.format("Load error in func %d: %s\n", func_idx, tostring(err)))
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
