# 共享心率 Relay 服务端

把原来的「局域网里一台设备当 Relay」换成一台常驻服务器。协议与客户端 **v1 完全兼容**，
客户端只需把「中继地址」填成这台服务器即可，不用改代码。

- 传输：WebSocket，路径 `/ws?room=<房间短码>`，默认端口 `8765`
- 房间状态：**纯内存**（无数据库）。进程重启后房间清空，客户端重新上报会自动恢复
- 单实例设计：先跑通再加横向扩展（见「扩展」一节）

## 目录

```
server/
├── src/
│   ├── index.js      # HTTP + WebSocket 升级、/healthz、优雅退出
│   └── relay.js      # 房间/成员状态机、快照与增量广播、剪枝
├── test/
│   ├── relay.test.js # 协议回归（假时钟，覆盖 5s 离线 / 2min 移除）
│   └── smoke.js      # 真实时钟烟测：3 客户端 + 5 秒离线判定
├── Dockerfile
├── .dockerignore
├── package.json
└── package-lock.json
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8765` | 监听端口；容器里同时决定宿主机映射端口。`0` = 让内核分配（仅调试） |
| `HOST` | `0.0.0.0` | 监听地址。要在容器/服务器外访问必须是 `0.0.0.0`，不要写 `127.0.0.1` |
| `ROOM_LIMIT` | `20` | 单个房间最大成员数，超出回 `ROOM_FULL` 并断开 |
| `OFFLINE_TIMEOUT_MS` | `5000` | 多久没收到有效上报判为离线（客户端也按 5 秒灰显，改这里客户端不会同步变） |
| `MAX_CLIENTS` | `200` | 全服最大并发连接数，超出回 `SERVER_FULL` 并断开 |
| `LOG_LEVEL` | `info` | `error` / `warn` / `info` / `debug` |
| `LOG_DIR` | `/app/logs` | 日志落盘目录（容器内）。compose 会把它挂到宿主机；目录不存在会自动创建（镜像里已经 `mkdir` 并 `chown node:node`） |
| `LOG_MAX_BYTES` | `20971520`（20 MB） | 单个 `relay.log` 的大小上限，超过即轮转 |
| `LOG_MAX_FILES` | `5` | 保留几份历史文件（`relay.log.1` … `relay.log.N`）。总占用 ≈ 上限 ×(N+1) = 60 MB |
| `WS_KEEPALIVE_MS` | `30000` | WebSocket 协议层 ping 间隔；上一轮没回 pong 就 `terminate`（半死连接清理） |

> 成员「2 分钟未上报自动移除」是协议固定值，不做成可配项，避免和客户端预期漂移。
>
> **日志**：stdout 与文件同时写。文件按大小轮转（`relay.log` → `.1` → … → `.N`），
> 写失败（只读挂载/磁盘满/权限）时打一条 `log_file_disabled` 告警并退化为只写 stdout，
> 进程照常收发。时间戳带时区偏移（受 `TZ` 影响），与客户端日志的 UTC/本地时间可直接对齐。
> 关键事件：`client_closed`（close code/reason、`initiator`、`closedBy`、`lastInboundMs`、
> `lastPingRttMs`、`connections`）、`keepalive_terminate`、`member_*`、`room_idle_dropped`、
> `bad_message`、`slow_send`。成员标识只留末 6 位，日志里不出现 payload/token。

## 快速开始

### 方式零：直接从 Docker Hub 运行（不用 clone、不用 build）

镜像由 GitHub Actions 自动构建：构建后先起容器 curl `/healthz` 冒烟，通过才推送。

```bash
docker run -d --name heartrate-relay \
  -p 8765:8765 \
  -e PORT=8765 \
  -e ROOM_LIMIT=20 \
  -e LOG_LEVEL=info \
  --restart unless-stopped \
  mawjgit/heart-rate-share:latest
```

拉取的是 `mawjgit/heart-rate-share`，**只保留一个 tag**：

| tag | 含义 |
|---|---|
| `latest` | 默认分支最新构建，每次发布覆盖（不再生成 `sha-*` / `v*`） |

要回滚就按 digest（`docker pull image@sha256:…`）或本地保留的旧镜像，不要再指望版本 tag。

常用操作：

