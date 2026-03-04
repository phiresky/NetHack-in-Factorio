// Paperdoll equipment panel — mirrors gui_equip.lua
import { observer } from 'mobx-react-lite';
import { useEffect, useRef } from 'react';
import { gameStore } from '../stores/GameStore';
import { getSpriteCoords, getSheets } from './RichText';
import { TILE_SIZE } from '../protocol/constants';

// owornmask bits from worn.h
const W_ARM    = 0x00000001;
const W_ARMC   = 0x00000002;
const W_ARMH   = 0x00000004;
const W_ARMS   = 0x00000008;
const W_ARMG   = 0x00000010;
const W_ARMF   = 0x00000020;
const W_ARMU   = 0x00000040;
const W_WEP    = 0x00000100;
const W_QUIVER = 0x00000200;
const W_SWAPWEP= 0x00000400;
const W_RINGL  = 0x00008000;
const W_RINGR  = 0x00010000;
const W_AMUL   = 0x00020000;
const W_BLINDF = 0x00040000;

interface SlotDef {
  mask: number;
  label: string;
  ghostTile: number; // tile index for placeholder sprite
}

// Ghost tile indices (global tile idx for each equipment placeholder)
// Matches prototypes/sprites.lua ghost_items
const GHOST = {
  eyes:    604,  // blindfold
  helmet:  473,  // etched-helmet-helm-of-brilliance
  quiver:  395,  // arrow
  shield:  525,  // small-shield
  weapon:  431,  // long-sword
  cloak:   522,  // opera-cloak-cloak-of-invisibility
  amulet:  574,  // circular-amulet-of-esp
  gloves:  532,  // old-gloves-leather-gloves
  ring:    546,  // wooden-adornment
  armor:   509,  // leather-armor
  boots:   538,  // jackboots-high-boots
  offhand: 411,  // dagger
};

// 4x4 grid matching Factorio layout (false = empty cell)
const PAPERDOLL_GRID: (SlotDef | false)[] = [
  // Row 0: head
  { mask: W_BLINDF, label: 'Eyes',     ghostTile: GHOST.eyes },
  { mask: W_ARMH,   label: 'Helmet',   ghostTile: GHOST.helmet },
  { mask: W_QUIVER, label: 'Quiver',   ghostTile: GHOST.quiver },
  false,
  // Row 1: upper body
  { mask: W_ARMS,   label: 'Shield',   ghostTile: GHOST.shield },
  { mask: W_WEP,    label: 'Weapon',   ghostTile: GHOST.weapon },
  { mask: W_ARMC,   label: 'Cloak',    ghostTile: GHOST.cloak },
  { mask: W_AMUL,   label: 'Amulet',   ghostTile: GHOST.amulet },
  // Row 2: hands + rings + armor
  { mask: W_ARMG,   label: 'Gloves',   ghostTile: GHOST.gloves },
  { mask: W_RINGL,  label: 'Ring L',   ghostTile: GHOST.ring },
  { mask: W_ARM,    label: 'Armor',    ghostTile: GHOST.armor },
  { mask: W_RINGR,  label: 'Ring R',   ghostTile: GHOST.ring },
  // Row 3: lower body
  { mask: W_ARMU,   label: 'Shirt',    ghostTile: GHOST.armor },
  { mask: W_ARMF,   label: 'Boots',    ghostTile: GHOST.boots },
  { mask: W_SWAPWEP,label: 'Off-hand', ghostTile: GHOST.offhand },
  false,
];

// Commands to remove equipped items (mirrors gui_equip.lua REMOVE_CMD)
const REMOVE_CMD: Record<number, string> = {
  [W_ARM]: 'T', [W_ARMC]: 'T', [W_ARMH]: 'T', [W_ARMS]: 'T',
  [W_ARMG]: 'T', [W_ARMF]: 'T', [W_ARMU]: 'T',
  [W_AMUL]: 'R', [W_RINGL]: 'R', [W_RINGR]: 'R', [W_BLINDF]: 'R',
  [W_WEP]: 'w', [W_SWAPWEP]: 'x', [W_QUIVER]: 'Q',
};

// Commands to equip an empty slot (mirrors gui_equip.lua EQUIP_CMD)
const EQUIP_CMD: Record<number, string> = {
  [W_ARM]: 'W', [W_ARMC]: 'W', [W_ARMH]: 'W', [W_ARMS]: 'W',
  [W_ARMG]: 'W', [W_ARMF]: 'W', [W_ARMU]: 'W',
  [W_AMUL]: 'P', [W_RINGL]: 'P', [W_RINGR]: 'P', [W_BLINDF]: 'P',
  [W_WEP]: 'w', [W_SWAPWEP]: 'x', [W_QUIVER]: 'Q',
};

const CELL_SIZE = 36;

function drawTile(ctx: CanvasRenderingContext2D, tileIdx: number, ghost: boolean) {
  const coords = getSpriteCoords(tileIdx);
  if (!coords) return;
  const img = getSheets()[coords.sheet];
  if (!img) return;
  if (ghost) ctx.globalAlpha = 0.3;
  ctx.drawImage(img, coords.sx, coords.sy, TILE_SIZE, TILE_SIZE, 2, 2, CELL_SIZE - 4, CELL_SIZE - 4);
  if (ghost) ctx.globalAlpha = 1;
}

function EquipSlot({ slot, tile, version }: { slot: SlotDef; tile: number | null; version: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, CELL_SIZE, CELL_SIZE);

    if (tile !== null) {
      drawTile(ctx, tile, false);
    } else {
      drawTile(ctx, slot.ghostTile, true);
    }
  }, [tile, slot.ghostTile, version]);

  const handleClick = () => {
    if (gameStore.inputMode.type !== 'getch') return;
    const cmd = tile !== null ? REMOVE_CMD[slot.mask] : EQUIP_CMD[slot.mask];
    if (!cmd) return;
    gameStore.sendKey(cmd.charCodeAt(0));
  };

  const tooltip = tile !== null
    ? `${slot.label} (click to remove)`
    : `${slot.label} (empty, click to equip)`;

  return (
    <canvas
      ref={canvasRef}
      width={CELL_SIZE}
      height={CELL_SIZE}
      className={`equip-slot ${tile !== null ? 'equipped' : 'empty'}`}
      title={tooltip}
      onClick={handleClick}
      style={{ cursor: gameStore.inputMode.type === 'getch' ? 'pointer' : undefined }}
    />
  );
}

export const EquipPanel = observer(function EquipPanel() {
  const inventory = gameStore.inventory;
  // Re-render when map updates (ensures sprite sheets are loaded)
  const version = gameStore.mapVersion;

  // Build mask -> tile mapping from equipped items
  const equipped = new Map<number, number>();
  for (const item of inventory) {
    if (item.owornmask) {
      for (const slot of PAPERDOLL_GRID) {
        if (slot && (item.owornmask & slot.mask)) {
          equipped.set(slot.mask, item.tile);
        }
      }
    }
  }

  return (
    <div className="equip-panel">
      <div className="status-label">Equipment</div>
      <div className="equip-grid">
        {PAPERDOLL_GRID.map((slot, i) =>
          slot ? (
            <EquipSlot key={i} slot={slot} tile={equipped.get(slot.mask) ?? null} version={version} />
          ) : (
            <div key={i} className="equip-empty" />
          )
        )}
      </div>
    </div>
  );
});
