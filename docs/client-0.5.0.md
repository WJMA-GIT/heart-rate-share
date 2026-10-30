# 客户端四项改造 + IPv6 连通（0.5.1）

版本 0.5.1+12（0.5.0 为四项改造，0.5.1 追加 IPv6/多地址回退/失败诊断）。协议仍为 v1：1 Hz 上报、5 秒离线判定、20 人容量、消息字段全部未动，
服务端代码零改动。

## 需求一：默认服务器 + 地址不露出

| 决策 | 实现位置 |
|---|---|
| 官方服务器固定 `wss://relay.mawj.asia`（443，不带端口） | `lib/core/config/app_config.dart`（`officialServerHost/Port/Secure` + `DEFAULT_SERVER`） |
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


---

# 追加：官方端点最终确定为 `wss://relay.mawj.asia`（0.5.2）

## 端点

| 项 | 值 | 可覆盖 |
|---|---|---|
| 官方服务器默认 | `wss://relay.mawj.asia`（443，**不显式带端口**） | `--dart-define=DEFAULT_SERVER=wss://...` |
| 备用线路（443 被运营商封时用） | `wss://relay.mawj.asia:8766` | `--dart-define=SECONDARY_SERVER=...` |
| 路径 | `/ws?room=<短码>` | `DEFAULT_SERVER` 带路径时以它为准 |

为什么是 `relay` 子域：家庭 NAS + 仅公网 IPv6，边界由 fn-knock 反代网关终止
TLS；证书是 `*.mawj.asia` 通配、**不含根域**，用 `mawj.asia` 会直接命中
"证书与域名不匹配"。运维侧配置见仓库 `deploy/fnknock-setup.md`。

## 三个必须显式处理的坑

1. **必须带 `wss://`**：`RoomAddress.parse` 对裸主机名默认补 `ws://`（本机/局域网
   的旧行为），明文打到 443 必然失败。所以官方/备用地址统一走
   `SecureEndpoint.parse()`：裸主机名**纠正**为 `wss://`，显式写 `ws://` **直接
   报错**（`RoomAddressError.insecureScheme`），让配置错误立刻暴露。
   另外裸地址带 `:443` 时 `RoomAddress.parse` 也会自动按 `wss` 解析。
2. **房间号先校验再拼**：`^[A-Za-z0-9_-]{1,64}$`（`lib/room/room_code.dart`），
   与服务端 `MAX_ROOM_CODE_LEN=64` 一致。非法值在本地就拦下并给中文提示，
   不会拿 400/404 回来再猜。
3. **400/404 能分辨**：升级失败后会回探一次等价 HTTP（`wss→https`、`ws→http`）的
   状态码 —— 400 →「请求被拒绝，通常是房间号或参数格式不对」，
   404 →「路径或房间号不对（路径应为 /ws，且带正确的 ?room=短码）」，
   其余仍是「反向代理没配 upgrade」。

## 证书提示指向域名不匹配

新增 `RoomErrorCode.certificateHostMismatch`：异常文本含 `Hostname mismatch` /
`certificate is not valid for` 时单独归类，中文提示直接写清
「证书可能是 `*.mawj.asia` 通配，必须用 `relay.mawj.asia` 这类子域访问
（根域不在证书范围内）」——通配证书场景下这是真实高频失败。

## 界面

- 主界面仍只有「官方服务器」+ 按钮，**不露域名与端口**；地址只在设置页显示，
  显示的是 `AppConfig.effectiveOfficialServer`（即实际生效的那个值）。
- 房间页「高级」里保留「切换备用端口（443 被运营商封时用）」按钮，
  点了只是把备用地址填进地址框，**不会自动改默认**。
- 失败提示继续是四类（无 IPv6 / DNS / 超时 / 证书），证书再细分
  「不受信」与「域名不匹配」，都带可复制的诊断信息。

## 构建时实际使用的 define

本次交付的 APK **没有传任何 `--dart-define`**，即全部走代码默认值：
`DEFAULT_SERVER` 未设置 → `wss://relay.mawj.asia`；
`SECONDARY_SERVER` 未设置 → `wss://relay.mawj.asia:8766`；
`CERT_SHA256` 未设置 → 走系统 CA 校验（fn-knock 用的是通配正式证书，不需要钉扎）。


---

