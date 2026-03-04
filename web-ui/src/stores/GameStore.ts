// MobX store for NetHack game state
import { makeAutoObservable, runInAction } from 'mobx';
import type { WorkerMessage, MenuItemData, InventoryItemData, PlselOption } from '../protocol/messages';
import { SAB_SIGNAL, SAB_VALUE, SAB_QUEUE_START, SAB_QUEUE_LENGTH, SAB_SIZE } from '../protocol/messages';
import { NHW_MAP, NHW_TEXT, NHW_MENU } from '../protocol/constants';

// --- IndexedDB helpers (db: 'nethack', store: 'saves') ---
const IDB_NAME = 'nethack';
const IDB_STORE = 'saves';

function idbOpen(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, 1);
    req.onupgradeneeded = () => { req.result.createObjectStore(IDB_STORE); };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbSave(key: string, value: unknown): Promise<void> {
  const db = await idbOpen();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, 'readwrite');
    tx.objectStore(IDB_STORE).put(value, key);
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

async function idbLoad<T>(key: string): Promise<T | undefined> {
  const db = await idbOpen();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, 'readonly');
    const req = tx.objectStore(IDB_STORE).get(key);
    req.onsuccess = () => { db.close(); resolve(req.result as T | undefined); };
    req.onerror = () => { db.close(); reject(req.error); };
  });
}

async function idbDelete(key: string): Promise<void> {
  const db = await idbOpen();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, 'readwrite');
    tx.objectStore(IDB_STORE).delete(key);
    tx.oncomplete = () => { db.close(); resolve(); };
    tx.onerror = () => { db.close(); reject(tx.error); };
  });
}

export interface CellData {
  tileIdx: number;
  ch: number;
  color: number;
  special: number;
  bkTileIdx: number;
}

export interface WindowData {
  winType: number;
  visible: boolean;
  blocking: boolean;
  items: MenuItemData[];
  prompt: string;
  text: string[];
}

export interface StatusField {
  value: string;
  color: number;
}

export type InputMode =
  | { type: 'none' }
  | { type: 'getch' }
  | { type: 'yn'; query: string; resp: string; def: number }
  | { type: 'getlin'; prompt: string }
  | { type: 'menu'; winid: number; how: number }
  | { type: 'plsel' }
  | { type: 'text'; winid: number };

export class GameStore {
  // Map state
  grid: Map<string, CellData> = new Map();
  heroX = 0;
  heroY = 0;
  mapVersion = 0; // bumped on batch updates for canvas redraw

  // Messages
  messages: { text: string; attr: number }[] = [];

  // Status
  statusFields: Map<number, StatusField> = new Map();
  statusVersion = 0;

  // Windows
  windows: Map<number, WindowData> = new Map();

  // Input state
  inputMode: InputMode = { type: 'none' };

  // Menu state
  menuItems: MenuItemData[] = [];
  menuPrompt = '';
  menuWinid = 0;

  // Player selection
  plselRoles: PlselOption[] = [];
  plselRaces: PlselOption[] = [];
  plselGenders: PlselOption[] = [];
  plselAligns: PlselOption[] = [];

  // Inventory
  inventory: InventoryItemData[] = [];

  // Engine state
  engineState: 'loading' | 'running' | 'waiting' | 'finished' | 'error' = 'loading';
  loadingProgress = 0;
  errorMessage = '';

  // Display mode
  asciiMode = false;

  // Worker + SharedArrayBuffer
  private worker: Worker | null = null;
  private sharedBuffer: SharedArrayBuffer | null = null;
  private sharedInt32: Int32Array | null = null;
  private lastVfsSnapshot: Record<string, string> | null = null;

  constructor() {
    makeAutoObservable(this, {
      grid: true,
      sendKey: false,
      sendClick: false,
      sendMenuResult: false,
      sendPlselResult: false,
    });
  }

  async start() {
    this.sharedBuffer = new SharedArrayBuffer(SAB_SIZE);
    this.sharedInt32 = new Int32Array(this.sharedBuffer);

    // Load saved VFS from IndexedDB (if any)
    let savedVfs: Record<string, string> | undefined;
    try {
      savedVfs = await idbLoad<Record<string, string>>('autosave');
    } catch { /* no saved game */ }

    this.worker = new Worker(
      new URL('../worker/nethack-worker.ts', import.meta.url),
      { type: 'module' }
    );

    this.worker.onmessage = (e: MessageEvent<WorkerMessage>) => {
      this.handleWorkerMessage(e.data);
    };

    this.worker.onerror = (e) => {
      runInAction(() => {
        this.engineState = 'error';
        this.errorMessage = e.message;
      });
    };

    this.worker.postMessage({ type: 'start', sharedBuffer: this.sharedBuffer, savedVfs });
  }

