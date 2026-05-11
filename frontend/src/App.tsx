import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { fetchPoints, type Point } from './api';
import MapView from './Map';

const DEVICE_ID_STORAGE_KEY = 'device_id';
const THEME_STORAGE_KEY = 'theme';

type Theme = 'light' | 'dark' | 'system';

function readStoredTheme(): Theme {
  try {
    const v = localStorage.getItem(THEME_STORAGE_KEY);
    if (v === 'dark' || v === 'light' || v === 'system') return v;
  } catch {
    /* storage disabled */
  }
  return 'system';
}

function resolveIsDark(theme: Theme): boolean {
  if (theme === 'dark') return true;
  if (theme === 'light') return false;
  return matchMedia('(prefers-color-scheme: dark)').matches;
}

function useTheme(): [Theme, (t: Theme) => void] {
  const [theme, setThemeState] = useState<Theme>(() => readStoredTheme());

  useEffect(() => {
    const root = document.documentElement;
    const apply = () => {
      const dark = resolveIsDark(theme);
      if (dark) {
        root.classList.add('dark');
      } else {
        root.classList.remove('dark');
      }
    };
    apply();
    const mq = matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => { if (theme === 'system') apply(); };
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, [theme]);

  const setTheme = useCallback((t: Theme) => {
    try { localStorage.setItem(THEME_STORAGE_KEY, t); } catch { /* ignore */ }
    setThemeState(t);
  }, []);

  return [theme, setTheme];
}

function ThemeToggle({
  theme,
  setTheme,
}: {
  theme: Theme;
  setTheme: (t: Theme) => void;
}) {
  return (
    <div className="panel__theme-toggle" role="radiogroup" aria-label="Color theme">
      <button
        className={`panel__theme-btn${theme === 'light' ? ' panel__theme-btn--active' : ''}`}
        onClick={() => setTheme('light')}
        aria-label="Light theme"
        role="radio"
        aria-checked={theme === 'light'}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <circle cx="8" cy="8" r="3.5" stroke="currentColor" strokeWidth="1.5" />
          <path d="M8 1v1.5M8 13.5V15M1 8h1.5M13.5 8H15M3.05 3.05l1.06 1.06M11.89 11.89l1.06 1.06M3.05 12.95l1.06-1.06M11.89 4.11l1.06-1.06" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        </svg>
      </button>
      <button
        className={`panel__theme-btn${theme === 'dark' ? ' panel__theme-btn--active' : ''}`}
        onClick={() => setTheme('dark')}
        aria-label="Dark theme"
        role="radio"
        aria-checked={theme === 'dark'}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path d="M13.5 9.5a6 6 0 0 1-7-7A6 6 0 1 0 13.5 9.5z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
        </svg>
      </button>
      <button
        className={`panel__theme-btn${theme === 'system' ? ' panel__theme-btn--active' : ''}`}
        onClick={() => setTheme('system')}
        aria-label="System theme"
        role="radio"
        aria-checked={theme === 'system'}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <rect x="1" y="2" width="14" height="10" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
          <path d="M5 14h6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          <path d="M8 12v2" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          <circle cx="8" cy="7" r="1.5" stroke="currentColor" strokeWidth="1.2" />
        </svg>
      </button>
    </div>
  );
}

function toLocalInputValue(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// Local-midnight of "now" — used as the default `from` so reopening the
// page lands on "everything since the day started" rather than a rolling
// 24 h window that drifts across midnight.
function startOfTodayLocal(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
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
  const [theme, setTheme] = useTheme();
  // Defaults fall back to "today since local midnight". URL params
  // (if valid) override on first render so reloads / shared links
  // hydrate the same range the previous session was looking at.
  const initialFrom = useMemo(
    () => readUrlDate('from') ?? startOfTodayLocal(),
    [],
  );
  const initialTo = useMemo(() => readUrlDate('to') ?? new Date(), []);
  // `defaultFrom`/`defaultTo` are the always-fresh values used by Logout to
  // reset the range to "today since 00:00" rather than to whatever URL the
  // session was loaded with.
  const defaultFrom = useMemo(() => startOfTodayLocal(), []);
  const defaultTo = useMemo(() => new Date(), []);

  const [deviceId, setDeviceId] = useState<string>(() => readStoredDeviceId());
  const [from, setFrom] = useState(toLocalInputValue(initialFrom));
  const [to, setTo] = useState(toLocalInputValue(initialTo));
  const [points, setPoints] = useState<Point[]>([]);
  const [sampled, setSampled] = useState(false);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hasQueried, setHasQueried] = useState(false);
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

  // Mirror the date range into the URL so the page is reloadable /
  // shareable. `replaceState` keeps the browser history clean — every
  // keystroke in the datetime-local inputs would otherwise push a new
  // entry. Invalid `Date` values (shouldn't happen via the input, but
  // defensively) skip the write instead of throwing.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    try {
      const params = new URLSearchParams(window.location.search);
      const fromDate = new Date(from);
      const toDate = new Date(to);
      if (Number.isNaN(fromDate.getTime()) || Number.isNaN(toDate.getTime())) return;
      params.set('from', fromDate.toISOString());
      params.set('to', toDate.toISOString());
      const qs = params.toString();
      const next = `${window.location.pathname}${qs ? `?${qs}` : ''}${window.location.hash}`;
      window.history.replaceState(null, '', next);
    } catch {
      /* non-browser or locked history API — non-fatal */
    }
  }, [from, to]);

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
    setHasQueried(true);
    try {
      const result = await fetchPoints(deviceId, new Date(from), new Date(to), ac.signal);
      const safe = Array.isArray(result?.data) ? result.data : [];
      setPoints(safe);
      setSampled(result?.sampled === true);
      setTotal(Number.isFinite(result?.total) ? result.total : safe.length);
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') return;
      setError(e instanceof Error ? e.message : String(e));
      setPoints([]);
      setSampled(false);
      setTotal(0);
    } finally {
      setLoading(false);
    }
  }, [deviceId, from, to]);

  // Auto-fetch on first mount when a device_id was already in storage,
  // so a page reload behaves like the user re-clicked Visualize. Gated
  // on the *initial* deviceId only — typing the ID after landing on a
  // logged-out page still waits for an explicit Visualize click.
  useEffect(() => {
    if (!deviceId) return;
    void onVisualize();
    // Mount-only: re-running on deviceId / onVisualize changes would
    // reintroduce the auto-fetch-on-typing behavior we explicitly
    // exclude above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const onLogout = useCallback(() => {
    setDeviceId('');
    setPoints([]);
    setError(null);
    setHasQueried(false);
    setSampled(false);
    setTotal(0);
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

  const pointsLabel = sampled
    ? `${points.length.toLocaleString()} of ${total.toLocaleString()} points (downsampled — narrow the range for full detail)`
    : `${points.length.toLocaleString()} points`;

  const status = error
    ? error
    : loading
      ? 'Loading…'
      : points.length > 0
        ? pointsLabel
        : hasQueried
          ? 'No points found for this time range'
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
        <ThemeToggle theme={theme} setTheme={setTheme} />
      </div>
      <MapView points={points} />
    </div>
  );
}
