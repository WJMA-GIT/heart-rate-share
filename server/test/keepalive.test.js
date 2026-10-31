'use strict';

/**
 * WS 保活回归测试。
 *
 * 背景（真机日志查出来的真 bug）：`wss.on('connection')` 在
 * `noServer: true` + 手动 `handleUpgrade` 的用法下**不会触发**，所以 pong 监听
 * 从来没挂上；`alive` 永远停在 false 的下一轮就被 `terminate()` —— 每条健康连接
 * 都会在 30~60 秒后被自己掐断，客户端看到 `1006 initiator=remote`，用户感知为
 * "中间会突然断线重连一下"。
 *
 * 这里用 150ms 的保活间隔（WS_KEEPALIVE_MS，测试专用旋钮）把两种情况都跑一遍：
 * 健康连接（自动回 pong）不能被关；不回 pong 的连接必须被 terminate 并留下日志。
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { WebSocket } = require('ws');

const KEEPALIVE_MS = 150;

function startServer({ logDir }) {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'index.js')], {
    env: {
      ...process.env,
      PORT: '0',
      LOG_LEVEL: 'info',
      LOG_DIR: logDir,
      WS_KEEPALIVE_MS: String(KEEPALIVE_MS),
      TZ: 'UTC',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const port = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server did not start in 5s')), 5000);
    child.stdout.on('data', (buf) => {
      for (const line of buf.toString('utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          const parsed = JSON.parse(line);
          if (parsed.msg === 'relay_started') {
            clearTimeout(timer);
            resolve(parsed.port);
          }
        } catch {
          /* 忽略非 JSON 输出 */
        }
      }
    });
    child.on('exit', (code) => reject(new Error(`server exited early: ${code}`)));
  });
  return { child, port };
}

/** 裸 socket 做 WS 握手，然后**什么都不回**（连 ping 都不回）＝半死连接。 */
function rawSilentSocket(port) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1', () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write(
        'GET /ws?room=KA1 HTTP/1.1\r\n' +
          `Host: 127.0.0.1:${port}\r\n` +
          'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
          `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
      resolve(socket);
    });
    socket.on('data', () => {});
  });
}

test('健康连接不会被保活掐断；不回 pong 的连接会被 terminate 且留下日志', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-ka-'));
  const logDir = path.join(tmp, 'logs');
  const { child, port } = startServer({ logDir });
  const readyPort = await port;
  try {
    // 1) 健康连接：ws 客户端会自动回 pong，必须一直是 OPEN
    const healthy = new WebSocket(`ws://127.0.0.1:${readyPort}/ws?room=KA1`);
    let healthyClosed = null;
    healthy.on('close', (code) => {
      healthyClosed = code;
    });
    await new Promise((resolve, reject) => {
      healthy.on('open', resolve);
      healthy.on('error', reject);
    });
    await new Promise((resolve) => setTimeout(resolve, KEEPALIVE_MS * 4));
    assert.equal(healthyClosed, null, '健康连接不能被保活误杀（旧实现的 bug）');
    assert.equal(healthy.readyState, WebSocket.OPEN);

    // 2) 半死连接：不回任何帧，必须被 terminate
    const silent = await rawSilentSocket(readyPort);
    let silentClosed = false;
    silent.on('close', () => {
      silentClosed = true;
    });
    await new Promise((resolve) => {
      const timer = setInterval(() => {
        if (silentClosed) {
          clearInterval(timer);
          resolve();
        }
      }, 25);
      setTimeout(() => {
        clearInterval(timer);
        resolve();
      }, KEEPALIVE_MS * 6);
    });
    assert.equal(silentClosed, true, '不回 pong 的连接应被保活 terminate');
    silent.destroy();
    healthy.close();

    await new Promise((resolve) => setTimeout(resolve, 150));
    const file = fs.readFileSync(path.join(logDir, 'relay.log'), 'utf8');
    assert.match(file, /"msg":"keepalive_terminate"/, '必须记录保活 terminate');
    assert.match(file, /"silentMs":\d+/, '要带"多久没回 pong"');
    const terminated = file
      .split('\n')
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .find((item) => item && item.msg === 'client_closed' && item.closeCode === 1006);
    assert.ok(terminated, '要有 1006 的 client_closed');
    assert.equal(terminated.closedBy, 'keepalive_terminate');
    assert.equal(terminated.initiator, 'server', '必须写明是服务端掐的');
  } finally {
    child.kill('SIGKILL');
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
