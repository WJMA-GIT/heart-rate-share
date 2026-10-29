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

> 成员「2 分钟未上报自动移除」是协议固定值，不做成可配项，避免和客户端预期漂移。

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

拉取的是 `mawjgit/heart-rate-share`，可用 tag：

| tag | 含义 |
|---|---|
| `latest` | 默认分支最新构建（只由 `main` 推送产生） |
| `sha-<短提交>` | 某个具体提交，便于回滚与对照 |
| `v0.2.0` 这类 | 打 `v*` tag 时生成，对应客户端版本 |

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

### 方式一：docker compose（推荐）

```bash
git clone https://github.com/WJMA-GIT/heart-rate-share.git
cd heart-rate-share
docker compose up -d --build
docker compose ps            # 应看到 healthy
curl -s http://127.0.0.1:8765/healthz
```

改端口 / 改上限：

```bash
PORT=9000 ROOM_LIMIT=30 OFFLINE_TIMEOUT_MS=5000 docker compose up -d
# 或写进当前目录的 .env，见 .env.example
```

### 方式二：只 build 镜像

```bash
docker build -t heart-rate-share-relay:0.1.0 ./server
docker run -d --name relay -p 8765:8765 \
  -e PORT=8765 -e ROOM_LIMIT=20 -e LOG_LEVEL=info \
  --restart unless-stopped \
  heart-rate-share-relay:0.1.0
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
# {"status":"ok","version":"0.1.0","protocol":1,"rooms":1,"members":3,"clients":3,
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
