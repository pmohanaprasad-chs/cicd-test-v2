# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Stage 1 – deps: install production + dev dependencies (cached separately)
# ---------------------------------------------------------------------------
FROM node:20-alpine AS deps
WORKDIR /app

# Enable corepack so pnpm is available inside the container
RUN corepack enable && corepack prepare pnpm@latest --activate

COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile

# ---------------------------------------------------------------------------
# Stage 2 – builder: compile the Next.js app
# ---------------------------------------------------------------------------
FROM node:20-alpine AS builder
WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# Re-use the already-installed node_modules from deps stage
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Build-time args injected by GitHub Actions
ARG APP_ENV=production
ARG BUILD_SHA=unknown
ENV APP_ENV=${APP_ENV}
ENV BUILD_SHA=${BUILD_SHA}
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

RUN pnpm run build

# ---------------------------------------------------------------------------
# Stage 3 – runner: minimal production image using standalone output
# ---------------------------------------------------------------------------
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Non-root user for security
RUN addgroup --system --gid 1001 nodejs && \
    adduser  --system --uid 1001 nextjs

# Copy standalone server + static assets
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static   ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public          ./public

USER nextjs

# Next.js standalone listens on port 3000 by default
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Propagate runtime env vars (APP_ENV, BUILD_SHA can be overridden via ECS task def)
CMD ["node", "server.js"]
