'use strict';

/**
 * 共享心率 Relay —— 与客户端 v1 协议（docs/protocol.md）兼容的服务端实现。
 *
 * 设计约束：
 * - 房间状态全在内存：重启即丢。协议里 room epoch 恢复本就是 pre-production 任务，
 *   单实例部署下"重启后客户端重新上报即可恢复"是可接受行为。
 * - 不做鉴权/加密：ws:// 明文。公网必须由反向代理终止 TLS（见 README）。
 * - 不记录任何消息正文：协议明确禁止记录 payload / token / 配对密钥。
 */

const PROTOCOL_VERSION = 1;
const WS_PATH = '/ws';

const DEFAULT_ROOM_LIMIT = 20;
const DEFAULT_OFFLINE_TIMEOUT_MS = 5000;
const DEFAULT_MAX_CLIENTS = 200;
// 协议固定值：2 分钟无有效上报即移除成员，不做成可配项，避免与客户端预期漂移。
const REMOVE_TIMEOUT_MS = 120000;
// 房间**无人**（零 WebSocket 连接）持续这么久就回收。1 分钟窗口内有人回来则
// 沿用原房间（成员、序号一概不动）。
const DEFAULT_IDLE_ROOM_TIMEOUT_MS = 60000;
const SNAPSHOT_INTERVAL_MS = 1000;
const MAX_DISPLAY_NAME = 32;
const MAX_ROOM_CODE_LEN = 64;

const CLIENT_TYPES = new Set(['hello', 'heartRate', 'ping']);

// ws 的 OPEN 常量是类静态属性，实例上取不可靠，统一用数值比较。
const WS_OPEN = 1;

// 日志实现搬到 ./logger（stdout + 大小轮转的文件），这里只是转出，保持既有 require 路径。
const { createLogger } = require('./logger');

/** 慢消费者阈值：单连接待发数据超过它就先记一条告警（不改变发送行为）。 */
const SLOW_SEND_BYTES = 256 * 1024;
const SLOW_SEND_LOG_INTERVAL_MS = 5000;

function envelope(type, data) {
  return JSON.stringify({ v: PROTOCOL_VERSION, type, ...(data || {}) });
}

/** memberId 视为不透明标识，日志里只留末 6 位，避免把设备标识完整写进日志。 */
function shortId(memberId) {
  if (typeof memberId !== 'string' || memberId.length <= 6) return '***';
  return '…' + memberId.slice(-6);
}

class Room {
  constructor(code, limit) {
    this.code = code;
    this.limit = limit;
    /** @type {Map<string, {report: object, lastSeen: number, online: boolean}>} */
    this.members = new Map();
    /** @type {Map<string, import('ws').WebSocket>} */
    this.sockets = new Map();
    /**
     * 房间里**一条连接都没有**的起始时刻（毫秒）。有连接时为 null。
     * 只有它超过 idleTimeoutMs 才会回收房间，见 RelayServer.tick()。
     * @type {number | null}
     */
    this.idleSince = null;
  }

  get isEmpty() {
    return this.members.size === 0 && this.sockets.size === 0;
  }

  /** 与客户端 RelayStore 一致：按 displayName 排序，保证两端快照顺序稳定。 */
  snapshotMembers(now) {
    return [...this.members.values()]
      .map((m) => this.memberJson(m, now))
      .sort((a, b) => (a.displayName < b.displayName ? -1 : a.displayName > b.displayName ? 1 : 0));
  }

  memberJson(member, now) {
    const r = member.report;
    return {
      memberId: r.memberId,
      displayName: r.displayName,
      bpm: r.bpm,
      rrMs: r.rrMs,
      sensorContact: r.sensorContact,
      sequence: r.sequence,
      measuredAt: r.measuredAt,
      lastSeen: new Date(member.lastSeen).toISOString(),
      online: member.online,
    };
  }

  /**
   * 接受一次上报。返回 null 表示旧包被丢弃（sequence 不递增）。
   * 新成员超额时抛错，由调用方回 ROOM_FULL。
   */
  accept(report, now) {
    const previous = this.members.get(report.memberId);
    if (previous && report.sequence <= previous.report.sequence) return null;
    if (!previous && this.members.size >= this.limit) {
      const err = new Error('ROOM_FULL');
      err.code = 'ROOM_FULL';
      throw err;
    }
    const state = { report, lastSeen: now, online: true };
    this.members.set(report.memberId, state);
    return state;
  }

