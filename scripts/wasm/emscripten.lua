-- scripts/wasm/emscripten.lua
-- Emscripten runtime support: provides WASM imports for the Emscripten-compiled
-- C code (invoke_*, WASI, syscalls, time functions, etc.)
--
-- These are NOT NetHack-specific -- they implement the Emscripten/WASI runtime
-- environment that any Emscripten-compiled C program needs.
--
-- Includes a virtual filesystem (VFS) backed by scripts/nethack_data.lua
-- for serving NetHack's data files (Lua scripts, help text, etc.)

local Interp = require("scripts.wasm.interp")
local bit32 = bit32

local Emscripten = {}

-- Load NetHack data files for the VFS (optional - won't crash if missing)
local ok_data, nethack_data = pcall(require, "scripts.nethack_data")
if not ok_data then nethack_data = {} end

-- Longjmp sentinel: thrown by _emscripten_throw_longjmp, caught by invoke_*
-- Has .msg so it passes through Interp.execute's error wrapping unchanged
local LONGJMP_TAG = {msg = "longjmp", longjmp = true}

-- WASI error codes
local WASI_ESUCCESS = 0
local WASI_EBADF = 8
local WASI_EINVAL = 28

-- POSIX errno values (syscalls return -errno on failure)
local ENOENT = 2
local EINVAL = 22
local ENOSYS = 38

-- O_* flags (from musl/Emscripten)
local O_WRONLY = 1
local O_RDWR   = 2
local O_CREAT  = 64
local O_TRUNC  = 512
local O_APPEND = 1024

-- Helper: read a null-terminated C string from WASM memory
local function read_cstring(memory, ptr, max_len)
    if ptr == 0 then return "" end
    max_len = max_len or 512
    local chars = {}
    for i = 0, max_len - 1 do
        local b = memory:load_byte(ptr + i)
        if b == 0 then break end
        chars[#chars + 1] = string.char(b)
    end
    return table.concat(chars)
end

-- Extract just the filename from a path (strip directory prefixes)
local function basename(path)
    return path:match("[^/]+$") or path
end

-----------------------------------------------------------------------
-- Virtual Filesystem (VFS)
-- Stores file data in memory, serves via openat/fd_read/fd_seek/fd_close.
-- fd 0-2 are stdin/stdout/stderr. VFS files start at fd 3.
-----------------------------------------------------------------------

local function vfs_new()
    local vfs = {
        files = nethack_data,  -- filename -> content string
        fds = {},              -- fd -> {data=string, pos=number, writable=bool}
        next_fd = 3,
    }

    -- Pre-create level 0 lock file with PID=1 (4 bytes, little-endian).
    -- NetHack's platform main (pcmain.c/unixmain.c) normally creates this
    -- via create_levelfile(0) + write(hackpid). Our sysfactorio.c skips it,
    -- so save_currentstate() would fail trying to open_levelfile(0).
    vfs.files["1lock.0"] = "\x01\x00\x00\x00"

    return vfs
end

local function vfs_open(vfs, path, flags)
    local name = basename(path)
    local is_write = (bit32.band(flags, O_WRONLY) ~= 0) or (bit32.band(flags, O_RDWR) ~= 0)
    local is_create = bit32.band(flags, O_CREAT) ~= 0

    -- Look up file in VFS
    local data = vfs.files[name]

    if data == nil then
        if is_create then
            -- Create a writable file (e.g., paniclog, save files)
            data = ""
        else
            return nil  -- file not found
        end
    end

    local fd = vfs.next_fd
    vfs.next_fd = fd + 1
    local pos = 0
    if bit32.band(flags, O_APPEND) ~= 0 then
        pos = #data
    end
    if bit32.band(flags, O_TRUNC) ~= 0 and is_write then
        data = ""
    end
    vfs.fds[fd] = {data = data, pos = pos, writable = is_write, name = name}
    return fd
end

local function vfs_read(vfs, fd, buf_ptr, buf_len, memory)
    local entry = vfs.fds[fd]
    if not entry then return -1 end

    local data = entry.data
    local pos = entry.pos
    local avail = #data - pos
    if avail <= 0 then return 0 end

    local to_read = buf_len
    if to_read > avail then to_read = avail end

    for i = 0, to_read - 1 do
        memory:store_byte(buf_ptr + i, string.byte(data, pos + i + 1))
    end
    entry.pos = pos + to_read
    return to_read
end

local function vfs_write(vfs, fd, buf_ptr, buf_len, memory)
    local entry = vfs.fds[fd]
    if not entry or not entry.writable then return -1 end

    -- Read bytes from WASM memory
    local chars = {}
    for i = 0, buf_len - 1 do
        chars[#chars + 1] = string.char(memory:load_byte(buf_ptr + i))
    end
    local new_data = table.concat(chars)

    -- Insert at current position
    local data = entry.data
    local pos = entry.pos
    if pos >= #data then
        -- Append (common case)
        entry.data = data .. new_data
    else
        -- Overwrite in the middle
        entry.data = data:sub(1, pos) .. new_data .. data:sub(pos + buf_len + 1)
    end
    entry.pos = pos + buf_len
    return buf_len
end

local function vfs_seek(vfs, fd, offset, whence)
    local entry = vfs.fds[fd]
    if not entry then return -1 end

    local new_pos
    if whence == 0 then      -- SEEK_SET
        new_pos = offset
    elseif whence == 1 then  -- SEEK_CUR
        new_pos = entry.pos + offset
    elseif whence == 2 then  -- SEEK_END
        new_pos = #entry.data + offset
    else
        return -1
    end

    if new_pos < 0 then new_pos = 0 end
    if new_pos > #entry.data then new_pos = #entry.data end
    entry.pos = new_pos
    return new_pos
end

local function vfs_close(vfs, fd)
    local entry = vfs.fds[fd]
    if entry then
        -- Persist writable file data so it can be re-opened later
        if entry.writable and entry.name then
            vfs.files[entry.name] = entry.data
        end
        vfs.fds[fd] = nil
        return true
    end
    return false
end

-- Add all Emscripten/WASI imports to the imports table.
-- memory_ref: function() returning the Memory object
-- instance_ref: table {inst = <instance>} (populated after instantiation)
function Emscripten.add_imports(imports, memory_ref, instance_ref)

    -- Shared VFS instance (created lazily, stored on WASM instance)
    local function get_vfs()
        local inst = instance_ref.inst
        if not inst._vfs then
            inst._vfs = vfs_new()
        end
        return inst._vfs
    end

    -------------------------------------------------------------------
    -- Emscripten core
    -------------------------------------------------------------------

    imports["env.__assert_fail"] = function(condition, filename, line, func_name)
        local memory = memory_ref()
        local cond_str = read_cstring(memory, condition)
        local file_str = read_cstring(memory, filename)
        error({msg = string.format("Assertion failed: %s (%s:%d)", cond_str, file_str, line)})
    end

    imports["env.exit"] = function(status)
        error({msg = "exit(" .. tostring(status) .. ")", exit = true, status = status})
    end

    imports["env._abort_js"] = function()
        error({msg = "abort()", abort = true})
    end

    imports["env._emscripten_system"] = function(command_ptr)
        return -1  -- system() not available
    end

    imports["env.emscripten_resize_heap"] = function(requested_size)
        local memory = memory_ref()
        local current = memory.byte_length
        if requested_size <= current then return 1 end
        local pages_needed = math.ceil(requested_size / 65536)
        local current_pages = math.floor(current / 65536)
        local delta = pages_needed - current_pages
        if delta <= 0 then return 1 end
        local old = memory:grow(delta)
        return (old ~= 0xFFFFFFFF) and 1 or 0
    end

    -------------------------------------------------------------------
    -- Longjmp support (setjmp/longjmp via Emscripten's invoke_* pattern)
    -------------------------------------------------------------------

    imports["env._emscripten_throw_longjmp"] = function()
        error(LONGJMP_TAG)
    end

    local function make_invoke(has_return)
        return function(index, ...)
            local inst = instance_ref.inst
            local args = {...}

            -- Look up function from indirect table (table 0)
            local func_idx = inst.tables[0][index]
            if func_idx == nil then
                error({msg = "invoke: bad function table index " .. tostring(index)})
            end

            -- Save stack pointer for longjmp recovery
            local sp = 0
            local sp_export = Interp.get_export(inst, "emscripten_stack_get_current")
            if sp_export then
                local saved_exec = inst.exec
                Interp.call(inst, sp_export, {})
                local sp_result = Interp.run(inst, 1000000)
                inst.exec = saved_exec
                sp = (sp_result.results and sp_result.results[1]) or 0
            end

            -- Call the target function (re-entrant into the interpreter)
            local saved_exec = inst.exec
            Interp.call(inst, func_idx, args)
            local result
            repeat
                result = Interp.run(inst, 100000000)
            until result.status ~= "running"
            inst.exec = saved_exec

            if result.status == "finished" then
                if has_return and result.results and result.results[1] ~= nil then
                    return result.results[1]
                end
                return
            end

            if result.status == "error" then
                local msg = result.message

                -- Check for longjmp
                if type(msg) == "table" and msg.longjmp then
                    -- Restore stack pointer
                    local restore_export = Interp.get_export(inst, "_emscripten_stack_restore")
                    if restore_export and sp ~= 0 then
                        Interp.call(inst, restore_export, {sp})
                        Interp.run(inst, 1000000)
                        inst.exec = saved_exec
                    end

                    -- Call setThrew(1, 0) to signal longjmp occurred
                    local set_threw = Interp.get_export(inst, "setThrew")
                    if set_threw then
                        Interp.call(inst, set_threw, {1, 0})
                        Interp.run(inst, 1000000)
                        inst.exec = saved_exec
                    end

                    return has_return and 0 or nil
                end

                -- Not longjmp, re-raise the error
                error(msg)
            end

            -- Unexpected (e.g., waiting_input inside invoke)
            error({msg = "invoke: unexpected status " .. tostring(result.status)})
        end
    end

    imports["env.invoke_viii"] = make_invoke(false)
    imports["env.invoke_iiiiiii"] = make_invoke(true)
    imports["env.invoke_vii"] = make_invoke(false)
    imports["env.invoke_iiii"] = make_invoke(true)

    -------------------------------------------------------------------
    -- WASI snapshot preview1 (filesystem, clock, environment)
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.fd_close"] = function(fd)
        if fd <= 2 then return WASI_ESUCCESS end
        local vfs = get_vfs()
        if vfs_close(vfs, fd) then return WASI_ESUCCESS end
        return WASI_EBADF
    end

    imports["wasi_snapshot_preview1.fd_read"] = function(fd, iovs_ptr, iovs_len, nread_ptr)
        local memory = memory_ref()
        local vfs = get_vfs()
        local total = 0

        for i = 0, iovs_len - 1 do
            local base = iovs_ptr + i * 8
            local buf_ptr = memory:load_i32(base)
            local buf_len = memory:load_i32(base + 4)
            if buf_len > 0 then
                local n = vfs_read(vfs, fd, buf_ptr, buf_len, memory)
                if n < 0 then
                    memory:store_i32(nread_ptr, total)
                    return WASI_EBADF
                end
                total = total + n
                if n < buf_len then break end  -- short read = EOF
            end
        end

        memory:store_i32(nread_ptr, total)
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.fd_write"] = function(fd, iovs_ptr, iovs_len, nwritten_ptr)
        local memory = memory_ref()
        local vfs = get_vfs()
        local total = 0

        for i = 0, iovs_len - 1 do
            local base = iovs_ptr + i * 8
            local buf_ptr = memory:load_i32(base)
            local buf_len = memory:load_i32(base + 4)
            if buf_len > 0 then
                -- Try VFS first (for writable files)
                local n = vfs_write(vfs, fd, buf_ptr, buf_len, memory)
                if n < 0 then
                    -- Not a VFS file - handle stdout/stderr
                    if fd == 1 or fd == 2 then
                        local chars = {}
                        for j = 0, buf_len - 1 do
                            local b = memory:load_byte(buf_ptr + j)
                            if b >= 32 and b < 127 then
                                chars[#chars + 1] = string.char(b)
                            elseif b == 10 then
                                chars[#chars + 1] = "\n"
                            end
                        end
                        local text = table.concat(chars)
                        if #text > 0 then
                            log("[WASM " .. (fd == 1 and "stdout" or "stderr") .. "] " .. text)
                        end
                        n = buf_len
                    else
                        memory:store_i32(nwritten_ptr, total)
                        return WASI_EBADF
                    end
                end
                total = total + n
            end
        end

        memory:store_i32(nwritten_ptr, total)
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.fd_seek"] = function(fd, offset, whence, newoffset_ptr)
        -- offset is i64 ({lo, hi} table), whence is i32, newoffset_ptr is i32
        local vfs = get_vfs()
        local memory = memory_ref()
        local off = offset
        if type(offset) == "table" then off = offset[1] end  -- use low 32 bits

        local new_pos = vfs_seek(vfs, fd, off, whence)
        if new_pos < 0 then return WASI_EBADF end

        -- Write new position as i64 to newoffset_ptr
        memory:store_i32(newoffset_ptr, new_pos)
        memory:store_i32(newoffset_ptr + 4, 0)
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.clock_time_get"] = function(clock_id, precision, time_ptr)
        local memory = memory_ref()
        -- Return a fixed timestamp in nanoseconds (~Nov 2023)
        memory:store_i32(time_ptr, 2063597568)      -- low 32 bits
        memory:store_i32(time_ptr + 4, 395812564)    -- high 32 bits
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.environ_sizes_get"] = function(count_ptr, buf_size_ptr)
        local memory = memory_ref()
        memory:store_i32(count_ptr, 0)
        memory:store_i32(buf_size_ptr, 0)
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.environ_get"] = function(environ_ptr, buf_ptr)
        return WASI_ESUCCESS
    end

    -------------------------------------------------------------------
    -- Linux syscalls (Emscripten's POSIX layer)
    -- These back musl's fopen/fread/fwrite/etc.
    -- Return -errno on failure, fd or 0 on success.
    -------------------------------------------------------------------

    imports["env.__syscall_openat"] = function(dirfd, path_ptr, flags, mode)
        local memory = memory_ref()
        local path = read_cstring(memory, path_ptr)
        local vfs = get_vfs()

        -- Decode flags for logging
        local flag_str = ""
        if bit32.band(flags, O_WRONLY) ~= 0 then flag_str = flag_str .. "WR " end
        if bit32.band(flags, O_RDWR) ~= 0 then flag_str = flag_str .. "RW " end
        if bit32.band(flags, O_CREAT) ~= 0 then flag_str = flag_str .. "CREAT " end
        if bit32.band(flags, O_TRUNC) ~= 0 then flag_str = flag_str .. "TRUNC " end
        if bit32.band(flags, O_APPEND) ~= 0 then flag_str = flag_str .. "APPEND " end
        if flag_str == "" then flag_str = "RDONLY " end

        local fd = vfs_open(vfs, path, flags)
        if fd then
            log("[WASM openat] " .. path .. " [" .. flag_str .. "] -> fd " .. fd)
            return fd
        end

        log("[WASM openat] " .. path .. " [" .. flag_str .. "] -> ENOENT")
        return -ENOENT
    end

    imports["env.__syscall_fcntl64"] = function(fd, cmd, arg)
        -- F_GETFD=1, F_SETFD=2, F_GETFL=3, F_SETFL=4
        if cmd == 1 then return 0 end  -- F_GETFD: return 0 (no close-on-exec)
        if cmd == 3 then return 0 end  -- F_GETFL: return 0 (read-only)
        return -EINVAL
    end

    imports["env.__syscall_ioctl"] = function(fd, op, arg)
        return -ENOSYS
    end

    imports["env.__syscall_faccessat"] = function(dirfd, path_ptr, amode, flags)
        local memory = memory_ref()
        local path = read_cstring(memory, path_ptr)
        local name = basename(path)
        -- Check if file exists in VFS (includes runtime-created files)
        local vfs = get_vfs()
        if vfs.files[name] then return 0 end
        return -ENOENT
    end

    imports["env.__syscall_dup3"] = function(oldfd, newfd, flags)
        return -ENOSYS
    end

    imports["env.__syscall_getcwd"] = function(buf_ptr, size)
        local memory = memory_ref()
        if size < 2 then return -EINVAL end
        memory:store_byte(buf_ptr, string.byte("/"))
        memory:store_byte(buf_ptr + 1, 0)
        return buf_ptr
    end

    imports["env.__syscall_unlinkat"] = function(dirfd, path_ptr, flags)
        return 0
    end

    imports["env.__syscall_rmdir"] = function(path_ptr)
        return 0
    end

    imports["env.__syscall_renameat"] = function(olddirfd, oldpath_ptr, newdirfd, newpath_ptr)
        return -ENOSYS
    end

    imports["env.__syscall_readlinkat"] = function(dirfd, path_ptr, buf_ptr, bufsize)
        return -EINVAL
    end

    -------------------------------------------------------------------
    -- Time functions
    -------------------------------------------------------------------

    imports["env.emscripten_date_now"] = function()
        return 1700000000000.0
    end

    imports["env.emscripten_get_now"] = function()
        return 0.0
    end

    imports["env._tzset_js"] = function(timezone_ptr, daylight_ptr, std_name_ptr, dst_name_ptr)
        local memory = memory_ref()
        memory:store_i32(timezone_ptr, 0)
        memory:store_i32(daylight_ptr, 0)
    end

    imports["env._mktime_js"] = function(tm_ptr)
        return {1700000000, 0}  -- i64
    end

    imports["env._localtime_js"] = function(time_val, tm_ptr)
        local memory = memory_ref()
        memory:store_i32(tm_ptr + 0, 0)     -- tm_sec
        memory:store_i32(tm_ptr + 4, 0)     -- tm_min
        memory:store_i32(tm_ptr + 8, 12)    -- tm_hour
        memory:store_i32(tm_ptr + 12, 14)   -- tm_mday
        memory:store_i32(tm_ptr + 16, 10)   -- tm_mon
        memory:store_i32(tm_ptr + 20, 123)  -- tm_year
        memory:store_i32(tm_ptr + 24, 2)    -- tm_wday
        memory:store_i32(tm_ptr + 28, 317)  -- tm_yday
        memory:store_i32(tm_ptr + 32, 0)    -- tm_isdst
    end

    imports["env._gmtime_js"] = function(time_val, tm_ptr)
        imports["env._localtime_js"](time_val, tm_ptr)
    end
end

return Emscripten
