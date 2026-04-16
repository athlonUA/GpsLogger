import pino from 'pino';

// Shared structured logger. JSON output (pino's default) is greppable,
// machine-parseable, and cheap. Log level is env-driven so production can
// run at `info` while local debugging flips to `debug` without a rebuild.
//
// `base: null` suppresses the default `pid` / `hostname` fields. Docker
// Compose already captures container identity, and the pid is ephemeral
// per container restart; dropping them keeps each log line compact.
export const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: null,
  timestamp: pino.stdTimeFunctions.isoTime,
});
