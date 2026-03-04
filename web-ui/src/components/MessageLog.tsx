import { useEffect, useRef } from 'react';
import { observer } from 'mobx-react-lite';
import { gameStore } from '../stores/GameStore';
import { RichText } from './RichText';

export const MessageLog = observer(function MessageLog() {
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [gameStore.messages.length]);

  return (
    <div className="message-log">
      {gameStore.messages.map((msg, i) => (
        <div key={i} className={`message ${msg.attr === 1 ? 'bold' : ''}`}>
          <RichText text={msg.text} />
        </div>
      ))}
      <div ref={endRef} />
    </div>
  );
});
