# 房间成员身份：方案对比与落地（0.4.0）

## 问题

用户关掉 App 再打开、重新加入同一房间，服务端把它当成**新成员**：成员数 +1，
旧成员滞留 2 分钟才移除（"幽灵成员"）。

根因在客户端：`RoomClient` 的 `memberId` 由 `RoomIdentity.memberId()` 在**构造时随机生成**
（`lib/room/room_identity.dart`），只活在内存里，进程一退就没了。服务端本来
就是按 `memberId` 认人的（`server/src/relay.js` 的 `room.members` / `room.sockets`
都以它做 key，`hello` 里还已经有"同一 memberId 重连就替换旧连接"的逻辑），
**缺的只是客户端把这个值持久化下来。**

另一个必须一起修的点：**上报序号**。服务端对同一 memberId 只接受严格递增的
`sequence`（`Room.accept` 里 `report.sequence <= previous.report.sequence` 直接丢弃），
而 `RoomClient._sequence` 每次启动从 0 开始。身份一旦稳定而序号不持久化，重启后
上报会被持续当成旧包丢弃：成员看着在线、数据却停着，直到序号追过上一个进程
（1 Hz 下可能要十几分钟）。所以序号必须和身份一起持久化。

## 一、三种做法

### a. 客户端安装标识（installId）—— 本版采用

**实现**：首次启动生成 UUID v4 → `SharedPreferences` 持久化 → 之后每次 `hello`
都用它作为 `memberId`。服务端按 `memberId` 复用成员（已有逻辑），并补一条
"成员仍在线时顺延 lastSeen"的规则，避免快速重连被判离线再复活。

**优点**
- **零协议变更**：`hello.memberId` 字段本来就有，只是以前填的是随机值。
- 零服务端存储、零数据库，重启服务端后房间状态照旧（本来就是内存态）。
- 纯局域网可用，不依赖外网、不依赖账号。
- 实现面最小：一个持久化键 + 一处构造注入 + 序号持久化。

**缺点**
- 不能跨设备（本身就是设计目标，见"边界 2"）。
- 清数据/重装即新身份。
- **不是凭证**：ws:// 明文，谁拿到这个字符串都能顶替该成员。它只解决"去重"，
  不解决"防冒充"。

**协议影响**：无（v1 不变）。旧客户端继续发随机 ID，行为与现在一致；新客户端
连旧服务端也能复用成员（旧服务端已按 memberId 存成员并替换旧连接），只是少了
`lastSeen` 顺延这一处优化。

**迁移**：完全向后兼容，无需协议协商。升级后第一次进房会遇到一次
`member_new`（因为旧版本从没持久化过 ID，本地是空的），之后就一直稳定。

### b. 服务端签发成员 ID + 恢复凭证（token）

**实现**：`hello` 不带 token → 服务端新建成员并回 `welcome{memberId, token}`；
客户端持久化 token；下次 `hello` 带 token，服务端校验后恢复该成员（含
displayName、sequence）。token→memberId 映射存服务端内存（重启即失效）。

**优点**
- 身份由服务端掌控，可撤销、可审计，能挡"随便报一个 memberId 就顶替别人"。
- 是将来做账号体系（c）的合理跳板。

**缺点**
- **要改协议**：`welcome` 要加 `token`，`hello` 要加可选 `token` 并放宽校验；
  客户端要处理"服务端不认这个 token"的降级路径（重新建成员、重新握手）。
- 在 `ws://` 明文上，token 与 memberId 一样可被窃听，**安全收益接近零**，
  除非同时上 TLS。
- 服务端重启丢 token → 所有客户端降级为新成员，反而制造新的"幽灵成员"。
- 内存里要维护 token 表（虽然不用数据库），测试面明显变大。

**协议影响**：需要新增可选字段（可以做成 v1 的向后兼容扩展，但 `hello` 的严格
校验要放宽，旧服务端遇到带 token 的 hello 需要忽略未知字段）。**服务端要同时
兼容不带 token 的 v1 客户端。**

**迁移**：旧客户端不带 token → 按旧逻辑当新成员；新客户端遇到旧服务端（不返回
token）→ 退化为 a 的行为。

### c. 账号体系（用户名/口令或第三方登录）

**实现**：账号表 + 口令哈希或 OAuth；`memberId` 由 accountId 派生；跨设备同一身份。

**优点**：真正解决"跨设备同一人"，可做权限、踢人、历史数据。

**缺点**：要引数据库、鉴权、口令存储、HTTPS、隐私合规；对一个**局域网心率共享**
工具严重过度设计；而且破坏"断网也能用"的前提（登录要联网）。任务明确要求
不引账号密码存储、不加后端数据库。

## 二、推荐：a（客户端安装标识）

理由，按权重排序：

1. **直接命中现象**：问题就是"重启后 memberId 变了"，a 把变的那一项固定住即可，
   不需要动协议、不需要服务端存储。
