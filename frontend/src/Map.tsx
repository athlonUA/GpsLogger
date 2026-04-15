import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  CircleMarker,
  MapContainer,
  Polyline,
  TileLayer,
  useMap,
} from 'react-leaflet';
import L from 'leaflet';
import type { Point } from './api';

const MAX_POINTS = 4000;
const GRADIENT_CHUNKS = 64;
const MAX_ZOOM = 20;

function downsample(points: Point[]): Point[] {
  if (points.length <= MAX_POINTS) return points;
  const step = Math.ceil(points.length / MAX_POINTS);
  const out: Point[] = [];
  for (let i = 0; i < points.length; i += step) out.push(points[i]);
  const last = points[points.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

// Blue (240°) → Purple (285°) → Red (360°) with purple exactly at t=0.5.
function gradientColor(t: number): string {
  const h =
    t < 0.5
      ? 240 + (285 - 240) * (t / 0.5)
      : 285 + (360 - 285) * ((t - 0.5) / 0.5);
  return `hsl(${h.toFixed(1)}, 78%, 58%)`;
}

type Segment = { positions: [number, number][]; color: string };

function buildSegments(points: Point[]): Segment[] {
  const n = points.length;
  if (n < 2) return [];
  const chunks = Math.min(GRADIENT_CHUNKS, n - 1);
  const segs: Segment[] = [];
  for (let c = 0; c < chunks; c++) {
    const start = Math.floor((c * (n - 1)) / chunks);
    const end = Math.floor(((c + 1) * (n - 1)) / chunks) + 1;
    const positions = points
      .slice(start, end)
      .map((p) => [p.latitude, p.longitude] as [number, number]);
    const t = chunks === 1 ? 0 : c / (chunks - 1);
    segs.push({ positions, color: gradientColor(t) });
  }
  return segs;
}

function findNearestPoint(points: Point[], lat: number, lng: number): Point | null {
  if (points.length === 0) return null;
  let best = points[0];
  let bestDist = Infinity;
  for (const p of points) {
    const dLat = p.latitude - lat;
    const dLng = p.longitude - lng;
    const d = dLat * dLat + dLng * dLng;
    if (d < bestDist) {
      bestDist = d;
      best = p;
    }
  }
  return best;
}

function FitBounds({ points }: { points: Point[] }) {
  const map = useMap();
  useEffect(() => {
    if (points.length === 0) return;
    const bounds = L.latLngBounds(
      points.map((p) => [p.latitude, p.longitude] as [number, number]),
    );
    map.fitBounds(bounds, { padding: [60, 60], maxZoom: 17 });
  }, [points, map]);
  return null;
}

// --------------------------------------------------------------------------
// Local time formatting (browser timezone, no UTC display)
// --------------------------------------------------------------------------

// en-GB keeps the output unambiguous ("01 Jun 2025, 03:14:22") regardless of
// the user's chosen UI locale. Conversion to local wall-clock time is still
// automatic because Intl.DateTimeFormat defaults to the runtime's timezone.
const LOCAL_FORMATTER = new Intl.DateTimeFormat('en-GB', {
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false,
});

const LOCAL_TIMEZONE = Intl.DateTimeFormat().resolvedOptions().timeZone;

function formatLocal(iso: string): { localTime: string; timezone: string } {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) {
    return { localTime: '—', timezone: LOCAL_TIMEZONE };
  }
  return {
    localTime: LOCAL_FORMATTER.format(d),
    timezone: LOCAL_TIMEZONE,
  };
}

// --------------------------------------------------------------------------
// Reverse geocoding (Nominatim, on-demand, no mass lookups)
// --------------------------------------------------------------------------

type AddressState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'ok'; value: string }
  | { status: 'error'; error: string };

