// env.host_* import implementations for the WASM bridge
// Mirrors scripts/bridge.lua

import { SAB_SIGNAL, SAB_VALUE, SAB_QUEUE_START, SAB_QUEUE_LENGTH } from '../protocol/messages';
import type { GlyphUpdate, InventoryItemData, WorkerMessage } from '../protocol/messages';
import { NHW_MAP, BL_FLUSH, BL_RESET } from '../protocol/constants';

export class Bridge {
  private memory!: WebAssembly.Memory;
  private sharedInt32!: Int32Array;
  private displayBatch: GlyphUpdate[] = [];
  private inventoryItems: InventoryItemData[] = [];
  private windows: Map<number, number> = new Map(); // winid -> winType
  private nextWinid = 1;
  private pendingYn: { query: string; resp: string; def: number } | null = null;
  private pendingGetlin: { prompt: string } | null = null;
  private autoFedInventory = false;
  private inputQueue: number[] = []; // pre-queued values for nhgetch
  private clickX = 0;
  private clickY = 0;
  private clickMod = 0;

  setMemory(mem: WebAssembly.Memory) {
    this.memory = mem;
  }

  setSharedBuffer(sab: SharedArrayBuffer) {
    this.sharedInt32 = new Int32Array(sab);
  }

  private u8() { return new Uint8Array(this.memory.buffer); }
  private readString(ptr: number, len: number): string {
    return new TextDecoder().decode(this.u8().slice(ptr, ptr + len));
  }

  private post(msg: WorkerMessage) {
    postMessage(msg);
  }

  private flushBatch() {
    if (this.displayBatch.length > 0) {
      this.post({ type: 'display_batch', updates: this.displayBatch });
      this.displayBatch = [];
    }
  }

  // Block the worker thread until input is ready, return the value
  private blockForInput(): number {
    // Wait until signal != 0
    Atomics.wait(this.sharedInt32, SAB_SIGNAL, 0);
    const value = this.sharedInt32[SAB_VALUE];
    // Reset signal
    Atomics.store(this.sharedInt32, SAB_SIGNAL, 0);
    return value;
  }

  // Read queued values from SAB into inputQueue
  private readSabQueue() {
    const len = Atomics.load(this.sharedInt32, SAB_QUEUE_LENGTH);
    for (let i = 0; i < len; i++) {
      this.inputQueue.push(Atomics.load(this.sharedInt32, SAB_QUEUE_START + i));
    }
    Atomics.store(this.sharedInt32, SAB_QUEUE_LENGTH, 0);
  }

