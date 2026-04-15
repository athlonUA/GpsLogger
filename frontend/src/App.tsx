import { useCallback, useEffect, useMemo, useState } from 'react';
import { fetchPoints, type Point } from './api';
import MapView from './Map';

const DEVICE_ID_STORAGE_KEY = 'device_id';

function toLocalInputValue(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function readStoredDeviceId(): string {
  try {
    return localStorage.getItem(DEVICE_ID_STORAGE_KEY) ?? '';
  } catch {
    // Private mode / storage disabled — treat as empty.
    return '';
  }
}

export default function App() {
  const initialFrom = useMemo(() => new Date(Date.now() - 24 * 60 * 60 * 1000), []);
  const initialTo = useMemo(() => new Date(), []);

  const [deviceId, setDeviceId] = useState<string>(() => readStoredDeviceId());
  const [from, setFrom] = useState(toLocalInputValue(initialFrom));
  const [to, setTo] = useState(toLocalInputValue(initialTo));
  const [points, setPoints] = useState<Point[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Persist device ID on every change. An empty value clears the key so a
  // page reload returns the UI to its initial (logged-out) state.
  useEffect(() => {
    try {
      if (deviceId) {
        localStorage.setItem(DEVICE_ID_STORAGE_KEY, deviceId);
      } else {
        localStorage.removeItem(DEVICE_ID_STORAGE_KEY);
      }
    } catch {
      /* storage disabled — in-memory state still works for this session */
    }
  }, [deviceId]);

  const onVisualize = useCallback(async () => {
    if (!deviceId) {
      setError('Device ID is required');
      return;
    }
    setError(null);
    setLoading(true);
    try {
      const data = await fetchPoints(deviceId, new Date(from), new Date(to));
      setPoints(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPoints([]);
    } finally {
      setLoading(false);
    }
  }, [deviceId, from, to]);

  const onLogout = useCallback(() => {
    setDeviceId('');
    setPoints([]);
    setError(null);
    setFrom(toLocalInputValue(initialFrom));
    setTo(toLocalInputValue(initialTo));
  }, [initialFrom, initialTo]);

  const status = error
    ? error
    : loading
      ? 'Loading…'
      : points.length > 0
        ? `${points.length.toLocaleString()} points`
        : deviceId
          ? 'Select range and click Visualize'
          : 'Enter device ID to begin';

  return (
    <div className="app">
      <div className="panel">
        <label className="device-id-label">
          Device ID
          <input
            type="text"
            value={deviceId}
            onChange={(e) => setDeviceId(e.target.value.trim())}
            placeholder="paste from mobile app"
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
          />
        </label>
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
        <button onClick={onVisualize} disabled={loading || !deviceId}>
          {loading ? 'Loading…' : 'Visualize'}
        </button>
        {deviceId && (
          <button
            type="button"
            className="panel__logout"
            onClick={onLogout}
            disabled={loading}
          >
            Logout
          </button>
        )}
        <span className={`stats${error ? ' error' : ''}`}>{status}</span>
      </div>
      <MapView points={points} />
    </div>
  );
}
