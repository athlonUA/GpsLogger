import express from 'express';
import cors from 'cors';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { migrate, pool } from './db.js';
import { logger } from './log.js';
import pointsRouter from './routes/points.js';
import diagnosticsRouter from './routes/diagnostics.js';

const app = express();

app.use(cors());
app.use(express.json({ limit: '4mb' }));

// Request logging + correlation ID. Inbound `X-Request-ID` is honored if
// present so upstream proxies (or the iOS client, in the future) can
// stitch traces across hops; otherwise we mint a fresh UUID v4. The id is
// echoed on the response so clients can quote it in bug reports, and
// attached to `req.log` as a pino child logger so every downstream log
// line carries it without thread-local plumbing.
app.use((req, res, next) => {
  const id = req.get('X-Request-ID') || randomUUID();
  res.setHeader('X-Request-ID', id);
  req.log = logger.child({ reqId: id });
  req.log.info({ method: req.method, url: req.url }, 'request');
  next();
});

// Timing-safe string compare for the Bearer token. `crypto.timingSafeEqual`
// requires equal-length inputs; we short-circuit on length mismatch, which
// leaks only the length — fixed by our API-key policy anyway and not a
// useful signal for an attacker. Avoids leaking the key prefix through the
// response-time side channel that a plain `===` comparison produces.
function safeEqualStr(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

// Optional bearer-token auth for write endpoints. When API_KEY is set,
// POST /points and POST /diagnostics require `Authorization: Bearer <key>`.
// GET /health and GET /points are unprotected so the frontend and Docker
// healthcheck keep working without a token. Middleware factored to a
// single function so a future auth-scheme change has exactly one edit site.
const apiKey = process.env.API_KEY || '';
if (apiKey) {
  const expected = `Bearer ${apiKey}`;
  const requireBearer = (req, res, next) => {
    if (req.method !== 'POST') return next();
    const auth = req.headers.authorization || '';
    if (safeEqualStr(auth, expected)) return next();
    req.log.warn('unauthorized');
    res.status(401).json({ error: 'unauthorized' });
  };
  app.use('/points', requireBearer);
  app.use('/diagnostics', requireBearer);
  logger.info('API_KEY set — POST endpoints require Bearer token');
}

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true });
  } catch (err) {
    req.log.error({ err }, 'health: db unreachable');
    res.status(503).json({ ok: false, error: 'database unreachable' });
  }
});

app.use('/points', pointsRouter);
app.use('/diagnostics', diagnosticsRouter);

app.use((err, req, res, _next) => {
  (req.log || logger).error({ err }, 'internal error');
  res.status(500).json({ error: 'internal_error' });
});

const port = Number(process.env.PORT || 3000);

// Graceful shutdown window. Docker sends SIGKILL 10 s after SIGTERM by
// default, so we aim to finish in 8 s to leave a safety margin.
const SHUTDOWN_GRACE_MS = 8_000;

async function main() {
  await migrate();
  const server = app.listen(port, () => {
    logger.info({ port }, 'api listening');
  });

  // Graceful shutdown: stop accepting new connections, drain the pg pool,
  // then exit. Without this, in-flight INSERTs can be killed mid-statement
  // when Docker sends SIGTERM; idempotency saves the data but the client
  // sees an unnecessary error and backs off. SIGINT is handled for the
  // same reasons under local `node src/index.js`.
  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info({ signal }, 'shutdown: closing server');
    // Hard deadline fallback: if server.close() or pool.end() hangs
    // (stuck connection, misbehaving client), bail before Docker kills us.
    const killer = setTimeout(() => {
      logger.error('shutdown: grace window elapsed — forcing exit');
      process.exit(1);
    }, SHUTDOWN_GRACE_MS);
    killer.unref();

    server.close(async (err) => {
      if (err) logger.error({ err }, 'shutdown: server.close failed');
      try {
        await pool.end();
        logger.info('shutdown: pool drained');
      } catch (e) {
        logger.error({ err: e }, 'shutdown: pool.end failed');
      }
      process.exit(err ? 1 : 0);
    });
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  logger.fatal({ err }, 'startup failed');
  process.exit(1);
});
