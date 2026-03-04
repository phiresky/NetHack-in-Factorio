import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';

export const YnDialog = observer(function YnDialog() {
  const mode = gameStore.inputMode;
  if (mode.type !== 'yn') return null;

  const { query, resp, def } = mode;

  const handleKey = (e: React.KeyboardEvent) => {
    e.preventDefault();
    const ch = e.key;
    if (ch === 'Escape') {
      gameStore.sendKey(27);
    } else if (ch === 'Enter') {
      gameStore.sendKey(def || 13);
    } else if (ch.length === 1) {
      gameStore.sendKey(ch.charCodeAt(0));
    }
  };

  return (
    <div className="dialog-overlay" onKeyDown={handleKey} tabIndex={0} autoFocus>
      <div className="dialog yn-dialog">
        <div className="dialog-text">{query}</div>
        {resp && <div className="dialog-hint">[{resp}]</div>}
        <div className="dialog-buttons">
          {resp.includes('y') && (
            <button onClick={() => gameStore.sendKey(121)}>Yes</button>
          )}
          {resp.includes('n') && (
            <button onClick={() => gameStore.sendKey(110)}>No</button>
          )}
          {!resp && (
            <button onClick={() => gameStore.sendKey(def || 32)}>OK</button>
          )}
        </div>
      </div>
    </div>
  );
});