```bash
docker ps --filter name=heartrate-relay          # 是否在跑（镜像自带健康检查，STATUS 会显示 healthy）
curl -s http://127.0.0.1:8765/healthz            # 应用层自检
docker logs -f heartrate-relay                    # 看日志（JSON 行）
docker inspect --format '{{.State.Health.Status}}' heartrate-relay
docker rm -f heartrate-relay                      # 停掉并删除
```

改端口/上限就改 `-e` 与 `-p` 两侧（宿主机映射与容器内端口要保持一致）：

```bash
docker run -d --name heartrate-relay -p 9000:9000 -e PORT=9000 mawjgit/heart-rate-share:latest
```

> 镜像内已设 `HOST=0.0.0.0`，非 root（`node` 用户）运行，并内置 `HEALTHCHECK`。
> 升级：`docker pull mawjgit/heart-rate-share:latest && docker rm -f heartrate-relay`，再用上面的 `docker run` 起回来即可。
>
> 要留日志就把宿主机目录挂进去（容器内是 uid 1000 的 `node` 用户，目录必须先给权限）：
> ```bash
> mkdir -p ./logs && sudo chown -R 1000:1000 ./logs
> docker run -d --name heartrate-relay -p 8765:8765 \
>   -e PORT=8765 -e LOG_DIR=/app/logs -e TZ=Asia/Shanghai \
>   -v "$PWD/logs:/app/logs" --restart unless-stopped \
>   mawjgit/heart-rate-share:latest
> tail -f ./logs/relay.log
> ```

### 方式零-B：用现成镜像 + compose 一键部署（推荐给服务器）

仓库根目录的 `docker-compose-hub.yml` 只拉取 Docker Hub 上的镜像、不在本地构建，
适合「只想把服务跑起来」的部署场景。

```bash
# 方式一：只要这一个文件（仓库当前是私有的，需要带凭据；公开后可直接 curl）
gh api repos/WJMA-GIT/heart-rate-share/contents/docker-compose-hub.yml \
  --jq .content | base64 -d > docker-compose-hub.yml
docker compose -f docker-compose-hub.yml up -d

# 方式二（推荐）：整仓 clone，文件随仓库一起下来
git clone https://github.com/WJMA-GIT/heart-rate-share.git
cd heart-rate-share
docker compose -f docker-compose-hub.yml up -d
```

> 仓库私有期间 `curl -O raw.githubusercontent.com/...` 会返回 404，必须带 token 或用上面的 `gh api`
> 写法；仓库公开后那条 curl 可以直接用。

跑起来后自检：

```bash
docker compose -f docker-compose-hub.yml ps          # STATUS 应显示 healthy
curl -s http://127.0.0.1:8765/healthz                # {"status":"ok",...}
docker compose -f docker-compose-hub.yml logs -f      # JSON 日志
```

**钉版本**：仓库只发布 `latest`（历史 `vX.Y.Z` / `sha-*` tag 已全部删除）。要固定到某个
具体构建，请钉 **digest** 而不是 tag：

```bash
# 应急：临时指到某个 digest（IMAGE 是**完整镜像引用**，不是 tag）
IMAGE=mawjgit/heart-rate-share@sha256:8affd9f3fbe444eadfe3dec5d1dbe05b2cfab9a81160ceba5a5dcda8c4e8eb41 \
  docker compose -f docker-compose-hub.yml up -d
```

> 变量已从 `IMAGE_TAG` 改成 `IMAGE`（tag 无法表达 digest）。宿主机 `.env` 里如果还留着
> `IMAGE_TAG=...`，它**不再生效**，会被忽略；请改成 `IMAGE=...` 或直接删掉。

> ⚠️ **不要再用 `IMAGE_TAG=<版本号>` 这种写法**：镜像仓库只有 `latest` 一个 tag，写版本号会 404。
> 如果宿主机上还留着旧 compose（`grep -rn 'v0\.3\.2' /opt /srv /root 2>/dev/null`），
> 把 `IMAGE_TAG` 那行删掉或改成 digest，再 `docker compose up -d`。

**升级**：保持默认 `latest` 直接重新 `up -d` 即可（要钉死就设 `IMAGE=<完整引用>`）。文件里设了 `pull_policy: always`，
所以 `up` 会先拉新镜像；镜像变了 Compose 会**重建容器**。重建会清空内存里的房间状态
（协议里房间 epoch 恢复本就是 pre-production 项），客户端下一次上报会自愈，不需要手动干预。

