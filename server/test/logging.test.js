'use strict';

/**
 * 日志落盘与断开日志字段的回归测试。
 *
 * 环境变量在 require 之前设置：logger 在模块初始化时读取 LOG_DIR / 轮转参数
 * （与容器行为一致——改配置要重启进程）。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-log-test-'));
process.env.LOG_DIR = path.join(tmpRoot, 'logs');
process.env.LOG_MAX_BYTES = '2048';
process.env.LOG_MAX_FILES = '2';
process.env.TZ = process.env.TZ || 'Asia/Shanghai';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');

const { createLogger, sink } = require('../src/logger');
const { RelayServer } = require('../src/relay');

const LOG_FILE = path.join(process.env.LOG_DIR, 'relay.log');

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
    }, 25);
  });
}

/**
 * 抓日志行，但**只吞 JSON 日志**：TAP 输出也走 stdout，全吞掉会让测试计数错乱。
 * 日志的 info 在 stdout、warn/error 在 stderr，两边都要抓。
 */
async function captureLogs(fn) {
  const outWrite = process.stdout.write.bind(process.stdout);
  const errWrite = process.stderr.write.bind(process.stderr);
  const chunks = [];
  const intercept = (forward) => (chunk, ...rest) => {
    const text = String(chunk);
    if (text.startsWith('{') && text.includes('"msg":')) {
      chunks.push(text);
      return true;
    }
    return forward(chunk, ...rest);
  };
  process.stdout.write = intercept(outWrite);
  process.stderr.write = intercept(errWrite);
  try {
    await fn();
  } finally {
    process.stdout.write = outWrite;
    process.stderr.write = errWrite;
  }
  return chunks.join('');
}

test.after(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

test('日志同时写 stdout 与文件，目录不存在会自动创建', async () => {
  const log = createLogger('info');
  const out = await captureLogs(() => log.info('unit_test_line', { room: 'R1' }));
  assert.match(out, /"msg":"unit_test_line"/, 'stdout 必须有同一行');
  // 写文件是流式的，等一小会儿
  await waitFor(() => fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 0, 2000, 'file');
  const file = fs.readFileSync(LOG_FILE, 'utf8');
  assert.match(file, /"msg":"unit_test_line"/);
  assert.match(file, /"room":"R1"/);
  // 本地时区带偏移量：TZ 生效
  assert.match(file, /"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"/);
});

test('按大小轮转：超过阈值生成 relay.log.1，保留份数不超过 LOG_MAX_FILES', async () => {
  const log = createLogger('info');
  const filler = 'x'.repeat(200);
  await captureLogs(() => {
    for (let index = 0; index < 60; index += 1) log.info('rotate_line', { index, filler });
  });
  await waitFor(() => fs.existsSync(`${LOG_FILE}.1`), 2000, 'relay.log.1');
  assert.ok(fs.statSync(LOG_FILE).size < 2048 + 4096, '当前文件不应无限增长');
  assert.ok(fs.existsSync(`${LOG_FILE}.1`));
  assert.ok(fs.existsSync(`${LOG_FILE}.2`));
  assert.ok(!fs.existsSync(`${LOG_FILE}.3`), 'LOG_MAX_FILES=2 时不能留下 .3');
});

test('写文件不可用时只打一条告警并继续工作（不抛错）', async () => {
  // 把路径指到一个"文件下面的子目录"：mkdir 必失败(ENOTDIR)，root 也绕不过去。
  const blocker = path.join(tmpRoot, 'blocker');
  fs.writeFileSync(blocker, 'not a directory');
  sink.dir = path.join(blocker, 'logs');
  sink.ready = false;
  sink.disabled = false;
  sink.stream = null;

  const log = createLogger('info');
  const out = await captureLogs(() => {
    log.info('after_disable_1');
    log.info('after_disable_2');
  });
  assert.match(out, /"msg":"log_file_disabled"/, '必须有一条降级告警');
  assert.equal(out.match(/"msg":"log_file_disabled"/g).length, 1, '告警只打一次，不要刷屏');
  assert.match(out, /"msg":"after_disable_1"/, 'stdout 仍要继续输出');
  assert.equal(sink.disabled, true);
});

test('断开日志带 close code / 无入站时长 / initiator / 连接数', async () => {
  const relay = new RelayServer({ logLevel: 'info' });
  const httpServer = http.createServer((req, res) => res.writeHead(404).end());
  const wss = new WebSocketServer({ noServer: true });
  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    wss.handleUpgrade(req, socket, head, (ws) => relay.handleConnection(ws, url.searchParams.get('room')));
  });
  await new Promise((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
  const port = httpServer.address().port;

  const out = await captureLogs(async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?room=LOGTEST`);
    await new Promise((resolve, reject) => {
      ws.on('open', resolve);
      ws.on('error', reject);
    });
    ws.send(
      JSON.stringify({
        v: 1,
        type: 'hello',
        memberId: 'log-test-member-0001',
        displayName: 'logtest',
      }),
    );
    await new Promise((resolve) => setTimeout(resolve, 150));
    ws.close(4001, 'test bye');
    await new Promise((resolve) => ws.on('close', resolve));
    await new Promise((resolve) => setTimeout(resolve, 100));
  });

  wss.close();
  await new Promise((resolve) => httpServer.close(resolve));

  const line = out
    .split('\n')
    .find((item) => item.includes('"msg":"client_closed"'));
  assert.ok(line, '要有 client_closed');
  const parsed = JSON.parse(line);
  assert.equal(parsed.room, 'LOGTEST');
  assert.equal(parsed.closeCode, 4001);
  assert.equal(parsed.closeReason, 'test bye');
  assert.equal(parsed.initiator, 'peer');
  assert.equal(parsed.closedBy, 'peer');
  assert.ok(Number.isInteger(parsed.lastInboundMs) && parsed.lastInboundMs >= 0);
  assert.equal(parsed.connections, 0, '断开后房间里已没有连接');
  assert.equal(parsed.member, '…r-0001', 'memberId 只保留末 6 位');
  assert.ok(!JSON.stringify(parsed).includes('log-test-member-0001'), '不得出现完整 memberId');
});
