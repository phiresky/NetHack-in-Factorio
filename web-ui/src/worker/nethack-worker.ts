// Web Worker: loads nethack.wasm with WASI + bridge imports, runs the game

import { WasiRuntime } from './wasi';
import { Bridge } from './bridge';
import type { MainMessage } from '../protocol/messages';

const base = import.meta.env.BASE_URL;
let wasi: WasiRuntime;
let bridge: Bridge;

async function loadDataFiles(): Promise<Record<string, Uint8Array>> {
  const resp = await fetch(`${base}nethack-data.json`);
  const json: Record<string, string> = await resp.json();
  const files: Record<string, Uint8Array> = {};
  for (const [name, b64] of Object.entries(json)) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    files[name] = bytes;
  }
  return files;
}

async function start(sharedBuffer: SharedArrayBuffer, savedVfs?: Record<string, string>) {
  try {
    postMessage({ type: 'loading', instructions: 0, estimated: 1770000 });

    // Load data files and WASM binary in parallel
    const [dataFiles, wasmResp] = await Promise.all([
      loadDataFiles(),
      fetch(`${base}nethack.wasm`),
    ]);

    // Overlay saved VFS files (from IndexedDB autosave) onto base data
    if (savedVfs) {
      for (const [name, b64] of Object.entries(savedVfs)) {
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        dataFiles[name] = bytes;
      }
    }

    const wasmBytes = await wasmResp.arrayBuffer();

    // Create WASI and Bridge
    wasi = new WasiRuntime(dataFiles);
    bridge = new Bridge();
    bridge.setSharedBuffer(sharedBuffer);
    bridge.setWasi(wasi);

    // Combine imports
    const wasiImports = wasi.getImports();
    const bridgeImports = bridge.getImports();

    const importObject: WebAssembly.Imports = {
      wasi_snapshot_preview1: wasiImports as unknown as Record<string, WebAssembly.ImportValue>,
      env: bridgeImports as unknown as Record<string, WebAssembly.ImportValue>,
    };

    // Instantiate WASM
    const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);

    // Set memory reference for WASI and Bridge
    const memory = instance.exports.memory as WebAssembly.Memory;
    wasi.setMemory(memory);
    bridge.setMemory(memory);

    postMessage({ type: 'ready' });

    // Call _start (WASI entry point)
    const startFn = instance.exports._start as Function;
    try {
      startFn();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes('proc_exit(0)')) {
        postMessage({ type: 'finished' });
      } else {
        postMessage({ type: 'error', message: msg });
      }
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    postMessage({ type: 'error', message: `Worker startup failed: ${msg}` });
  }
}

// Handle messages from main thread
self.onmessage = (e: MessageEvent<MainMessage>) => {
  const msg = e.data;
  switch (msg.type) {
    case 'start':
      start(msg.sharedBuffer, msg.savedVfs);
      break;
    case 'menu_result':
      // Menu results are handled via SAB — the queue values are already written
      break;
    case 'plsel_result':
      // Plsel results are handled via SAB
      break;
    case 'request_vfs_snapshot':
      if (bridge) bridge.postVfsSnapshot();
      break;
  }
};
