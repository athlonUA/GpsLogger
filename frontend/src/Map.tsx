import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  CircleMarker,
  MapContainer,
  Marker,
  Polyline,
  TileLayer,
  Tooltip,
  useMap,
} from 'react-leaflet';
import L from 'leaflet';
import type { Point } from './api';
import { arrowsAlong, buildRenderData, ROUTE_COLOR } from './route';

const MAX_ZOOM = 20;

// Snap distance in screen pixels. Converting through `latLngToContainerPoint`
// makes the threshold zoom-invariant: 30 px is 30 px on the user's screen
// whether they're looking at a continent (zoom 3) or a street (zoom 18).
const MAX_CLICK_DIST_PX = 30;
const MAX_CLICK_DIST_PX_SQ = MAX_CLICK_DIST_PX * MAX_CLICK_DIST_PX;

type Nearest = { point: Point; index: number } | null;

function findNearestPoint(
  points: Point[],
  map: L.Map,
  clickLat: number,
  clickLng: number,
): Nearest {
  if (points.length === 0) return null;
  const clickPt = map.latLngToContainerPoint([clickLat, clickLng]);
  let bestIdx = 0;
  let bestDistSq = Infinity;
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    const pt = map.latLngToContainerPoint([p.latitude, p.longitude]);
    const dx = pt.x - clickPt.x;
    const dy = pt.y - clickPt.y;
    const d = dx * dx + dy * dy;
    if (d < bestDistSq) {
      bestDistSq = d;
      bestIdx = i;
    }
  }
  if (bestDistSq > MAX_CLICK_DIST_PX_SQ) return null;
  return { point: points[bestIdx], index: bestIdx };
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

// Capture the Leaflet `Map` instance into a ref owned by the parent so
// the click handler (which lives outside the MapContainer subtree) can
// call `latLngToContainerPoint` for pixel-space snap math.
function MapRefCapture({ mapRef }: { mapRef: React.MutableRefObject<L.Map | null> }) {
  const map = useMap();
  useEffect(() => {
    mapRef.current = map;
    return () => {
      mapRef.current = null;
    };
  }, [map, mapRef]);
  return null;
}

// --------------------------------------------------------------------------
// Local time formatting (browser timezone, no UTC display)
// --------------------------------------------------------------------------

// en-GB keeps the output unambiguous ("01 Jun 2025, 03:14:22") regardless
// of the user's chosen UI locale. Conversion to local wall-clock time is
// automatic because Intl.DateTimeFormat defaults to the runtime's tz.
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

