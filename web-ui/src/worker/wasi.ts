// WASI snapshot_preview1 implementation for browser
// Mirrors scripts/wasm/wasi.lua

const WASI_ESUCCESS = 0;
const WASI_EBADF = 8;
const WASI_EEXIST = 20;
const WASI_EINVAL = 28;
const WASI_ENOENT = 44;
// const WASI_ENOSYS = 52;

const WASI_FILETYPE_DIRECTORY = 3;
const WASI_FILETYPE_REGULAR = 4;

const WASI_OFLAGS_CREAT = 1;
const WASI_OFLAGS_EXCL = 4;
const WASI_OFLAGS_TRUNC = 8;

const WASI_WHENCE_SET = 0;
const WASI_WHENCE_CUR = 1;
const WASI_WHENCE_END = 2;

interface VfsFile {
  data: Uint8Array;
  pos: number;
  flags: number;
}

interface FdEntry {
  type: 'stdin' | 'stdout' | 'stderr' | 'preopen' | 'file';
  path?: string;
  file?: VfsFile;
  preopenPath?: string;
}

export class WasiRuntime {
  private memory!: WebAssembly.Memory;
  private vfsFiles: Map<string, Uint8Array>;
  private fds: Map<number, FdEntry> = new Map();
  private nextFd = 4;
  private args: string[];
  private envVars: string[];

  constructor(dataFiles: Record<string, Uint8Array>) {
    // Initialize VFS with data files (overlay pattern — writes go to a copy)
    this.vfsFiles = new Map();
    for (const [name, data] of Object.entries(dataFiles)) {
      this.vfsFiles.set(name, data);
    }

    // Pre-create lock file (PID=1, little-endian)
    this.vfsFiles.set('1lock.0', new Uint8Array([0x01, 0x00, 0x00, 0x00]));

    // Standard fds
    this.fds.set(0, { type: 'stdin' });
    this.fds.set(1, { type: 'stdout' });
    this.fds.set(2, { type: 'stderr' });
    // Preopened dir: fd 3 = "/"
    this.fds.set(3, { type: 'preopen', preopenPath: '/' });

    this.args = ['nethack'];
    this.envVars = ['NETHACKOPTIONS=color,!autopickup,showexp,time,toptenwin'];
  }

  setMemory(mem: WebAssembly.Memory) {
    this.memory = mem;
  }

  private view() { return new DataView(this.memory.buffer); }
  private u8() { return new Uint8Array(this.memory.buffer); }

  private readString(ptr: number, len: number): string {
    const bytes = this.u8().slice(ptr, ptr + len);
    return new TextDecoder().decode(bytes);
  }

