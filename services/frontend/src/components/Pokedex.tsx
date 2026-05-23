import { useEffect, useState } from "react";
import type { Card } from "../hooks/useGame";

type Props = {
  playerName: string;
  onClose: () => void;
};

const GATEWAY_URL =
  (import.meta as unknown as { env: Record<string, string> }).env
    .VITE_GATEWAY_URL ?? "http://localhost:8080";

export function Pokedex({ playerName, onClose }: Props) {
  const [allCards, setAllCards] = useState<Card[]>([]);
  const [collectedIds, setCollectedIds] = useState<Set<number>>(new Set());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const encoded = encodeURIComponent(playerName);
    Promise.all([
      fetch(`${GATEWAY_URL}/api/cards`).then((r) => r.json()),
      fetch(`${GATEWAY_URL}/api/pokedex/player/${encoded}`).then((r) => r.json()),
    ])
      .then(([cardsData, pokedexData]) => {
        const cards: Card[] = Array.isArray(cardsData)
          ? cardsData
          : (cardsData.cards ?? []);
        setAllCards(cards);
        setCollectedIds(new Set<number>(pokedexData.card_ids ?? []));
      })
      .catch(() => setError("データの読み込みに失敗しました"))
      .finally(() => setLoading(false));
  }, [playerName]);

  const collected = allCards.filter((c) => collectedIds.has(c.id));
  const remaining = allCards.filter((c) => !collectedIds.has(c.id));

  return (
    <div className="pokedex">
      <div className="pokedex__header">
        <div>
          <h2 className="pokedex__title">図鑑</h2>
          <p className="pokedex__player">{playerName} の収集記録</p>
        </div>
        <div className="pokedex__meta">
          <span className="pokedex__progress-text">
            {collectedIds.size} <span className="pokedex__progress-sep">/</span> {allCards.length} 枚
          </span>
          <button type="button" className="pokedex__close-btn" onClick={onClose}>閉じる</button>
        </div>
      </div>

      {loading && <p className="pokedex__loading">読み込み中…</p>}
      {error && <p className="pokedex__error">{error}</p>}

      {!loading && !error && (
        <>
          <div className="pokedex__progress-bar-wrap">
            <div
              className="pokedex__progress-bar-fill"
              style={{ width: allCards.length > 0 ? `${(collectedIds.size / allCards.length) * 100}%` : "0%" }}
            />
          </div>

          {collected.length > 0 && (
            <section className="pokedex__section">
              <p className="pokedex__section-title">収集済み ({collected.length}枚)</p>
              <div className="pokedex__grid">
                {collected.map((card) => (
                  <div key={card.id} className="pokedex__card pokedex__card--collected">
                    <div className="pokedex__img-wrap">
                      <img
                        src={card.image}
                        alt={card.fuda}
                        className="pokedex__img"
                        onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = "none"; }}
                      />
                    </div>
                    <p className="pokedex__card-name">{card.fuda}</p>
                  </div>
                ))}
              </div>
            </section>
          )}

          {remaining.length > 0 && (
            <section className="pokedex__section">
              <p className="pokedex__section-title">未収集 ({remaining.length}枚)</p>
              <div className="pokedex__grid">
                {remaining.map((card) => (
                  <div key={card.id} className="pokedex__card pokedex__card--unknown">
                    <div className="pokedex__img-wrap pokedex__img-wrap--unknown">
                      <div className="pokedex__silhouette" />
                    </div>
                    <p className="pokedex__card-name pokedex__card-name--unknown">???</p>
                  </div>
                ))}
              </div>
            </section>
          )}

          {allCards.length === 0 && (
            <p className="pokedex__empty">カードデータが見つかりませんでした</p>
          )}
        </>
      )}
    </div>
  );
}
