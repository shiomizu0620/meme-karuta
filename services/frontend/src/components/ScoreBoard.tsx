import type { RoomState } from "../hooks/useGame";
import { EfudaCard } from "./EfudaCard";

type Props = {
  room: RoomState;
  onPlayAgain: () => void;
  onShowPokedex: () => void;
};

export function ScoreBoard({ room, onPlayAgain, onShowPokedex }: Props) {
  const { game, playerName } = room;
  if (!game) return null;

  const { scores, cards, takenCardIds } = game;
  const ranking = Object.entries(scores).sort(([, a], [, b]) => b - a);
  const myScore = scores[playerName] ?? 0;
  const takenCards = cards.filter((c) => takenCardIds.has(c.id));

  return (
    <div className="scoreboard">
      <div className="scoreboard__card">
        <h2 className="scoreboard__title">ゲーム終了！</h2>
        <div className="scoreboard__ranking">
          {ranking.map(([name, score], idx) => (
            <div key={name} className={`scoreboard__row ${name === playerName ? "scoreboard__row--me" : ""}`}>
              <span className="scoreboard__rank">{idx === 0 ? "🥇" : idx === 1 ? "🥈" : idx === 2 ? "🥉" : `${idx + 1}位`}</span>
              <span className="scoreboard__name">{name}</span>
              <span className="scoreboard__score">{score} 枚</span>
            </div>
          ))}
        </div>
        <p className="scoreboard__my-score">あなたの取り枚数: <strong>{myScore} 枚</strong></p>
        {takenCards.length > 0 && (
          <div className="scoreboard__collection">
            <p className="scoreboard__collection-title">取り札コレクション（タップで表裏切り替え）</p>
            <div className="scoreboard__collection-grid">
              {takenCards.map((card) => (
                <EfudaCard key={card.id} card={card} taken takenBy={null} isMe={false} onClick={() => {}} collectionMode />
              ))}
            </div>
          </div>
        )}
        <div className="scoreboard__actions">
          <button type="button" className="scoreboard__pokedex-btn" onClick={onShowPokedex}>図鑑を見る</button>
          <button type="button" className="scoreboard__again-btn" onClick={onPlayAgain}>ロビーに戻る</button>
        </div>
      </div>
    </div>
  );
}