配置项就是 `docker-compose-hub.yml` 里的那些，用环境变量覆盖即可（**这是唯一权威 compose**，
根目录原 `docker-compose.yml`（本地 build）已删除，避免 `docker compose up` 误起本地构建）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8765` | 容器监听端口，同时决定宿主机映射端口 |
| `ROOM_LIMIT` | `20` | 单房间最大成员数 |
| `OFFLINE_TIMEOUT_MS` | `5000` | 多久无有效上报判离线 |
| `MAX_CLIENTS` | `200` | 全服最大并发连接 |
| `LOG_LEVEL` | `info` | `error`/`warn`/`info`/`debug` |

**只有一份 compose**：`docker-compose-hub.yml`（拉现成镜像）。根目录原来的
`docker-compose.yml`（本地 build）已删除 —— 它会让 `docker compose up`（默认文件名）偷偷起一套
本地构建，和"用 latest 部署"互相打架。

### 方式一：从源码本地构建（不经过 compose）

改了服务端代码、想自己验一遍时用这两条，别再加回一份 compose：

```bash
docker build -t heart-rate-share-relay:dev ./server
install -d -o 1000 -g 1000 -m 0750 ./logs
docker run -d --name relay-dev -p 8765:8765 \
  -e PORT=8765 -e LOG_DIR=/app/logs -e TZ=Asia/Shanghai \
  -v "$PWD/logs:/app/logs" heart-rate-share-relay:dev
docker ps --filter name=relay-dev          # STATUS 应显示 healthy
curl -s http://127.0.0.1:8765/healthz
```

改端口 / 改上限就是多加 `-e PORT=9000 -e ROOM_LIMIT=30`（`-p` 与 `-e PORT` 两侧要一致）。
```

### 方式二：只 build 镜像

```bash
docker build -t heart-rate-share-relay:dev ./server
docker run -d --name relay -p 8765:8765 \
  -e PORT=8765 -e ROOM_LIMIT=20 -e LOG_LEVEL=info \
  --restart unless-stopped \
  heart-rate-share-relay:dev
```

### 方式三：不装 Docker，直接用 Node 20

```bash
cd server
npm ci --omit=dev
PORT=8765 node src/index.js
```

## 健康检查

```bash
curl -s http://127.0.0.1:8765/healthz
# {"status":"ok","version":"1.0.1","protocol":1,"rooms":1,"members":3,"clients":3,
#  "uptimeSec":42,"config":{"roomLimit":20,"offlineTimeoutMs":5000,"maxClients":200}}
```

- `GET /healthz` → 200 + 运行状态（Docker `HEALTHCHECK` 与 compose `healthcheck` 都用它）
- `GET /` → 服务标识，便于人肉确认「活着」
- 其它路径 → 404

## 部署到服务器

1. **端口**：默认 `8765`。改 `PORT` 时 compose 的宿主机映射会一起变（`${PORT}:${PORT}`）。
2. **防火墙**（二选一）：
   - 直连 `ws://`：放行 TCP `8765`
     ```bash
     ufw allow 8765/tcp            # Ubuntu/Debian
     firewall-cmd --add-port=8765/tcp --permanent && firewall-cmd --reload   # CentOS/RHEL
     ```
   - 走反向代理 `wss://`：**只放行 443**，8765 绑到 `127.0.0.1` 不对外：
     ```yaml
     ports: ["127.0.0.1:8765:8765"]
     ```
3. **云厂商安全组**：同样要单独放行上面的端口，系统防火墙放行了但安全组没放是最常见的「连不上」。

## ⚠️ 公网必须上 TLS

`ws://` 是**明文**：房间里的心率、昵称、设备标识都会以明文经过中间网络，任何人可抓包。
部署到公网（有公网 IP / 域名）就必须用 `wss://`，由反向代理终止 TLS。局域网内部测试可以先用 `ws://`。

### Caddy（自动申请并续期证书，最省事）

`Caddyfile`：

```caddyfile
hr.example.com {
    reverse_proxy 127.0.0.1:8765
}
```

Caddy 会**自动**为 WebSocket 处理 `Upgrade`/`Connection` 头并申请 Let's Encrypt 证书，不需要额外写
`proxy_set_header`。前提：域名 A/AAAA 记录已指向本机，且 80/443 可从公网访问。

启动：

```bash
caddy run --config Caddyfile      # 或 systemctl reload caddy
```

客户端连：`wss://hr.example.com/ws?room=ABC123`

### Nginx（需要手动写 WebSocket 升级头）

