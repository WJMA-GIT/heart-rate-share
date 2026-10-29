# syntax=docker/dockerfile:1
# 两段构建：deps 只装生产依赖，运行层不带 npm 缓存与构建工具。
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-alpine
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8765
WORKDIR /app

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
