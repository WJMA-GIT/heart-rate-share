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
    idleTimeoutMs: opts.idleTimeoutMs ?? 60000,
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

test('ping 的可选 displayName 更新已有成员昵称且不改其它字段', async () => {
  const srv = await startServer();
  const c = connect(srv.port);
  await c.opened;
  hello(c, 'm1', '张三');
  await waitFor(() => c.of('welcome').length === 1);
  report(c, 'm1', '张三', 72, 1);
  await waitFor(() => c.of('memberDelta').length === 1);

  c.send({ v: 1, type: 'ping', displayName: '新昵称' });
  await waitFor(
    () => c.of('memberDelta').some((d) => d.member.displayName === '新昵称'),
    2000,
    'rename delta',
  );
  const member = c.of('memberDelta').at(-1).member;
  assert.equal(member.bpm, 72);
  assert.equal(member.sequence, 1);
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

// ---------------------------------------------------------------- 身份恢复
// 客户端把"安装标识 + 上报序号"持久化后，重进房间必须复用同一个成员。
// 下面四个用例覆盖：不新增成员 / 旧连接被替换 / 序号必须连续 / 短暂重连不判离线。

test('同一 memberId 重连：旧连接以 4000 被替换，成员表不新增', async () => {
  const srv = await startServer();
  const first = connect(srv.port);
  await first.opened;
  hello(first, 'install-1', '张三');
  await waitFor(() => first.of('welcome').length === 1, 2000, 'welcome#1');
  report(first, 'install-1', '张三', 70, 1);
  await waitFor(() => first.of('memberDelta').length === 1, 2000, 'delta#1');

  const room = srv.relay.rooms.get('ROOM01');
  assert.equal(room.members.size, 1);

  // 模拟 App 重启后的新连接：同一个安装标识
  const closed = new Promise((resolve) => first.ws.on('close', (code) => resolve(code)));
  const second = connect(srv.port);
  await second.opened;
  hello(second, 'install-1', '张三');
  await waitFor(() => second.of('welcome').length === 1, 2000, 'welcome#2');

  assert.equal(await closed, 4000, '旧连接应以 4000 replaced 关闭');
  assert.equal(room.members.size, 1, '不得新增成员');
  assert.equal(room.sockets.size, 1, '同一成员只保留一条连接');
  assert.equal(room.sockets.get('install-1').readyState, 1);

  report(second, 'install-1', '张三', 72, 2);
  await waitFor(() => second.of('memberDelta').length >= 1, 2000, 'delta#2');
  const member = room.members.get('install-1');
  assert.equal(member.report.sequence, 2);
  assert.equal(member.report.bpm, 72);

  second.close();
  await srv.close();
});

test('重连保留昵称与序号：客户端重启若从 1 重新计数会被当旧包丢弃', async () => {
  const srv = await startServer();
  const first = connect(srv.port);
  await first.opened;
  hello(first, 'install-2', '张三');
  await waitFor(() => first.of('welcome').length === 1);
  report(first, 'install-2', '张三', 70, 10);
  await waitFor(() => first.of('memberDelta').length === 1);
  const room = srv.relay.rooms.get('ROOM01');
  first.close();
  await new Promise((r) => setTimeout(r, 50));

  const second = connect(srv.port);
  await second.opened;
  hello(second, 'install-2', '张三');
  await waitFor(() => second.of('welcome').length === 1);

  // 序号回退：必须被丢弃（这就是客户端要持久化序号的原因）
  report(second, 'install-2', '张三', 60, 5);
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(second.of('memberDelta').length, 0, '序号回退的旧包不得广播');
  assert.equal(room.members.get('install-2').report.sequence, 10);

  // 序号继续：正常广播，且昵称/心率沿用同一成员
  report(second, 'install-2', '李四', 75, 11);
  await waitFor(() => second.of('memberDelta').length === 1, 2000, 'delta');
  const member = room.members.get('install-2');
  assert.equal(member.report.sequence, 11);
  assert.equal(member.report.displayName, '李四');
  assert.equal(room.members.size, 1);

  second.close();
  await srv.close();
});

test('3 秒内重连不会被 5 秒判定打成离线再复活', async () => {
  const srv = await startServer({ offlineTimeoutMs: 5000 });
  const watcher = connect(srv.port);
  const member = connect(srv.port);
  await Promise.all([watcher.opened, member.opened]);
  hello(watcher, 'mw', '观察者');
  hello(member, 'mm', '张三');
  await waitFor(() => watcher.of('welcome').length === 1 && member.of('welcome').length === 1);

  report(member, 'mm', '张三', 70, 1);
  await waitFor(() => watcher.of('memberDelta').length === 1);

  member.close();
  srv.advance(3000);
  srv.tick();

  // 3 秒后回来：hello 顺延 lastSeen，不该出现 online=false 的增量
  const back = connect(srv.port);
  await back.opened;
  hello(back, 'mm', '张三');
  await waitFor(() => back.of('welcome').length === 1);
  srv.advance(3000);
  srv.tick();

  const offline = watcher
    .of('memberDelta')
    .filter((d) => d.member.memberId === 'mm' && d.member.online === false);
  assert.equal(offline.length, 0, '短暂重连不应被判离线');
  assert.equal(srv.relay.rooms.get('ROOM01').members.size, 1);

  back.close();
  watcher.close();
  await srv.close();
});

test('重装/清数据 = 新安装标识 = 新成员，旧成员 5 秒离线、2 分钟移除', async () => {
  const srv = await startServer({ offlineTimeoutMs: 5000 });
  const watcher = connect(srv.port);
  const oldApp = connect(srv.port);
  await Promise.all([watcher.opened, oldApp.opened]);
  hello(watcher, 'mw', '观察者');
  hello(oldApp, 'install-old', '张三');
  await waitFor(() => watcher.of('welcome').length === 1 && oldApp.of('welcome').length === 1);
  report(oldApp, 'install-old', '张三', 70, 1);
  await waitFor(() => watcher.of('memberDelta').length >= 1, 2000, 'old delta');
  oldApp.close();

  // 重装后是全新标识：服务端只能当成另一个人
  srv.advance(6000);
  const reinstalled = connect(srv.port);
  await reinstalled.opened;
  hello(reinstalled, 'install-new', '张三');
  await waitFor(() => reinstalled.of('welcome').length === 1);
  report(reinstalled, 'install-new', '张三', 71, 1);
  await waitFor(() => watcher.of('memberDelta').length >= 2, 2000, 'new delta');

  srv.tick(); // 让 prune 跑一次：旧成员此刻才被判离线
  const room = srv.relay.rooms.get('ROOM01');
  assert.equal(room.members.size, 2, '新旧标识是两个成员');
  assert.equal(room.members.get('install-old').online, false);
  assert.equal(room.members.get('install-new').online, true);

  // 旧成员在 2 分钟保留期后移除
  srv.advance(114000);
  srv.tick();
  assert.equal(room.members.size, 1, '旧成员应被移除');
  assert.ok(room.members.has('install-new'));

  reinstalled.close();
  watcher.close();
  await srv.close();
});

// ------------------------------------------------- 加入即创建 / 闲置 1 分钟回收

test('首次连接自动创建房间，该客户端成为首个成员', async () => {
  const srv = await startServer();
  const c = connect(srv.port, 'BRAND1');
  await c.opened;
  hello(c, 'm-new', '张三');
  await waitFor(() => c.of('welcome').length === 1, 2000, 'welcome');
  report(c, 'm-new', '张三', 70, 1);
  await waitFor(() => c.of('memberDelta').length === 1, 2000, 'delta');

  const room = srv.relay.rooms.get('BRAND1');
  assert.ok(room, '房间应被创建');
  assert.equal(room.members.size, 1);
  assert.equal(room.members.get('m-new').report.bpm, 70);
  c.close();
  await srv.close();
});

test('第二个客户端加入同一房间：不新建、共享成员表', async () => {
  const srv = await startServer();
  const a = connect(srv.port, 'SHARED');
  await a.opened;
  hello(a, 'm-a', '张三');
  await waitFor(() => a.of('welcome').length === 1);
  report(a, 'm-a', '张三', 70, 1);
  await waitFor(() => a.of('memberDelta').length === 1);

  const b = connect(srv.port, 'SHARED');
  await b.opened;
  hello(b, 'm-b', '李四');
  await waitFor(() => b.of('welcome').length === 1);
  report(b, 'm-b', '李四', 88, 1);
  await waitFor(() => a.of('memberDelta').length === 2, 2000, 'b 的 delta 到 a');

  const room = srv.relay.rooms.get('SHARED');
  assert.equal(room.members.size, 2);
  assert.equal(srv.relay.rooms.size, 1, '不应产生第二个房间对象');
  a.close();
  b.close();
  await srv.close();
});

test('空置未到 1 分钟回来：沿用原房间，成员与序号都不重置', async () => {
  const srv = await startServer({ idleTimeoutMs: 60000 });
  const a = connect(srv.port, 'KEEP');
  await a.opened;
  hello(a, 'm-keep', '张三');
  await waitFor(() => a.of('welcome').length === 1);
  report(a, 'm-keep', '张三', 70, 5);
  await waitFor(() => a.of('memberDelta').length === 1);
  a.close();
  await new Promise((r) => setTimeout(r, 50));

  srv.advance(30000); // 30 秒，还没到 1 分钟
  srv.tick();
  assert.ok(srv.relay.rooms.get('KEEP'), '未到 1 分钟不应回收');
  assert.equal(srv.relay.rooms.get('KEEP').members.size, 1);

  const back = connect(srv.port, 'KEEP');
  await back.opened;
  hello(back, 'm-keep', '张三');
  await waitFor(() => back.of('welcome').length === 1);
  const room = srv.relay.rooms.get('KEEP');
  assert.equal(room.members.get('m-keep').report.sequence, 5, '序号原样保留');
  assert.equal(room.members.get('m-keep').report.bpm, 70);
  back.close();
  await srv.close();
});

test('空置超过 1 分钟：房间被回收，重连是新房间', async () => {
  const srv = await startServer({ idleTimeoutMs: 60000 });
  const a = connect(srv.port, 'GONE');
  await a.opened;
  hello(a, 'm-gone', '张三');
  await waitFor(() => a.of('welcome').length === 1);
  report(a, 'm-gone', '张三', 70, 1);
  await waitFor(() => a.of('memberDelta').length === 1);
  a.close();
  await new Promise((r) => setTimeout(r, 50));

  srv.advance(60000);
  srv.tick();
  assert.equal(srv.relay.rooms.get('GONE'), undefined, '房间应被回收');

  const again = connect(srv.port, 'GONE');
  await again.opened;
  hello(again, 'm-gone', '张三');
  await waitFor(() => again.of('welcome').length === 1);
  const room = srv.relay.rooms.get('GONE');
  assert.equal(room.members.size, 0, '新房间没有旧成员');
  assert.equal(room.idleSince, null, '有人连上就不是空闲状态');
  again.close();
  await srv.close();
});

test('1 分钟回收不影响 5 秒离线判定（房间仍有人时）', async () => {
  const srv = await startServer({ offlineTimeoutMs: 5000, idleTimeoutMs: 60000 });
  const watcher = connect(srv.port, 'OFFLINE');
  const member = connect(srv.port, 'OFFLINE');
  await Promise.all([watcher.opened, member.opened]);
  hello(watcher, 'mw', '观察者');
  hello(member, 'mm', '张三');
  await waitFor(() => watcher.of('welcome').length === 1 && member.of('welcome').length === 1);
  report(member, 'mm', '张三', 70, 1);
  await waitFor(() => watcher.of('memberDelta').length === 1);

  member.close(); // 观察者还连着，房间不算无人
  await new Promise((r) => setTimeout(r, 50));
  srv.advance(6000);
  srv.tick();

  assert.ok(srv.relay.rooms.get('OFFLINE'), '有人连着不该回收');
  const state = srv.relay.rooms.get('OFFLINE').members.get('mm');
  assert.equal(state.online, false, '5 秒离线判定照常生效');
  assert.equal(srv.relay.rooms.get('OFFLINE').members.size, 1, '2 分钟内不移除成员');
  watcher.close();
  await srv.close();
});

test('20 人上限仍然生效（第 21 人收到 ROOM_FULL）', async () => {
  const srv = await startServer({ roomLimit: 3 });
  const clients = [];
  for (let i = 0; i < 3; i++) {
    const c = connect(srv.port, 'LIMIT');
    clients.push(c);
    await c.opened;
    hello(c, `m${i}`, `人${i}`);
    await waitFor(() => c.of('welcome').length === 1);
    report(c, `m${i}`, `人${i}`, 60 + i, 1);
    await waitFor(() => c.of('memberDelta').length >= 1);
  }
  const extra = connect(srv.port, 'LIMIT');
  await extra.opened;
  hello(extra, 'm-extra', '多余的');
  await waitFor(() => extra.of('welcome').length === 1);
  report(extra, 'm-extra', '多余的', 90, 1);
  await waitFor(() => extra.of('error').length >= 1, 2000, 'ROOM_FULL');
  assert.equal(extra.last('error').code, 'ROOM_FULL');
  for (const c of clients) c.close();
  extra.close();
  await srv.close();
});
