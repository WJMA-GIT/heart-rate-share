'use strict';

/**
 * 真实时钟烟测：3 个客户端同房间，1 Hz 上报 → 看快照广播 → 一个停止上报
 * → 用真实时间验证「5 秒判离线」。
 *
 * 用法：
 *   node test/smoke.js                     # 自动起一个临时服务（PORT=0）
 *   node test/smoke.js ws://1.2.3.4:8765/ws?room=ABC123
 *
 * 输出为 PASS/FAIL 行，便于人工核对，也可用于部署后验收。
 */

const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');
const { WebSocket } = require('ws');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function startServer() {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'index.js')], {
    env: { ...process.env, PORT: '0', LOG_LEVEL: 'info' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server start timeout')), 5000);
    child.stdout.on('data', (buf) => {
      for (const line of buf.toString('utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const m = JSON.parse(line);
          if (m.msg === 'relay_started') {
            clearTimeout(timer);
            resolve(m.port);
          }
        } catch {
          /* ignore */
        }
      }
    });
  });
  return { child, port };
}

function client(port, room) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?room=${room}`);
  const state = { messages: [], snapshots: [], deltas: [] };
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString('utf8'));
    state.messages.push(msg);
    if (msg.type === 'snapshot') state.snapshots.push(msg);
    if (msg.type === 'memberDelta') state.deltas.push(msg);
  });
  return {
    ws,
    state,
    open: new Promise((resolve, reject) => {
      ws.on('open', resolve);
      ws.on('error', reject);
    }),
    send: (obj) => ws.send(JSON.stringify(obj)),
  };
}

async function main() {
  const urlArg = process.argv[2];
  let child = null;
  let port;
  let room = 'SMOKE1';

  if (urlArg) {
    const u = new URL(urlArg);
    port = Number(u.port || 80);
    room = u.searchParams.get('room') || room;
    if (u.hostname !== '127.0.0.1' && u.hostname !== 'localhost') {
      // 远程验收：直接按 URL 连，不做健康检查（可能没有 /healthz 权限）
      console.log(`INFO 连接远程中继 ${u.href}`);
    }
  } else {
    const started = await startServer();
    child = started.child;
    port = started.port;
    console.log(`INFO 临时中继已启动 port=${port} room=${room}`);
  }

  // 健康检查（本机临时服务才有 /healthz）
  if (!urlArg) {
    const health = await new Promise((resolve, reject) => {
      http
        .get(`http://127.0.0.1:${port}/healthz`, (res) => {
          let d = '';
          res.on('data', (c) => (d += c));
          res.on('end', () => resolve({ code: res.statusCode, body: JSON.parse(d) }));
        })
        .on('error', reject);
    });
    console.log(
      health.code === 200 && health.body.status === 'ok'
        ? `PASS /healthz 200 status=ok protocol=${health.body.protocol}`
        : `FAIL /healthz code=${health.code}`,
    );
  }

  const names = ['张三', '李四', '王五'];
  const clients = names.map(() => client(port, room));
  await Promise.all(clients.map((c) => c.open));

  clients.forEach((c, i) => {
    c.send({ v: 1, type: 'hello', memberId: `smoke-${i}`, displayName: names[i] });
  });
  await sleep(200);

  // 3 个客户端各按 1 Hz 上报 3 秒
  const lastReportAt = {};
  for (let seq = 1; seq <= 3; seq += 1) {
    clients.forEach((c, i) => {
      if (i === 2 && seq === 3) return; // 王五最后 1 秒停止上报，用于验证离线
      c.send({
        v: 1,
        type: 'heartRate',
        memberId: `smoke-${i}`,
        displayName: names[i],
        bpm: 70 + i * 8 + seq,
        rrMs: [800, 810],
        sensorContact: true,
        sequence: seq,
        measuredAt: new Date().toISOString(),
      });
      lastReportAt[i] = Date.now();
    });
    await sleep(1000);
  }

  const lastSnap = clients[0].state.snapshots.at(-1);
  const namesInSnap = (lastSnap?.members || []).map((m) => m.displayName);
  console.log(
    namesInSnap.length === 3
      ? `PASS 快照广播：1 秒一条，最新快照含 ${namesInSnap.length} 人 [${namesInSnap.join('、')}]`
      : `FAIL 快照人数异常：${JSON.stringify(namesInSnap)}`,
  );
  console.log(
    clients[0].state.deltas.length > 0
      ? `PASS memberDelta 增量：收到 ${clients[0].state.deltas.length} 条`
      : 'FAIL 未收到 memberDelta',
  );

  // 张三、李四继续按 1 Hz 上报；只有王五静默。
  let seq = 3;
  const keepAlive = setInterval(() => {
    seq += 1;
    for (const i of [0, 1]) {
      clients[i].send({
        v: 1,
        type: 'heartRate',
        memberId: `smoke-${i}`,
        displayName: names[i],
        bpm: 72 + i * 8,
        rrMs: [800],
        sensorContact: true,
        sequence: seq,
        measuredAt: new Date().toISOString(),
      });
      lastReportAt[i] = Date.now();
    }
  }, 1000);

  const memberOf = (idx) =>
    (clients[0].state.snapshots.at(-1)?.members || []).find((m) => m.memberId === `smoke-${idx}`);

  // 王五静默 4.2 秒：仍应在线（未到 5 秒阈值）
  let wait = lastReportAt[2] + 4200 - Date.now();
  if (wait > 0) await sleep(wait);
  console.log(
    memberOf(2)?.online === true
      ? 'PASS 王五静默 4.2 秒仍在线（未误判离线）'
      : `FAIL 王五 4.2 秒状态异常：${JSON.stringify(memberOf(2)?.online)}`,
  );

  // 到 6 秒：应判离线
  wait = lastReportAt[2] + 6000 - Date.now();
  if (wait > 0) await sleep(wait);
  const elapsed = ((Date.now() - lastReportAt[2]) / 1000).toFixed(1);
  console.log(
    memberOf(2)?.online === false
      ? `PASS 王五静默约 ${elapsed} 秒后判离线（online=false）`
      : `FAIL 王五 ${elapsed} 秒后仍在线：${JSON.stringify(memberOf(2)?.online)}`,
  );

  const others = [0, 1].map((i) => memberOf(i));
  console.log(
    others.every((m) => m?.online === true)
      ? 'PASS 持续上报的张三/李四保持在线'
      : `FAIL 在线成员被误判：${JSON.stringify(others.map((m) => [m?.memberId, m?.online]))}`,
  );
  clearInterval(keepAlive);

  clients.forEach((c) => c.ws.close());
  if (child) child.kill('SIGTERM');
  await sleep(200);
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error('SMOKE ERROR', err);
    process.exit(1);
  },
);
