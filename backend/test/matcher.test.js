import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  splitByTimeGap,
  chunkBySize,
  buildMatchUrl,
  parseMatchResponse,
  matchTrace,
  TRIP_GAP_SECONDS,
  BATCH_SIZE,
  DEFAULT_RADIUS_METERS,
} from '../src/matcher.js';

/** Helper: build a points-shaped row with a time offset from a base ISO. */
function row(id, lat, lon, tSec, base = '2026-04-17T16:34:00Z') {
  const baseMs = new Date(base).getTime();
  return {
    id,
    latitude: lat,
    longitude: lon,
    created_at: new Date(baseMs + tSec * 1000).toISOString(),
  };
}

// ---- splitByTimeGap ----

test('splitByTimeGap: empty input returns empty array', () => {
  assert.deepEqual(splitByTimeGap([]), []);
  assert.deepEqual(splitByTimeGap(null), []);
});

test('splitByTimeGap: single point returns single segment', () => {
  const segs = splitByTimeGap([row(1, 0, 0, 0)]);
  assert.equal(segs.length, 1);
  assert.equal(segs[0].length, 1);
});

test('splitByTimeGap: continuous trace stays as one segment', () => {
  const pts = [];
  for (let i = 0; i < 10; i++) pts.push(row(i, 0, 0, i * 10));
  const segs = splitByTimeGap(pts);
  assert.equal(segs.length, 1);
  assert.equal(segs[0].length, 10);
});

test('splitByTimeGap: splits on gap larger than threshold', () => {
  // Two 5-point trips separated by a 10-minute gap (≫ 5 min threshold).
  const pts = [
    row(1, 0, 0, 0),
    row(2, 0, 0, 10),
    row(3, 0, 0, 20),
    row(4, 0, 0, 30),
    row(5, 0, 0, 40),
    row(6, 0, 0, 40 + 10 * 60),
    row(7, 0, 0, 40 + 10 * 60 + 10),
  ];
  const segs = splitByTimeGap(pts);
  assert.equal(segs.length, 2);
  assert.equal(segs[0].length, 5);
  assert.equal(segs[1].length, 2);
});

test('splitByTimeGap: gap exactly at threshold is NOT split (strict >)', () => {
  const pts = [row(1, 0, 0, 0), row(2, 0, 0, TRIP_GAP_SECONDS)];
  const segs = splitByTimeGap(pts);
  assert.equal(segs.length, 1);
});

// ---- chunkBySize ----

test('chunkBySize: smaller than size returns single chunk', () => {
  const seg = Array.from({ length: 30 }, (_, i) => row(i, 0, 0, i));
  assert.equal(chunkBySize(seg, BATCH_SIZE).length, 1);
});

test('chunkBySize: large segment splits with 1-point overlap', () => {
  // 150 points, BATCH_SIZE=100 → chunks of 100 and 51 with index 99 shared.
  const seg = Array.from({ length: 150 }, (_, i) => row(i, 0, 0, i));
  const chunks = chunkBySize(seg, 100);
  assert.equal(chunks.length, 2);
  assert.equal(chunks[0].length, 100);
  assert.equal(chunks[1].length, 51);
  assert.equal(chunks[0][99].id, chunks[1][0].id);
});

test('chunkBySize: drops tail chunks of length < 2', () => {
  const seg = Array.from({ length: 100 }, (_, i) => row(i, 0, 0, i));
  // 100 points, size 100 → one chunk exactly, no leftover 1-point tail.
  const chunks = chunkBySize(seg, 100);
  assert.equal(chunks.length, 1);
});

// ---- buildMatchUrl ----

