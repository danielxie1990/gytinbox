# ─── Build Stage ──────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

# Switch Prisma datasource to PostgreSQL for the VPS/Docker deployment.
# Local dev & Hostinger keep SQLite (schema.prisma stays untouched in git).
RUN sed -i 's/provider = "sqlite"/provider = "postgresql"/' prisma/schema.prisma

RUN npx prisma generate
RUN npm run build

# ─── Production Stage ─────────────────────────
FROM node:20-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Public assets
COPY --from=builder /app/public ./public

# Next.js standalone output
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Prisma (for db push + seed at runtime)
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma ./node_modules/@prisma
COPY --from=builder /app/node_modules/prisma ./node_modules/prisma

# Seed dependencies (tsx + dev deps for seed)
COPY --from=builder /app/node_modules/tsx ./node_modules/tsx
COPY --from=builder /app/node_modules/typescript ./node_modules/typescript
COPY --from=builder /app/node_modules/@types ./node_modules/@types
COPY --from=builder /app/tsconfig.json ./tsconfig.json

COPY --from=builder /app/package.json ./package.json

# Uploads volume (persisted images/docs; empty dir so the volume can mount over it)
RUN mkdir -p /app/public/uploads && chown -R nextjs:nodejs /app

USER nextjs

EXPOSE 3000
ENV PORT=3000

# db push creates/updates tables from schema (no SQLite migrations on Postgres),
# seed is idempotent (admin + defaults), then start the standalone server.
CMD ["sh", "-c", "npx prisma db push --accept-data-loss && npx prisma db seed && node server.js"]
