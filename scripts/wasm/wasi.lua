-- scripts/wasm/wasi.lua
-- WASI snapshot preview1 runtime support: provides WASM imports for the
-- clang+wasi-libc compiled C code.
--
-- These are NOT NetHack-specific -- they implement the WASI runtime
-- environment that any wasi-libc compiled C program needs.
--
-- Includes a virtual filesystem (VFS) backed by scripts/nethack_data.lua
-- for serving NetHack's data files (Lua scripts, help text, etc.)

local bit32 = bit32

local Wasi = {}

-- Load NetHack data files for the VFS (optional - won't crash if missing)
local ok_data, nethack_data = pcall(require, "scripts.nethack_data")
if not ok_data then nethack_data = {} end

-- WASI error codes
local WASI_ESUCCESS = 0
local WASI_E2BIG    = 1
local WASI_EACCES   = 2
local WASI_EBADF    = 8
local WASI_EEXIST   = 20
local WASI_EINVAL   = 28
local WASI_EIO      = 29
local WASI_ENOENT   = 44
local WASI_ENOSYS   = 52
local WASI_ENOTDIR  = 54

-- WASI file types
local WASI_FILETYPE_UNKNOWN   = 0
local WASI_FILETYPE_DIRECTORY = 3
local WASI_FILETYPE_REGULAR   = 4

-- WASI fd flags
local WASI_FDFLAG_APPEND = 1
local WASI_FDFLAG_DSYNC  = 2
local WASI_FDFLAG_NONBLOCK = 4
local WASI_FDFLAG_SYNC  = 16

-- WASI open flags
local WASI_OFLAGS_CREAT = 1
local WASI_OFLAGS_DIRECTORY = 2
local WASI_OFLAGS_EXCL = 4
local WASI_OFLAGS_TRUNC = 8

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

-- Read a string of known length from WASM memory
local function read_string_n(memory, ptr, len)
    if len <= 0 then return "" end
    local chars = {}
    for i = 0, len - 1 do
        local b = memory:load_byte(ptr + i)
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
-- Stores file data in memory, serves via WASI fd_read/fd_seek/fd_close.
-- fd 0 = stdin, 1 = stdout, 2 = stderr
-- fd 3 = preopened directory "/"
-- VFS file fds start at 4.
-----------------------------------------------------------------------

local function vfs_new()
    local vfs = {
        files = nethack_data,  -- filename -> content string
        fds = {},              -- fd -> {data=string, pos=number, writable=bool, name=string}
        next_fd = 4,           -- fd 3 is preopened dir
    }

    -- Pre-create level 0 lock file with PID=1 (4 bytes, little-endian).
    -- NetHack's platform main (pcmain.c/unixmain.c) normally creates this
    -- via create_levelfile(0) + write(hackpid). Our sysfactorio.c does this
    -- via Sfo_int, and save_currentstate() expects it to exist.
    vfs.files["1lock.0"] = "\x01\x00\x00\x00"

    return vfs
end

local function vfs_open(vfs, path, oflags, fdflags)
    local name = basename(path)
    local is_create = bit32.band(oflags, WASI_OFLAGS_CREAT) ~= 0
    local is_trunc = bit32.band(oflags, WASI_OFLAGS_TRUNC) ~= 0
    local is_append = bit32.band(fdflags, WASI_FDFLAG_APPEND) ~= 0

    -- Look up file in VFS
    local data = vfs.files[name]

    if data == nil then
        if is_create then
            data = ""
        else
            return nil  -- file not found
        end
    end

    local fd = vfs.next_fd
    vfs.next_fd = fd + 1
    local pos = 0
    if is_append then
        pos = #data
    end
    if is_trunc then
        data = ""
    end
    -- All VFS files are writable (simplifies implementation)
    vfs.fds[fd] = {data = data, pos = pos, writable = true, name = name}
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
        entry.data = data .. new_data
    else
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

-- Add all WASI imports to the imports table.
-- memory_ref: function() returning the Memory object
-- instance_ref: table {inst = <instance>} (populated after instantiation)
function Wasi.add_imports(imports, memory_ref, instance_ref)

    -- Shared VFS instance (created lazily, stored on WASM instance)
    local function get_vfs()
        local inst = instance_ref.inst
        if not inst._vfs then
            inst._vfs = vfs_new()
        end
        return inst._vfs
    end

    -------------------------------------------------------------------
    -- Process lifecycle
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.proc_exit"] = function(code)
        error({msg = "exit(" .. tostring(code) .. ")", exit = true, status = code})
    end

    -------------------------------------------------------------------
    -- Command line arguments
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.args_sizes_get"] = function(argc_ptr, argv_buf_size_ptr)
        local memory = memory_ref()
        -- One arg: "nethack"
        memory:store_i32(argc_ptr, 1)
        memory:store_i32(argv_buf_size_ptr, 8) -- "nethack\0"
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.args_get"] = function(argv_ptr, argv_buf_ptr)
        local memory = memory_ref()
        -- argv[0] points to argv_buf
        memory:store_i32(argv_ptr, argv_buf_ptr)
        -- Write "nethack\0" to argv_buf
        local arg = "nethack"
        for i = 1, #arg do
            memory:store_byte(argv_buf_ptr + i - 1, string.byte(arg, i))
        end
        memory:store_byte(argv_buf_ptr + #arg, 0)
        return WASI_ESUCCESS
    end

    -------------------------------------------------------------------
    -- Environment variables
    -------------------------------------------------------------------

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
    -- Preopened directories
    -- wasi-libc startup calls fd_prestat_get on fd 3, 4, 5, ... until EBADF
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.fd_prestat_get"] = function(fd, buf_ptr)
        local memory = memory_ref()
        if fd == 3 then
            -- Preopened directory: type = 0 (dir), name_len = 1 ("/")
            memory:store_i32(buf_ptr, 0)     -- pr_type = dir
            memory:store_i32(buf_ptr + 4, 1) -- pr_name_len = 1
            return WASI_ESUCCESS
        end
        return WASI_EBADF
    end

    imports["wasi_snapshot_preview1.fd_prestat_dir_name"] = function(fd, path_ptr, path_len)
        local memory = memory_ref()
        if fd == 3 then
            memory:store_byte(path_ptr, string.byte("/"))
            return WASI_ESUCCESS
        end
        return WASI_EBADF
    end

    -------------------------------------------------------------------
    -- File descriptor operations
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.fd_close"] = function(fd)
        if fd <= 3 then return WASI_ESUCCESS end
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

    imports["wasi_snapshot_preview1.fd_fdstat_get"] = function(fd, buf_ptr)
        local memory = memory_ref()
        -- struct fdstat: u8 fs_filetype, u16 fs_flags, u64 fs_rights_base, u64 fs_rights_inheriting
        -- total 24 bytes
        if fd == 0 then
            -- stdin: character device
            memory:store_byte(buf_ptr, 2)  -- FILETYPE_CHARACTER_DEVICE
            memory:store_byte(buf_ptr + 1, 0)
            memory:store_i32(buf_ptr + 8, 0xFFFFFFFF)  -- all rights
            memory:store_i32(buf_ptr + 12, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 16, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 20, 0xFFFFFFFF)
            return WASI_ESUCCESS
        elseif fd == 1 or fd == 2 then
            -- stdout/stderr: character device
            memory:store_byte(buf_ptr, 2)  -- FILETYPE_CHARACTER_DEVICE
            memory:store_byte(buf_ptr + 1, 0)
            memory:store_i32(buf_ptr + 8, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 12, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 16, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 20, 0xFFFFFFFF)
            return WASI_ESUCCESS
        elseif fd == 3 then
            -- preopened directory
            memory:store_byte(buf_ptr, WASI_FILETYPE_DIRECTORY)
            memory:store_byte(buf_ptr + 1, 0)
            memory:store_i32(buf_ptr + 8, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 12, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 16, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 20, 0xFFFFFFFF)
            return WASI_ESUCCESS
        else
            -- VFS file
            local vfs = get_vfs()
            local entry = vfs.fds[fd]
            if not entry then return WASI_EBADF end
            memory:store_byte(buf_ptr, WASI_FILETYPE_REGULAR)
            memory:store_byte(buf_ptr + 1, 0)
            memory:store_i32(buf_ptr + 8, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 12, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 16, 0xFFFFFFFF)
            memory:store_i32(buf_ptr + 20, 0xFFFFFFFF)
            return WASI_ESUCCESS
        end
    end

    imports["wasi_snapshot_preview1.fd_fdstat_set_flags"] = function(fd, flags)
        -- No-op: flag changes don't matter in our VFS
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.fd_renumber"] = function(from_fd, to_fd)
        -- dup2-like: make to_fd refer to from_fd's file
        if from_fd <= 3 or to_fd <= 3 then return WASI_EBADF end
        local vfs = get_vfs()
        local entry = vfs.fds[from_fd]
        if not entry then return WASI_EBADF end
        vfs_close(vfs, to_fd)
        vfs.fds[to_fd] = entry
        vfs.fds[from_fd] = nil
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.fd_filestat_get"] = function(fd, buf_ptr)
        local memory = memory_ref()
        -- struct filestat: u64 dev, u64 ino, u8 filetype, u64 nlink, u64 size, u64 atim, u64 mtim, u64 ctim
        -- total 64 bytes - zero-fill then set what we know
        for i = 0, 63 do
            memory:store_byte(buf_ptr + i, 0)
        end
        if fd == 3 then
            memory:store_byte(buf_ptr + 16, WASI_FILETYPE_DIRECTORY) -- filetype at offset 16
            return WASI_ESUCCESS
        end
        local vfs = get_vfs()
        local entry = vfs.fds[fd]
        if not entry then return WASI_EBADF end
        memory:store_byte(buf_ptr + 16, WASI_FILETYPE_REGULAR) -- filetype
        -- size at offset 32 (u64)
        memory:store_i32(buf_ptr + 32, #entry.data)
        memory:store_i32(buf_ptr + 36, 0)
        return WASI_ESUCCESS
    end

    -------------------------------------------------------------------
    -- Path operations
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.path_open"] = function(dirfd, dirflags, path_ptr, path_len, oflags, fs_rights_base, fs_rights_inheriting, fdflags, fd_ptr)
        local memory = memory_ref()
        local path = read_string_n(memory, path_ptr, path_len)
        local vfs = get_vfs()

        log("[WASM path_open] " .. path .. " oflags=" .. tostring(oflags) .. " fdflags=" .. tostring(fdflags))

        local fd = vfs_open(vfs, path, oflags, fdflags)
        if fd then
            memory:store_i32(fd_ptr, fd)
            return WASI_ESUCCESS
        end
        return WASI_ENOENT
    end

    imports["wasi_snapshot_preview1.path_unlink_file"] = function(fd, path_ptr, path_len)
        -- No-op: we don't actually delete files
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.path_remove_directory"] = function(fd, path_ptr, path_len)
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.path_rename"] = function(old_fd, old_path_ptr, old_path_len, new_fd, new_path_ptr, new_path_len)
        local memory = memory_ref()
        local old_path = basename(read_string_n(memory, old_path_ptr, old_path_len))
        local new_path = basename(read_string_n(memory, new_path_ptr, new_path_len))
        local vfs = get_vfs()
        local data = vfs.files[old_path]
        if data then
            vfs.files[new_path] = data
            vfs.files[old_path] = nil
            return WASI_ESUCCESS
        end
        return WASI_ENOENT
    end

    imports["wasi_snapshot_preview1.path_filestat_get"] = function(fd, flags, path_ptr, path_len, buf_ptr)
        local memory = memory_ref()
        local path = read_string_n(memory, path_ptr, path_len)
        local name = basename(path)
        local vfs = get_vfs()

        -- Zero-fill the 64-byte filestat struct
        for i = 0, 63 do
            memory:store_byte(buf_ptr + i, 0)
        end

        local data = vfs.files[name]
        if data then
            memory:store_byte(buf_ptr + 16, WASI_FILETYPE_REGULAR)
            memory:store_i32(buf_ptr + 32, #data)
            memory:store_i32(buf_ptr + 36, 0)
            return WASI_ESUCCESS
        end
        return WASI_ENOENT
    end

    -------------------------------------------------------------------
    -- Clock
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.clock_time_get"] = function(clock_id, precision, time_ptr)
        local memory = memory_ref()
        -- Return a fixed timestamp in nanoseconds (~Nov 2023)
        memory:store_i32(time_ptr, 2063597568)      -- low 32 bits
        memory:store_i32(time_ptr + 4, 395812564)    -- high 32 bits
        return WASI_ESUCCESS
    end

    -------------------------------------------------------------------
    -- Random
    -------------------------------------------------------------------

    imports["wasi_snapshot_preview1.random_get"] = function(buf_ptr, buf_len)
        local memory = memory_ref()
        -- Simple PRNG: fill with pseudo-random bytes
        -- Good enough for NetHack's seed initialization
        local seed = os.time and os.time() or 42
        for i = 0, buf_len - 1 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            memory:store_byte(buf_ptr + i, seed % 256)
        end
        return WASI_ESUCCESS
    end

    imports["wasi_snapshot_preview1.poll_oneoff"] = function(in_ptr, out_ptr, nsubscriptions, nevents_ptr)
        local memory = memory_ref()
        -- Stub: report 0 events (NetHack doesn't use async I/O)
        memory:store_i32(nevents_ptr, 0)
        return WASI_ESUCCESS
    end

    -------------------------------------------------------------------
    -- POSIX stubs (referenced by NetHack but never actually called in WASM)
    -- These are imported due to --allow-undefined; provide no-op stubs.
    -------------------------------------------------------------------

    imports["env.fork"] = function() return -1 end
    imports["env.waitpid"] = function(pid, status, options) return -1 end
    imports["env.setgid"] = function(gid) return 0 end
    imports["env.setuid"] = function(uid) return 0 end
    imports["env.execv"] = function(path, argv) return -1 end
    imports["env.execl"] = function(path, ...) return -1 end
    imports["env.child"] = function(wt) return 0 end
    imports["env.system"] = function(cmd) return -1 end
    imports["env.tmpnam"] = function(buf) return 0 end
end

return Wasi
