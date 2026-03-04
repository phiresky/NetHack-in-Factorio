// Messages from Worker to Main thread

export interface GlyphUpdate {
  type: 'glyph';
  x: number;
  y: number;
  tileIdx: number;
  ch: number;
  color: number;
  special: number;
  bkTileIdx: number;
}

export interface MenuItemData {
  glyph: number;
  identifier: number;
  accelerator: number;
  groupAccel: number;
  attr: number;
  text: string;
  preselected: boolean;
}

export interface InventoryItemData {
  slot: number;
  tile: number;
  oId: number;
  invlet: number;
  name: string;
  quantity: number;
  oclass: number;
  owornmask: number;
}

export interface PlselOption {
  idx: number;
  name: string;
  allow: number;
}

export type WorkerMessage =
  | { type: 'ready' }
  | { type: 'loading'; instructions: number; estimated: number }
  | { type: 'waiting_input'; inputType: 'getch'; pendingYn?: { query: string; resp: string; def: number }; pendingGetlin?: { prompt: string } }
  | { type: 'waiting_input'; inputType: 'menu'; winid: number; how: number }
  | { type: 'waiting_input'; inputType: 'plsel' }
  | { type: 'display_batch'; updates: GlyphUpdate[] }
  | { type: 'message'; winid: number; text: string; attr: number }
  | { type: 'raw_print'; text: string }
  | { type: 'status_update'; idx: number; value: string; color: number; percent: number }
  | { type: 'status_flush' }
  | { type: 'status_reset' }
  | { type: 'window_create'; winid: number; winType: number }
  | { type: 'window_display'; winid: number; blocking: boolean }
  | { type: 'window_clear'; winid: number; winType: number }
  | { type: 'window_destroy'; winid: number }
  | { type: 'cursor'; winid: number; x: number; y: number }
  | { type: 'cliparound'; x: number; y: number }
  | { type: 'menu_start'; winid: number }
  | { type: 'menu_item'; winid: number; item: MenuItemData }
  | { type: 'menu_end'; winid: number; prompt: string }
  | { type: 'inventory'; items: InventoryItemData[] }
  | { type: 'plsel_setup'; field: 'roles' | 'races' | 'genders' | 'aligns'; option: PlselOption }
  | { type: 'exit'; message: string }
  | { type: 'error'; message: string }
  | { type: 'finished' }
  | { type: 'vfs_snapshot'; files: Record<string, string> };

// Messages from Main to Worker (via postMessage for complex data)
export type MainMessage =
  | { type: 'start'; sharedBuffer: SharedArrayBuffer; savedVfs?: Record<string, string> }
  | { type: 'menu_result'; count: number; selections: number[] }
  | { type: 'plsel_result'; name: string; role: number; race: number; gender: number; align: number }
  | { type: 'request_vfs_snapshot' };

// SharedArrayBuffer layout (Int32Array):
// [0] = signal: 0=idle, 1=input_ready
// [1] = value: key code, menu count, etc.
// [2..33] = queue: additional values (menu selections, string chars)
// [34] = queue_length
export const SAB_SIGNAL = 0;
export const SAB_VALUE = 1;
export const SAB_QUEUE_START = 2;
export const SAB_QUEUE_LENGTH = 34;
export const SAB_SIZE = 35 * 4; // bytes
