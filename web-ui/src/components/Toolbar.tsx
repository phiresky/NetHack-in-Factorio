import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { TOOLBAR_BUTTONS } from '../protocol/constants';

export const Toolbar = observer(function Toolbar() {
  return (
    <div className="toolbar">
      {TOOLBAR_BUTTONS.map(btn => (
        <button
          key={btn.name}
          className="toolbar-btn"
          onClick={() => {
            if (gameStore.inputMode.type === 'getch') {
              gameStore.sendKey(btn.key);
            }
          }}
          title={btn.label}
        >
          <img src={btn.icon} alt="" className="toolbar-icon" />
          {btn.label}
        </button>
      ))}
    </div>
  );
});