# 追加：默认地址定稿 `wss://heart.mawj.asia:10086`（0.5.3）

| 项 | 值 |
|---|---|
| 官方服务器（内置默认） | `wss://heart.mawj.asia:10086`（**必须保留 wss:// 与显式 :10086**） |
| 覆盖 | `--dart-define=DEFAULT_SERVER=wss://heart.mawj.asia:10086` |
| 备用线路 | 默认**不配置**；需要时 `--dart-define=SECONDARY_SERVER=...`，房间页「高级」里的按钮只在配置后出现 |
| 路径 | `/ws?room=<短码>`（`^[A-Za-z0-9_-]{1,64}$`） |

## 端口不能丢

10086 是非标准端口，凡是"看到 443 就省略端口"的写法都会连错服务。当前实现里：

- `RoomAddress.parse` 保留显式端口，只有**没写端口**时才用协议默认值（wss→443）；
- `ConnectionProfile.toUri()` / `endpoint` 只在 `secure && port == 443` 时省略端口，
  10086 一律显式保留；
- 逐地址建连用的是 `uri.port`（本机房间用 `relay.port` 覆盖），不会回落到默认端口；
- 诊断信息 `endpoint=` 同样带端口。

单测覆盖：`wss://heart.mawj.asia:10086` 经解析 / `SecureEndpoint.parse` /
`normalizedEndpoint` / `toUri` / `RoomDiagnostics` 五个层次，端口都必须是 10086。

## 证书判据

证书是 `*.mawj.asia` 通配，`heart.mawj.asia` 在其覆盖范围内 —— 所以正常情况**不应该**
出现证书错误。一旦出现，说明是真实的域名/证书不匹配（或反代换了证书），
提示直接写：

> 服务器证书与访问的域名不匹配（不是网络问题）：证书是 `*.mawj.asia` 通配，
> `heart.mawj.asia` 本应在其覆盖范围内；若报此错，说明反代用的证书与该域名对不上，
> 请联系管理员核对证书与 SNI。

## IPv6 与四类失败提示（不变）

域名解析出 AAAA 正常建连、IPv6 字面量方括号、多地址逐个回退（每地址 4 秒预算）
都不变；失败仍是四类：无 IPv6 / DNS 解析失败 / 连接超时 / TLS 证书错误（证书再分
不受信、域名不匹配、指纹不匹配）。

## 本版构建参数

`flutter build apk --release --split-per-abi --dart-define=DEFAULT_SERVER=wss://heart.mawj.asia:10086`

（`SECONDARY_SERVER`、`CERT_SHA256` 未传，走默认：无备用线路 / 系统 CA 校验。）


---

# 追加：连接诊断能力（0.5.4）

真机反馈：`wss://heart.mawj.asia:10086` 连不上，但诊断只给出 `result=unknown`，
等于没告诉用户原因。本轮先修诊断本身。

## 诊断字段（新增）

`RoomDiagnostics.toClipboardText()` 现在按「原始事实 → 分类」输出：

| 字段 | 含义 |
|---|---|
| `endpoint` / `result` | 端点与最终分类 |
| `tcp_reached` | TCP 是否至少连通过一条（区分"网络不通"与"TLS 之后失败"） |
| `resolved` / `attempt` | 解析到的地址与逐地址结果；每条带 `type=`（原始异常类型） |
| `error_type` / `error_message` | 最终异常的**原始类型与完整 message** |
| `http_probe` | 升级失败后回探等价 HTTP（wss→https、ws→http）的状态与原因短语 |
| `http_location` / `http_redirects` | 3xx 的跳转目标（反代"要求登录"直接可见）；回探用 `followRedirects=false` |
| `http_content_type` / `http_server` / `http_body` | 反代特征（nginx/1.24、`<html>login…`） |
| `tls_cert_subject` / `tls_cert_issuer` | 回探拿到证书 = **TLS 握手已成功**，从而把证书问题和反代问题分开 |
| `http_probe_error` | 回探本身失败时的类型与消息（含"TLS 失败但明文可用"的判定） |

## 分类表（新增）

