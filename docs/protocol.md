# HeartRate local room protocol

**Version:** 1 (`v: 1`)  
**Transport:** one WebSocket per member to one Relay, `/ws?room=XXXXXX`.  
**Status:** `ws://` is cleartext and development-only. The client accepts
`wss://` (default port 443) using the platform's standard TLS certificate
validation; no custom pinning or bypass is implemented, so self-signed
certificates are not supported by default. Join-token authentication remains a
production prerequisite. Short codes are discovery IDs, not credentials. No
payload, token, pairing key, or secret may be logged.

## Envelope

Every text frame is JSON: `{ "v": 1, "type": "...", ...fields }`. Unknown
versions/types are rejected. Maximum room size is 20 members.

## Client → Relay

- `hello`: `memberId` (opaque ID), `displayName` (maximum 32 characters).
  Since 0.4.0 the client derives `memberId` from a **persisted install id** (UUID v4,
  created on first launch), so relaunching the app rejoins the same member instead of
  creating a new one. It identifies an **install**, not a person: reinstalling or
  clearing app data yields a new member, and two phones are always two members.
  Cross-device identity would require an account system and is out of scope.
  The server keys member state by `memberId`, so v1 is unchanged: old clients keep
  sending random IDs and behave exactly as before.
- `heartRate`: `memberId`, `displayName`, `bpm` integer, `rrMs` integer array,
  `sensorContact` true/false/null, `sequence` positive monotonically increasing
  integer, `measuredAt` UTC ISO-8601.
- `ping`: optional `displayName`; Relay answers `pong`. When present and the
  sender already exists in the room, a Relay may update that member's display
  name and broadcast a normal `memberDelta`. Relays that do not implement this
  optional field ignore it; no new message type is introduced and `v` stays 1.

`sequence` prevents stale packets from replacing newer state. HRS contact null
means the strap does not support contact detection; false means no contact.
RR values are converted from 1/1024-second units to rounded milliseconds.

## Relay → clients

- `welcome`: connection accepted by this development relay.
- `snapshot`: `members` array; sent every 1 second.
- `memberDelta`: `member` object; sent on new/changed samples and online changes.
- `pong`: heartbeat response.
- `error`: `code`, currently `BAD_MESSAGE` or connection-level rejection.

Member object = heartRate fields plus `lastSeen` UTC ISO-8601 and `online` bool.

## Thresholds and flow

- Client heart-rate report: at most 1 Hz, only when a new sample exists.
- WebSocket application ping: every 3 seconds.
- Member online → offline after 5 seconds without an accepted report.
- Member removed after 2 minutes without an accepted report.
- Relay sends full snapshots every 1 second and deltas after accepted reports.
- Maximum members: 20. Further members get `ROOM_FULL` internally; production
  must expose a stable protocol error code before closing.

## Discovery and fallback

Preferred discovery is mDNS/Bonjour `_heartrate._tcp`; the short code maps to a
Relay address. This skeleton contains an explicit unimplemented discovery
boundary, not fake results. Manual input accepts a domain or IP with optional
port, plus `ws://` or `wss://`. Missing port defaults to 8765 for `ws` and 443
for `wss`.

UDP multicast is not on the data path. mDNS failure does not affect manual join.
A Relay restart creates a new room epoch in production; sequence/epoch semantics
remain a pre-production task to prevent stale clients joining the wrong room.


## 房间生命周期（server 0.6.0 / client 0.5.6）

### 加入即创建

客户端带 `?room=<短码>` 升级 WebSocket 时：

- 房间**不存在 → 立即创建**，该客户端成为首个成员（日志 `room_created reason=first_join`）；
- 房间存在 → 直接加入，只取消空闲计时，**成员表、序号、在线状态一概不动**。

**没有"房间不存在 → 拒绝"这条分支。** 唯一的拒绝条件是房间码格式
（`^[A-Za-z0-9_-]{1,64}$`，不合法返回 400）和容量（成员数达到上限返回 `ROOM_FULL`）。

### 三个阈值各自管什么（不要混淆）

| 阈值 | 触发条件 | 后果 | 可配置 |
|---|---|---|---|
| **5 秒** `OFFLINE_TIMEOUT_MS` | 成员 `lastSeen` 超过 5s 没有有效上报 | 该成员 `online=false`（房间还在、成员还在） | 环境变量 |
| **1 分钟** `IDLE_ROOM_TIMEOUT_MS` | 房间**零 WebSocket 连接**持续 1 分钟 | 销毁房间对象与成员表，释放内存 | 环境变量 |
| **2 分钟** `REMOVE_TIMEOUT_MS` | 成员 `lastSeen` 超过 2 分钟 | 把该成员从成员表移除（房间仍存在时才有意义） | 固定值 |

**"无人"的口径是 `sockets.size === 0`（没有任何 WebSocket 连接），不是
`online=false`。** 这很重要：一个房间里有人连着但心率带断了，成员会在 5 秒后
`online=false`，但房间**不会**因为"看起来没人"而被回收。

三者的关系：

- 房间只要还有一条连接，就永远不会被 1 分钟回收；
- 最后一条连接断开后开始计时，1 分钟内有人回来 → 沿用原房间（成员、序号原样）；
- 超过 1 分钟 → 房间连同成员一起销毁，下次连接是全新房间；
- 2 分钟移除只在"房间还活着"时起作用（例如 A 断开、B 还连着，A 的成员记录在 2 分钟后被清掉）。

### 与客户端重连的关系

客户端自动重连（0.3.3 起）在 1 分钟窗口内回来时，服务端按 `memberId` 复用成员，
序号继续递增，不会出现"重复成员"。超过 1 分钟窗口后回来，房间已是新的，
客户端按首次加入处理（成员身份仍由同一个 `installId` 决定）。

### 部署

阈值通过环境变量注入，默认值即上表；改完需要重新部署容器才会生效：

```
OFFLINE_TIMEOUT_MS=5000      # 5 秒离线
IDLE_ROOM_TIMEOUT_MS=60000   # 1 分钟回收
ROOM_LIMIT=20                # 20 人上限
```

`GET /healthz` 的 `config` 字段会回显这三个值，便于确认线上跑的是哪套参数。
