'use strict';

/**
 * 结构化日志：**始终**写 stdout/stderr（`docker logs` 照旧可读），同时可选落文件。
 *
 * 为什么要有文件：容器 json-file 驱动会被轮转（默认 10m×3），出问题时现场只剩
 * 最后几十分钟；挂到宿主机目录上才能长期留证（比如"谁先断的"这种要事后对齐的问题）。
 *
 * 落盘策略：
 * - 目录由 `LOG_DIR` 指定（默认 `/app/logs`），文件名固定 `relay.log`；
 * - 按大小轮转：`relay.log` → `relay.log.1` → … → `relay.log.N`，
 *   总量 ≈ LOG_MAX_BYTES × (LOG_MAX_FILES + 1)；
 * - 惰性打开、所有 logger 实例共用**同一个** sink（index 与 RelayServer 各有一个
 *   logger，各开一条流会写出交错的行、并且轮转判断互相打架）；
 * - 写失败（只读挂载/权限/磁盘满）只打一条 `log_file_disabled` 告警并退化为
 *   stdout-only，绝不抛错、绝不阻塞收包；流缓冲超过上限时直接丢文件行（宁可少日志）。
 *
 * 敏感信息：本模块不记录 payload；调用方只传结构化的元数据（房间码、截断后的
 * 成员标识、close code 等）。协议里禁止出现的 token/配对密钥一律不进日志。
 */

const fs = require('node:fs');
const path = require('node:path');

const LOG_LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };

const LOG_FILE = 'relay.log';
// 文件 sink 的写缓冲上限：磁盘卡住时宁可丢文件行，也不让内存涨起来、不阻塞事件循环。
const MAX_BUFFER_BYTES = 4 * 1024 * 1024;

function intFromEnv(name, fallback, { min = 1 } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < min) return fallback;
  return parsed;
}

/** 本地时区的 ISO 时间戳（带偏移量），TZ 由容器环境变量决定，便于和客户端日志对齐。 */
function isoTs(date = new Date()) {
  const pad = (value, width = 2) => String(Math.trunc(Math.abs(value))).padStart(width, '0');
  const offsetMinutes = -date.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? '+' : '-';
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `.${pad(date.getMilliseconds(), 3)}` +
    `${sign}${pad(offsetMinutes / 60)}:${pad(offsetMinutes % 60)}`
  );
}

const sink = {
  /** @type {import('node:fs').WriteStream | null} */
  stream: null,
  ready: false,
  disabled: false,
  dir: process.env.LOG_DIR || '/app/logs',
  file: '',
  bytes: 0,
  maxBytes: intFromEnv('LOG_MAX_BYTES', 20 * 1024 * 1024),
  maxFiles: intFromEnv('LOG_MAX_FILES', 5),
};

function rawStderr(fields) {
  process.stderr.write(JSON.stringify({ ts: isoTs(), level: 'warn', ...fields }) + '\n');
}

function disable(reason) {
  if (sink.disabled) return;
  sink.disabled = true;
  try {
    sink.stream?.destroy();
  } catch {
    /* ignore */
  }
  sink.stream = null;
  // 这条告警直接写 stderr：不能走会再次尝试落盘的路径。
  rawStderr({
    msg: 'log_file_disabled',
    dir: sink.dir,
    reason: String(reason && reason.message ? reason.message : reason),
    fallback: 'stdout',
  });
}

function openStream() {
  const file = path.join(sink.dir, LOG_FILE);
  sink.file = file;
  fs.mkdirSync(sink.dir, { recursive: true });
  // createWriteStream 是异步打开的：先同步 touch 一下，保证随后的轮转能 rename 到文件。
  fs.closeSync(fs.openSync(file, 'a'));
  sink.bytes = fs.statSync(file).size;
  const stream = fs.createWriteStream(file, { flags: 'a' });
  stream.on('error', (err) => disable(err));
  return stream;
}

function init() {
  if (sink.ready) return;
  sink.ready = true;
  try {
    sink.stream = openStream();
  } catch (err) {
    disable(err);
  }
}

/** relay.log.N 删掉，其余依次后移，当前文件变成 relay.log.1，然后重开空文件。 */
function rotate() {
  const file = sink.file;
  // 先断开旧流，避免 rename 之后还有缓冲行写进已经改名的那份文件（最多丢一行）。
  try {
    sink.stream?.destroy();
  } catch {
    /* ignore */
  }
  sink.stream = null;
  try {
    if (sink.maxFiles > 0) {
      fs.rmSync(`${file}.${sink.maxFiles}`, { force: true });
      for (let index = sink.maxFiles - 1; index >= 1; index -= 1) {
        try {
          fs.renameSync(`${file}.${index}`, `${file}.${index + 1}`);
        } catch {
          /* 该份不存在，跳过 */
        }
      }
    }
    fs.renameSync(file, `${file}.1`);
  } catch (err) {
    disable(err);
    return;
  }
  try {
    sink.stream = openStream();
  } catch (err) {
    disable(err);
  }
}

function writeFile(line) {
  init();
  if (!sink.stream || sink.disabled) return;
  try {
    const size = Buffer.byteLength(line);
    // 背压：磁盘卡住时宁可丢文件行，也不让内存涨、不阻塞事件循环。
    if (sink.stream.writableLength > MAX_BUFFER_BYTES) return;
    // 轮转在**写之前**判断：超限就先切文件，这一行自然落到新文件里。
    if (sink.bytes > 0 && sink.bytes + size > sink.maxBytes) rotate();
    const stream = sink.stream;
    if (!stream || sink.disabled) return;
    stream.write(line);
    sink.bytes += size;
  } catch (err) {
    disable(err);
  }
}

function createLogger(level) {
  const threshold = LOG_LEVELS[String(level || 'info').toLowerCase()] ?? LOG_LEVELS.info;
  const emit = (lvl, msg, fields) => {
    if (LOG_LEVELS[lvl] > threshold) return;
    const line = JSON.stringify({ ts: isoTs(), level: lvl, msg, ...(fields || {}) }) + '\n';
    const out = lvl === 'error' || lvl === 'warn' ? process.stderr : process.stdout;
    out.write(line);
    writeFile(line);
  };
  return {
    error: (msg, fields) => emit('error', msg, fields),
    warn: (msg, fields) => emit('warn', msg, fields),
    info: (msg, fields) => emit('info', msg, fields),
    debug: (msg, fields) => emit('debug', msg, fields),
  };
}

module.exports = { createLogger, isoTs, LOG_LEVELS, LOG_FILE, sink };
