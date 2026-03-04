import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { RichText } from './RichText';
import {
  BL_TITLE, BL_DLEVEL, BL_HP, BL_HPMAX, BL_ALIGN, BL_HUNGER, BL_CAP,
  BL_CONDITION, BL_TIME, BL_SCORE,
  STAT_LABELS, VITAL_LABELS, CONDITION_BITS,
} from '../protocol/constants';

function getHpColor(hp: number, hpmax: number): string {
  if (hpmax <= 0) return '#fff';
  const ratio = hp / hpmax;
  if (ratio > 0.75) return '#fff';
  if (ratio > 0.50) return '#ff0';
  if (ratio > 0.25) return '#ffc000';
  if (ratio > 0.10) return '#f33';
  return '#f4f';
}

// Strip rich text for numeric parsing only
function stripRichText(s: string): string {
  return s.replace(/\[img=nh-sprite-\d+\]/g, '');
}

function getFieldRaw(idx: number): string {
  return gameStore.statusFields.get(idx)?.value ?? '';
}

function getFieldNum(idx: number): string {
  return stripRichText(getFieldRaw(idx));
}

export const StatusPanel = observer(function StatusPanel() {
  // Access statusVersion to observe changes
  void gameStore.statusVersion;

  const title = getFieldRaw(BL_TITLE);
  const dlevel = getFieldRaw(BL_DLEVEL);
  const hp = parseInt(getFieldNum(BL_HP)) || 0;
  const hpmax = parseInt(getFieldNum(BL_HPMAX)) || 0;
  const align = getFieldNum(BL_ALIGN);
  const hunger = getFieldNum(BL_HUNGER);
  const cap = getFieldNum(BL_CAP);
  const time = getFieldNum(BL_TIME);
  const score = getFieldNum(BL_SCORE);

  const condValue = parseInt(getFieldNum(BL_CONDITION)) || 0;
  const activeConditions = CONDITION_BITS.filter(c => condValue & c.mask);

  return (
    <div className="status-panel">
      {title && <div className="status-title"><RichText text={title} /></div>}
      {dlevel && <div className="status-dlevel"><RichText text={dlevel} /></div>}

      <div className="status-section">
        <div className="status-label">Stats</div>
        <div className="status-grid">
          {STAT_LABELS.map(s => (
            <div key={s.name} className="stat-item" title={s.prefix}>
              <img src={s.icon} alt="" className="stat-icon" />
              <span className="stat-prefix">{s.prefix}</span>
              <RichText text={getFieldRaw(s.idx)} className="stat-value" />
            </div>
          ))}
        </div>
      </div>

      <div className="status-section">
        <div className="status-label">Vitals</div>
        <div className="status-grid">
          {VITAL_LABELS.map(v => {
            const raw = getFieldRaw(v.idx);
            const isHp = v.name === 'hp';
            const color = isHp ? getHpColor(hp, hpmax) : undefined;
            const maxRaw = v.idx2 !== undefined ? getFieldRaw(v.idx2) : null;
            const display = maxRaw ? `${raw}/${maxRaw}` : raw;
            return (
              <div key={v.name} className="stat-item">
                <span className="stat-prefix">{v.prefix}</span>
                <RichText text={display} className="stat-value" style={color ? { color } : undefined} />
              </div>
            );
          })}
        </div>
      </div>

      {(time || score) && (
        <div className="status-section">
          {time && <span className="stat-item"><span className="stat-prefix">T:</span>{time}</span>}
          {score && <span className="stat-item"><span className="stat-prefix">S:</span>{score}</span>}
        </div>
      )}

      <div className="status-conditions">
        {align && <span className="condition">{align}</span>}
        {hunger && hunger !== 'Not Hungry' && (
          <span className="condition warning">{hunger}</span>
        )}
        {cap && cap !== '' && <span className="condition warning">{cap}</span>}
        {activeConditions.map(c => (
          <span key={c.name} className={`condition ${c.dangerous ? 'dangerous' : ''}`}>
            {c.name}
          </span>
        ))}
      </div>
    </div>
  );
});
