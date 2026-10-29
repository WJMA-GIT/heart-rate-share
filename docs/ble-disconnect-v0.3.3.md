# BLE 自动断连：定位、修复与现场取证（v0.3.3）

## 症状

心率带连上后，用户没有做任何操作，链路自行断开且不再恢复；房间里该成员的
心率冻结，5 秒后被判离线。

## 一、定位结论（代码级）

### 已确认

**1）根本没有自动重连 —— 这是「自动断连」最直接的成因**

`lib/ble/heart_rate_service.dart` 只有 `connect()` / `disconnect()` 两个
入口，`lib/ble/flutter_blue_plus_source.dart` 的 `connect()` 是一次性的。
链路断开后传输层把 phase 退回 `idle`，之后**没有任何代码会再尝试连接**，
必须由用户重新「扫描 → 选择设备 → 连接」。所以一次系统侧掉线等于永久离线。

**2）断连回调被静默吞掉（三处叠加）**

| 位置 | 问题 |
|------|------|
| `FlutterBluePlusSource.connect()` | 连接状态监听是在 `await device.connect()` **之后**才挂的。握手期间或 connect 刚返回时的掉线事件完全收不到，phase 会一直停在 `connecting`/`discovering`。 |
| `FlutterBluePlusSource.connect()` 内的监听回调 | 掉线时只做 `copyWith(phase: idle)`：不设 `lastError`、不写 any 日志。导出日志里只有 `HeartRateService._onSnapshot` 的一行 `connection phase=idle`，看不出「断过」。 |
| `measurement.lastValueStream.listen(...)` | 没有 `onError` / `onDone`。而 flutter_blue_plus 的 `lastValueStream` 会过滤 `success == true` 之外的事件，GATT 级通知错误根本冒不出来 —— 数据停了，UI 却以为还连着。 |

**3）Android 侧没有任何后台保护**

`android/app/src/main/AndroidManifest.xml` 声明了 `FOREGROUND_SERVICE` 与
`FOREGROUND_SERVICE_CONNECTED_DEVICE`，但 `MainActivity.kt` 里只有一行 TODO：
**没有 `<service>` 声明，也没有前台服务实现**。targetSdk 36 下，息屏/切后台
后进程按普通后台进程被回收，GATT 链路随之中断 —— 与「没人碰它自己断」吻合。

**4）断连后状态残留，重连路径被自己的清理逻辑拖慢**

掉线后 `_connected` 与 `_notificationSubscription` 都没有清理；下一次
`connect()` 开头调 `disconnect()` 会对**已经断开**的 device 再调一次
`device.disconnect()`。flutter_blue_plus 的 `disconnect()` 会无条件做
「连接/断开最小间隔」竞态规避（`_ensureAndroidDisconnectionDelay`，默认
2000 ms）——如果掉线发生在连接后 2 秒内，重连会先白等最多 2 秒，正好吃掉
Relay 5 秒离线窗口的一大半。

### 待现场验证（需要真机日志才能定性）

- 掉线属于**进程被系统回收**（日志里应能看到 `[app] lifecycle=paused` 之后
  出现新的 `logger initialized` / 会话号变化），还是**GATT supervision
  timeout**（`[fbp]` 原生日志 + `code=gatt_disconnected` 而生命周期无变化）。
- 是否叠加 OEM 省电策略（小米/华为/OPPO 会清掉前台服务之外的一切）。
- 心率带是否被厂商 App 抢占连接（部分 HRS 带只接受单连接）。

## 二、修复内容

1. **自动重连监督器**（`lib/ble/heart_rate_service.dart`）
   链路在 `subscribed` 之后掉回 `idle`，按 `ReconnectPolicy` 退避重连；
   用户主动 `disconnect()` 后不再重连；连续失败用尽配额进入
   `reconnectFailed` 并给出中文提示。
2. **退避参数按 Relay 窗口反推**（`lib/ble/reconnect_policy.dart`）
   等待 0.5s → 1s → 1.5s → 2s 封顶（上限远小于 `AppConfig.offlineAfter`
   的 5 秒），最多 12 次；重连单次连接超时 6 秒（手动连接仍是 15 秒）。
3. **传输层如实上报**（`lib/ble/flutter_blue_plus_source.dart`）
   - 先挂 `connectionState` 监听再发起连接；
   - 用 `_linkUp` 区分「订阅初始值」和「真的掉线」，避免把未连接误判为掉线；
   - notify 流补 `onError` / `onDone`；
   - `connect()` 返回后校验 `device.isConnected`；
   - 失败日志带 `stage=connect|discover|subscribe`；
   - 接上 `FlutterBluePlus.logs` 原生日志（带 133 之类系统错误码）；
   - 只在 `device.isConnected` 为真时才调 `disconnect()`。
4. **Android 前台服务**（`BleKeepAliveService.kt` + `HrsForeground`）
   链路可用期间以 `connectedDevice` 类型前台服务把进程钉住，断连即停止。
   服务不碰 BLE，失败只记 `fg_unavailable` 一行日志，不影响采集。
5. **可筛选的日志**（`AppLogger`）
   `debug/info/warn` 增加可选 `code` 参数，导出日志的 `code=` 字段可直接
   grep：`connect_start`、`hrs_subscribed`、`gatt_disconnected`、
   `notify_error`、`notify_closed`、`reconnect_scheduled`、
   `reconnect_attempt`、`reconnect_ok`、`reconnect_exhausted`、
   `notify_unverified`、`fg_unavailable`。另加 `[app] lifecycle=...`，
   用来判断掉线时 App 处于前台、息屏还是后台。

## 三、行为变化（升级需知）

- 新增两个连接阶段：`reconnecting`（正在自动重连）、`reconnectFailed`
  （自动重连失败，请手动重连），界面文案随之更新。
- 采集期间会出现一条常驻通知「正在采集心率」（前台服务）。断开连接即消失。
- 自动重连的单次连接超时是 6 秒，短于手动连接的 15 秒。
- **Relay 协议版本不变（仍为 1）**，消息字段、1 Hz 上报、5 秒离线判定均未改动。

## 四、已知未修（需要协议变更，本次不动）

Relay 的离线判定只看心率上报（`RelayStore.prune` 比较 `lastSeen`，而
`RoomClient` 的 ping 不带心率、`RelayStore.rename` 也不刷新 `lastSeen`）。
所以若重连耗时超过 5 秒，房间内该成员会先显示离线再恢复。彻底消除需要协议
v2 让 ping 也刷新 `lastSeen`，属于协议变更，本次不做。

## 五、复现需要的现场信息

1. **断连间隔**：连接后多久断？固定值（30 秒 / 2 分钟）还是随屏幕熄灭？
   断开后是否从不恢复（旧版本），还是自己接回来了（v0.3.3）？
2. **当时界面状态**：前台亮屏 / 息屏 / 切到后台 / 锁屏。
3. **设备信息**：心率带型号（如 Polar H10、Garmin HRM-Dual、Coospo H6）、
   手机型号与 Android 版本、是否有厂商省电/后台清理设置。
4. **导出日志**：设置 → 调试诊断（先打开）→ 分享日志。按 `code=` 过滤，
   重点看 `lifecycle=`、`gatt_disconnected`、`notify_*`、`reconnect_*`。
5. **是否同时开着心率带厂商 App**，或另一台手机也连着同一根带子。
