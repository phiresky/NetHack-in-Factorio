import { useState } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';

export const PlayerSelect = observer(function PlayerSelect() {
  const mode = gameStore.inputMode;
  if (mode.type !== 'plsel') return null;

  const [selectedRole, setSelectedRole] = useState(-1);
  const [selectedRace, setSelectedRace] = useState(-1);
  const [selectedGender, setSelectedGender] = useState(-1);
  const [selectedAlign, setSelectedAlign] = useState(-1);
  const [name, setName] = useState('');

  const roles = gameStore.plselRoles;
  const races = gameStore.plselRaces;
  const genders = gameStore.plselGenders;
  const aligns = gameStore.plselAligns;

  const play = () => {
    gameStore.sendPlselResult(0, name || 'Player', selectedRole, selectedRace, selectedGender, selectedAlign);
  };

  const random = () => {
    gameStore.sendPlselResult(0, name || 'Player', -1, -1, -1, -1);
  };

  const quit = () => {
    gameStore.sendPlselResult(-1);
  };

  return (
    <div className="dialog-overlay">
      <div className="dialog plsel-dialog">
        <h2>Choose Your Character</h2>

        <div className="plsel-name">
          <label>Name: </label>
          <input
            type="text"
            value={name}
            onChange={e => setName(e.target.value)}
            placeholder="Player name"
            autoFocus
          />
        </div>

        <div className="plsel-columns">
          <div className="plsel-column">
            <h3>Role</h3>
            <div className="plsel-list">
              {roles.filter(r => r.allow).map(r => (
                <button
                  key={r.idx}
                  className={selectedRole === r.idx ? 'selected' : ''}
                  onClick={() => setSelectedRole(r.idx)}
                >
                  {r.name}
                </button>
              ))}
            </div>
          </div>

          <div className="plsel-column">
            <h3>Race</h3>
            <div className="plsel-list">
              {races.filter(r => r.allow).map(r => (
                <button
                  key={r.idx}
                  className={selectedRace === r.idx ? 'selected' : ''}
                  onClick={() => setSelectedRace(r.idx)}
                >
                  {r.name}
                </button>
              ))}
            </div>
          </div>

          <div className="plsel-column">
            <h3>Gender</h3>
            <div className="plsel-options">
              {genders.filter(g => g.allow).map(g => (
                <label key={g.idx}>
                  <input
                    type="radio"
                    name="gender"
                    checked={selectedGender === g.idx}
                    onChange={() => setSelectedGender(g.idx)}
                  />
                  {g.name}
                </label>
              ))}
            </div>

            <h3>Alignment</h3>
            <div className="plsel-options">
              {aligns.filter(a => a.allow).map(a => (
                <label key={a.idx}>
                  <input
                    type="radio"
                    name="align"
                    checked={selectedAlign === a.idx}
                    onChange={() => setSelectedAlign(a.idx)}
                  />
                  {a.name}
                </label>
              ))}
            </div>
          </div>
        </div>

        <div className="dialog-buttons">
          <button onClick={random}>Random</button>
          <button onClick={play} className="primary">Play</button>
          <button onClick={quit}>Quit</button>
        </div>
      </div>
    </div>
  );
});
