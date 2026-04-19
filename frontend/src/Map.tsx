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

// Make trackpad / wheel zoom snap to integer steps, matching the feel of
// a double-tap (+1/-1). `zoomSnap` stays fractional for slider smoothness
// so we can't fix this globally; instead we patch Leaflet's internal
// `_performZoom` for the scroll-wheel handler to ignore softplus math and
// snap straight to ±1 per debounced burst. Stable in Leaflet 1.9.x.
function SnappyWheelZoom() {
  const map = useMap();
  useEffect(() => {
    const wheel = (
      map as unknown as {
        scrollWheelZoom?: {
          _performZoom?: () => void;
          _delta?: number;
          _lastMousePos?: L.Point;
          _startTime?: number | null;
        };
      }
    ).scrollWheelZoom;
    const orig = wheel?._performZoom;
    if (!wheel || !orig) return;
    wheel._performZoom = function (this: {
      _delta?: number;
      _lastMousePos?: L.Point;
      _startTime?: number | null;
    }) {
      const delta = this._delta ?? 0;
      this._delta = 0;
      this._startTime = null;
      if (!delta) return;
      const dir: 1 | -1 = delta > 0 ? 1 : -1;
      const target = map.getZoom() + dir;
      if (this._lastMousePos) {
        map.setZoomAround(this._lastMousePos, target);
      } else {
        map.setZoom(target);
      }
    };
    return () => {
      wheel._performZoom = orig;
    };
  }, [map]);
  return null;
}

// Clamp zoom-out so the world fully covers the container on both axes —
// no empty margin, no horizontal tile wrapping. At zoom `z` the Web
// Mercator world is `256 * 2^z` px on each side, so the minimum zoom
// that fills the container is `log2(max(W, H) / 256)`.
//
// We deliberately do NOT use `setMaxBounds` here. Bound clamping forces
// Leaflet to pan the center after zoom-out so the view fits inside the
// bounds, which in turn drifts the center (e.g. Valencia sliding off
// screen after zoom-out → zoom-in). `noWrap` on the tile layer already
// prevents horizontal repetition, so we can just rely on the min-zoom
// floor to stop the user from zooming out past a useful point.
function WorldMinZoom() {
  const map = useMap();
  useEffect(() => {
    const apply = () => {
      const size = map.getSize();
      if (size.x <= 0 || size.y <= 0) return;
      const minZoom = Math.max(
        0,
        Math.log2(Math.max(size.x, size.y) / 256),
      );
      map.setMinZoom(minZoom);
      if (map.getZoom() < minZoom) {
        map.setZoom(minZoom, { animate: false });
      }
    };
    apply();
    map.on('resize', apply);
    return () => {
      map.off('resize', apply);
    };
  }, [map]);
  return null;
}

// Capture the Leaflet `Map` instance into a ref owned by the parent and
// publish it via state so siblings (e.g. `RouteMinimap`) can render against
// the same instance. The ref covers synchronous callbacks; the state covers
// React subtrees that need to re-render once the map is ready.
function MapRefCapture({
  mapRef,
  onReady,
}: {
  mapRef: React.MutableRefObject<L.Map | null>;
  onReady?: (map: L.Map) => void;
}) {
  const map = useMap();
  useEffect(() => {
    mapRef.current = map;
    onReady?.(map);
    return () => {
      mapRef.current = null;
    };
  }, [map, mapRef, onReady]);
  return null;
}

// --------------------------------------------------------------------------
// Route minimap — Google-Photos-style overview with a draggable viewport
// handle and a horizontal zoom slider. By default the minimap is fitted
// to the full route bounds, so the clear rectangle shows what fraction
// of the route is in the main viewport (everything outside is a soft
// sea-tinted matte). If the main map is zoomed out past the route, the
// minimap expands to contain `route ∪ main-bounds`, so the rectangle
// stays symmetric and the matte reads correctly on both sides.
//
// Interactions: drag the rectangle to pan the main map; click elsewhere
// on the thumb to recenter the main map there; drag/click the zoom
// slider or ± buttons to change the main map's zoom.
// --------------------------------------------------------------------------

const MINIMAP_MAX_ZOOM = 16;

function MinimapBootstrap({ onReady }: { onReady: () => void }) {
  const map = useMap();
  useEffect(() => {
    // Leaflet measures the container on construction; the minimap DOM is
    // sized by CSS, so a manual invalidate guarantees correct projection
    // math the first time we compute the rect.
    requestAnimationFrame(() => {
      map.invalidateSize();
      onReady();
    });
  }, [map, onReady]);
  return null;
}

function MinimapRefCapture({ onReady }: { onReady: (map: L.Map) => void }) {
  const map = useMap();
  useEffect(() => {
    onReady(map);
  }, [map, onReady]);
  return null;
}

type Rect = { left: number; top: number; width: number; height: number };

