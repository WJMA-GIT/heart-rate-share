# Windows 桌面版（PC）下载说明

同一份代码，两个形态，**按自己的机器选一个**：

| 选哪个 | 文件 | 体积 | 需要装 .NET 8 吗 |
|---|---|---|---|
| 我不确定 / 发给别人 | `heartrate-pc-1.0.15-win-x64-selfcontained.exe` | ≈ 69 MB | 不需要 |
| 我机器已装 .NET 8 / 在意体积 | `heartrate-pc-1.0.15-win-x64-framework-dependent.exe` | ≈ 1–2 MB | **需要** .NET 8 Desktop Runtime |

- **自包含版**：双击即用；首次启动稍慢（会在 `%TEMP%\.net` 解一次原生库，用户不可见，不是安装）。
- **框架依赖版**：体积小、启动快，但没装运行时会弹"缺少 .NET"的提示。
  下载：<https://dotnet.microsoft.com/download/dotnet/8.0> → **.NET Desktop Runtime 8.x · x64**。
  检测：`dotnet --list-runtimes | Select-String "Microsoft.WindowsDesktop.App 8\."`

两版功能完全一致：蓝牙直连心率设备 / 局域网投射手机 / 云端房间，外加透明置顶悬浮窗。
