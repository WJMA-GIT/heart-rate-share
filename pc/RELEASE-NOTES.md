# 共享心率 v1.0.15

## 三个资产怎么选

| 资产 | 适用场景 |
|---|---|
| `heartrate-pc-1.0.15-win-x64-selfcontained.exe`（~69 MB） | **推荐**。自包含 .NET 8 运行时，双击即用，不装任何东西 |
| `heartrate-pc-1.0.15-win-x64-framework-dependent.exe`（~25 MB） | 电脑已装 **.NET 8 Desktop Runtime**；未装会弹系统提示（不是闪退） |
| `heartrate-1.0.15-arm64-v8a-release.apk` | 安卓手机（arm64），versionCode **1002117**，可覆盖安装 |

## 两版对比（实测于 GitHub Windows runner）

| | 自包含 A | 依赖运行时 B |
|---|---|---|
| 体积 | ~69.3 MB | ~25.0 MB |
| 需要 .NET 8 Desktop Runtime | 否 | 是（未装会弹提示） |
| 启动耗时（到窗口可见） | **1299 ms** | **510 ms** |

> B 压不到 10 MB 的原因：蓝牙所需的 WinRT 投影 `Microsoft.Windows.SDK.NET.dll` 单文件就有 24.9 MB，
> 且 WPF 不支持 `PublishTrimmed`。

## 本次更新

- **Android**：新增深色模式 —— 设置 → **外观** → 跟随系统 / 浅色 / 深色（默认跟随系统，选择会记住）。
- **Windows**：全新 WPF 客户端，两条数据通路（蓝牙直连 / 局域网手机投射）+ 云端房间；
  悬浮窗透明置顶、可拖动、字号 24–96、可选点击穿透；日志在
  `%LOCALAPPDATA%\HeartRateShare\logs\app.log`（1 MB × 3 轮转）。

## 未验证的部分（重要）

**云端通路未在 CI 验证**：构建环境（沙箱与 GitHub runner）都连不上 `heart.mawj.asia:10086`，
很可能是因为该域名只解析到公网 IPv6 而 CI 没有 IPv6 出口。请在你自己的 PC/手机上验证云端房间；
若失败请把报错发回。

安装提示：旧版直接覆盖安装即可；若界面仍是旧版，先卸载再装，或删掉
`%LOCALAPPDATA%\heartrate` 与 `%LOCALAPPDATA%\HeartRateShare` 后再启动。