function RouteMinimap({
  points,
  mainMap,
}: {
  points: Point[];
  mainMap: L.Map | null;
}) {
  const [mini, setMini] = useState<L.Map | null>(null);
  const [miniReady, setMiniReady] = useState(false);
  const [rect, setRect] = useState<Rect | null>(null);
  const [zoomFrac, setZoomFrac] = useState(0);
  const containerRef = useRef<HTMLDivElement | null>(null);
  // When the user is dragging the viewport handle or scrubbing the zoom
  // slider, pan/zoom events fire rapidly on the main map. Each one would
  // normally trigger a `mini.fitBounds(...)` refit, which shifts the
  // minimap's projection under the cursor mid-drag — pixel→latlng math
  // computed off the new projection produces the "drunken" wander the
  // user reported. We pause refits during interactions and fire one
  // final refit on pointer-up.
  const isDraggingRef = useRef(false);

  // Track the main map's zoom fraction in [0..1] so the slider handle
  // position mirrors the current zoom. Updates on `zoom` (live during
  // animation) and `zoomend` (final snap).
  useEffect(() => {
    if (!mainMap) return;
    const update = () => {
      const z = mainMap.getZoom();
      const minZ = mainMap.getMinZoom();
      const maxZ = mainMap.getMaxZoom();
      const span = maxZ - minZ;
      setZoomFrac(span > 0 ? Math.max(0, Math.min(1, (z - minZ) / span)) : 0);
    };
    update();
    mainMap.on('zoom zoomend', update);
    return () => {
      mainMap.off('zoom zoomend', update);
    };
  }, [mainMap]);

  const positions = useMemo(
    () =>
      points.map((p) => [p.latitude, p.longitude] as [number, number]),
    [points],
  );

  const routeBounds = useMemo<L.LatLngBounds | null>(
    () => (positions.length > 0 ? L.latLngBounds(positions) : null),
    [positions],
  );

  const refit = useCallback(() => {
    if (!mini || !mainMap || !miniReady || !routeBounds) return;
    if (isDraggingRef.current) return;
    const mainBounds = mainMap.getBounds();
    let target = routeBounds;
    if (!routeBounds.contains(mainBounds)) {
      const expanded = L.latLngBounds(
        routeBounds.getSouthWest(),
        routeBounds.getNorthEast(),
      );
      expanded.extend(mainBounds);
      target = expanded;
    }
    mini.fitBounds(target, { padding: [6, 6], animate: false });
  }, [mini, mainMap, miniReady, routeBounds]);

  // Keep the minimap's view wide enough to always contain the main map's
  // current viewport. Default is the route bounds; if the main map is
  // zoomed out past the route, the minimap expands to the union so the
  // viewport rectangle (and its matte) stays symmetric and never gets
  // clipped against a minimap edge.
  useEffect(() => {
    if (!mainMap) return;
    refit();
    mainMap.on('moveend zoomend', refit);
    return () => {
      mainMap.off('moveend zoomend', refit);
    };
  }, [mainMap, refit]);

  // Keep the viewport rect in sync with the main map. `move` (fires during
  // pan) + `zoom` (fires during zoom) + `resize` (window resize) cover the
  // live cases; `moveend`/`zoomend` are belt-and-suspenders for when a
  // programmatic setView bypasses the continuous events.
  //
  // The rect is clamped to the minimap's container bounds so it never
  // escapes the thumb area when the main map is zoomed out past the route.
  useEffect(() => {
    if (!mini || !mainMap || !miniReady) return;
    const update = () => {
      const b = mainMap.getBounds();
      const nw = mini.latLngToContainerPoint(b.getNorthWest());
      const se = mini.latLngToContainerPoint(b.getSouthEast());
      const size = mini.getSize();
      const left = Math.max(0, Math.min(size.x, nw.x));
      const top = Math.max(0, Math.min(size.y, nw.y));
      const right = Math.max(left, Math.min(size.x, se.x));
      const bottom = Math.max(top, Math.min(size.y, se.y));
      setRect({
        left,
        top,
        width: Math.max(6, right - left),
        height: Math.max(6, bottom - top),
      });
    };
    update();
    mainMap.on('move zoom moveend zoomend resize', update);
    mini.on('move zoom moveend zoomend resize', update);
    return () => {
      mainMap.off('move zoom moveend zoomend resize', update);
      mini.off('move zoom moveend zoomend resize', update);
    };
  }, [mini, mainMap, miniReady, positions]);

  const onViewportPointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if (!mini || !mainMap) return;
      e.preventDefault();
      e.stopPropagation();

      const startX = e.clientX;
      const startY = e.clientY;
      const startCenterPx = mini.latLngToContainerPoint(mainMap.getCenter());
      isDraggingRef.current = true;

      const onMove = (me: PointerEvent) => {
        const dx = me.clientX - startX;
        const dy = me.clientY - startY;
        const newPt = L.point(startCenterPx.x + dx, startCenterPx.y + dy);
        mainMap.panTo(mini.containerPointToLatLng(newPt), {
          animate: false,
        });
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        window.removeEventListener('pointercancel', onUp);
        isDraggingRef.current = false;
        refit();
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
      window.addEventListener('pointercancel', onUp);
    },
    [mini, mainMap, refit],
  );

  const onBackgroundClick = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      if (!mini || !mainMap) return;
      const box = containerRef.current?.getBoundingClientRect();
      if (!box) return;
      const pt = L.point(e.clientX - box.left, e.clientY - box.top);
      mainMap.panTo(mini.containerPointToLatLng(pt));
    },
    [mini, mainMap],
  );

  // Zoom slider: pointerdown anywhere on the track sets the zoom to the
  // fraction at that x, and subsequent moves continue to track the cursor.
  // The track captures pointer events on the handle too (handle is
  // pointer-events: none) so we never race between "click track" and
  // "drag handle" logic.
  const onZoomTrackPointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if (!mainMap) return;
      e.preventDefault();
      e.stopPropagation();
      const track = e.currentTarget;
      const trackRect = track.getBoundingClientRect();
      if (trackRect.width <= 0) return;
      const minZ = mainMap.getMinZoom();
      const maxZ = mainMap.getMaxZoom();
      const span = maxZ - minZ;
      isDraggingRef.current = true;

      const applyFromClientX = (clientX: number) => {
        const x = Math.max(0, Math.min(trackRect.width, clientX - trackRect.left));
        const frac = x / trackRect.width;
        mainMap.setZoom(minZ + frac * span, { animate: false });
      };
      applyFromClientX(e.clientX);

      const onMove = (me: PointerEvent) => applyFromClientX(me.clientX);
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        window.removeEventListener('pointercancel', onUp);
        isDraggingRef.current = false;
        refit();
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
      window.addEventListener('pointercancel', onUp);
    },
    [mainMap, refit],
  );

  if (positions.length === 0) return null;

  return (
    <div className="route-minimap">
      <div
        className="route-minimap__thumb"
        ref={containerRef}
        onClick={onBackgroundClick}
      >
        <MapContainer
          className="route-minimap__map"
          center={[0, 0]}
          zoom={2}
          maxZoom={MINIMAP_MAX_ZOOM}
          zoomControl={false}
          attributionControl={false}
          dragging={false}
          scrollWheelZoom={false}
          doubleClickZoom={false}
          boxZoom={false}
          keyboard={false}
          touchZoom={false}
        >
          <TileLayer
            url="https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
            subdomains="abcd"
            maxZoom={MINIMAP_MAX_ZOOM}
          />
          <Polyline
            positions={positions}
            pathOptions={{
              color: ROUTE_COLOR,
              weight: 2,
              opacity: 0.95,
              lineCap: 'round',
              lineJoin: 'round',
            }}
            interactive={false}
          />
          <MinimapBootstrap onReady={() => setMiniReady(true)} />
          <MinimapRefCapture onReady={setMini} />
        </MapContainer>
        {rect && (
          <>
            {/* Four-sided matte darkens everything outside the viewport
                rectangle, so the minimap visually emphasizes the portion
                of the route that's currently rendered on the main map. */}
            <div
              className="route-minimap__matte"
              style={{ left: 0, top: 0, right: 0, height: rect.top }}
            />
            <div
              className="route-minimap__matte"
              style={{
                left: 0,
                top: rect.top + rect.height,
                right: 0,
                bottom: 0,
              }}
            />
            <div
              className="route-minimap__matte"
              style={{
                left: 0,
                top: rect.top,
                width: rect.left,
                height: rect.height,
              }}
            />
            <div
              className="route-minimap__matte"
              style={{
                left: rect.left + rect.width,
                top: rect.top,
                right: 0,
                height: rect.height,
              }}
            />
            <div
              className="route-minimap__viewport"
              style={{
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
              }}
              onClick={(e) => e.stopPropagation()}
              onPointerDown={onViewportPointerDown}
            />
          </>
        )}
      </div>
      <div className="route-minimap__zoom-bar">
        <button
          type="button"
          className="route-minimap__zoom-btn"
          onClick={() => mainMap?.zoomOut(1, { animate: true })}
          aria-label="Zoom out"
        >
          −
        </button>
        <div
          className="route-minimap__zoom-track"
          onPointerDown={onZoomTrackPointerDown}
        >
          <div
            className="route-minimap__zoom-handle"
            style={{
              left: `calc(18px + ${zoomFrac} * (100% - 36px))`,
            }}
          />
        </div>
        <button
          type="button"
          className="route-minimap__zoom-btn"
          onClick={() => mainMap?.zoomIn(1, { animate: true })}
          aria-label="Zoom in"
        >
          +
        </button>
      </div>
    </div>
  );
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
  const [mainMap, setMainMap] = useState<L.Map | null>(null);

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
        zoomControl={false}
        zoomSnap={0.25}
        scrollWheelZoom
        attributionControl
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/attributions">CARTO</a>'
          url="https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png"
          subdomains="abcd"
          maxZoom={MAX_ZOOM}
          noWrap
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

        <WorldMinZoom />
        <SnappyWheelZoom />
        <FitBounds points={sampled} />
        <MapRefCapture mapRef={mapRef} onReady={setMainMap} />
      </MapContainer>

      <RouteMinimap points={sampled} mainMap={mainMap} />

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
