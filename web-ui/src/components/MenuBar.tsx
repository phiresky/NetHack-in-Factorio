import { useState } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { MENU_BAR } from '../protocol/constants';

export const MenuBar = observer(function MenuBar() {
  const [openMenu, setOpenMenu] = useState<string | null>(null);

  const handleItemClick = (key?: number, ext?: string, action?: string) => {
    setOpenMenu(null);
    if (action === 'toggle_ascii') {
      gameStore.toggleAscii();
      return;
    }
    if (key !== undefined && gameStore.inputMode.type === 'getch') {
      if (ext) {
        // Extended command: send '#' then the command string
        gameStore.sendKey(35); // '#'
        // The C code will call getlin for the extended command name
        // It will be handled by the getlin dialog
      } else {
        gameStore.sendKey(key);
      }
    }
  };

  return (
    <div className="menu-bar">
      {MENU_BAR.map(menu => (
        <div
          key={menu.name}
          className={`menu-bar-item ${openMenu === menu.name ? 'open' : ''}`}
          onMouseEnter={() => openMenu && setOpenMenu(menu.name)}
          onClick={() => setOpenMenu(openMenu === menu.name ? null : menu.name)}
        >
          <span className="menu-bar-label">{menu.label}</span>
          {openMenu === menu.name && (
            <div className="menu-dropdown">
              {menu.items.map((item, i) => {
                if (item.separator) {
                  return <div key={i} className="menu-separator" />;
                }
                return (
                  <div
                    key={i}
                    className="menu-dropdown-item"
                    onClick={(e) => {
                      e.stopPropagation();
                      handleItemClick(item.key, item.ext, item.action);
                    }}
                  >
                    <span>{item.label}</span>
                    {item.shortcut && <span className="shortcut">{item.shortcut}</span>}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ))}
    </div>
  );
});
