// Canvas-based tile/ASCII map renderer
import { useEffect, useRef, useCallback } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { MAP_COLS, MAP_ROWS, TILE_SIZE, NH_COLORS, MG_PET, MG_DETECT } from '../protocol/constants';
import { ensureSpriteAssets, getSpriteCoords, getSheets, getTileConfig } from './RichText';

const groundTiles: Record<string, HTMLImageElement> = {};

// Ground tile name resolution from bk_tile_idx
// Mirrors display.lua resolve_base_tile() + TILE_NAME_MAP
const TILE_NAME_MAP: Record<string, string> = {
  'pool': 'nh-water',
  'water': 'nh-water',
  'molten-lava': 'nh-lava',
  'ice': 'nh-water',  // ice over water in Factorio
};

function getGroundTileName(bkTileIdx: number, ch: number): string {
  if (ch === 32) return 'nh-void'; // space = unexplored/void
  if (bkTileIdx < 0) return 'nh-floor';
  const tc = getTileConfig();
  if (!tc) return 'nh-floor';
  const otherBase = tc.n_monsters + tc.n_objects;
  if (bkTileIdx >= otherBase && tc.other_names) {
    const name = tc.other_names[bkTileIdx - otherBase];
    if (name) return TILE_NAME_MAP[name] || 'nh-floor';
  }
  return 'nh-floor';
}

async function loadAssets() {
  await ensureSpriteAssets();

  const loadImg = (src: string): Promise<HTMLImageElement> =>
    new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = reject;
      img.src = src;
    });

  if (Object.keys(groundTiles).length === 0) {
    const groundNames = ['nh-floor', 'nh-corridor', 'nh-void', 'nh-water', 'nh-lava', 'nh-ice', 'nh-grass'];
    await Promise.allSettled(
      groundNames.map(async (name) => {
        try { groundTiles[name] = await loadImg(`/tiles/${name}.png`); } catch { /* skip */ }
      })
    );
  }
}

function drawAscii(ctx: CanvasRenderingContext2D) {
  const store = gameStore;
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, MAP_COLS * TILE_SIZE, MAP_ROWS * TILE_SIZE);

  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = `${TILE_SIZE - 4}px monospace`;

  for (const [key, cell] of store.grid) {
    const [xs, ys] = key.split(',');
    const x = parseInt(xs);
    const y = parseInt(ys);
    if (x < 0 || x >= MAP_COLS || y < 0 || y >= MAP_ROWS) continue;

    const ch = String.fromCharCode(cell.ch);
    const color = NH_COLORS[cell.color] || '#aaa';

    ctx.fillStyle = color;
    ctx.fillText(ch, x * TILE_SIZE + TILE_SIZE / 2, y * TILE_SIZE + TILE_SIZE / 2);
  }
}

function drawTiles(ctx: CanvasRenderingContext2D) {
  const store = gameStore;
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, MAP_COLS * TILE_SIZE, MAP_ROWS * TILE_SIZE);

  for (const [key, cell] of store.grid) {
    const [xs, ys] = key.split(',');
    const x = parseInt(xs);
    const y = parseInt(ys);
    if (x < 0 || x >= MAP_COLS || y < 0 || y >= MAP_ROWS) continue;

    const px = x * TILE_SIZE;
    const py = y * TILE_SIZE;

    // Draw ground tile
    const groundName = getGroundTileName(cell.bkTileIdx, cell.ch);
    const groundImg = groundTiles[groundName];
    if (groundImg) {
      // Ground tiles are 512x512 tiled; take a 32x32 region
      ctx.drawImage(groundImg, 0, 0, TILE_SIZE, TILE_SIZE, px, py, TILE_SIZE, TILE_SIZE);
    } else {
      ctx.fillStyle = groundName === 'nh-void' ? '#000' : '#333';
      ctx.fillRect(px, py, TILE_SIZE, TILE_SIZE);
    }

    // Draw entity sprite
    const coords = getSpriteCoords(cell.tileIdx);
    if (coords) {
      const img = getSheets()[coords.sheet];
      if (img) {
        // Apply tint for pets/detected
        if (cell.special & MG_PET) {
          ctx.globalAlpha = 1;
          ctx.drawImage(img, coords.sx, coords.sy, TILE_SIZE, TILE_SIZE, px, py, TILE_SIZE, TILE_SIZE);
          ctx.globalCompositeOperation = 'source-atop';
          ctx.fillStyle = 'rgba(0, 255, 0, 0.25)';
          ctx.fillRect(px, py, TILE_SIZE, TILE_SIZE);
          ctx.globalCompositeOperation = 'source-over';
        } else if (cell.special & MG_DETECT) {
          ctx.drawImage(img, coords.sx, coords.sy, TILE_SIZE, TILE_SIZE, px, py, TILE_SIZE, TILE_SIZE);
          ctx.globalCompositeOperation = 'source-atop';
          ctx.fillStyle = 'rgba(0, 255, 255, 0.25)';
          ctx.fillRect(px, py, TILE_SIZE, TILE_SIZE);
          ctx.globalCompositeOperation = 'source-over';
        } else {
          ctx.drawImage(img, coords.sx, coords.sy, TILE_SIZE, TILE_SIZE, px, py, TILE_SIZE, TILE_SIZE);
        }
      }
    }
  }
}

export const GameMap = observer(function GameMap() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const assetsLoaded = useRef(false);

  useEffect(() => {
    loadAssets().then(() => {
      assetsLoaded.current = true;
    });
  }, []);

  // Access mapVersion to trigger re-render
  const _version = gameStore.mapVersion;
  const _ascii = gameStore.asciiMode;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    ctx.imageSmoothingEnabled = false;

    if (gameStore.asciiMode || !assetsLoaded.current || Object.keys(getSheets()).length === 0) {
      drawAscii(ctx);
    } else {
      drawTiles(ctx);
    }
  }, [_version, _ascii]);

  // Click-to-move
  const handleClick = useCallback((e: React.MouseEvent<HTMLCanvasElement>) => {
    if (gameStore.inputMode.type !== 'getch') return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const scaleX = canvas.width / rect.width;
    const scaleY = canvas.height / rect.height;
    const tileX = Math.floor((e.clientX - rect.left) * scaleX / TILE_SIZE);
    const tileY = Math.floor((e.clientY - rect.top) * scaleY / TILE_SIZE);
    gameStore.sendClick(tileX, tileY, 1);
  }, []);

  // Scroll to keep hero centered (also re-scroll on map redraws)
  const containerRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const container = containerRef.current;
    if (!container || gameStore.heroX === 0 && gameStore.heroY === 0) return;
    const cx = gameStore.heroX * TILE_SIZE + TILE_SIZE / 2;
    const cy = gameStore.heroY * TILE_SIZE + TILE_SIZE / 2;
    container.scrollLeft = cx - container.clientWidth / 2;
    container.scrollTop = cy - container.clientHeight / 2;
  }, [gameStore.heroX, gameStore.heroY, _version]);

  return (
    <div ref={containerRef} className="game-map-container">
      <canvas
        ref={canvasRef}
        width={MAP_COLS * TILE_SIZE}
        height={MAP_ROWS * TILE_SIZE}
        className="game-map-canvas"
        onClick={handleClick}
      />
    </div>
  );
});
