import { useState, useEffect } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { PICK_NONE, PICK_ONE, PICK_ANY } from '../protocol/constants';
import { RichText } from './RichText';

export const MenuDialog = observer(function MenuDialog() {
  const mode = gameStore.inputMode;
  if (mode.type !== 'menu') return null;

  const { how } = mode;
  const items = gameStore.menuItems;
  const prompt = gameStore.menuPrompt;

  const [selected, setSelected] = useState<Set<number>>(new Set());

  // Pre-select items marked as preselected
  useEffect(() => {
    const pre = new Set<number>();
    for (const item of items) {
      if (item.preselected && item.identifier !== 0) pre.add(item.identifier);
    }
    setSelected(pre);
  }, [items]);

  const handleItemClick = (identifier: number) => {
    if (how === PICK_NONE) return;
    if (how === PICK_ONE) {
      gameStore.sendMenuResult(1, [identifier]);
      return;
    }
    // PICK_ANY: toggle
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(identifier)) next.delete(identifier);
      else next.add(identifier);
      return next;
    });
  };

  const handleAccelerator = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      gameStore.sendMenuResult(-1, []);
      return;
    }
    if (e.key === 'Enter' || e.key === ' ') {
      if (how === PICK_ANY) {
        const sel = Array.from(selected);
        gameStore.sendMenuResult(sel.length, sel);
      } else if (how === PICK_NONE) {
        gameStore.sendMenuResult(0, []);
      }
      return;
    }
    // Accelerator key
    const code = e.key.charCodeAt(0);
    for (const item of items) {
      if (item.accelerator === code && item.identifier !== 0) {
        if (how === PICK_ONE) {
          gameStore.sendMenuResult(1, [item.identifier]);
        } else if (how === PICK_ANY) {
          handleItemClick(item.identifier);
        }
        return;
      }
    }
  };

  return (
    <div className="dialog-overlay" onKeyDown={handleAccelerator} tabIndex={0} autoFocus>
      <div className="dialog menu-dialog">
        {prompt && <div className="dialog-text">{prompt}</div>}
        <div className="menu-items">
          {items.map((item, i) => {
            if (item.identifier === 0) {
              // Header/separator
              return <div key={i} className="menu-header"><RichText text={item.text} /></div>;
            }
            const accel = item.accelerator ? String.fromCharCode(item.accelerator) : '';
            const isSelected = selected.has(item.identifier);
            return (
              <div
                key={i}
                className={`menu-item ${isSelected ? 'selected' : ''} ${how !== PICK_NONE ? 'clickable' : ''}`}
                onClick={() => handleItemClick(item.identifier)}
              >
                {how === PICK_ANY && (
                  <span className="menu-checkbox">{isSelected ? '[x]' : '[ ]'}</span>
                )}
                {accel && <span className="menu-accel">{accel}) </span>}
                <span className="menu-text"><RichText text={item.text} /></span>
              </div>
            );
          })}
        </div>
        <div className="dialog-buttons">
          {how === PICK_ANY && (
            <>
              <button onClick={() => {
                const all = new Set(items.filter(i => i.identifier !== 0).map(i => i.identifier));
                setSelected(all);
              }}>All</button>
              <button onClick={() => setSelected(new Set())}>None</button>
              <button onClick={() => {
                const sel = Array.from(selected);
                gameStore.sendMenuResult(sel.length, sel);
              }}>OK</button>
            </>
          )}
          {how === PICK_NONE && (
            <button onClick={() => gameStore.sendMenuResult(0, [])}>OK</button>
          )}
          <button onClick={() => gameStore.sendMenuResult(-1, [])}>Cancel</button>
        </div>
      </div>
    </div>
  );
});