2. **在明文 ws:// 上，b 的安全收益接近于零**：token 和 memberId 一样能被同网段
   抓走。先上 TLS 再谈 token 才有意义；顺序反了只是增加复杂度。
3. **零运维**：不引数据库、不引 token 表，服务端重启行为不变。
4. **保留升级路径**：`installId` 就是未来 token 体系里的 `deviceId`。等真的需要
   防冒充时，在 a 之上叠加 b 即可，客户端持久化层不用重写。

## 三、两个边界

### 边界 1：同一部手机重装 / 清数据 → **视为新人**

服务端表现：
- 新 installId → `member_new`，房间成员数 +1；
- 旧成员在 5 秒无上报后 `online=false`（`memberDelta` 广播一次），2 分钟后被移除；
- 因此最多有 **2 分钟** 两条并存（旧的离线、新的在线），随后自动收敛成一条。

为什么不做"恢复"：本地存储是唯一依据，清数据就什么都不剩了。想在这种情况下
恢复身份，只有 b（token 得存在 App 之外）或 c（账号）才可能 —— 都不在本版范围。

### 边界 2：换手机 → **明确不认成同一人**

这不是缺陷，是产品语义：每台手机连自己的心率带，两台设备同时在场就是房间里的
两个成员。为了让"不认"成为显式设计而不是将来被当 bug 报：

1. 字段与类名统一叫 `installId`（不是 `userId` / `deviceId`），
   `lib/core/profile/install_identity.dart` 顶部注释写清"per install, not per user"；
2. 服务端日志区分 `member_new` / `member_resumed`（含 `wasOnline`、`sequence`），
   排障时一眼看出"是换了安装还是同一台重连"；
3. 导出日志里必有 `[identity] install id loaded|created ... device=…xxxxxxxx`
   —— 两台手机的日志比对后 8 位即可确认是不是同一标识；
4. 本文件、`docs/protocol.md`、README 都写明：**跨设备同一身份需要账号体系，不在本版范围**。

## 四、落地要点（代码位置）

| 位置 | 改动 |
|---|---|
| `lib/core/profile/install_identity.dart`（新） | `IdentityStore`（installId + 预留序号）+ `InstallId.generate()/isValid()` + SharedPreferences / InMemory 两套实现 |
| `lib/room/sequence_counter.dart`（新） | 跨启动单调递增的序号：区块预留（默认 60）持久化、`bumpAbove()` 自愈 |
| `lib/room/room_client.dart` | 构造注入 `memberId` 与 `SequenceCounter`；`_nextSequence()`；从快照里看到自己的序号更大时 `bumpAbove`；`dispose` 时 `flush` |
| `lib/ui/app_state.dart` / `lib/main.dart` | 启动时读/建 installId，恢复序号计数器，注入 `AppState` → `RoomClient` |
| `server/src/relay.js` | `hello`：区分 `member_new` / `member_resumed`；成员当前在线时顺延 `lastSeen`（避免 3 秒重连被判离线）；替换旧连接逻辑保持不变 |
| `lib/room/relay_store.dart` / `relay_server.dart` | 同上语义（App 内自建 Relay 与服务端对齐）：`resume()`、替换旧 socket、旧 socket 关闭不再误删新连接登记 |

**序号策略细节**：只在用满预留区块时写盘（默认 60 个/块，1 Hz 下约每分钟一次），
进程被强杀最多浪费一块、绝不回退；另外从服务端快照里看到自己的序号更大时会
`bumpAbove`，覆盖"本地序号被清、从旧备份恢复"这类脏情况。

## 五、协议影响

**不改版本，仍是 v1。** 字段、消息类型、时序、5 秒离线、20 人容量都没变。
唯一的语义变化是客户端把 `hello.memberId` 从一个每次随机值改成稳定值 ——
服务端本来就按它认人，所以旧服务端无需改动即可工作（只是少了 `lastSeen` 顺延）。

## 六、测试

Dart（`flutter test`，54 项全过）：
- `test/install_identity_test.dart`（8 项）：UUID 格式/唯一性、合法性校验、
  重启读回同一标识、清数据得到新标识、序号跨重启不回退、区块越界落盘、
  `bumpAbove` 抬升且不回退、`flush` 落盘。
- `test/relay_store_test.dart`（+3 项）：`resume` 保留心率与序号、只顺延在线成员、
  不把已离线成员凭空点亮、未知成员不新建。
- `test/relay_integration_test.dart`（+1 项）：真实 WebSocket 下"同一安装标识重进
  房间 → 成员表仍 1 条、心率刷新、序号继续递增、仍在线"。

Node（`npm test`，14 项全过）：
- 同一 memberId 重连：旧连接以 4000 replaced 关闭、成员表不新增、socket 只剩一条。
- 重连保留昵称与序号；序号回退的旧包被丢弃（说明客户端为何必须持久化序号）。
- 3 秒内重连不被 5 秒判定打成离线再复活。
- 重装/清数据 = 新安装标识 = 新成员，旧成员 5 秒离线、2 分钟移除。
