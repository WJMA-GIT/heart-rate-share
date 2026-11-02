# 构建与发布：本地只写代码，产物一律由 CI 产出

> 用户明确要求：「编译全交给 GitHub 来编译啊，你只需要写代码就是了」。
> 本地不安装 JDK / Android SDK / NDK / .NET SDK，也不产出任何二进制。

## 本地能做

```bash
dart format lib test
flutter analyze        # 0 issue
flutter test           # 全量
```

跑不了（缺 SDK）就交给 CI 的 `quality` job 兜底——它跑同三条命令。

## 必须走 CI（本地禁止）

| 产物 | 谁构建 | 触发 |
|---|---|---|
| `heartrate-<ver>-arm64-v8a-release.apk` | `ci` → `android` | push 到 `main` 或打 tag |
| `heartrate-pc-<ver>-win-x64-selfcontained.exe` | `windows-pc` | push 到 `main`/`windows` 命中 `pc/**`，或 tag |
| `heartrate-pc-<ver>-win-x64-framework-dependent.exe` | 同上 | 同上 |

本地禁止：`flutter build apk`、`flutter build windows`、`dotnet publish`、手工 `gh release upload`。

## 发布（tag 驱动）

1. `main` 合并齐，`ci` + `windows-pc` 双绿；
2. 打 tag；同版本名重建时用 `PATCH git/refs/tags/<tag> -f force=true` 重指——
   **不要 delete+create**（会把 Release 变 untagged，直链 404）；
3. tag 触发 `windows-pc` 在 runner 上 `gh release upload --clobber`；`ci` 的 release job 管 APK；
4. 核对：`gh api .../releases/tags/<tag>` 的 asset size 与 CI 日志 `uploading ... (NNNN bytes)` 一致，
   再 `curl -I -L` 三个直链确认 200。

## 失败怎么看

`gh run list --limit 10` → `gh run view <id> --log-failed | sed 's/^[^\t]*\t[^\t]*\t//' | tail -50`。
常见坑：`.fvmrc` 必须是合法 JSON；无 `checkout` 的 job 里 `gh` 要显式 `--repo`；
`.rc` 先用 `rc.exe` 编成 `.res` 再链接（否则 `LNK1107`）。
