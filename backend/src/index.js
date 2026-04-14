import express from 'express';
import cors from 'cors';
import { migrate } from './db.js';
import pointsRouter from './routes/points.js';

const app = express();

app.use(cors());
app.use(express.json({ limit: '2mb' }));

app.use((req, _res, next) => {
  console.log(`${new Date().toISOString()} ${req.method} ${req.url}`);
  next();
});

app.get('/health', (_req, res) => res.json({ ok: true }));

app.use('/points', pointsRouter);

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