test('buildMatchUrl: coordinates in lon,lat order separated by semicolons', () => {
  const url = buildMatchUrl('http://osrm:5000', [
    row(1, 39.48, -0.38, 0),
    row(2, 39.49, -0.37, 5),
  ]);
  // Substring checks avoid coupling to URLSearchParams key order.
  assert.match(url, /\/match\/v1\/foot\//);
  assert.match(url, /-0\.38,39\.48;-0\.37,39\.49/);
  assert.match(url, /radiuses=25;25/);
  assert.match(url, /geometries=geojson/);
  assert.match(url, /overview=full/);
});

test('buildMatchUrl: radius option overrides default', () => {
  const url = buildMatchUrl('http://osrm:5000', [row(1, 0, 0, 0), row(2, 0, 0, 5)], {
    radius: 40,
  });
  assert.match(url, /radiuses=40;40/);
});

test('buildMatchUrl: trims trailing slashes on base', () => {
  const url = buildMatchUrl('http://osrm:5000///', [row(1, 0, 0, 0), row(2, 0, 0, 5)]);
  assert.ok(!url.includes('5000////'));
  assert.match(url, /5000\/match/);
});

// ---- parseMatchResponse ----

test('parseMatchResponse: happy path snaps every point', () => {
  const batch = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const json = {
    code: 'Ok',
    tracepoints: [
      { location: [-0.381, 39.481] },
      { location: [-0.371, 39.491] },
    ],
  };
  const out = parseMatchResponse(json, batch);
  assert.equal(out.length, 2);
  assert.equal(out[0].matched, true);
  assert.equal(out[0].latitude, 39.481);
  assert.equal(out[0].longitude, -0.381);
  assert.equal(out[1].matched, true);
});

test('parseMatchResponse: null tracepoint falls back to raw', () => {
  const batch = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const json = {
    code: 'Ok',
    // OSRM returns null for samples it rejects as outliers.
    tracepoints: [{ location: [-0.381, 39.481] }, null],
  };
  const out = parseMatchResponse(json, batch);
  assert.equal(out[0].matched, true);
  assert.equal(out[1].matched, false);
  assert.equal(out[1].latitude, 39.49);
  assert.equal(out[1].longitude, -0.37);
});

test('parseMatchResponse: NoMatch overall response → all raw', () => {
  const batch = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const json = { code: 'NoMatch', message: 'Could not find matching.' };
  const out = parseMatchResponse(json, batch);
  assert.ok(out.every((p) => p.matched === false));
  assert.equal(out[0].latitude, 39.48);
});

test('parseMatchResponse: malformed JSON → all raw', () => {
  const batch = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  assert.ok(parseMatchResponse(null, batch).every((p) => p.matched === false));
  assert.ok(parseMatchResponse({}, batch).every((p) => p.matched === false));
  assert.ok(parseMatchResponse({ code: 'Ok' }, batch).every((p) => p.matched === false));
});

// ---- matchTrace (end-to-end via injected fetch) ----

test('matchTrace: empty input returns empty', async () => {
  const r = await matchTrace('http://osrm', []);
  assert.deepEqual(r, { points: [], matchedCount: 0, totalCount: 0 });
});

test('matchTrace: no OSRM_URL → raw echo, zero matches', async () => {
  const pts = [row(1, 0, 0, 0), row(2, 0, 0, 5)];
  const r = await matchTrace('', pts);
  assert.equal(r.matchedCount, 0);
  assert.equal(r.totalCount, 2);
  assert.ok(r.points.every((p) => p.matched === false));
});

test('matchTrace: happy path returns snapped coords and counts', async () => {
  const pts = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const fakeFetch = async () => ({
    ok: true,
    json: async () => ({
      code: 'Ok',
      tracepoints: [
        { location: [-0.381, 39.481] },
        { location: [-0.371, 39.491] },
      ],
    }),
  });
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch });
  assert.equal(r.totalCount, 2);
  assert.equal(r.matchedCount, 2);
  assert.equal(r.points[0].latitude, 39.481);
  assert.equal(r.points[1].latitude, 39.491);
});

test('matchTrace: HTTP error falls back to raw', async () => {
  const pts = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const fakeFetch = async () => ({ ok: false, json: async () => ({}) });
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch });
  assert.equal(r.matchedCount, 0);
  assert.equal(r.totalCount, 2);
  assert.ok(r.points.every((p) => p.matched === false));
  // And the raw coordinates survived intact.
  assert.equal(r.points[0].latitude, 39.48);
});

