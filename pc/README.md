# 共享心率 · Windows 桌面客户端（C# / .NET 8 + WPF）

替换原来的 Flutter Windows 目标：目标是**一个自包含单文件 exe**，双击即用。

## 构建

```powershell
dotnet publish pc/HeartRateShare.Desktop -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -o pc-out
```

产物：`pc-out/HeartRateShare.exe`（CI 会把体积/哈希/首启耗时打在日志里，见 `.github/workflows/windows-pc.yml`）。

## 参数

- `--mock`：不连任何设备，注入 3 个假成员（CI 截图与冒烟用）。

## 目录

```
pc/HeartRateShare.Desktop/
  HeartRateShare.Desktop.csproj   单文件发布配置
  app.manifest                    PerMonitorV2 DPI
  App.xaml(.cs)                   启动 + --mock
  AppState.cs                     Member/Sample/全局状态（数据源往这里写）
  MainWindow.xaml(.cs)            左导航 + 心率/房间/设置
  OverlayWindow.xaml(.cs)         透明置顶悬浮窗（拖动条 + 24px 断开）
```