async function reverseGeocode(lat: number, lng: number, signal: AbortSignal): Promise<string> {
  const url = new URL('https://nominatim.openstreetmap.org/reverse');
  url.searchParams.set('format', 'jsonv2');
  url.searchParams.set('lat', String(lat));
  url.searchParams.set('lon', String(lng));
  url.searchParams.set('zoom', '18');
  url.searchParams.set('addressdetails', '1');

  const res = await fetch(url, { signal, headers: { Accept: 'application/json' } });
  if (!res.ok) throw new Error(`Nominatim HTTP ${res.status}`);
  const data = await res.json();
  const name =
    (typeof data?.display_name === 'string' && data.display_name) ||
    (typeof data?.name === 'string' && data.name) ||
    '';
  if (!name) throw new Error('No address found');
  return name;
}

// --------------------------------------------------------------------------
// Detail card
// --------------------------------------------------------------------------

type CopyTarget = 'coords' | 'address';

function DetailCard({
  lat,
  lng,
  createdAt,
  address,
  onClose,
}: {
  lat: number;
  lng: number;
  createdAt: string;
  address: AddressState;
  onClose: () => void;
}) {
  const coordsText = `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
  const { localTime, timezone } = useMemo(() => formatLocal(createdAt), [createdAt]);
  const [copied, setCopied] = useState<CopyTarget | null>(null);

  const copy = useCallback(async (text: string, which: CopyTarget) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(which);
      window.setTimeout(() => setCopied(null), 1200);
    } catch {
      /* clipboard denied — nothing to do */
    }
  }, []);

  return (
    <div className="point-card" role="dialog" aria-label="Selected point">
      <button className="point-card__close" onClick={onClose} aria-label="Close">
        ×
      </button>

      <div className="point-card__label">Coordinates</div>
      <div className="point-card__row">
        <code className="point-card__coords">{coordsText}</code>
        <button
          className="point-card__copy"
          onClick={() => copy(coordsText, 'coords')}
          disabled={copied === 'coords'}
        >
          {copied === 'coords' ? 'Copied' : 'Copy'}
        </button>
      </div>

      <div className="point-card__label">Address</div>
      <div className="point-card__address">
        {address.status === 'loading' && (
          <span className="point-card__muted">Looking up…</span>
        )}
        {address.status === 'error' && (
          <span className="point-card__error">{address.error}</span>
        )}
        {address.status === 'ok' && <span>{address.value}</span>}
        {address.status === 'idle' && (
          <span className="point-card__muted">—</span>
        )}
      </div>

      {address.status === 'ok' && (
        <div className="point-card__actions">
          <button
            className="point-card__copy"
            onClick={() => copy(address.value, 'address')}
            disabled={copied === 'address'}
          >
            {copied === 'address' ? 'Copied' : 'Copy address'}
          </button>
        </div>
      )}

      <div className="point-card__label">Local time</div>
      <div className="point-card__time">{localTime}</div>

      <div className="point-card__label">Time zone</div>
      <div className="point-card__timezone">{timezone}</div>
    </div>
  );
}

// --------------------------------------------------------------------------
// Map
// --------------------------------------------------------------------------

export default function MapView({ points }: { points: Point[] }) {
  const sampled = useMemo(() => downsample(points), [points]);
  const segments = useMemo(() => buildSegments(sampled), [sampled]);

  const haloPositions = useMemo(
    () =>
      sampled.map(
        (p) => [p.latitude, p.longitude] as [number, number],
      ),
    [sampled],
  );

  const [selected, setSelected] = useState<
    { lat: number; lng: number; createdAt: string } | null
  >(null);
  const [address, setAddress] = useState<AddressState>({ status: 'idle' });

  // Client-side cache of address lookups for the current session. Keeps repeat
  // clicks free and avoids hammering Nominatim (which has a 1 req/sec policy).
  const cacheRef = useRef(new Map<string, string>());
  const requestIdRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);

  // Reset selection when the underlying points change (new query).
  useEffect(() => {
    setSelected(null);
    setAddress({ status: 'idle' });
    abortRef.current?.abort();
  }, [points]);

  const selectPoint = useCallback((point: Point) => {
    const id = ++requestIdRef.current;
    const lat = point.latitude;
    const lng = point.longitude;
    setSelected({ lat, lng, createdAt: point.created_at });

    const key = `${lat.toFixed(6)},${lng.toFixed(6)}`;
    const cached = cacheRef.current.get(key);
    if (cached) {
      setAddress({ status: 'ok', value: cached });
      return;
    }

    abortRef.current?.abort();
    const ctrl = new AbortController();
    abortRef.current = ctrl;

    setAddress({ status: 'loading' });
    reverseGeocode(lat, lng, ctrl.signal)
      .then((value) => {
        if (requestIdRef.current !== id) return;
        cacheRef.current.set(key, value);
        setAddress({ status: 'ok', value });
      })
      .catch((err: unknown) => {
        if (requestIdRef.current !== id) return;
        if (err instanceof DOMException && err.name === 'AbortError') return;
        const message = err instanceof Error ? err.message : 'lookup failed';
        setAddress({ status: 'error', error: message });
      });
  }, []);

  const handleRouteClick = useCallback(
    (e: L.LeafletMouseEvent) => {
      const nearest = findNearestPoint(sampled, e.latlng.lat, e.latlng.lng);
      if (nearest) selectPoint(nearest);
    },
    [sampled, selectPoint],
  );

  const hasRoute = sampled.length >= 2;
  const first = hasRoute ? sampled[0] : null;
  const last = hasRoute ? sampled[sampled.length - 1] : null;

  return (
    <div className="map-wrapper">
      <MapContainer
        className="map"
        center={[20, 0]}
        zoom={2}
        maxZoom={MAX_ZOOM}
        zoomControl={true}
        scrollWheelZoom
        attributionControl
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/attributions">CARTO</a>'
          url="https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
          subdomains="abcd"
          maxZoom={MAX_ZOOM}
        />

        {hasRoute && (
          <Polyline
            positions={haloPositions}
            pathOptions={{
              color: '#0f172a',
              weight: 10,
              opacity: 0.12,
              lineCap: 'round',
              lineJoin: 'round',
            }}
            eventHandlers={{ click: handleRouteClick }}
          />
        )}

        {segments.map((s, i) => (
          <Polyline
            key={i}
            positions={s.positions}
            pathOptions={{
              color: s.color,
              weight: 5,
              opacity: 0.95,
              lineCap: 'round',
              lineJoin: 'round',
            }}
            eventHandlers={{ click: handleRouteClick }}
          />
        ))}

        {first && (
          <CircleMarker
            center={[first.latitude, first.longitude]}
            radius={7}
            pathOptions={{
              color: 'hsl(240, 78%, 58%)',
              fillColor: '#ffffff',
              fillOpacity: 1,
              weight: 3,
            }}
            eventHandlers={{
              click: () => selectPoint(first),
            }}
          />
        )}

        {last && (
          <CircleMarker
            center={[last.latitude, last.longitude]}
            radius={7}
            pathOptions={{
              color: 'hsl(360, 78%, 58%)',
              fillColor: '#ffffff',
              fillOpacity: 1,
              weight: 3,
            }}
            eventHandlers={{
              click: () => selectPoint(last),
            }}
          />
        )}

        {selected && (
          <CircleMarker
            center={[selected.lat, selected.lng]}
            radius={11}
            pathOptions={{
              color: '#0f172a',
              fillOpacity: 0,
              weight: 2,
              dashArray: '3 3',
            }}
            interactive={false}
          />
        )}

        <FitBounds points={sampled} />
      </MapContainer>

      {selected && (
        <DetailCard
          lat={selected.lat}
          lng={selected.lng}
          createdAt={selected.createdAt}
          address={address}
          onClose={() => {
            abortRef.current?.abort();
            setSelected(null);
            setAddress({ status: 'idle' });
          }}
        />
      )}
    </div>
  );
}