  private normalizePath(path: string): string {
    // Extract just the filename (strip directory prefixes), matching Lua WASI's basename()
    const idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  private openVfsFile(path: string, oflags: number, fdflags: number): number {
    const normalized = this.normalizePath(path);
    let data = this.vfsFiles.get(normalized);

    const creat = (oflags & WASI_OFLAGS_CREAT) !== 0;
    const excl = (oflags & WASI_OFLAGS_EXCL) !== 0;
    const trunc = (oflags & WASI_OFLAGS_TRUNC) !== 0;

    if (!data && !creat) return -WASI_ENOENT;
    if (data && creat && excl) return -WASI_EEXIST;

    if (!data || trunc) {
      data = new Uint8Array(0);
      this.vfsFiles.set(normalized, data);
    }

    const fd = this.nextFd++;
    this.fds.set(fd, {
      type: 'file',
      path: normalized,
      file: { data, pos: 0, flags: fdflags },
    });
    return fd;
  }

  getImports(): Record<string, Function> {
    const self = this;
    return {
      proc_exit(code: number) {
        throw new Error(`WASI proc_exit(${code})`);
      },

      args_sizes_get(argc_ptr: number, argv_buf_size_ptr: number): number {
        const v = self.view();
        v.setUint32(argc_ptr, self.args.length, true);
        let size = 0;
        for (const a of self.args) size += new TextEncoder().encode(a).length + 1;
        v.setUint32(argv_buf_size_ptr, size, true);
        return WASI_ESUCCESS;
      },

      args_get(argv_ptr: number, argv_buf_ptr: number): number {
        const v = self.view();
        const u8 = self.u8();
        let bufOff = argv_buf_ptr;
        for (let i = 0; i < self.args.length; i++) {
          v.setUint32(argv_ptr + i * 4, bufOff, true);
          const encoded = new TextEncoder().encode(self.args[i]);
          u8.set(encoded, bufOff);
          u8[bufOff + encoded.length] = 0;
          bufOff += encoded.length + 1;
        }
        return WASI_ESUCCESS;
      },

      environ_sizes_get(count_ptr: number, buf_size_ptr: number): number {
        const v = self.view();
        v.setUint32(count_ptr, self.envVars.length, true);
        let size = 0;
        for (const e of self.envVars) size += new TextEncoder().encode(e).length + 1;
        v.setUint32(buf_size_ptr, size, true);
        return WASI_ESUCCESS;
      },

      environ_get(environ_ptr: number, buf_ptr: number): number {
        const v = self.view();
        const u8 = self.u8();
        let bufOff = buf_ptr;
        for (let i = 0; i < self.envVars.length; i++) {
          v.setUint32(environ_ptr + i * 4, bufOff, true);
          const encoded = new TextEncoder().encode(self.envVars[i]);
          u8.set(encoded, bufOff);
          u8[bufOff + encoded.length] = 0;
          bufOff += encoded.length + 1;
        }
        return WASI_ESUCCESS;
      },

      fd_prestat_get(fd: number, buf_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry || entry.type !== 'preopen') return WASI_EBADF;
        const v = self.view();
        v.setUint32(buf_ptr, 0, true); // tag = __WASI_PREOPENTYPE_DIR
        const pathBytes = new TextEncoder().encode(entry.preopenPath!);
        v.setUint32(buf_ptr + 4, pathBytes.length, true);
        return WASI_ESUCCESS;
      },

      fd_prestat_dir_name(fd: number, path_ptr: number, path_len: number): number {
        const entry = self.fds.get(fd);
        if (!entry || entry.type !== 'preopen') return WASI_EBADF;
        const pathBytes = new TextEncoder().encode(entry.preopenPath!);
        self.u8().set(pathBytes.slice(0, path_len), path_ptr);
        return WASI_ESUCCESS;
      },

      fd_close(fd: number): number {
        if (!self.fds.has(fd)) return WASI_EBADF;
        self.fds.delete(fd);
        return WASI_ESUCCESS;
      },

      fd_read(fd: number, iovs_ptr: number, iovs_len: number, nread_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry) return WASI_EBADF;
        if (entry.type === 'stdin') {
          self.view().setUint32(nread_ptr, 0, true);
          return WASI_ESUCCESS;
        }
        if (entry.type !== 'file' || !entry.file) return WASI_EBADF;

        const file = entry.file;
        // Re-read in case file was replaced
        const currentData = self.vfsFiles.get(entry.path!);
        if (currentData) file.data = currentData;

        const v = self.view();
        let totalRead = 0;
        for (let i = 0; i < iovs_len; i++) {
          const bufPtr = v.getUint32(iovs_ptr + i * 8, true);
          const bufLen = v.getUint32(iovs_ptr + i * 8 + 4, true);
          const avail = Math.min(bufLen, file.data.length - file.pos);
          if (avail > 0) {
            self.u8().set(file.data.subarray(file.pos, file.pos + avail), bufPtr);
            file.pos += avail;
            totalRead += avail;
          }
        }
        v.setUint32(nread_ptr, totalRead, true);
        return WASI_ESUCCESS;
      },

      fd_write(fd: number, iovs_ptr: number, iovs_len: number, nwritten_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry) return WASI_EBADF;

        const v = self.view();
        const u8 = self.u8();

        if (entry.type === 'stdout' || entry.type === 'stderr') {
          let total = 0;
          let text = '';
          for (let i = 0; i < iovs_len; i++) {
            const bufPtr = v.getUint32(iovs_ptr + i * 8, true);
            const bufLen = v.getUint32(iovs_ptr + i * 8 + 4, true);
            text += new TextDecoder().decode(u8.slice(bufPtr, bufPtr + bufLen));
            total += bufLen;
          }
          if (text.trim()) console.log(`[${entry.type}]`, text);
          v.setUint32(nwritten_ptr, total, true);
          return WASI_ESUCCESS;
        }

        if (entry.type !== 'file' || !entry.file) return WASI_EBADF;
        const file = entry.file;

        let totalWritten = 0;
        for (let i = 0; i < iovs_len; i++) {
          const bufPtr = v.getUint32(iovs_ptr + i * 8, true);
          const bufLen = v.getUint32(iovs_ptr + i * 8 + 4, true);
          const writeEnd = file.pos + bufLen;

          // Grow file if needed
          if (writeEnd > file.data.length) {
            const newData = new Uint8Array(writeEnd);
            newData.set(file.data);
            file.data = newData;
            self.vfsFiles.set(entry.path!, file.data);
          }

          file.data.set(u8.slice(bufPtr, bufPtr + bufLen), file.pos);
          file.pos += bufLen;
          totalWritten += bufLen;
        }
        v.setUint32(nwritten_ptr, totalWritten, true);
        return WASI_ESUCCESS;
      },

      fd_seek(fd: number, offset: bigint, whence: number, newoffset_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry || entry.type !== 'file' || !entry.file) return WASI_EBADF;

        const file = entry.file;
        const off = Number(offset & 0xFFFFFFFFn) | 0; // sign-extend to i32

        let newPos: number;
        if (whence === WASI_WHENCE_SET) newPos = off;
        else if (whence === WASI_WHENCE_CUR) newPos = file.pos + off;
        else if (whence === WASI_WHENCE_END) newPos = file.data.length + off;
        else return WASI_EINVAL;

        if (newPos < 0) return WASI_EINVAL;
        file.pos = newPos;

