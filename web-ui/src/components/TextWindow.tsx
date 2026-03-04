import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';

export const TextWindow = observer(function TextWindow() {
  const mode = gameStore.inputMode;
  if (mode.type !== 'text') return null;

  const win = gameStore.windows.get(mode.winid);
  if (!win) return null;

  const dismiss = () => {
    gameStore.sendKey(27); // ESC or space to dismiss
  };

  return (
    <div className="dialog-overlay" tabIndex={0} autoFocus onKeyDown={(e) => {
      if (e.key === 'Escape' || e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        dismiss();
      }
    }}>
      <div className="dialog text-window">
        <div className="text-content">
          {win.text.map((line, i) => (
            <div key={i}>{line || '\u00A0'}</div>
          ))}
        </div>
        <div className="dialog-buttons">
          <button onClick={dismiss}>OK</button>
        </div>
      </div>
    </div>
  );
});
