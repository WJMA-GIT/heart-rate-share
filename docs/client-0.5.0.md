# 客户端四项改造 + IPv6 连通（0.5.1）

版本 0.5.1+12（0.5.0 为四项改造，0.5.1 追加 IPv6/多地址回退/失败诊断）。协议仍为 v1：1 Hz 上报、5 秒离线判定、20 人容量、消息字段全部未动，
服务端代码零改动。

## 需求一：默认服务器 + 地址不露出

| 决策 | 实现位置 |
|---|---|
| 官方服务器固定 `wss://mawj.asia:8766` | `lib/core/config/app_config.dart`（`officialServerHost/Port/Secure`） |
| 主界面只显示「官方服务器」一行 + 一个按钮（连接/切换） | `lib/ui/pages/heart_rate_page.dart#_officialServerRow` |
| 地址只在设置页露出 | `lib/ui/pages/settings_page.dart#_serverTile` |

按钮行为：未连接且最近记录里有官方房间号 → 直接连；否则切到房间页去选/填。
主界面任何位置都不渲染 host:port。

## 需求二：建房流程与本地持久化

**取消默认本机房间。** `AppState` 启动时 `_mode == null`、`_relay == null`
（`test/app_state_test.dart` 第一条用例锁死这一点），必须先选：

- `connectProfile(官方/远程)` → 先停本机 relay（两者互斥）→ 连接 → 记入最近列表；
- `createLocalRoom()` → 起 `RelayServer` → 自己连 `ws://127.0.0.1:<端口>`（显式一键，
  原来要用户手填 127.0.0.1）。

**配置持久化**（`lib/core/profile/connection_profile.dart`）：

```dart
ConnectionProfile { mode(official|remote|local), host, port, secure, roomCode, lastUsedAt }
```

- 主键 `id`：官方/远程按 `mode|scheme://host:port`，本机固定 `local`
  —— 本机端口每次启动都变，不能让它把最近列表刷成一堆无效项。
- 最近列表：`RecentProfiles.touch()` 去重置顶 + 最多 6 条；`encode/decode` 容忍脏数据
  （单条坏了跳过，不让整份列表消失）。
- **统一存储层**：所有键都走 `IdentityStore`（`lib/core/profile/install_identity.dart`），
  即 v0.4.0 身份任务那套 `SharedPreferences`：
  `identity.installId`、`room.reservedSequence`、`connection.recentProfiles`。
  **没有第二套存储。**

界面（`lib/ui/pages/room_page.dart`）：房间号输入 → 「连接官方服务器 / 在本机创建房间」
二选一按钮 → 「最近连接」卡片列表（点一下即连，右侧 ✕ 删除这条记录）→
「高级：手动填写地址」折叠区（ws/wss 都支持，沿用 `RoomAddress` 解析）。

## 需求三：wss 与证书

`lib/room/room_transport.dart`：

- `openRoomChannel()`：`ws` 走默认实现；`wss` 且**未配置指纹**时同样走默认实现，
  即 **dart:io 的系统 CA 校验**（域名匹配 + 链校验 + 有效期）。
  **没有任何 accept-all 开关**。
- 自签证书场景：构建时 `--dart-define=CERT_SHA256=<指纹>` 钉住一张明确的证书。
  `HttpClient.badCertificateCallback` 里比对 DER 的 SHA-256，匹配才放行，
  不匹配直接失败并标记 `certificatePinnedMismatch`。
  取指纹：`openssl x509 -in server.crt -noout -fingerprint -sha256`。
- 错误分类 `classifyRoomError()` → `RoomErrorCode`：`certificateUntrusted` /
  `certificatePinnedMismatch` / `tlsHandshake` / `dnsFailure` /
  `connectionRefused` / `connectionTimeout` / `handshakeRejected` / `unknown`，
  写进日志（`code=...` + 端点）并在界面用中文提示（`Zh.roomErrorCode`）。
  **证书错误与网络错误在日志与 UI 上都能一眼分开。**
- 本机房间固定 `ws://127.0.0.1:<端口>`，不做加密（不出网）。

## 需求四：设备列表与视觉

- 设备从下拉框改成列表卡片（`heart_rate_page.dart#_deviceCard`）：
  每行显示设备名、`RSSI -52 dBm`、标识（MAC/UUID），右侧「连接」按钮；
  **点整行也能连**；已连接的那行高亮并显示「已连接」。
- 两个操作区分开：`⋮` 菜单 →「断开连接」（保留在列表里，可再点连接）/
  「从列表移除」（`HeartRateService.forget()` → `FlutterBluePlusSource.forget()`，
  若是当前设备先断开，再从 `_devices` 与快照里移除）。
- 视觉：`lib/ui/widgets/heartbeat_ecg.dart`，纯 `CustomPainter` + `AnimationController`
  画 ECG 网格与 P-QRS-T 波形，扫速由 BPM 驱动（60000/BPM，夹在 400–1600 ms）；
  **无数据或无连接时停止 controller**，只画静止待机基线，不空转耗电。
  心跳图标为 Material 内置 `Icons.favorite`，**没有引入任何图片素材或动效依赖**
  （本运行时也没有配置图片生成工具；用绘制实现反而更小、更省电）。

## 与现有架构的冲突（已处理，不硬塞）

1. **本机房间与远程房间状态机不同**：本机是「进程内起 Relay + 自己当客户端」，
   远程是纯客户端。两者不能并存，因此 `AppState` 引入显式 `ConnectionMode`
   并在 `connectProfile` 里先 `stopRelay()`；`createLocalRoom` 先
   `room.disconnect()` 再起服务。`currentRoomCode` 仍按「客户端房间号优先、
   否则本机 relay 房间号」取，避免本机房间 UI 显示旧房间号。
