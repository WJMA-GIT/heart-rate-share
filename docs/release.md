# 发版手册（一次性发，不按单发）

> 纪律（2026-10-31 起）：**改动先攒着**。平时只做"改代码 → 跑测试 → 推到 main"，不建 Release、
> 不打版本 tag、不推镜像。只有收到明确的「发布」指令，才按下面 5 步走一次，一次把攒下来的
> 全部发出去。
>
> 为什么 CI 也这么改：`docker-publish.yml` 原来挂在 `push: main`（命中 `server/**` 就覆盖
> `latest`），等于"改一行服务端就发一版"。现在**只允许手动触发**，闸门交给这条纪律。

## 发布前检查

- [ ] 待发布清单（工作区 `generated/release/pending.md`）已全部完成并通过测试
- [ ] `flutter analyze` / `flutter test` / `npm test`（server）本地全绿
- [ ] 没有改协议、1 Hz 上报、5 秒离线判定、20 人上限、闲置回收、保活、证书校验
- [ ] 若动了 compose / 环境变量 / 数据目录：在清单里写清用户要不要改 compose、要不要重启

## 五步发布

```bash
# 1) 版本号：App 与服务端各一处（都是单一真源）
#    App:      pubspec.yaml      version: 1.0.2+1000102   → arm64 versionCode 1002102（必须大于上一版的 versionCode）
#    服务端:    server/package.json  "version": "0.3.0"（有行为变化升 minor，只修 bug 升 patch）

# 2) 推 main（只跑测试与构建检查，**不会**产生 Release、不会推镜像）
git push origin main

# 3) 服务端镜像（仅当 server/ 有改动时；手动触发，推唯一 tag latest）
gh workflow run docker-publish.yml --repo WJMA-GIT/heart-rate-share -f release="1.0.2 / 服务端 1.0.2"
gh run watch --repo WJMA-GIT/heart-rate-share $(gh run list --repo WJMA-GIT/heart-rate-share \
  --workflow docker-publish --limit 1 --json databaseId --jq '.[0].databaseId')

# 4) App 发布：打 tag → CI 自动建 Release 并上传 APK（质量门 + 冒烟通过才会发）
git tag v1.0.2
#    注：`git push` 在本机对 github 会卡死（TLS reset），实际用 Git Data API 建 tag 引用：
#    gh api repos/WJMA-GIT/heart-rate-share/git/refs -X POST \
#      -f ref=refs/tags/v1.0.2 -f sha=<main 的提交号>

# 5) 验收（贴进报告）
gh release view v1.0.2 --repo WJMA-GIT/heart-rate-share --json assets \
  --jq '.assets[]|"\(.name) \(.size)"'
# 下载 arm64 包实读 versionCode / 签名（必须与前版逐位相同）
aapt2 dump badging heartrate-1.0.2-arm64-v8a-release.apk | head -1
apksigner verify --print-certs heartrate-1.0.2-arm64-v8a-release.apk | grep SHA-256
# 服务端三处同源：--version == /healthz == 首条日志
docker run --rm --entrypoint node mawjgit/heart-rate-share:latest src/index.js --version
curl -s http://127.0.0.1:8765/healthz | head -c 200
docker exec heart-rate-relay sh -c 'head -n 1 /app/logs/relay.log'
```

## 版本号规则

| 位置 | 唯一真源 | 何时改 |
|---|---|---|
| App | `pubspec.yaml` 的 `version: X.Y.Z+NNNN` | 每次发版都改；`+NNNN` 递增 → versionCode = abiCode×1000 + NNNN（arm64=4xxx） |
| 服务端 | `server/package.json` 的 `version` | 行为/接口变化升 minor，只修 bug 升 patch；镜像永远只有 `latest`，版本靠这个文件 |

## 不要做的事

- 不要为单条需求打 tag / 建 Release / 推镜像；
- 不要在同版本号上覆盖重建资产（已发的 1.0.1 就留着）；
- 不要恢复 `sha-*` / `v*` 镜像 tag，也不要让 `latest` 绑到 tag 上；
- 需要真机才能验证的改动（例如安装器弹窗），按待发布清单标注"需真机验收"，**不要**为了验证单独发版。
