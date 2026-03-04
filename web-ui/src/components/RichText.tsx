// Renders Factorio-style rich text with inline sprite images
// Parses [img=nh-sprite-N] tags and renders them as inline tile sprites

import { useEffect, useRef } from 'react';
import { TILE_SIZE, SHEET_COLS } from '../protocol/constants';

// Shared sprite assets — same as GameMap but accessed here for inline rendering
let tileConfig: { n_monsters: number; n_objects: number; n_other: number; other_names?: string[] } | null = null;
const sheets: Record<string, HTMLImageElement> = {};
let assetsReady = false;
let assetsPromise: Promise<void> | null = null;

export function ensureSpriteAssets(): Promise<void> {
  if (assetsReady) return Promise.resolve();
  if (assetsPromise) return assetsPromise;

  assetsPromise = (async () => {
    try {
      const resp = await fetch('/tile-config.json');
      tileConfig = await resp.json();
    } catch {
      tileConfig = { n_monsters: 394, n_objects: 456, n_other: 232, other_names: [] };
    }

    const loadImg = (src: string): Promise<HTMLImageElement> =>
      new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = reject;
        img.src = src;
      });

    try {
      const [mon, obj, oth] = await Promise.all([
        loadImg('/sheets/nh-monsters.png'),
        loadImg('/sheets/nh-objects.png'),
        loadImg('/sheets/nh-other.png'),
      ]);
      sheets['nh-monsters'] = mon;
      sheets['nh-objects'] = obj;
      sheets['nh-other'] = oth;
    } catch {
      // No sprites available
    }
    assetsReady = true;
  })();
  return assetsPromise;
}

export function getSpriteCoords(tileIdx: number): { sheet: string; sx: number; sy: number } | null {
  if (!tileConfig) return null;
  const { n_monsters, n_objects } = tileConfig;
  let sheetName: string;
  let localIdx: number;
  if (tileIdx < n_monsters) {
    sheetName = 'nh-monsters';
    localIdx = tileIdx;
  } else if (tileIdx < n_monsters + n_objects) {
    sheetName = 'nh-objects';
    localIdx = tileIdx - n_monsters;
  } else {
    sheetName = 'nh-other';
    localIdx = tileIdx - n_monsters - n_objects;
  }
  return {
    sheet: sheetName,
    sx: (localIdx % SHEET_COLS) * TILE_SIZE,
    sy: Math.floor(localIdx / SHEET_COLS) * TILE_SIZE,
  };
}

export function getSheets() { return sheets; }
export function getTileConfig() { return tileConfig; }

// Inline sprite rendered as a small canvas
function InlineSprite({ tileIdx, size }: { tileIdx: number; size: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !assetsReady) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, size, size);

    const coords = getSpriteCoords(tileIdx);
    if (coords) {
      const img = sheets[coords.sheet];
      if (img) {
        ctx.drawImage(img, coords.sx, coords.sy, TILE_SIZE, TILE_SIZE, 0, 0, size, size);
      }
    }
  }, [tileIdx, size]);

  return (
    <canvas
      ref={canvasRef}
      width={size}
      height={size}
      style={{ display: 'inline-block', verticalAlign: 'middle', imageRendering: 'pixelated', width: size, height: size }}
    />
  );
}

// Rich text pattern: [img=nh-sprite-N]
const RICH_TEXT_RE = /\[img=nh-sprite-(\d+)\]/g;

interface RichTextProps {
  text: string;
  spriteSize?: number;
  style?: React.CSSProperties;
  className?: string;
}

export function RichText({ text, spriteSize = 16, style, className }: RichTextProps) {
  const parts: React.ReactNode[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  RICH_TEXT_RE.lastIndex = 0;
  while ((match = RICH_TEXT_RE.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }
    parts.push(<InlineSprite key={match.index} tileIdx={parseInt(match[1])} size={spriteSize} />);
    lastIndex = RICH_TEXT_RE.lastIndex;
  }
  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return <span style={style} className={className}>{parts}</span>;
}
