import { useEffect, useMemo } from 'react';
import { MapContainer, TileLayer, Polyline, useMap } from 'react-leaflet';
import L from 'leaflet';
import type { Point } from './api';

const MAX_POINTS = 4000;
const GRADIENT_CHUNKS = 64;

function downsample(points: Point[]): Point[] {
  if (points.length <= MAX_POINTS) return points;
  const step = Math.ceil(points.length / MAX_POINTS);
  const out: Point[] = [];
  for (let i = 0; i < points.length; i += step) out.push(points[i]);
  const last = points[points.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

function gradientColor(t: number): string {
  // HSL interpolation blue (240) -> red (0) via green/yellow for a smoother perceptual gradient.
  const h = Math.round(240 - 240 * t);
  return `hsl(${h}, 85%, 50%)`;
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

function FitBounds({ points }: { points: Point[] }) {
  const map = useMap();
  useEffect(() => {
    if (points.length === 0) return;
    const bounds = L.latLngBounds(
      points.map((p) => [p.latitude, p.longitude] as [number, number]),
    );
    map.fitBounds(bounds, { padding: [40, 40], maxZoom: 17 });
  }, [points, map]);
  return null;
}

export default function MapView({ points }: { points: Point[] }) {
  const sampled = useMemo(() => downsample(points), [points]);
  const segments = useMemo(() => buildSegments(sampled), [sampled]);

  return (
    <MapContainer className="map" center={[20, 0]} zoom={2} scrollWheelZoom>
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      {segments.map((s, i) => (
        <Polyline
          key={i}
          positions={s.positions}
          pathOptions={{ color: s.color, weight: 4, opacity: 0.9 }}
        />
      ))}
      <FitBounds points={sampled} />
    </MapContainer>
  );
}
