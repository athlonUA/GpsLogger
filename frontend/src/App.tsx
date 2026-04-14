import { useCallback, useMemo, useState } from 'react';
import { fetchPoints, type Point } from './api';
import MapView from './Map';

function toLocalInputValue(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function App() {
  const initialFrom = useMemo(() => new Date(Date.now() - 24 * 60 * 60 * 1000), []);
  const initialTo = useMemo(() => new Date(), []);

  const [from, setFrom] = useState(toLocalInputValue(initialFrom));
  const [to, setTo] = useState(toLocalInputValue(initialTo));
  const [points, setPoints] = useState<Point[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onVisualize = useCallback(async () => {
    setError(null);
    setLoading(true);
    try {
      const data = await fetchPoints(new Date(from), new Date(to));
      setPoints(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPoints([]);
    } finally {
      setLoading(false);
    }
  }, [from, to]);

  const status = error
    ? error
    : loading
      ? 'Loading…'
      : points.length > 0
        ? `${points.length.toLocaleString()} points`
        : 'Select range and click Visualize';

  return (
    <div className="app">
      <div className="panel">
        <label>
          From
          <input
            type="datetime-local"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
          />
        </label>
        <label>
          To
          <input
            type="datetime-local"
            value={to}
            onChange={(e) => setTo(e.target.value)}
          />
        </label>
        <button onClick={onVisualize} disabled={loading}>
          {loading ? 'Loading…' : 'Visualize'}
        </button>
        <span className={`stats${error ? ' error' : ''}`}>{status}</span>
      </div>
      <MapView points={points} />
    </div>
  );
}
