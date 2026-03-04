import { useEffect, useCallback } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from './stores/GameStore';
import { GameMap } from './components/GameMap';
import { MessageLog } from './components/MessageLog';
import { StatusPanel } from './components/StatusPanel';
import { MenuBar } from './components/MenuBar';
import { Toolbar } from './components/Toolbar';
import { YnDialog } from './components/YnDialog';
import { GetlinDialog } from './components/GetlinDialog';
import { MenuDialog } from './components/MenuDialog';
import { TextWindow } from './components/TextWindow';
import { PlayerSelect } from './components/PlayerSelect';
import { EquipPanel } from './components/EquipPanel';
import './App.css';

const App = observer(function App() {
  useEffect(() => {
    gameStore.start();
  }, []);

  const handleKeyDown = useCallback((e: KeyboardEvent) => {
    const mode = gameStore.inputMode;
    // Don't capture keys when dialogs with their own input are active
    if (mode.type === 'getlin' || mode.type === 'plsel') return;
    if (mode.type === 'menu' || mode.type === 'yn' || mode.type === 'text') return;
    if (mode.type !== 'getch') return;

    e.preventDefault();

    let key: number | null = null;

    if (e.ctrlKey && e.key.length === 1) {
      key = e.key.toUpperCase().charCodeAt(0) - 64;
    } else if (e.key === 'ArrowUp') key = 107; // k
    else if (e.key === 'ArrowDown') key = 106; // j
    else if (e.key === 'ArrowLeft') key = 104; // h
    else if (e.key === 'ArrowRight') key = 108; // l
    else if (e.key === 'Escape') key = 27;
    else if (e.key === 'Enter') key = 13;
    else if (e.key === ' ') key = 32;
    else if (e.key === 'Backspace') key = 8;
    else if (e.key.length === 1) key = e.key.charCodeAt(0);

    if (key !== null) gameStore.sendKey(key);
  }, []);

  useEffect(() => {
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [handleKeyDown]);

  const { engineState, inputMode } = gameStore;

  return (
    <div className="app">
      <div className="top-bar">
        <MenuBar />
        <Toolbar />
      </div>
      <div className="main-area">
        <div className="left-panel">
          <StatusPanel />
          <EquipPanel />
        </div>
        <div className="center-area">
          <GameMap />
          <MessageLog />
        </div>
      </div>

      {engineState === 'loading' && (
        <div className="dialog-overlay">
          <div className="dialog loading-dialog">
            <h2>Loading NetHack...</h2>
            <div className="loading-bar">
              <div className="loading-fill" style={{ width: `${Math.min(100, gameStore.loadingProgress * 100)}%` }} />
            </div>
          </div>
        </div>
      )}

      {engineState === 'error' && (
        <div className="dialog-overlay">
          <div className="dialog error-dialog">
            <h2>Error</h2>
            <p>{gameStore.errorMessage}</p>
          </div>
        </div>
      )}

      {inputMode.type === 'yn' && <YnDialog />}
      {inputMode.type === 'getlin' && <GetlinDialog />}
      {inputMode.type === 'menu' && <MenuDialog />}
      {inputMode.type === 'text' && <TextWindow />}
      {inputMode.type === 'plsel' && <PlayerSelect />}
    </div>
  );
});

export default App;
