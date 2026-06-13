FROM node:24-bookworm-slim

WORKDIR /app

# Non-Composer models use the full Cursor SDK agent path, which spawns /bin/sh for
# tools like `date`. Alpine's minimal image and USER node often break that path.
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates coreutils git \
  && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
ENV SHELL=/bin/bash
ENV CURSOR_SDK_BRIDGE_HOST=0.0.0.0
ENV CURSOR_SDK_BRIDGE_PORT=8792

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY scripts/cursor-sdk-local-agent-bridge.mjs ./scripts/cursor-sdk-local-agent-bridge.mjs
COPY scripts/composer-tool-markers.mjs ./scripts/composer-tool-markers.mjs

EXPOSE 8792

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=15s \
  CMD node -e "fetch('http://127.0.0.1:8792/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "scripts/cursor-sdk-local-agent-bridge.mjs"]