/// Format cumulative distance for the detail card. Below 1 km render as
/// whole meters; at or above, render kilometers with one decimal. Matches
/// the level of precision a user actually cares about — sub-meter output
/// would be fake precision given GPS noise.
function formatDistance(meters: number): string {
  if (!Number.isFinite(meters) || meters < 0) return '—';
  if (meters < 1000) return `${Math.round(meters)} m from start`;
  return `${(meters / 1000).toFixed(1)} km from start`;
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
  distanceMeters,
  address,
  onClose,
}: {
  lat: number;
  lng: number;
  createdAt: string;
  distanceMeters: number;
  address: AddressState;
  onClose: () => void;
}) {
  const coordsText = `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
  const { localTime, timezone } = useMemo(() => formatLocal(createdAt), [createdAt]);
  const distanceText = useMemo(() => formatDistance(distanceMeters), [distanceMeters]);
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

      <div className="point-card__label">Distance</div>
      <div className="point-card__distance">{distanceText}</div>

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
  const render = useMemo(() => buildRenderData(points), [points]);
  const { groups, sampled, distancesMeters, segments, singletons } = render;

  // One halo polyline per group — keeps the subtle shadow under the route
  // but honors the same time-gap breaks so it does not bridge
  // disconnected sessions.
  const haloGroups = useMemo(
    () =>
      groups
        .filter((g) => g.length >= 2)
        .map((g) =>
          g.map((p) => [p.latitude, p.longitude] as [number, number]),
        ),
    [groups],
  );

  // Direction-of-travel arrows along each polyline group, computed in
  // meters along the geodesic so spacing is zoom-invariant.
  const directionArrows = useMemo(() => {
    const out: {
      key: string;
      latitude: number;
      longitude: number;
      bearing: number;
    }[] = [];
    groups.forEach((group, gi) => {
      if (group.length < 2) return;
      const positions = group.map((p) => ({
        latitude: p.latitude,
        longitude: p.longitude,
      }));
      arrowsAlong(positions).forEach((a, ai) => {
        out.push({ key: `arrow-${gi}-${ai}`, ...a });
      });
    });
    return out;
  }, [groups]);

  // DivIcon factories. `L.divIcon` must be called after Leaflet has
  // finished loading, so they live inside `useMemo` rather than module
  // scope. The Start / End icons are static (no state).
  const startIcon = useMemo(
    () =>
      L.divIcon({
        className: 'endpoint-marker',
        html: '<div class="endpoint-pin endpoint-pin--start">S</div>',
        iconSize: [28, 28],
        iconAnchor: [14, 14],
      }),
    [],
  );
  const endIcon = useMemo(
    () =>
      L.divIcon({
        className: 'endpoint-marker',
        html: '<div class="endpoint-pin endpoint-pin--end">E</div>',
        iconSize: [28, 28],
        iconAnchor: [14, 14],
      }),
    [],
  );

  const [selected, setSelected] = useState<
    { lat: number; lng: number; createdAt: string; distanceMeters: number } | null
  >(null);
  const [address, setAddress] = useState<AddressState>({ status: 'idle' });

  // Client-side cache of address lookups for the current session. Keeps
  // repeat clicks free and avoids hammering Nominatim (1 req/sec policy).
  const cacheRef = useRef(new Map<string, string>());
  const requestIdRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);
  const mapRef = useRef<L.Map | null>(null);

  // Reset selection when the underlying points change (new query).
  useEffect(() => {
    setSelected(null);
    setAddress({ status: 'idle' });
    abortRef.current?.abort();
  }, [points]);

  const selectPoint = useCallback(
    (point: Point, distanceMeters: number) => {
      const id = ++requestIdRef.current;
      const lat = point.latitude;
      const lng = point.longitude;
      setSelected({ lat, lng, createdAt: point.created_at, distanceMeters });

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
    },
    [],
  );

  // Helper: snap a sampled index to its cumulative distance, falling
  // back to 0 if the parallel arrays ever drift out of alignment (they
  // shouldn't — `buildRenderData` guarantees it — but cheap insurance).
  const distanceAt = useCallback(
    (index: number) => distancesMeters[index] ?? 0,
    [distancesMeters],
  );

  const handleRouteClick = useCallback(
    (e: L.LeafletMouseEvent) => {
      const map = mapRef.current;
      if (!map) return;
      const nearest = findNearestPoint(sampled, map, e.latlng.lat, e.latlng.lng);
      if (nearest) selectPoint(nearest.point, distanceAt(nearest.index));
    },
    [sampled, selectPoint, distanceAt],
  );

  // Start/end markers anchor the polyline endpoints, not any isolated
  // singleton fix. Deriving them from the first/last polyline group
  // prevents the white-filled endpoint ring from drawing over a
  // singleton CircleMarker that happens to sit at position 0 or
  // length-1 of `sampled`.
  const firstInfo = useMemo(() => {
    let flatIndex = 0;
    for (const g of groups) {
      if (g.length >= 2) return { point: g[0], index: flatIndex };
      flatIndex += g.length;
    }
    return null;
  }, [groups]);
  const lastInfo = useMemo(() => {
    let flatIndex = 0;
    let result: { point: Point; index: number } | null = null;
    for (const g of groups) {
      if (g.length >= 2) {
        result = { point: g[g.length - 1], index: flatIndex + g.length - 1 };
      }
      flatIndex += g.length;
    }
    return result;
  }, [groups]);

  // Pre-compute the flat index of each singleton so clicks can look up
  // its cumulative distance without another pass.
  const singletonIndices = useMemo(() => {
    const out: number[] = [];
    let flatIndex = 0;
    for (const g of groups) {
      if (g.length === 1) out.push(flatIndex);
      flatIndex += g.length;
    }
    return out;
  }, [groups]);

  return (
    <div className="map-wrapper">
      <MapContainer
        className="map"
        center={[20, 0]}
        zoom={2}
        maxZoom={MAX_ZOOM}
        zoomControl={true}
        zoomSnap={0.25}
        zoomDelta={0.25}
        wheelPxPerZoomLevel={120}
        scrollWheelZoom
        attributionControl
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/attributions">CARTO</a>'
          url="https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
          subdomains="abcd"
          maxZoom={MAX_ZOOM}
        />

        {haloGroups.map((positions, i) => (
          <Polyline
            key={`halo-${i}`}
            positions={positions}
            pathOptions={{
              color: '#0f172a',
              weight: 10,
              opacity: 0.12,
              lineCap: 'round',
              lineJoin: 'round',
            }}
            eventHandlers={{ click: handleRouteClick }}
          />
        ))}

        {segments.map((s, i) => (
          <Polyline
            key={i}
            positions={s.positions}
            pathOptions={{
              color: ROUTE_COLOR,
              weight: 5,
              opacity: 0.95,
              lineCap: 'round',
              lineJoin: 'round',
            }}
            eventHandlers={{ click: handleRouteClick }}
          />
        ))}

        {/* Isolated fixes — groups of a single point after gap-split.
            Rendered on their own so the on-map count matches the status
            bar. */}
        {singletons.map((s, i) => {
          const flatIndex = singletonIndices[i] ?? 0;
          return (
            <CircleMarker
              key={`singleton-${i}`}
              center={[s.point.latitude, s.point.longitude]}
              radius={5}
              pathOptions={{
                color: ROUTE_COLOR,
                fillColor: ROUTE_COLOR,
                fillOpacity: 0.9,
                weight: 2,
              }}
              eventHandlers={{
                click: () => selectPoint(s.point, distanceAt(flatIndex)),
              }}
            />
          );
        })}

        {/* Direction-of-travel arrows along each polyline group. */}
        {directionArrows.map((a) => (
          <Marker
            key={a.key}
            position={[a.latitude, a.longitude]}
            icon={L.divIcon({
              className: 'direction-arrow',
              html: `<span class="direction-arrow__inner" style="transform: rotate(${a.bearing}deg)">
                <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
                  <polygon points="6,1 11,11 6,8.5 1,11" />
                </svg>
              </span>`,
              iconSize: [12, 12],
              iconAnchor: [6, 6],
            })}
            interactive={false}
          />
        ))}

        {firstInfo && (
          <Marker
            position={[firstInfo.point.latitude, firstInfo.point.longitude]}
            icon={startIcon}
            eventHandlers={{
              click: () => selectPoint(firstInfo.point, distanceAt(firstInfo.index)),
            }}
            zIndexOffset={1000}
          >
            <Tooltip direction="top" offset={[0, -14]} opacity={0.95}>
              Start
            </Tooltip>
          </Marker>
        )}

        {lastInfo && (
          <Marker
            position={[lastInfo.point.latitude, lastInfo.point.longitude]}
            icon={endIcon}
            eventHandlers={{
              click: () => selectPoint(lastInfo.point, distanceAt(lastInfo.index)),
            }}
            zIndexOffset={1000}
          >
            <Tooltip direction="top" offset={[0, -14]} opacity={0.95}>
              End
            </Tooltip>
          </Marker>
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
        <MapRefCapture mapRef={mapRef} />
      </MapContainer>

      {selected && (
        <DetailCard
          lat={selected.lat}
          lng={selected.lng}
          createdAt={selected.createdAt}
          distanceMeters={selected.distanceMeters}
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
