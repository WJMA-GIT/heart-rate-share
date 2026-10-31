# 分支模型（三条长期分支）

| 分支 | 谁推 | 用途 |
|---|---|---|
| `main` | 线 A（发布人） | **只做整合与发布**：合并 `android`/`windows`、打 tag、建 Release、推镜像 |
| `android` | 线 A | 安卓与共享 Dart 层（`lib/**` 除 `lib/ui/win/**`、`android/**`、`test/**`） |
| `windows` | 线 B | Windows 原生与桌面 Dart（`windows/**`、`lib/ui/win/**`、`lib/main.dart` 的 Windows 分支） |

## 流程
1. 各自在自己分支上提交，**不要跨线改文件**。
2. 完成后由线 A 合并进 `main`：`android` → `main`、`windows` → `main`。
3. 合并方式：**逐 hunk / 逐文件合并，禁止整份覆盖**。冲突时按"文件所有权"解决：
   `windows/**`、`lib/ui/win/**` 归线 B；其余归线 A。
4. 合并后必须校验关键实现仍在（防覆盖丢代码）：
   - `WS_THICKFRAME` + `WM_NCHITTEST`（窗口可拖边缩放）
   - `HEARTRATE_PREVIEW`（mock 连接态开关）
   - `::swscanf_s`（window_state 读取，`std::` 下没有）
   - `lib/ui/win/win_app.dart` 中无 `version: 'x.y.z'` 字面量（版本走 `AppVersion.read()`）
5. 回归：`dart format` → `flutter analyze`（0 issue）→ `flutter test`（全量）→ Windows release 构建
   → 单文件 loader 冒烟（三模式 + 最小目录 + 冷/热启动 + 载荷截断）→ `windows-preview-smoke` 绿。
6. 发布：只有 `main` 能打 tag。
   ```
   tag vX.Y.Z → 资产仅 heartrate-X.Y.Z-arm64-v8a-release.apk + heartrate-X.Y.Z-windows-x64.exe
   ```

## 自动化
- `branch-hygiene.yml`：push 到 main 或每周一自动删除**已合并进 main** 的临时分支；
  未合并的分支只告警不删（避免丢代码）。
- `main` 受分支保护：禁止 force push、禁止删除。

## 工具链版本（避免格式化/编译漂移）
- 版本锚点在仓库根的 **`.fvmrc`**（当前 `3.47.8`）。本地用 `fvm use`（或直接安装同一版本），
  CI 用 `subosito/flutter-action` 的 `flutter-version-file: .fvmrc` 读同一个文件。
- 提交前本地跑：
  ```
  dart format --set-exit-if-changed lib test
  flutter analyze   # 0 issue
  flutter test      # 全量
  ```
- CI 的 format 门禁会先格式化再比对 `git diff`，文件名直接打在日志里（旧写法只说"1 file changed"）。

## 发版前必查（两次踩坑固化）
1. **回读远端 pubspec.yaml**：push 后必须 `gh api .../contents/pubspec.yaml?ref=main` 确认 `version:` 已是目标值。
   只上传变更文件的推送脚本可能判定该文件"未变"，导致打出的包版本号落后一版。
2. **版本号在同一 job 内解析**：CI 不要跨 job 传 `outputs` 取版本（曾出现 1.0.11/1.0.12 串号）；
   每个用到版本的 job 自己从 `pubspec.yaml` 解析并打印。
3. **版本锚 `​.fvmrc` 必须是合法 JSON**（`{"flutter":"3.47.8"}`）：裸文本会让
   `subosito/flutter-action` 的 jq 解析失败，CI 8 秒红且 quality 从未执行（假红）。