  getImports(): Record<string, Function> {
    const self = this;

    return {
      host_print_glyph(x: number, y: number, tileIdx: number, ch: number, color: number, special: number, bkTileIdx: number) {
        self.displayBatch.push({ type: 'glyph', x, y, tileIdx, ch, color, special, bkTileIdx });
      },

      host_putstr(win: number, attr: number, strPtr: number, len: number) {
        const text = self.readString(strPtr, len);
        self.post({ type: 'message', winid: win, text, attr });
      },

      host_raw_print(strPtr: number, len: number) {
        const text = self.readString(strPtr, len);
        self.post({ type: 'raw_print', text });
      },

      host_status_update(idx: number, valPtr: number, len: number, color: number, percent: number) {
        if (idx === BL_FLUSH) {
          self.post({ type: 'status_flush' });
          return;
        }
        if (idx === BL_RESET) {
          self.post({ type: 'status_reset' });
          return;
        }
        const value = self.readString(valPtr, len);
        self.post({ type: 'status_update', idx, value, color, percent });
      },

      host_create_nhwindow(winType: number): number {
        const winid = self.nextWinid++;
        self.windows.set(winid, winType);
        self.post({ type: 'window_create', winid, winType });
        return winid;
      },

      host_display_nhwindow(winid: number, blocking: number) {
        self.flushBatch();
        self.post({ type: 'window_display', winid, blocking: blocking !== 0 });
      },

      host_clear_nhwindow(winid: number) {
        const winType = self.windows.get(winid) ?? 0;
        if (winType === NHW_MAP) {
          self.flushBatch();
        }
        self.post({ type: 'window_clear', winid, winType });
      },

      host_destroy_nhwindow(winid: number) {
        self.post({ type: 'window_destroy', winid });
        self.windows.delete(winid);
      },

      host_exit_nhwindows(strPtr: number, len: number) {
        const message = self.readString(strPtr, len);
        self.flushBatch();
        self.post({ type: 'exit', message });
      },

      host_curs(winid: number, x: number, y: number) {
        self.post({ type: 'cursor', winid, x, y });
      },

      host_cliparound(x: number, y: number) {
        self.post({ type: 'cliparound', x, y });
      },

      host_delay_output() { /* no-op */ },
      host_update_inventory() { /* no-op */ },
      host_mark_synch() { /* no-op */ },

      host_inventory_begin() {
        self.inventoryItems = [];
      },

      host_inventory_item(
        slot: number, tile: number, oId: number, invlet: number,
        namePtr: number, nameLen: number, quantity: number,
        oclass: number, owornmask: number
      ) {
        self.inventoryItems.push({
          slot, tile, oId, invlet,
          name: self.readString(namePtr, nameLen),
          quantity, oclass, owornmask,
        });
      },

      host_inventory_done(_count: number) {
        self.post({ type: 'inventory', items: self.inventoryItems });
        self.inventoryItems = [];
      },

      host_start_menu(winid: number) {
        self.post({ type: 'menu_start', winid });
      },

      host_add_menu_item(
        winid: number, glyph: number, identifier: number,
        accelerator: number, groupAccel: number, attr: number,
        strPtr: number, len: number, preselected: number
      ) {
        const text = self.readString(strPtr, len);
        self.post({
          type: 'menu_item',
          winid,
          item: { glyph, identifier, accelerator, groupAccel, attr, text, preselected: preselected !== 0 },
        });
      },

      host_end_menu(winid: number, promptPtr: number, promptLen: number) {
        const prompt = promptLen > 0 ? self.readString(promptPtr, promptLen) : '';
        self.post({ type: 'menu_end', winid, prompt });
      },

      // NON-BLOCKING: just sets up UI state; nhgetch actually blocks
      // Mirrors bridge.lua: auto-feed '?' or '*' for inventory-style prompts
      // ONCE per prompt cycle. After inventory is dismissed, getobj loops and
      // calls yn_function again — the second call falls through to the yn popup.
      host_yn_function(queryPtr: number, qlen: number, respPtr: number, rlen: number, def: number) {
        const query = self.readString(queryPtr, qlen);
        const resp = rlen > 0 ? self.readString(respPtr, rlen) : '';

        const hasHelp = query.includes('[?]') || query.includes('[*]');
        if (hasHelp && !self.autoFedInventory) {
          // First time: queue '?' or '*' to trigger NetHack's built-in inventory menu
          self.autoFedInventory = true;
          self.inputQueue.push(query.includes('[?]') ? 63 : 42);
          // Don't set pendingYn — nhgetch will drain the queue without blocking
          return;
        }

        // Normal yn prompt (or re-prompt after auto-fed inventory was dismissed)
        if (resp) {
          self.pendingYn = { query, resp, def };
        }
        // If empty resp and no brackets: no pendingYn, nhgetch treated as regular getch
      },

      // NON-BLOCKING: just sets up UI state; nhgetch actually blocks
      host_getlin(promptPtr: number, len: number) {
        const prompt = self.readString(promptPtr, len);
        self.pendingGetlin = { prompt };
      },

      // BLOCKING: the main input function
      host_nhgetch(): number {
        // Drain pre-queued values first (from plsel name+indices, getlin chars, auto-fed inventory, etc.)
        if (self.inputQueue.length > 0) {
          return self.inputQueue.shift()!;
        }

        // If no pending prompt, we're back at the main command loop — reset auto-feed
        if (!self.pendingYn && !self.pendingGetlin) {
          self.autoFedInventory = false;
        }

        self.flushBatch();
        self.post({
          type: 'waiting_input',
          inputType: 'getch',
          pendingYn: self.pendingYn ?? undefined,
          pendingGetlin: self.pendingGetlin ?? undefined,
        });

        const key = self.blockForInput();

        // Click: read x, y, mod from queue
        if (key === 0) {
          self.readSabQueue();
          self.clickX = self.inputQueue.shift() ?? 0;
          self.clickY = self.inputQueue.shift() ?? 0;
          self.clickMod = self.inputQueue.shift() ?? 0;
        }

        // Clear pending state after receiving input
        if (self.pendingYn) self.pendingYn = null;
        if (self.pendingGetlin) self.pendingGetlin = null;

        return key;
      },

      // BLOCKING: menu selection
      host_select_menu(winid: number, how: number): number {
        self.flushBatch();
        self.post({ type: 'waiting_input', inputType: 'menu', winid, how });

        const count = self.blockForInput();
        // Transfer selection IDs from SAB queue into inputQueue
        // so nhgetch can drain them when C code reads each one
        self.readSabQueue();
        return count;
      },

      // Player selection setup (non-blocking)
      host_plsel_setup_role(idx: number, namePtr: number, len: number, allow: number) {
        self.post({ type: 'plsel_setup', field: 'roles', option: { idx, name: self.readString(namePtr, len), allow } });
      },
      host_plsel_setup_race(idx: number, namePtr: number, len: number, allow: number) {
        self.post({ type: 'plsel_setup', field: 'races', option: { idx, name: self.readString(namePtr, len), allow } });
      },
      host_plsel_setup_gend(idx: number, namePtr: number, len: number, allow: number) {
        self.post({ type: 'plsel_setup', field: 'genders', option: { idx, name: self.readString(namePtr, len), allow } });
      },
      host_plsel_setup_align(idx: number, namePtr: number, len: number, allow: number) {
        self.post({ type: 'plsel_setup', field: 'aligns', option: { idx, name: self.readString(namePtr, len), allow } });
      },

      // BLOCKING: show player selection dialog
      // After unblocking, reads queued name chars + null + 4 selection indices from SAB
      host_plsel_show(): number {
        self.flushBatch();
        self.post({ type: 'waiting_input', inputType: 'plsel' });
        const status = self.blockForInput();
        // Read name+null+indices queued by main thread into inputQueue
        self.readSabQueue();
        return status;
      },

      host_describe_result(_bufPtr: number, _bufLen: number, _monbufPtr: number, _monbufLen: number) {
        // No-op — describe_pos requires a secondary WASM call
      },

      host_poskey_x(): number { return self.clickX; },
      host_poskey_y(): number { return self.clickY; },
      host_poskey_mod(): number { return self.clickMod; },

      // Stub imports (POSIX functions that NetHack references)
      fork() { return -1; },
      waitpid() { return -1; },
      setgid() { return 0; },
      setuid() { return 0; },
      execv() { return -1; },
      execl() { return -1; },
      child() { return 0; },
      system() { return -1; },
      tmpnam() { return 0; },
    };
  }
}
