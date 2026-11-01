# 共享心率 · Windows 桌面客户端（C# / .NET 8 + WPF）

一个窗口跑完：蓝牙直连 / 局域网投射 / 云端房间，外带一个透明置顶悬浮窗。
**同一个代码库出两个形态，按需选一个下载。**

## 两种分发形态

| | **A · self-contained**（推荐给普通用户） | **B · framework-dependent** |
|---|---|---|
| 文件名 | `heartrate-pc-1.0.15-win-x64-selfcontained.exe` | `heartrate-pc-1.0.15-win-x64-framework-dependent.exe` |
| 体积 | ≈ 69 MB | ≈ 1–2 MB |
| 需要装 .NET | **不需要** | **需要 .NET 8 Desktop Runtime** |
| 首次启动 | 慢一些（会解压到 `%TEMP%\.net`） | 快 |
| 缺运行时的表现 | 不存在此问题 | 弹 .NET 的"缺少运行时/去下载"提示 |
| 适用 | 发给别人、干净机器、不想解释依赖 | 自己机器、已装 .NET 8、在意体积 |

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
