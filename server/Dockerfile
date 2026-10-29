# syntax=docker/dockerfile:1
# 两段构建：deps 只装生产依赖，运行层不带 npm 缓存与构建工具。
FROM node:20.19.2-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20.19.2-alpine
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8765
WORKDIR /app

# OCI 标签：Docker Hub 页面会据此关联源码仓库与许可
LABEL org.opencontainers.image.title="heart-rate-share-relay" \
      org.opencontainers.image.description="共享心率 v1 协议的 WebSocket 中继（Node 20 + ws，内存房间状态）" \
      org.opencontainers.image.source="https://github.com/WJMA-GIT/heart-rate-share" \
      org.opencontainers.image.licenses="UNLICENSED"

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# 不用 root 跑服务；node 镜像自带 uid 1000 的 node 用户。
USER node

EXPOSE 8765

# 用 node 自带 fetch，避免为健康检查往镜像里装 curl。
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8765)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
