import express from 'express';
import cors from 'cors';
import { migrate, pool } from './db.js';
import pointsRouter from './routes/points.js';
import diagnosticsRouter from './routes/diagnostics.js';

const app = express();

app.use(cors());
app.use(express.json({ limit: '4mb' }));

app.use((req, _res, next) => {
  console.log(`${new Date().toISOString()} ${req.method} ${req.url}`);
  next();
});

// Optional bearer-token auth for write endpoints. When API_KEY is set,
// POST /points and POST /diagnostics require `Authorization: Bearer <key>`.
// GET /health and GET /points are unprotected so the frontend and Docker
// healthcheck keep working without a token.
const apiKey = process.env.API_KEY || '';
if (apiKey) {
  app.use('/points', (req, res, next) => {
    if (req.method !== 'POST') return next();
    const auth = req.headers.authorization || '';
    if (auth === `Bearer ${apiKey}`) return next();
    res.status(401).json({ error: 'unauthorized' });
  });
  app.use('/diagnostics', (req, res, next) => {
    if (req.method !== 'POST') return next();
    const auth = req.headers.authorization || '';
    if (auth === `Bearer ${apiKey}`) return next();
    res.status(401).json({ error: 'unauthorized' });
  });
  console.log('[auth] API_KEY is set — POST endpoints require Bearer token');
}

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true });
  } catch {
    res.status(503).json({ ok: false, error: 'database unreachable' });
  }
});

app.use('/points', pointsRouter);
app.use('/diagnostics', diagnosticsRouter);

app.use((err, _req, res, _next) => {
  console.error('[error]', err);
  res.status(500).json({ error: 'internal_error' });
});

const port = Number(process.env.PORT || 3000);

async function main() {
  await migrate();
  app.listen(port, () => {
    console.log(`[api] listening on :${port}`);
  });
}

main().catch((err) => {
  console.error('[fatal]', err);
  process.exit(1);
});
