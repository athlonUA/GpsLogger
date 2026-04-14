export interface Point {
  id: number;
  latitude: number;
  longitude: number;
  created_at: string;
}

const BASE = import.meta.env.VITE_API_URL ?? 'http://localhost:3000';

export async function fetchPoints(from: Date, to: Date): Promise<Point[]> {
  const url = new URL('/points', BASE);
  url.searchParams.set('from', from.toISOString());
  url.searchParams.set('to', to.toISOString());

  const res = await fetch(url);
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`GET /points failed: ${res.status} ${body}`);
  }
  return res.json();
}
