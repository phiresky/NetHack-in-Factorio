import { useState } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';

export const GetlinDialog = observer(function GetlinDialog() {
  const mode = gameStore.inputMode;
  if (mode.type !== 'getlin') return null;

  const [text, setText] = useState('');

  const submit = () => {
    // Queue each character + null terminator via successive nhgetch calls
    // First char goes as the direct response, rest queued
    for (let i = 0; i < text.length; i++) {
      if (i === 0) {
        gameStore.sendKey(text.charCodeAt(i));
      } else {
        // Subsequent chars: the C code will call nhgetch again for each
        // We need to send them one at a time through the SAB
        // For simplicity, queue all remaining via rapid sends
        setTimeout(() => gameStore.sendKey(text.charCodeAt(i)), i);
      }
    }
    // Send newline to terminate
    setTimeout(() => gameStore.sendKey(10), text.length);
    setText('');
  };

  const handleKey = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      submit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      gameStore.sendKey(27);
      setText('');
    }
  };

  return (
    <div className="dialog-overlay">
      <div className="dialog getlin-dialog">
        <div className="dialog-text">{mode.prompt}</div>
        <input
          type="text"
          value={text}
          onChange={e => setText(e.target.value)}
          onKeyDown={handleKey}
          autoFocus
          className="getlin-input"
        />
        <div className="dialog-buttons">
          <button onClick={submit}>OK</button>
          <button onClick={() => { gameStore.sendKey(27); setText(''); }}>Cancel</button>
        </div>
      </div>
    </div>
  );
});
