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
  DEFAULT_IDLE_ROOM_TIMEOUT_MS,
  PROTOCOL_VERSION,
  MAX_ROOM_CODE_LEN,
} = require('./relay');

const pkg = require('../package.json');

// 构建信息：CI 用 build-arg 注入；本地直接跑就是 unknown（日志字段始终存在，便于解析）。
const GIT_COMMIT = process.env.GIT_COMMIT || 'unknown';
const BUILD_TIME = process.env.BUILD_TIME || 'unknown';

// 版本唯一真源是 package.json；这里只做出口，不再硬编码任何版本号。
if (process.argv.includes('--version')) {
  process.stdout.write(`${pkg.version}\n`);
  process.exit(0);
}

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
// 房间无人（零连接）多久回收；1 分钟内回来沿用原房间。
const IDLE_ROOM_TIMEOUT_MS = intFromEnv(
  'IDLE_ROOM_TIMEOUT_MS',
  DEFAULT_IDLE_ROOM_TIMEOUT_MS,
  { min: 100 },
);
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';

const log = createLogger(LOG_LEVEL);
const relay = new RelayServer({
  roomLimit: ROOM_LIMIT,
  offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
  maxClients: MAX_CLIENTS,
  idleTimeoutMs: IDLE_ROOM_TIMEOUT_MS,
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
      commit: GIT_COMMIT,
      buildTime: BUILD_TIME,
      protocol: PROTOCOL_VERSION,
      ...stats,
      config: {
        roomLimit: ROOM_LIMIT,
        offlineTimeoutMs: OFFLINE_TIMEOUT_MS,
        maxClients: MAX_CLIENTS,
        idleRoomTimeoutMs: IDLE_ROOM_TIMEOUT_MS,
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
    trackLink(ws);
    relay.handleConnection(ws, room);
  });
});

// WebSocket 级保活：应用层 ping/pong 之外，再用协议层 ping 清理半死连接。
//
// 这里是"客户端看到 1006 + initiator=remote"最可能的来源之一，所以每条连接都留
// 证据：上一轮 ping 有没有回 pong、最近一次 pong 距今多久、RTT 多少。客户端那边
// 只能看到"对端关了、之前 4~5 秒没入站"，对不上是谁下手；服务端这条能直接定死。
// 保活间隔（毫秒）。默认 30s 不变，抽成环境变量只为让回归测试能在 1 秒内跑完。
const KEEPALIVE_MS = intFromEnv('WS_KEEPALIVE_MS', 30000, { min: 100 });
/** @type {WeakMap<import('ws').WebSocket, {alive:boolean, lastPongAt:number, pingSentAt:number, rttMs:number|null}>} */
const links = new WeakMap();

/**
 * 每条连接都要登记：`wss.on('connection')` 在 `noServer: true` + 手动 handleUpgrade
 * 的用法下**不会触发**（这里从来没人 emit 过 connection），保活和 RTT 只能挂在这里。
 */
function trackLink(ws) {
  const link = { alive: true, lastPongAt: Date.now(), pingSentAt: 0, rttMs: null };
  links.set(ws, link);
  ws.on('pong', () => {
    link.alive = true;
    link.lastPongAt = Date.now();
    if (link.pingSentAt > 0) {
      link.rttMs = link.lastPongAt - link.pingSentAt;
      // 断开日志要能带上最近一次 RTT，跨模块共享只能挂在 socket 上。
      ws.lastPingRttMs = link.rttMs;
    }
  });
}
const keepalive = setInterval(() => {
  for (const ws of wss.clients) {
    const link = links.get(ws);
    if (!link) {
      trackLink(ws);
      continue;
    }
    if (link.alive === false) {
      // 上一轮 ping 没回 pong：半死连接。terminate 会让客户端看到 1006 + remote。
      ws.closedBy = 'keepalive_terminate';
      log.warn('keepalive_terminate', {
        clients: wss.clients.size,
        silentMs: Date.now() - link.lastPongAt,
        lastPingRttMs: link.rttMs,
        pingIntervalMs: KEEPALIVE_MS,
      });
      ws.terminate();
      continue;
    }
    link.alive = false;
    link.pingSentAt = Date.now();
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
    commit: GIT_COMMIT,
    buildTime: BUILD_TIME,
  });
});

function shutdown(signal) {
  log.info('shutting_down', { signal });
  clearInterval(keepalive);
  if (relay.snapshotTimer) clearInterval(relay.snapshotTimer);
  for (const ws of wss.clients) {
    try {
      ws.closedBy = 'shutdown';
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
