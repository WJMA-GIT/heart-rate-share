'use strict';

/**
 * 协议回归测试：直接走真实 WebSocket，不 mock。
 * 时钟用注入的假时钟推进，因此"5 秒判离线 / 2 分钟移除"不需要真等。
 *
 * 运行：npm test
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const { WebSocketServer, WebSocket } = require('ws');

const { RelayServer } = require('../src/relay');

const TICK_MS = 20;

function waitFor(fn, timeoutMs = 3000, label = 'condition') {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const timer = setInterval(() => {
      if (fn()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() - started > timeoutMs) {
        clearInterval(timer);
        reject(new Error(`timeout waiting for ${label}`));
      }
    }, TICK_MS);
  });
}

/** 起一个测试用服务端：假时钟 + 随机端口。 */
async function startServer(opts = {}) {
  let now = opts.startTime ?? Date.now();
  const relay = new RelayServer({
    roomLimit: opts.roomLimit ?? 20,
    offlineTimeoutMs: opts.offlineTimeoutMs ?? 5000,
    maxClients: opts.maxClients ?? 200,
    logLevel: 'error',
    clock: () => now,
  });

  const httpServer = http.createServer((req, res) => {
    if (req.url === '/healthz') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', ...relay.stats() }));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  const wss = new WebSocketServer({ noServer: true });
  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    wss.handleUpgrade(req, socket, head, (ws) => {
      relay.handleConnection(ws, url.searchParams.get('room') || 'ROOM01');
    });
  });

  await new Promise((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
  const port = httpServer.address().port;

  return {
    relay,
    port,
    advance(ms) {
      now += ms;
    },
    tick() {
      relay.manualTick();
    },
    async close() {
      for (const client of wss.clients) client.terminate();
      await new Promise((resolve) => httpServer.close(resolve));
    },
  };
}

/** 客户端桩：记录所有收到的消息，便于断言。 */
function connect(port, room = 'ROOM01') {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?room=${room}`);
  const messages = [];
  ws.on('message', (raw) => {
    messages.push(JSON.parse(raw.toString('utf8')));
  });
  const opened = new Promise((resolve, reject) => {
    ws.on('open', resolve);
    ws.on('error', reject);
  });
  return {
    ws,
    messages,
    opened,
    send(obj) {
      ws.send(JSON.stringify(obj));
    },
    of(type) {
      return messages.filter((m) => m.type === type);
    },
    last(type) {
      const list = messages.filter((m) => m.type === type);
      return list[list.length - 1];
    },
    close() {
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    },
  };
}

function hello(client, memberId, displayName) {
  client.send({ v: 1, type: 'hello', memberId, displayName });
}

function report(client, memberId, displayName, bpm, sequence, extra = {}) {
  client.send({
    v: 1,
    type: 'heartRate',
    memberId,
    displayName,
    bpm,
    rrMs: [800, 810],
    sensorContact: true,
    sequence,
    measuredAt: new Date().toISOString(),
    ...extra,
  });
}

test('hello 收到 welcome', async () => {
  const srv = await startServer();
  const c = connect(srv.port);
  await c.opened;
  hello(c, 'm1', '张三');
  await waitFor(() => c.of('welcome').length === 1, 2000, 'welcome');
  assert.equal(c.of('welcome')[0].v, 1);
  c.close();
  await srv.close();
});

test('两个客户端上报后互相收到 memberDelta，快照含两人且按姓名字典序', async () => {
  const srv = await startServer();
  const a = connect(srv.port);
  const b = connect(srv.port);
  await Promise.all([a.opened, b.opened]);

  hello(a, 'ma', '张三');
  hello(b, 'mb', '李四');
  await waitFor(() => a.of('welcome').length === 1 && b.of('welcome').length === 1);

  report(a, 'ma', '张三', 72, 1);
  await waitFor(() => a.of('memberDelta').length >= 1 && b.of('memberDelta').length >= 1, 2000, 'delta a');
  assert.equal(a.last('memberDelta').member.bpm, 72);
  assert.equal(b.last('memberDelta').member.memberId, 'ma');

  report(b, 'mb', '李四', 88, 1);
  await waitFor(() => a.of('memberDelta').length >= 2, 2000, 'delta b');

  srv.tick();
  await waitFor(() => a.of('snapshot').length >= 1, 2000, 'snapshot');
  const snap = a.last('snapshot');
  assert.equal(snap.members.length, 2);
  assert.deepEqual(
    snap.members.map((m) => m.displayName),
    ['张三', '李四'].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)),
  );
  // 成员对象必须带 lastSeen 与 online，客户端解析依赖这两个字段
  for (const m of snap.members) {
    assert.ok(m.lastSeen, 'lastSeen 必填');
    assert.equal(typeof m.online, 'boolean');
    assert.ok(Array.isArray(m.rrMs));
  }

  a.close();
  b.close();
  await srv.close();
});

test('旧包（sequence 不递增）被丢弃，不产生 memberDelta', async () => {
  const srv = await startServer();
  const c = connect(srv.port);
  await c.opened;
  hello(c, 'm1', '张三');
  await waitFor(() => c.of('welcome').length === 1);

  report(c, 'm1', '张三', 70, 5);
  await waitFor(() => c.of('memberDelta').length === 1);

  report(c, 'm1', '张三', 60, 3); // 旧包
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(c.of('memberDelta').length, 1, '旧包不应广播');

  report(c, 'm1', '张三', 75, 6);
  await waitFor(() => c.of('memberDelta').length === 2);
  assert.equal(c.last('memberDelta').member.bpm, 75);

  c.close();
  await srv.close();
});

test('5 秒无上报判离线，2 分钟移除', async () => {
  const srv = await startServer({ offlineTimeoutMs: 5000 });
  const watcher = connect(srv.port);
  const member = connect(srv.port);
  await Promise.all([watcher.opened, member.opened]);
  hello(watcher, 'mw', '观察者');
  hello(member, 'mm', '张三');
  await waitFor(() => watcher.of('welcome').length === 1 && member.of('welcome').length === 1);

  report(member, 'mm', '张三', 70, 1);
  await waitFor(() => watcher.last('memberDelta')?.member?.online === true);

  // 4.9 秒：仍然在线
  srv.advance(4900);
  srv.tick();
  await new Promise((r) => setTimeout(r, 100));
  const onlineBefore = watcher.messages
    .filter((m) => m.type === 'memberDelta' && m.member.memberId === 'mm')
    .map((m) => m.member.online);
  assert.equal(onlineBefore.every((v) => v === true), true, '5 秒内不应离线');

  // 5 秒：翻成离线
  srv.advance(200);
  srv.tick();
  await waitFor(
    () => watcher.last('memberDelta')?.member?.online === false,
    2000,
    'offline delta',
  );

  // 2 分钟：从成员表移除
  srv.advance(120000);
  srv.tick();
  await new Promise((r) => setTimeout(r, 100));
  const snap = watcher.last('snapshot');
  assert.equal(
    snap.members.filter((m) => m.memberId === 'mm').length,
    0,
    'mm 应已被移除',
  );

  watcher.close();
  member.close();
  await srv.close();
});

test('协议版本不符 / 客户端发送服务端类型 → BAD_MESSAGE', async () => {
  const srv = await startServer();
  const c = connect(srv.port);
  await c.opened;
  hello(c, 'm1', '张三');
  await waitFor(() => c.of('welcome').length === 1);

  c.send({ v: 2, type: 'hello', memberId: 'm1', displayName: '张三' });
  await waitFor(() => c.of('error').some((e) => e.code === 'BAD_MESSAGE'), 2000, 'bad version');

  c.send({ v: 1, type: 'snapshot', members: [] });
  await waitFor(() => c.of('error').length >= 2, 2000, 'bad type');

  // 上报 memberId 与 hello 不一致
  report(c, 'other', '张三', 70, 1);
  await waitFor(() => c.of('error').length >= 3, 2000, 'member mismatch');

  c.close();
  await srv.close();
});

test('ping → pong', async () => {
  const srv = await startServer();
  const c = connect(srv.port);
  await c.opened;
  c.send({ v: 1, type: 'ping' });
  await waitFor(() => c.of('pong').length === 1, 2000, 'pong');
  c.close();
  await srv.close();
});

test('房间满员（ROOM_LIMIT=1）时新成员收到 ROOM_FULL 并被关闭', async () => {
  const srv = await startServer({ roomLimit: 1 });
  const a = connect(srv.port);
  const b = connect(srv.port);
  await Promise.all([a.opened, b.opened]);
  hello(a, 'ma', '张三');
  hello(b, 'mb', '李四');
  await waitFor(() => a.of('welcome').length === 1 && b.of('welcome').length === 1);

  report(a, 'ma', '张三', 70, 1);
  await waitFor(() => a.of('memberDelta').length === 1);

  const closed = new Promise((resolve) => b.ws.on('close', resolve));
  report(b, 'mb', '李四', 80, 1);
  await waitFor(() => b.of('error').some((e) => e.code === 'ROOM_FULL'), 2000, 'room full');
  await closed;

  a.close();
  await srv.close();
});

test('不同房间互不可见', async () => {
  const srv = await startServer();
  const r1 = connect(srv.port, 'ROOM01');
  const r2 = connect(srv.port, 'ROOM02');
  await Promise.all([r1.opened, r2.opened]);
  hello(r1, 'a1', '张三');
  hello(r2, 'b1', '李四');
  await waitFor(() => r1.of('welcome').length === 1 && r2.of('welcome').length === 1);

  report(r1, 'a1', '张三', 70, 1);
  await waitFor(() => r1.of('memberDelta').length === 1);
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(r2.of('memberDelta').length, 0, 'ROOM02 不应收到 ROOM01 的数据');

  r1.close();
  r2.close();
  await srv.close();
});

test('真实进程：/healthz 可用，PORT=0 时能读到实际端口', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'index.js')], {
    env: { ...process.env, PORT: '0', LOG_LEVEL: 'info' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let port = null;
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start in 5s')), 5000);
    child.stdout.on('data', (buf) => {
      for (const line of buf.toString('utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const parsed = JSON.parse(line);
          if (parsed.msg === 'relay_started' && parsed.port) {
            port = parsed.port;
            clearTimeout(timer);
            resolve();
          }
        } catch {
          /* 非 JSON 行忽略 */
        }
      }
    });
    child.on('exit', (code) => reject(new Error(`server exited early: ${code}`)));
  });

  try {
    await ready;
    const body = await new Promise((resolve, reject) => {
      const req = http.get(`http://127.0.0.1:${port}/healthz`, (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
      });
      req.on('error', reject);
    });
    assert.equal(body.status, 200);
    assert.equal(body.body.status, 'ok');
    assert.equal(body.body.protocol, 1);
    assert.equal(body.body.config.roomLimit, 20);
  } finally {
    child.kill('SIGTERM');
  }
});
