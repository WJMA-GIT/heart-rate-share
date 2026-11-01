# 共享心率 · Windows 桌面客户端（C# / .NET 8 + WPF）

一个窗口跑完：蓝牙直连 / 局域网投射 / 云端房间，外带一个透明置顶悬浮窗。
**同一个代码库出两个形态，按需选一个下载。**

## 两种分发形态

| | **A · self-contained**（推荐给普通用户） | **B · framework-dependent** |
|---|---|---|
| 文件名 | `heartrate-pc-1.0.15-win-x64-selfcontained.exe` | `heartrate-pc-1.0.15-win-x64-framework-dependent.exe` |
| 体积 | ≈ 69 MB | ≈ 25 MB（当前实测，见下） |
| 需要装 .NET | **不需要** | **需要 .NET 8 Desktop Runtime** |
| 首次启动 | ≈1.3 s（会解压到 `%TEMP%\.net`） | ≈0.5 s，更快 |
| 缺运行时的表现 | 不存在此问题 | 弹 .NET 的"缺少运行时/去下载"提示 |
| 适用 | 发给别人、干净机器、不想解释依赖 | 自己机器、已装 .NET 8、在意体积 |

B 当前体积（25 MB）比理论上限（~2 MB）大：publish 走的是
`PublishSingleFile` 的 RID 特定路径，仍把一部分 WPF 程序集打进了 bundle。
功能与依赖要求不受影响（仍然需要运行时、仍然启动更快），下一轮再抠体积。

> A 解压目录是 `%TEMP%\.net\<app>\<hash>`，用户看不到、不写安装目录，退出后可被系统清理；
> 这是 .NET 自包含单文件的固有行为，不是安装包。

## B 形态的前置条件

装 **.NET 8 Desktop Runtime**（不是 ASP.NET 也不是 SDK）：

- 下载页：<https://dotnet.microsoft.com/download/dotnet/8.0> → 选 **.NET Desktop Runtime 8.x · x64**
- 检测是否已装：

```powershell
dotnet --list-runtimes | Select-String "Microsoft.WindowsDesktop.App 8\."
```

没有任何输出就是没装 → B 会弹"需要 .NET"的提示框，装完再双击即可。

## 构建

```powershell
# A 自包含单文件
dotnet publish pc/HeartRateShare.Desktop -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -o pc-out-a

# B 框架依赖单文件
dotnet publish pc/HeartRateShare.Desktop -c Release -r win-x64 --self-contained false `
  -p:PublishSingleFile=true -o pc-out-b
```

CI（`.github/workflows/windows-pc.yml`）会把两个 exe 一起出：先跑单测，再分别 publish，
再把体积/哈希/首启二启耗时/"缺运行时"行为打在日志里，产物在 artifact `win-pc-exes`。

## 参数

- `--mock`：不连任何设备，注入 3 个假成员（CI 截图与冒烟用）。

## 目录

```
pc/HeartRateShare.Desktop/
  HeartRateShare.Desktop.csproj   单文件发布配置（net8.0-windows10.0.19041.0）
  app.manifest                    PerMonitorV2 DPI
  App.xaml(.cs)                   启动 + --mock
  Protocol.cs                     v1 协议 / 房间号 / 0x2A37 flags / UDP 广播 / 成员表
  RoomConnection.cs               WS 客户端（局域网与云端共用）
  Sources.cs                      IHeartRateSource + LanSource + CloudSource
  BleSource.cs                    蓝牙扫描/连接/订阅 0x2A37
  AppState.cs                     全局状态（三条通路都往这里写）
  MainWindow.xaml(.cs)            左导航：心率 / 房间 / 设置
  OverlayWindow.xaml(.cs)         透明置顶悬浮窗
pc/HeartRateShare.Tests/          协议类单测（xunit）
```

## 真机验证清单（交给用户前自己先过一遍）

### 蓝牙（需要一支心率带）
1. 插上/打开蓝牙，戴上心率带（有些带子要贴着皮肤才上电）。
2. 主窗口「心率」→ 点「扫描设备」→ 列表里应出现**广播带 0x180D** 的设备（只列心率设备；想看全部去「设置 → 显示全部蓝牙设备」）。
3. 点该设备「连接」→ 大数字开始跳，顶部显示「当前通路：蓝牙」。
4. 走远一点断开 → 日志里应有 `error: 蓝牙…`；回来重连应能接上。
5. 常见失败：`蓝牙未开启`（去设置开）/ `没有心率服务`（被手机 App 占用）/ `订阅失败`（未配对）。

### 局域网（手机开投射）
1. 手机和 PC 同一个 Wi-Fi（路由器别开 AP 隔离），手机端「投射到局域网」开着。
2. PC「房间」→「发现局域网手机」→ 列表里出现手机（UDP 8771 广播）。
3. 点「连接」→ 回「心率」页看到成员大数字；不行就用「手动连接」填 `手机IP:8770`。
4. 失败排查：Windows 防火墙要允许专用网络；日志 `error: 无法监听 8771`（端口被占）。

### 云端（relay）
1. 「房间」页服务器留默认 `wss://heart.mawj.asia:10086`，房间号留空 → 点「创建/加入云端」会随机生成一个。
2. 记下房间号（「复制房间号」），手机端加入同一个房间号。
3. 双方都能看到对方心率即成功；失败看「设置 → 诊断」里的**最近错误**。

### 悬浮窗
- 连接成功自动出现；左侧 16px 条可拖；右侧 ⏻ 断开；「设置 → 悬浮窗心率字号」24–96 联动。
- 勾「悬浮窗点击穿透」后鼠标会穿透到下层（打游戏时不挡），此时**不能拖也不能点断开**——回主窗口「设置」取消勾选即可恢复。