  /** 仅更新已存在成员的昵称，不改心率、序列号、lastSeen 或在线状态。 */
  rename(memberId, displayName) {
    const member = this.members.get(memberId);
    if (!member) return null;
    member.report = { ...member.report, displayName };
    return member;
  }

  /** 返回 { changed: MemberState[], removed: string[] }，只用于广播增量。 */
  prune(now, offlineTimeoutMs) {
    const changed = [];
    const removed = [];
    for (const [id, member] of this.members) {
      const age = now - member.lastSeen;
      if (age >= REMOVE_TIMEOUT_MS) {
        this.members.delete(id);
        removed.push(id);
      } else if (age >= offlineTimeoutMs && member.online) {
        member.online = false;
        changed.push(member);
      }
    }
    return { changed, removed };
  }
}

class RelayServer {
  /**
   * @param {object} opts
   * @param {number} [opts.roomLimit]
   * @param {number} [opts.offlineTimeoutMs]
   * @param {number} [opts.maxClients]
   * @param {string} [opts.logLevel]
   * @param {() => number} [opts.clock]
   */
  constructor(opts = {}) {
    this.roomLimit = opts.roomLimit ?? DEFAULT_ROOM_LIMIT;
    this.offlineTimeoutMs = opts.offlineTimeoutMs ?? DEFAULT_OFFLINE_TIMEOUT_MS;
    this.idleTimeoutMs = opts.idleTimeoutMs ?? DEFAULT_IDLE_ROOM_TIMEOUT_MS;
    this.maxClients = opts.maxClients ?? DEFAULT_MAX_CLIENTS;
    this.log = opts.logLevel ? createLogger(opts.logLevel) : createLogger('info');
    this.clock = opts.clock ?? (() => Date.now());
    /** @type {Map<string, Room>} */
    this.rooms = new Map();
    this.clientCount = 0;
    this.startedAt = this.clock();
    this.snapshotTimer = null;
    this.pruneTimer = null;
    this.wss = null;
    this.httpServer = null;
  }

  /**
   * 取房间；**不存在就创建**（加入即创建）。已有房间被重新加入时只取消空闲
   * 计时，成员表、序号、在线状态一概不动。
   */
  room(code) {
    let room = this.rooms.get(code);
    if (!room) {
      room = new Room(code, this.roomLimit);
      this.rooms.set(code, room);
      this.log.info('room_created', { room: code, reason: 'first_join' });
      return room;
    }
    if (room.idleSince !== null) {
      this.log.debug('room_reused', { room: code, idleMs: this.clock() - room.idleSince });
      room.idleSince = null;
    }
    return room;
  }

  stats() {
    let members = 0;
    for (const room of this.rooms.values()) members += room.members.size;
    return {
      rooms: this.rooms.size,
      members,
      clients: this.clientCount,
      uptimeSec: Math.round((this.clock() - this.startedAt) / 1000),
    };
  }

  broadcast(room, type, data) {
    const text = envelope(type, data);
    const now = this.clock();
    for (const socket of room.sockets.values()) {
      if (socket.readyState !== WS_OPEN) continue;
      // 慢消费者：只记录，不改变发送行为（跳过发送会破坏快照语义）。
      if (socket.bufferedAmount > SLOW_SEND_BYTES) {
        if (!socket.slowLoggedAt || now - socket.slowLoggedAt > SLOW_SEND_LOG_INTERVAL_MS) {
          socket.slowLoggedAt = now;
          this.log.warn('slow_send', {
            room: room.code,
            buffered: socket.bufferedAmount,
            type,
          });
        }
      }
      socket.send(text);
    }
  }

