FROM node:22-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends git curl procps python3 make g++ cron tini \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json docker-entrypoint.sh ./
RUN npm ci --omit=dev \
  && npm cache clean --force

ENV PATH="/app/node_modules/.bin:$PATH"
ENV ALPHACLAW_ROOT_DIR=/data

RUN chmod +x /app/docker-entrypoint.sh \
  && mkdir -p /data \
  && chown -R node:node /app /data

USER node

EXPOSE 3000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