test('matchTrace: network error falls back to raw', async () => {
  const pts = [row(1, 39.48, -0.38, 0), row(2, 39.49, -0.37, 5)];
  const fakeFetch = async () => {
    throw new Error('ECONNREFUSED');
  };
  const logs = [];
  const log = { warn: (obj, msg) => logs.push({ obj, msg }) };
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch, log });
  assert.equal(r.matchedCount, 0);
  assert.equal(r.totalCount, 2);
  assert.equal(logs.length, 1);
  assert.match(logs[0].msg, /osrm match failed/);
});

test('matchTrace: splits a long trace across multiple requests', async () => {
  // 250 continuous points → 3 chunks (100 + 100 + 51 with 1-overlap).
  const pts = Array.from({ length: 250 }, (_, i) => row(i, 39.48, -0.38 + i * 1e-5, i));
  let callCount = 0;
  const fakeFetch = async (url) => {
    callCount++;
    // Parse the coords count to know how many tracepoints to emit.
    const coordStr = url.split('/match/v1/foot/')[1].split('?')[0];
    const n = coordStr.split(';').length;
    return {
      ok: true,
      json: async () => ({
        code: 'Ok',
        tracepoints: Array.from({ length: n }, () => ({ location: [-0.38, 39.48] })),
      }),
    };
  };
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch });
  assert.equal(callCount, 3);
  assert.equal(r.totalCount, 250);
  assert.equal(r.matchedCount, 250);
});

test('matchTrace: splits by time gap into separate OSRM calls', async () => {
  // Two trips separated by 10-min gap → two requests, one per trip.
  const pts = [
    row(1, 39.48, -0.38, 0),
    row(2, 39.48, -0.38, 10),
    row(3, 39.48, -0.38, 20),
    row(4, 39.50, -0.40, 20 + 10 * 60),
    row(5, 39.50, -0.40, 20 + 10 * 60 + 10),
  ];
  let callCount = 0;
  const fakeFetch = async (url) => {
    callCount++;
    const n = url.split('/match/v1/foot/')[1].split('?')[0].split(';').length;
    return {
      ok: true,
      json: async () => ({
        code: 'Ok',
        tracepoints: Array.from({ length: n }, (_, i) => ({ location: [-0.38, 39.48 + i * 1e-5] })),
      }),
    };
  };
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch });
  assert.equal(callCount, 2);
  assert.equal(r.totalCount, 5);
});

test('matchTrace: single-point segment bypasses OSRM and returns raw', async () => {
  // One isolated point surrounded by gaps — /match needs ≥ 2 inputs.
  const pts = [
    row(1, 39.48, -0.38, 0),
    row(2, 39.50, -0.40, 10 * 60),
    row(3, 39.50, -0.40, 10 * 60 + 10),
  ];
  let callCount = 0;
  const fakeFetch = async (url) => {
    callCount++;
    const n = url.split('/match/v1/foot/')[1].split('?')[0].split(';').length;
    return {
      ok: true,
      json: async () => ({
        code: 'Ok',
        tracepoints: Array.from({ length: n }, () => ({ location: [-0.40, 39.50] })),
      }),
    };
  };
  const r = await matchTrace('http://osrm', pts, { fetchImpl: fakeFetch });
  // One /match call for the 2-point second trip, zero for the singleton.
  assert.equal(callCount, 1);
  assert.equal(r.totalCount, 3);
  assert.equal(r.points[0].matched, false); // the isolated first point
  assert.equal(r.points[1].matched, true);
});

test('DEFAULT_RADIUS_METERS is a sane positive number', () => {
  // Sanity — if this ever ships as 0 or NaN the HMM degenerates.
  assert.ok(DEFAULT_RADIUS_METERS > 0 && DEFAULT_RADIUS_METERS < 200);
});