  /** 单条连接的处理入口，与 HTTP/WS 层解耦，便于测试直接驱动。 */
  handleConnection(socket, roomCode) {
    if (this.clientCount >= this.maxClients) {
      this.log.warn('server_full', { maxClients: this.maxClients });
      this.sendError(socket, 'SERVER_FULL');
      socket.closedBy = 'server_full';
      socket.close(1013, 'server full');
      return;
    }
    const room = this.room(roomCode);
    this.clientCount += 1;
    const openedAt = this.clock();
    let lastInboundAt = openedAt;

    let memberId = null;

    socket.on('message', (raw) => {
      lastInboundAt = this.clock();
      let msg;
      try {
        msg = JSON.parse(typeof raw === 'string' ? raw : raw.toString('utf8'));
      } catch {
        this.sendError(socket, 'BAD_MESSAGE');
        return;
      }
      this.onMessage(socket, room, msg, (id) => {
        memberId = id;
      }, () => memberId);
    });

    // 断开日志是"谁先断的"唯一证据，按 info 记：close code/reason、是服务端还是对端
    // 发起的、断开前多久没收到任何数据、最近一次 WS ping 的 RTT、当时房里还有几条连接。
    const onClose = (code, reasonBuf) => {
      this.clientCount = Math.max(0, this.clientCount - 1);
      if (memberId && room.sockets.get(memberId) === socket) {
        room.sockets.delete(memberId);
      }
      // 不再"空了立刻删"：先记下无连接的起始时刻，交给 tick() 按 1 分钟窗口
      // 回收。这样短暂断线回来仍能沿用原房间（成员/序号不重置）。
      if (room.sockets.size === 0 && room.idleSince === null) {
        room.idleSince = this.clock();
      }
      const now = this.clock();
      const closedBy = socket.closedBy || 'peer';
      this.log.info('client_closed', {
        room: room.code,
        member: shortId(memberId || ''),
        connections: room.sockets.size,
        durationMs: now - openedAt,
        lastInboundMs: now - lastInboundAt,
        lastPingRttMs: socket.lastPingRttMs ?? null,
        closeCode: code,
        closeReason: reasonBuf ? String(reasonBuf).slice(0, 120) : '',
        initiator: closedBy === 'peer' ? 'peer' : 'server',
        closedBy,
      });
    };
    socket.on('close', onClose);
    socket.on('error', (err) => {
      this.log.warn('socket_error', {
        room: room.code,
        member: shortId(memberId || ''),
        code: err && err.code ? String(err.code) : null,
        error: String(err && err.message),
      });
    });
  }

  onMessage(socket, room, msg, setMemberId, getMemberId) {
    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) {
      this.sendError(socket, 'BAD_MESSAGE');
      return;
    }
    if (msg.v !== PROTOCOL_VERSION) {
      this.sendError(socket, 'BAD_MESSAGE');
      return;
    }
    const type = msg.type;
    if (!CLIENT_TYPES.has(type)) {
      // 协议：客户端不得发送 welcome/snapshot/memberDelta/pong/error。
      this.sendError(socket, 'BAD_MESSAGE');
      return;
    }

    if (type === 'hello') {
      const id = msg.memberId;
      if (typeof id !== 'string' || id.length === 0 || id.length > 128) {
        this.sendError(socket, 'BAD_MESSAGE');
        return;
      }
      const previous = room.sockets.get(id);
      if (previous && previous !== socket) {
        // 同一 memberId 重连：旧连接让位，避免同一成员被广播两次。
        this.log.info('member_reconnect', { room: room.code, member: shortId(id) });
        previous.closedBy = 'replaced';
        try {
          previous.close(4000, 'replaced');
        } catch {
          /* ignore */
        }
      }
      const existing = room.members.get(id);
      room.sockets.set(id, socket);
      setMemberId(id);
      if (existing) {
        // 身份恢复：心率、序号、昵称一律保留，不新建成员。
        // 仅当成员此刻仍在线时顺延 lastSeen —— "关掉 App 3 秒又回来"不该被判
        // 离线再复活；而已经离线的成员必须等真实上报才恢复在线，不凭空点亮。
        if (existing.online) existing.lastSeen = this.clock();
        this.log.info('member_resumed', {
          room: room.code,
          member: shortId(id),
          wasOnline: existing.online,
          sequence: existing.report.sequence,
        });
      } else {
        this.log.info('member_new', { room: room.code, member: shortId(id) });
      }
      socket.send(envelope('welcome', {}));
      this.log.info('member_hello', { room: room.code, member: shortId(id) });
      return;
    }

    if (type === 'ping') {
      // v1 可选扩展：仅更新已存在成员昵称；缺省或非法值一律忽略，保持旧客户端兼容。
      const current = getMemberId();
      const nextName = typeof msg.displayName === 'string' ? msg.displayName.trim() : '';
      if (current && nextName) {
        const renamed = room.rename(current, nextName.slice(0, MAX_DISPLAY_NAME));
        if (renamed) {
          this.broadcast(room, 'memberDelta', { member: room.memberJson(renamed, this.clock()) });
        }
      }
      socket.send(envelope('pong', {}));
      return;
    }

