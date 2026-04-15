# -----------------------------------------------------------------------------
# Stage 1 — build the Vite app
# -----------------------------------------------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

# VITE_* env vars are inlined at BUILD time by Vite. docker-compose passes
# VITE_API_URL=/api so the compiled bundle talks to the sibling nginx location
# that proxies to the backend service.
ARG VITE_API_URL=/api
ENV VITE_API_URL=$VITE_API_URL

COPY . .
RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2 — serve the built static files with nginx
# -----------------------------------------------------------------------------
FROM nginx:alpine AS serve

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80

# nginx:alpine ships with a default CMD that runs nginx in the foreground.