| 现场 | 新分类 | 提示指向 |
|---|---|---|
| 升级被 3xx | `redirectedToLogin` | 反代要求登录/鉴权，`/ws` 需放行 |
| 回探 401 / 403 | `unauthorized` / `forbidden` | 反代鉴权 / 来源限制 |
| 回探 502 / 503 / 504 | `badGateway` / `serviceUnavailable` / `gatewayTimeout` | 反代到 NAS 的上游不通/超时 |
| 握手期被关闭/重置（`Connection reset by peer`、`Connection closed before full header`、`Connection terminated during handshake`） | `tlsAborted` | 反代不认识该 SNI、或要求客户端证书 |
| 端口返回明文（`WRONG_VERSION_NUMBER`、`HTTP/1.1`、`Illegal request`，或 wss 失败但明文回探有响应） | `plaintextOnTlsPort` | 端口/协议错配，反代未在该端口启用 https |
| 以上都不匹配 | `unclassified` | 兜底，明确要求"把整段诊断发给管理员" |

**`unknown` 已移除**；回探结果优先于异常文本分类，所以"TCP 通、升级失败"不再可能只剩一个标签。

## 回探策略

只要 TCP 通过就一定回探（不再只在 `handshakeRejected` 时回探），并且：
https 回探在 TLS 层失败时，会用**明文 http** 再问同一个 host:port —— 拿到响应即可判定
`plaintextOnTlsPort`。回探不跟随重定向，也不放宽任何证书校验。


---

# 追加：修正 plaintextOnTlsPort 误判 + 新增 redirectLoop（0.5.5）

真机复现（v0.5.4）：

```
result=plaintextOnTlsPort          ← 误判
error_message=WebSocketChannelException: RedirectException: Redirect loop detected
http_probe=http status=307 Temporary Redirect
http_location=https://heart.mawj.asia:10086/ws?room=1
```

能拿到 307 + Location，说明 TLS 早已握手成功；判"明文端口"是错的。

## 两处修正

1. **`plaintextOnTlsPort` 收窄**：只有"真实 wss 连接在 **TLS 层**失败"
   （`HandshakeException` / `TlsException` / `WRONG_VERSION_NUMBER` / 非 TLS 数据）
   且旁路明文探测有响应时才成立。只要收到过 HTTP 响应（`HttpException`、
   `RedirectException`、`HTTP status code: N`），就**绝不允许**判成明文端口。
2. **新增 `redirectLoop`**：异常文本含 `Redirect loop detected` / `RedirectException`，
   或逐跳链路绕回同一 URL 时成立。提示直指反代 Target 填成了自身域名 / 响应类型
   配成了"重定向"。

## 诊断新增

| 字段 | 说明 |
|---|---|
| `root_error_type` / `root_error_message` | 剥掉 `WebSocketChannelException` 外壳后的真正异常（实测：明文端口是 `HandshakeException`，重定向/TLS 成功是 `HttpException`/`RedirectException`） |
| `tls_ok` / `tls_evidence` | TLS 是否成功的**独立判据**：证书 subject、https 回探状态，或"已解析出 HTTP 响应"；不再依赖明文旁路猜测 |
| `http_redirect_chain` | 逐跳链路（`307 url -> loop-> url`），用于证明循环 |

## 明文回探的定位（代码注释已写明）

`probe.scheme == 'http'` 只表示"https 回探没成、明文探测有响应"，它是**旁路探测**，
只能补充说明，**不得覆盖基于真实连接得到的结论**。v0.5.4 的 bug 就是把旁路结果
当成了判定依据。


---

# 追加：房间加入即创建 + 服务端错误可见（0.5.6）

服务端行为核实结论：**`?room=<码>` 本来就是"首次出现即创建"**（`relay.handleConnection`
→ `this.room(code)`，不存在就 `new Room(...)`），代码里没有"房间不存在 → 拒绝"的分支。
本轮实际改的是回收策略与错误可见性：

- 服务端：房间不再"空了立刻删"，改为**零连接持续 1 分钟**才回收（`IDLE_ROOM_TIMEOUT_MS`），
  1 分钟内回来沿用原房间；文档见 `docs/protocol.md` 的「房间生命周期」。
- 客户端：服务端 `error` 消息（`ROOM_FULL` / `SERVER_FULL` / `BAD_MESSAGE`）过去只写日志，
  现在 `RoomClient.lastServerError` 会带出来，房间页直接显示中文提示 —— 房间满员不再是
  「连不上」这种无信息失败。
- 客户端没有"房间不存在"这类提示，也不需要：加入不存在的房间会直接建成。