    // heartRate
    const report = this.parseReport(msg);
    if (!report) {
      this.sendError(socket, 'BAD_MESSAGE');
      return;
    }
    const current = getMemberId();
    if (current === null || current !== report.memberId) {
      // 与客户端 Relay 一致：必须先 hello，且上报的 memberId 必须与 hello 一致。
      this.sendError(socket, 'BAD_MESSAGE');
      return;
    }
    let state;
    try {
      state = room.accept(report, this.clock());
    } catch (err) {
      if (err && err.code === 'ROOM_FULL') {
        this.log.warn('room_full', { room: room.code, limit: room.limit });
        this.sendError(socket, 'ROOM_FULL');
        socket.closedBy = 'room_full';
        socket.close(1013, 'room full');
        return;
      }
      throw err;
    }
    if (!state) return; // 旧包，丢弃
    this.broadcast(room, 'memberDelta', { member: room.memberJson(state, this.clock()) });
  }

  parseReport(msg) {
    const { memberId, displayName, bpm, rrMs, sensorContact, sequence, measuredAt } = msg;
    if (typeof memberId !== 'string' || memberId.length === 0) return null;
    if (typeof displayName !== 'string' || displayName.trim().length === 0) return null;
    if (!Number.isInteger(bpm) || bpm < 0 || bpm > 1000) return null;
    if (!Array.isArray(rrMs) || rrMs.some((v) => !Number.isInteger(v))) return null;
    if (!(sensorContact === true || sensorContact === false || sensorContact === null)) return null;
    if (!Number.isInteger(sequence) || sequence <= 0) return null;
    if (typeof measuredAt !== 'string' || Number.isNaN(Date.parse(measuredAt))) return null;
    return {
      memberId,
      displayName: displayName.trim().slice(0, MAX_DISPLAY_NAME),
      bpm,
      rrMs,
      sensorContact,
      sequence,
      measuredAt: new Date(measuredAt).toISOString(),
    };
  }

  sendError(socket, code) {
    if (socket.readyState === WS_OPEN) socket.send(envelope('error', { code }));
    this.log.warn('bad_message', { code });
  }

  /** 每秒：先剪枝（离线/移除）再发全量快照，顺序与客户端 Relay 一致。 */
  tick() {
    const now = this.clock();
    for (const room of [...this.rooms.values()]) {
      const { changed } = room.prune(now, this.offlineTimeoutMs);
      for (const member of changed) {
        this.broadcast(room, 'memberDelta', { member: room.memberJson(member, now) });
      }
      if (room.sockets.size > 0) {
        this.broadcast(room, 'snapshot', { members: room.snapshotMembers(now) });
        continue;
      }
      // 无人（零连接）超过 idleTimeoutMs → 回收房间对象与成员表。
      if (room.idleSince !== null && now - room.idleSince >= this.idleTimeoutMs) {
        this.rooms.delete(room.code);
        this.log.info('room_idle_dropped', {
          room: room.code,
          idleMs: now - room.idleSince,
          members: room.members.size,
        });
      }
    }
  }

  startTimers() {
    if (this.snapshotTimer) return;
    this.snapshotTimer = setInterval(() => {
      try {
        this.tick();
      } catch (err) {
        this.log.error('tick_failed', { error: String(err && err.message) });
      }
    }, SNAPSHOT_INTERVAL_MS);
    if (typeof this.snapshotTimer.unref === 'function') this.snapshotTimer.unref();
  }

  /** 供测试手动推进时间用：剪枝 + 快照各跑一次。 */
  manualTick() {
    this.tick();
  }
}

module.exports = {
  RelayServer,
  Room,
  createLogger,
  envelope,
  shortId,
  PROTOCOL_VERSION,
  WS_PATH,
  DEFAULT_ROOM_LIMIT,
  DEFAULT_OFFLINE_TIMEOUT_MS,
  DEFAULT_MAX_CLIENTS,
  REMOVE_TIMEOUT_MS,
  DEFAULT_IDLE_ROOM_TIMEOUT_MS,
  SNAPSHOT_INTERVAL_MS,
  MAX_DISPLAY_NAME,
  MAX_ROOM_CODE_LEN,
};