```nginx
# /etc/nginx/conf.d/heartrate.conf
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name hr.example.com;

    ssl_certificate     /etc/letsencrypt/live/hr.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/hr.example.com/privkey.pem;

    location /ws {
        proxy_pass http://127.0.0.1:8765;

        # ↓ WebSocket 必需，缺了会 400/连上就断
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 心率是持续长连接：默认 60s 会把空闲连接掐断
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location /healthz {
        proxy_pass http://127.0.0.1:8765;
        access_log off;
    }
}

server {
    listen 80;
    server_name hr.example.com;
    return 301 https://$host$request_uri;
}
```

> 反代的三个坑：① 少写 `Upgrade`/`Connection` → 握手失败；② `proxy_read_timeout` 太短 → 客户端每隔一分钟掉线（应用层 3 秒一次 ping 会重置计时，但代理空闲超时仍建议放大）；③ 把 `/ws` 写成带尾斜杠的 `location /ws/` → 路径不匹配。

## 客户端要填什么地址

客户端的「服务器地址」支持域名、IP、`host:port`、`ws://`、`wss://`，缺端口时
`ws` 默认 8765、`wss` 默认 443：

| 部署方式 | 客户端填 | 说明 |
|---|---|---|
| 本机/局域网直连 | `192.168.1.10:8765` 或 `ws://192.168.1.10:8765` | 明文，仅限可信局域网 |
| 公网 IP 直连 | `ws://1.2.3.4:8765` | **明文**，不推荐；仅临时测试 |
| 域名 + 反代 | `hr.example.com` 或 `wss://hr.example.com` | 推荐；走 443，TLS 由 Caddy/Nginx 终止 |

房间短码由客户端自己决定，**同一短码 = 同一房间**（大小写敏感，服务端按字符串精确匹配）。

## 验证

```bash
cd server
npm ci
npm test                 # 9 个协议回归用例（假时钟，约 2 秒）
npm run smoke            # 真实时钟：3 客户端 + 快照 + 5 秒判离线（约 7 秒）
node test/smoke.js wss://hr.example.com/ws?room=SMOKE1   # 部署后验收
```

`smoke.js` 的期望输出：

```
PASS /healthz 200 status=ok protocol=1
PASS 快照广播：1 秒一条，最新快照含 3 人 [张三、李四、王五]
PASS memberDelta 增量：收到 8 条
PASS 王五静默 4.2 秒仍在线（未误判离线）
PASS 王五静默约 6.0 秒后判离线（online=false）
PASS 持续上报的张三/李四保持在线
```

## 日志

JSON 行，便于接 Loki/ELK：

```json
{"ts":"2026-10-29T04:41:17.035Z","level":"info","msg":"relay_started","port":8765,"roomLimit":20,...}
{"ts":"...","level":"info","msg":"member_hello","room":"ABC123","member":"…a1b2c3"}
```

**不记录消息正文**：协议要求不得记录 payload / token / 配对密钥，因此只记录事件类型、房间码、
成员标识末 6 位与计数。`docker compose` 已配 `json-file` 轮转（10 MB × 3）。

## 扩展（为什么现在只做单实例）

单实例单进程足够一个房间到几十个房间的规模（每房间 20 人 × 1 Hz 上报 = 20 msg/s）。
要横向扩展需要解决两件事：

1. **状态共享**：成员表目前在各进程内存里，多副本会让同一房间的人看不到彼此 → 需要 Redis/共享缓存或一致性路由。
2. **连接亲和**：WebSocket 是长连接，负载均衡必须保证同一房间的客户端落到同一实例（一致性哈希 / sticky），否则广播会串。

这两件事都要引入外部依赖，所以当前版本刻意只做单实例；等真的有量再加。

## 协议兼容说明（保持 `v: 1`）

1. **昵称变更**：客户端在 `ping` 中发送**可选**字段 `displayName`。本服务只对已存在成员更新昵称，
   并广播普通 `memberDelta`，不改心率、序列号或在线状态；旧客户端不发送该字段时行为不变。
   旧服务端会忽略未知字段，因此该扩展向后兼容，未新增消息类型、未提升协议版本。
2. **`ROOM_FULL`**：本服务按文档的 TODO 把它作为稳定错误码下发
   （`{"v":1,"type":"error","code":"ROOM_FULL"}` 后关闭连接），客户端现有实现只打日志不崩，
   属兼容扩展。
