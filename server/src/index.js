'use strict';

/**
 * 入口：HTTP 服务 + WebSocket 升级 + 健康检查 + 优雅退出。
 * 配置全部来自环境变量，便于 docker / docker-compose / systemd 注入。
 */

const http = require('node:http');
const { WebSocketServer } = require('ws');
const {
  RelayServer,
  createLogger,
  WS_PATH,
  DEFAULT_ROOM_LIMIT,
  DEFAULT_OFFLINE_TIMEOUT_MS,
  DEFAULT_MAX_CLIENTS,
  PROTOCOL_VERSION,
  MAX_ROOM_CODE_LEN,
} = require('./relay');

const pkg = require('../package.json');

function intFromEnv(name, fallback, { min = 0 } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < min) {
    // 配置错误要吵，不要静默降级成默认值。
    throw new Error(`${name} must be an integer >= ${min}, got ${JSON.stringify(raw)}`);
  }
  return parsed;
}

const HOST = process.env.HOST || '0.0.0.0';
// min=0 允许 PORT=0：交给内核分配空闲端口（测试与临时调试用）
const PORT = intFromEnv('PORT', 8765, { min: 0 });
const ROOM_LIMIT = intFromEnv('ROOM_LIMIT', DEFAULT_ROOM_LIMIT, { min: 1 });
const OFFLINE_TIMEOUT_MS = intFromEnv('OFFLINE_TIMEOUT_MS', DEFAULT_OFFLINE_TIMEOUT_MS, { min: 100 });
const MAX_CLIENTS = intFromEnv('MAX_CLIENTS', DEFAULT_MAX_CLIENTS, { min: 1 });
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';

const log = createLogger(LOG_LEVEL);
const relay = new RelayServer({
  roomLimit: ROOM_LIMIT,
  offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
  maxClients: MAX_CLIENTS,
  logLevel: LOG_LEVEL,
});

const ROOM_CODE_RE = /^[A-Za-z0-9_-]{1,64}$/;

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'cache-control': 'no-store',
  });
  res.end(text);
}

const httpServer = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && url.pathname === '/healthz') {
    const stats = relay.stats();
    sendJson(res, 200, {
      status: 'ok',
      version: pkg.version,
      protocol: PROTOCOL_VERSION,
      ...stats,
      config: {
        roomLimit: ROOM_LIMIT,
        offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
        maxClients: MAX_CLIENTS,
      },
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/') {
    // 便于人肉确认"服务活着"，不暴露内部状态。
    sendJson(res, 200, {
      service: 'heart-rate-share-relay',
      version: pkg.version,
      websocket: `${WS_PATH}?room=<房间短码>`,
      health: '/healthz',
    });
    return;
  }

  sendJson(res, 404, { error: 'not found' });
});

const wss = new WebSocketServer({ noServer: true });

httpServer.on('upgrade', (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  } catch {
    socket.destroy();
    return;
  }
  if (url.pathname !== WS_PATH) {
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  const room = url.searchParams.get('room');
  if (!room || room.length > MAX_ROOM_CODE_LEN || !ROOM_CODE_RE.test(room)) {
    socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    socket.destroy();
    log.warn('bad_room_code', { room: room || '' });
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    relay.handleConnection(ws, room);
  });
});

// WebSocket 级保活：应用层 ping/pong 之外，再用协议层 ping 清理半死连接。
const KEEPALIVE_MS = 30000;
const alive = new WeakMap();
wss.on('connection', (ws) => {
  alive.set(ws, true);
  ws.on('pong', () => alive.set(ws, true));
});
const keepalive = setInterval(() => {
  for (const ws of wss.clients) {
    if (alive.get(ws) === false) {
      ws.terminate();
      continue;
    }
    alive.set(ws, false);
    try {
      ws.ping();
    } catch {
      /* ignore */
    }
  }
}, KEEPALIVE_MS);
if (typeof keepalive.unref === 'function') keepalive.unref();

relay.startTimers();

httpServer.listen(PORT, HOST, () => {
  const bound = httpServer.address();
  log.info('relay_started', {
    host: HOST,
    // 打印实际绑定端口：PORT=0（测试用）时才知道随机分到哪个端口
    port: bound && typeof bound === 'object' ? bound.port : PORT,
    roomLimit: ROOM_LIMIT,
    offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
    maxClients: MAX_CLIENTS,
    protocol: PROTOCOL_VERSION,
    version: pkg.version,
  });
});

function shutdown(signal) {
  log.info('shutting_down', { signal });
  clearInterval(keepalive);
  if (relay.snapshotTimer) clearInterval(relay.snapshotTimer);
  for (const ws of wss.clients) {
    try {
      ws.close(1001, 'server shutting down');
    } catch {
      /* ignore */
    }
  }
  httpServer.close(() => process.exit(0));
  // 兜底：5 秒内没关干净就强退，避免容器僵死。
  setTimeout(() => process.exit(0), 5000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = { httpServer, relay };