  private handleWorkerMessage(msg: WorkerMessage) {
    runInAction(() => {
      switch (msg.type) {
        case 'ready':
          this.engineState = 'running';
          break;

        case 'loading':
          this.loadingProgress = msg.instructions / msg.estimated;
          break;

        case 'display_batch':
          for (const u of msg.updates) {
            this.grid.set(`${u.x},${u.y}`, {
              tileIdx: u.tileIdx,
              ch: u.ch,
              color: u.color,
              special: u.special,
              bkTileIdx: u.bkTileIdx,
            });
          }
          this.mapVersion++;
          break;

        case 'message': {
          const winData = this.windows.get(msg.winid);
          // NHW_TEXT and NHW_MENU windows can receive putstr text for display as a popup
          // (questpgr.c delivers quest intro via NHW_MENU windows)
          if (winData && (winData.winType === NHW_TEXT || winData.winType === NHW_MENU)) {
            winData.text.push(msg.text);
          } else {
            this.messages.push({ text: msg.text, attr: msg.attr });
            if (this.messages.length > 50) {
              this.messages.splice(0, this.messages.length - 50);
            }
          }
          break;
        }

        case 'raw_print':
          this.messages.push({ text: msg.text, attr: 0 });
          break;

        case 'status_update':
          this.statusFields.set(msg.idx, { value: msg.value, color: msg.color });
          break;

        case 'status_flush':
          this.statusVersion++;
          break;

        case 'status_reset':
          this.statusFields.clear();
          this.statusVersion++;
          break;

        case 'window_create':
          this.windows.set(msg.winid, {
            winType: msg.winType,
            visible: false,
            blocking: false,
            items: [],
            prompt: '',
            text: [],
          });
          break;

        case 'window_display': {
          const win = this.windows.get(msg.winid);
          if (win) {
            win.visible = true;
            win.blocking = msg.blocking;
          }
          break;
        }

        case 'window_clear': {
          if (msg.winType === NHW_MAP) {
            this.grid.clear();
            this.mapVersion++;
          }
          const win = this.windows.get(msg.winid);
          if (win) {
            win.items = [];
            win.text = [];
          }
          break;
        }

        case 'window_destroy':
          this.windows.delete(msg.winid);
          break;

        case 'cursor':
          if (msg.winid === NHW_MAP) {
            this.heroX = msg.x;
            this.heroY = msg.y;
          }
          break;

        case 'cliparound':
          this.heroX = msg.x;
          this.heroY = msg.y;
          break;

        case 'menu_start':
          this.menuItems = [];
          this.menuWinid = msg.winid;
          break;

        case 'menu_item':
          this.menuItems.push(msg.item);
          break;

        case 'menu_end':
          this.menuPrompt = msg.prompt;
          break;

        case 'inventory':
          this.inventory = msg.items;
          break;

        case 'plsel_setup':
          switch (msg.field) {
            case 'roles': this.plselRoles.push(msg.option); break;
            case 'races': this.plselRaces.push(msg.option); break;
            case 'genders': this.plselGenders.push(msg.option); break;
            case 'aligns': this.plselAligns.push(msg.option); break;
          }
          break;

        case 'waiting_input':
          this.engineState = 'waiting';
          switch (msg.inputType) {
            case 'getch':
              if (msg.pendingYn) {
                this.inputMode = { type: 'yn', ...msg.pendingYn };
              } else if (msg.pendingGetlin) {
                this.inputMode = { type: 'getlin', ...msg.pendingGetlin };
              } else {
                // Check if there's a visible TEXT/MENU window with text that needs dismissal
                // NHW_MENU is included because quest text can arrive via NHW_MENU windows
                let textWin: number | null = null;
                for (const [wid, w] of this.windows) {
                  if ((w.winType === NHW_TEXT || (w.winType === NHW_MENU && w.text.length > 0)) && w.visible) {
                    textWin = wid;
                    break;
                  }
                }
                if (textWin !== null) {
                  this.inputMode = { type: 'text', winid: textWin };
                } else {
                  this.inputMode = { type: 'getch' };
                }
              }
              break;
            case 'menu':
              this.inputMode = { type: 'menu', winid: msg.winid, how: msg.how };
              break;
            case 'plsel':
              this.inputMode = { type: 'plsel' };
              break;
          }
          break;

        case 'exit':
          this.engineState = 'finished';
          if (msg.message) {
            this.messages.push({ text: msg.message, attr: 0 });
          }
          break;

        case 'error':
          this.engineState = 'error';
          this.errorMessage = msg.message;
          break;

        case 'finished':
          this.engineState = 'finished';
          break;

        case 'vfs_snapshot':
          // Persist to IndexedDB (fire-and-forget)
          idbSave('autosave', msg.files).catch(() => {});
          this.lastVfsSnapshot = msg.files;
          break;
      }
    });
  }

