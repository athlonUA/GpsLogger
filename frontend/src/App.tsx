import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  fetchMatchedPoints,
  fetchPoints,
  MatchingDisabledError,
  type FetchResult,
  type Point,
} from './api';
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

// Parse an ISO datetime string from the URL query string. Returns undefined
// if the param is missing or unparseable so callers can fall back to the
// default 24 h window. The wire format is ISO UTC (from `Date.toISOString`)
// so the URL is time-zone stable across browsers — sharing a link between
// two users in different zones produces the same absolute time window.
function readUrlDate(key: string): Date | undefined {
  if (typeof window === 'undefined') return undefined;
  const raw = new URLSearchParams(window.location.search).get(key);
  if (!raw) return undefined;
  const d = new Date(raw);
  return Number.isNaN(d.getTime()) ? undefined : d;
}

export default function App() {
  // Defaults fall back to a 24 h window ending now. URL params (if valid)
  // override on first render so reloads / shared links hydrate the same
  // range the previous session was looking at.
  const initialFrom = useMemo(
    () => readUrlDate('from') ?? new Date(Date.now() - 24 * 60 * 60 * 1000),
    [],
  );
  const initialTo = useMemo(() => readUrlDate('to') ?? new Date(), []);
  // `defaultFrom`/`defaultTo` are the always-fresh values used by Logout to
  // reset the range to "last 24 h" rather than to whatever URL the session
  // was loaded with.
  const defaultFrom = useMemo(() => new Date(Date.now() - 24 * 60 * 60 * 1000), []);
  const defaultTo = useMemo(() => new Date(), []);

  const initialMatched = useMemo(() => {
    if (typeof window === 'undefined') return false;
    return new URLSearchParams(window.location.search).get('matched') === '1';
  }, []);

  const [deviceId, setDeviceId] = useState<string>(() => readStoredDeviceId());
  const [from, setFrom] = useState(toLocalInputValue(initialFrom));
  const [to, setTo] = useState(toLocalInputValue(initialTo));
  const [matched, setMatched] = useState<boolean>(initialMatched);
  const [points, setPoints] = useState<Point[]>([]);
  const [truncated, setTruncated] = useState(false);
  const [matchStats, setMatchStats] = useState<{
    matched: number;
    total: number;
  } | null>(null);
  /** Backend reported that OSRM is not configured. Latch this so the
   *  toggle UI can self-disable and we stop hitting the endpoint. */
  const [matchingUnavailable, setMatchingUnavailable] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

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

  // Mirror the date range + matched toggle into the URL so the page is
  // reloadable / shareable. `replaceState` keeps the browser history
  // clean — every keystroke in the datetime-local inputs would otherwise
  // push a new entry. Invalid `Date` values (shouldn't happen via the
  // input, but defensively) skip the write instead of throwing.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    try {
      const params = new URLSearchParams(window.location.search);
      const fromDate = new Date(from);
      const toDate = new Date(to);
      if (Number.isNaN(fromDate.getTime()) || Number.isNaN(toDate.getTime())) return;
      params.set('from', fromDate.toISOString());
      params.set('to', toDate.toISOString());
      if (matched) {
        params.set('matched', '1');
      } else {
        params.delete('matched');
      }
      const qs = params.toString();
      const next = `${window.location.pathname}${qs ? `?${qs}` : ''}${window.location.hash}`;
      window.history.replaceState(null, '', next);
    } catch {
      /* non-browser or locked history API — non-fatal */
    }
  }, [from, to, matched]);

  const onVisualize = useCallback(async () => {
    if (!deviceId) {
      setError('Device ID is required');
      return;
    }
    // Cancel any in-flight request before starting a new one.
    abortRef.current?.abort();
    const ac = new AbortController();
    abortRef.current = ac;

    setError(null);
    setLoading(true);
    setMatchStats(null);
    // Use matched endpoint only when the toggle is on AND the backend
    // has not reported the feature disabled in a previous call. A 503
    // latch prevents repeated round trips once we learn OSRM is absent.
    const useMatched = matched && !matchingUnavailable;
    try {
      let result: FetchResult;
      if (useMatched) {
        try {
          result = await fetchMatchedPoints(
            deviceId,
            new Date(from),
            new Date(to),
            ac.signal,
          );
        } catch (e) {
          if (e instanceof MatchingDisabledError) {
            // OSRM is not configured — latch the UI into raw mode and
            // retry the same window without the matched path, so the
            // user still sees their data.
            setMatchingUnavailable(true);
            result = await fetchPoints(
              deviceId,
              new Date(from),
              new Date(to),
              ac.signal,
            );
          } else {
            throw e;
          }
        }
      } else {
        result = await fetchPoints(
          deviceId,
          new Date(from),
          new Date(to),
          ac.signal,
        );
      }
      setPoints(result.data);
      setTruncated(result.truncated);
      if (
        typeof result.matched_count === 'number' &&
        typeof result.total_count === 'number'
      ) {
        setMatchStats({
          matched: result.matched_count,
          total: result.total_count,
        });
      }
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') return;
      setError(e instanceof Error ? e.message : String(e));
      setPoints([]);
      setTruncated(false);
    } finally {
      setLoading(false);
    }
  }, [deviceId, from, to, matched, matchingUnavailable]);

  const onLogout = useCallback(() => {
    setDeviceId('');
    setPoints([]);
    setError(null);
    setMatched(false);
    setMatchStats(null);
    setFrom(toLocalInputValue(defaultFrom));
    setTo(toLocalInputValue(defaultTo));
    // Clear query params too, so the refreshed URL reflects the logged-out
    // state. Hash is preserved in case routing is ever added.
    if (typeof window !== 'undefined') {
      try {
        window.history.replaceState(
          null,
          '',
          `${window.location.pathname}${window.location.hash}`,
        );
      } catch {
        /* non-fatal */
      }
    }
  }, [defaultFrom, defaultTo]);

  const matchLabel =
    matchStats && matchStats.total > 0
      ? ` · ${matchStats.matched.toLocaleString()} / ${matchStats.total.toLocaleString()} snapped to roads`
      : '';
  const pointsLabel = truncated
    ? `${points.length.toLocaleString()} points (truncated — narrow the time range)${matchLabel}`
    : `${points.length.toLocaleString()} points${matchLabel}`;

  const status = error
    ? error
    : loading
      ? 'Loading…'
      : points.length > 0
        ? pointsLabel
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
        <label className="panel__toggle" title={matchingUnavailable
            ? 'Map-matching service not configured on the backend'
            : 'Snap points to OSM roads / paths (OSRM)'}>
          <input
            type="checkbox"
            checked={matched && !matchingUnavailable}
            onChange={(e) => setMatched(e.target.checked)}
            disabled={loading || matchingUnavailable}
          />
          Snap to roads
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