        const v = self.view();
        // Write i64 result
        v.setUint32(newoffset_ptr, newPos, true);
        v.setUint32(newoffset_ptr + 4, 0, true);
        return WASI_ESUCCESS;
      },

      fd_fdstat_get(fd: number, buf_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry) return WASI_EBADF;

        const v = self.view();
        // Zero out the struct (24 bytes)
        for (let i = 0; i < 24; i++) self.u8()[buf_ptr + i] = 0;

        if (entry.type === 'preopen') {
          v.setUint8(buf_ptr, WASI_FILETYPE_DIRECTORY);
        } else if (entry.type === 'file') {
          v.setUint8(buf_ptr, WASI_FILETYPE_REGULAR);
        }
        // fs_rights_base and fs_rights_inheriting: all rights
        v.setBigUint64(buf_ptr + 8, 0xFFFFFFFFFFFFFFFFn, true);
        v.setBigUint64(buf_ptr + 16, 0xFFFFFFFFFFFFFFFFn, true);
        return WASI_ESUCCESS;
      },

      fd_fdstat_set_flags(_fd: number, _flags: number): number {
        return WASI_ESUCCESS;
      },

      fd_renumber(from_fd: number, to_fd: number): number {
        const entry = self.fds.get(from_fd);
        if (!entry) return WASI_EBADF;
        self.fds.set(to_fd, entry);
        self.fds.delete(from_fd);
        return WASI_ESUCCESS;
      },

      fd_filestat_get(fd: number, buf_ptr: number): number {
        const entry = self.fds.get(fd);
        if (!entry) return WASI_EBADF;

        const v = self.view();
        // Zero 64 bytes
        for (let i = 0; i < 64; i++) self.u8()[buf_ptr + i] = 0;

        if (entry.type === 'file' && entry.file) {
          v.setUint8(buf_ptr + 16, WASI_FILETYPE_REGULAR);
          v.setBigUint64(buf_ptr + 32, BigInt(entry.file.data.length), true);
        } else if (entry.type === 'preopen') {
          v.setUint8(buf_ptr + 16, WASI_FILETYPE_DIRECTORY);
        }
        return WASI_ESUCCESS;
      },

      path_open(
        dirfd: number, _dirflags: number,
        path_ptr: number, path_len: number,
        oflags: number,
        _fs_rights_base: bigint,
        _fs_rights_inheriting: bigint,
        fdflags: number,
        fd_ptr: number
      ): number {
        if (!self.fds.has(dirfd)) return WASI_EBADF;
        const path = self.readString(path_ptr, path_len);
        const result = self.openVfsFile(path, oflags, fdflags);
        if (result < 0) return -result; // result is negated error
        self.view().setUint32(fd_ptr, result, true);
        return WASI_ESUCCESS;
      },

      path_unlink_file(_fd: number, path_ptr: number, path_len: number): number {
        const path = self.normalizePath(self.readString(path_ptr, path_len));
        self.vfsFiles.delete(path);
        return WASI_ESUCCESS;
      },

      path_remove_directory(_fd: number, _path_ptr: number, _path_len: number): number {
        return WASI_ESUCCESS;
      },

      path_rename(
        _old_fd: number, old_path_ptr: number, old_path_len: number,
        _new_fd: number, new_path_ptr: number, new_path_len: number
      ): number {
        const oldPath = self.normalizePath(self.readString(old_path_ptr, old_path_len));
        const newPath = self.normalizePath(self.readString(new_path_ptr, new_path_len));
        const data = self.vfsFiles.get(oldPath);
        if (!data) return WASI_ENOENT;
        self.vfsFiles.set(newPath, data);
        self.vfsFiles.delete(oldPath);
        return WASI_ESUCCESS;
      },

      path_filestat_get(
        _fd: number, _flags: number,
        path_ptr: number, path_len: number,
        buf_ptr: number
      ): number {
        const path = self.normalizePath(self.readString(path_ptr, path_len));
        const data = self.vfsFiles.get(path);

        const v = self.view();
        for (let i = 0; i < 64; i++) self.u8()[buf_ptr + i] = 0;

        if (data) {
          v.setUint8(buf_ptr + 16, WASI_FILETYPE_REGULAR);
          v.setBigUint64(buf_ptr + 32, BigInt(data.length), true);
        } else {
          // Could be a directory prefix
          v.setUint8(buf_ptr + 16, WASI_FILETYPE_DIRECTORY);
        }
        return WASI_ESUCCESS;
      },

      clock_time_get(_clock_id: number, _precision: bigint, time_ptr: number): number {
        const ns = BigInt(Date.now()) * 1000000n;
        self.view().setBigUint64(time_ptr, ns, true);
        return WASI_ESUCCESS;
      },

      random_get(buf_ptr: number, buf_len: number): number {
        const buf = new Uint8Array(buf_len);
        crypto.getRandomValues(buf);
        self.u8().set(buf, buf_ptr);
        return WASI_ESUCCESS;
      },

      poll_oneoff(_in_ptr: number, _out_ptr: number, _nsubs: number, nevents_ptr: number): number {
        self.view().setUint32(nevents_ptr, 0, true);
        return WASI_ESUCCESS;
      },
    };
  }
}