  // Send a single key to the worker
  sendKey(key: number) {
    if (!this.sharedInt32) return;
    runInAction(() => {
      this.inputMode = { type: 'none' };
      this.engineState = 'running';
    });
    Atomics.store(this.sharedInt32, SAB_VALUE, key);
    Atomics.store(this.sharedInt32, SAB_SIGNAL, 1);
    Atomics.notify(this.sharedInt32, SAB_SIGNAL);
  }

  // Send menu result
  sendMenuResult(count: number, selections: number[]) {
    if (!this.sharedInt32) return;
    runInAction(() => {
      this.inputMode = { type: 'none' };
      this.engineState = 'running';
    });
    // Write selections to queue
    for (let i = 0; i < selections.length; i++) {
      Atomics.store(this.sharedInt32, SAB_QUEUE_START + i, selections[i]);
    }
    Atomics.store(this.sharedInt32, SAB_QUEUE_LENGTH, selections.length);
    Atomics.store(this.sharedInt32, SAB_VALUE, count);
    Atomics.store(this.sharedInt32, SAB_SIGNAL, 1);
    Atomics.notify(this.sharedInt32, SAB_SIGNAL);
  }

  // Send player selection result
  // Queues: name chars + null terminator + role/race/gender/align indices
  sendPlselResult(status: number, name?: string, role?: number, race?: number, gender?: number, align?: number) {
    if (!this.sharedInt32) return;
    runInAction(() => {
      this.inputMode = { type: 'none' };
      this.engineState = 'running';
    });

    // Queue name chars + null + 4 selection indices into SAB
    const playerName = name || 'Player';
    let qi = 0;
    for (let i = 0; i < playerName.length && qi < 30; i++) {
      Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, playerName.charCodeAt(i));
    }
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, 0); // null terminator
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, role ?? -1);
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, race ?? -1);
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, gender ?? -1);
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + qi++, align ?? -1);
    Atomics.store(this.sharedInt32, SAB_QUEUE_LENGTH, qi);

    Atomics.store(this.sharedInt32, SAB_VALUE, status);
    Atomics.store(this.sharedInt32, SAB_SIGNAL, 1);
    Atomics.notify(this.sharedInt32, SAB_SIGNAL);
  }

  // Send a click (key=0) with x,y,mod in the queue
  sendClick(x: number, y: number, mod: number) {
    if (!this.sharedInt32) return;
    runInAction(() => {
      this.inputMode = { type: 'none' };
      this.engineState = 'running';
    });
    Atomics.store(this.sharedInt32, SAB_QUEUE_START, x);
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + 1, y);
    Atomics.store(this.sharedInt32, SAB_QUEUE_START + 2, mod);
    Atomics.store(this.sharedInt32, SAB_QUEUE_LENGTH, 3);
    Atomics.store(this.sharedInt32, SAB_VALUE, 0); // key=0 means click
    Atomics.store(this.sharedInt32, SAB_SIGNAL, 1);
    Atomics.notify(this.sharedInt32, SAB_SIGNAL);
  }

  toggleAscii() {
    this.asciiMode = !this.asciiMode;
    this.mapVersion++;
  }

  async exportSave() {
    // Use last snapshot from memory, or try loading from IDB
    let vfs = this.lastVfsSnapshot;
    if (!vfs) {
      try { vfs = await idbLoad<Record<string, string>>('autosave') ?? null; } catch { /* */ }
    }
    if (!vfs || Object.keys(vfs).length === 0) {
      alert('No save data available. Play a few turns first.');
      return;
    }
    const blob = new Blob([JSON.stringify(vfs)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `nethack-save-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }

  importSave() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json';
    input.onchange = async () => {
      const file = input.files?.[0];
      if (!file) return;
      try {
        const text = await file.text();
        const vfs = JSON.parse(text) as Record<string, string>;
        await idbSave('autosave', vfs);
        location.reload();
      } catch (e) {
        alert(`Failed to import save: ${e instanceof Error ? e.message : e}`);
      }
    };
    input.click();
  }

  async newGame() {
    if (!confirm('Start a new game? Your current save will be deleted.')) return;
    try { await idbDelete('autosave'); } catch { /* */ }
    location.reload();
  }
}

// Singleton
export const gameStore = new GameStore();
(window as any).__gameStore = gameStore;