2. **本机端口每次不同**：所以本机配置的 `port` 存 0、`id` 固定 `local`，
   连接时才用 `relay.port` 覆盖，不污染最近列表。
3. **`AppState.dispose()` 的 use-after-dispose**：改造中测试暴露的旧问题——
   异步 `stopRelay()` 在 dispose 之后调 `notifyListeners()` 会命中
   ChangeNotifier 断言。已加 `_disposed` 守卫（`_notify()`）。

## 测试

`flutter test` **73 项全过**（新增 19 项）：
- `connection_profile_test.dart`：官方默认 wss/8766、本机 id 稳定、`toUri` 房间号与
  `/ws`、JSON 往返、最近列表去重置顶/上限 6/脏数据容错、与 installId 共用同一 store
  的重启读回。
- `room_transport_test.dart`：证书错误 vs 网络错误分类（含指纹不匹配、TLS 握手失败、
  DNS、拒绝、超时、WebSocket 升级失败）、`RoomTls` 默认不钉证书与指纹归一化。
- `app_state_test.dart`：启动不建本机房间、本机房间显式创建并连上自己、
  最近列表落盘且重启后仍在、删除记录落盘。
- `heart_rate_devices_test.dart`：设备列表暴露名称/RSSI/标识、点击连接与断开、
  移除当前设备先断开再从列表消失、移除未连接设备不触发断开。
- 既有 54 项（BLE 重连/通知重订阅/身份/序号/Relay）全部保持通过。

`dart format` / `flutter analyze` 干净。


---

# 追加：IPv6 连通、多地址回退、失败诊断（0.5.1）

背景：目标服务器是家庭 NAS + 家宽，**只有公网 IPv6**，`mawj.asia` 只有 AAAA
记录（这是正常的，不是配置错误）。上一轮现场把 `Failed host lookup` 当成断连原因
追偏过，所以这次把"能不能连、卡在哪一步"做成可读、可复制的。

## 实现（`lib/room/room_endpoint.dart`）

1. **自己解析地址**：`resolveHost()` 先用 `InternetAddress.tryParse` 认字面量
   （IPv6 字面量不走 DNS），否则 `InternetAddress.lookup()` 拿**全部** A/AAAA。
   没有任何"只取第一条""默认 IPv4"的假设。
2. **逐地址快速回退**：`connectFirstAvailable()` 依次尝试，每个地址单独限时
   （默认 4 秒），首选失败立刻换下一个，并把每次结果记进诊断。
3. **保住 TLS 校验目标**：用 `HttpClient.connectionFactory` 自己建 socket，
   请求 URI 仍然是最初的域名 —— SNI 与证书校验依旧针对 `mawj.asia`，
   不会因为"先连 IP"而变成对 IP 校验（那样会一证书失败就全盘连不上）。
4. **IPv6 字面量方括号**：`RoomAddress.bracket()` / `ConnectionProfile.endpoint`
   统一处理；`Uri` 构造本身会给 host 补括号，手拼字符串的地方全部改走这两个入口。
   裸 `::1` 这种输入会自动补成 `ws://[::1]`。
5. **新增错误码 `ipv6Unreachable`**：只有 IPv6 地址且所有尝试都是
   `Network is unreachable` / `Address family not supported` / `Cannot assign
   requested address` 时归到这里，中文提示明确指向"当前网络不支持 IPv6"。

## 四种必须区分的中文提示（`Zh.roomErrorCode`）

| 场景 | 文案要点 |
|---|---|
| 当前网络不支持 IPv6 | 「这台服务器只有 IPv6 地址（AAAA 记录），请改用支持 IPv6 的网络，或请管理员提供 IPv4 入口」 |
| DNS 解析失败 | 「域名解析失败：找不到服务器地址」 |
| 连接超时 | 「连接超时：服务器没有响应，请检查 IPv6 是否可用、端口是否开放」 |
| TLS 证书错误 | 分「未通过系统 CA 校验」与「与内置指纹不一致」两句 |

用户界面不会出现 `Failed host lookup`、`SocketException` 这类原始文本；
原始细节在「诊断信息」里（`RoomDiagnostics.toClipboardText()`：端点、解析到的
每个地址及家族、逐地址结果与耗时、最终归类），可一键复制。

## 官方服务器那一栏

仍然只显示「官方服务器」+ 按钮，不露地址；失败时先给一句中文原因，
SnackBar 上带「诊断」→ 弹窗展示可复制的诊断信息（同一份也会进导出日志）。
最近连接列表同样改用友好命名：官方服务器 / 本机房间 / 自定义服务器，
IP 与端口只在「连接详情」弹窗里出现。

## 测试

`flutter test` **82 项全过**（新增 9 项）：
- `connectFirstAvailable`：首选失败立刻换下一个、单地址超时不拖住后面、全失败抛最后错误。
- `resolveHost('::1')`：字面量直接解析不走 DNS。
- `RoomDiagnostics`：IPv6 端点方括号、复制文本含 result/resolved/attempt。
- `RoomAddress`：`[::1]:8766`、裸 `::1`、`wss://[2001:db8::5]:8766` 解析与格式化。
- `ConnectionProfile`：IPv6 字面量端点与 `toUri` 带方括号。
- **端到端**：在本机 `::1` 上起真实 Relay，经 `ws://[::1]:<port>/ws` 连上并收到 `welcome`
  （无 DNS、无 IPv4 路径），验证连接工厂 + 升级 + 握手链路。
