# syntax=docker/dockerfile:1
#
# One worker image for every backend: the providers compiled to a single
# binary on a lean runtime. The agent spawns it and dials it over gRPC on every
# parameter:<action>; PARAMETERS_PROVIDER in the worker's environment names the
# backend it serves: aws-secrets-manager, aws-parameter-store, azure-key-vault,
# gcp-secret-manager or hashicorp-vault.
#
#   docker build -t parameters .

# ── stage 1: compile the worker ───────────────────────────────────────────────
# The build stage runs on the builder's own architecture and cross-compiles:
# bun targets any platform, so a multi-arch buildx emulates nothing here.
FROM --platform=$BUILDPLATFORM oven/bun:1-alpine AS build
ARG TARGETARCH
WORKDIR /w
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY src ./src
# bun names amd64 "x64".
RUN arch=$([ "${TARGETARCH:-amd64}" = "amd64" ] && echo x64 || echo "$TARGETARCH") \
    && bun build --compile --target="bun-linux-${arch}-musl" src/main.ts --outfile /out/worker

# ── stage 2: the runtime ──────────────────────────────────────────────────────
FROM alpine:3.24
# bun's musl binary links libstdc++/libgcc; the backends are reached over HTTPS.
RUN apk upgrade --no-cache \
    && apk add --no-cache libstdc++ libgcc ca-certificates \
    && addgroup -g 10001 app \
    && adduser -u 10001 -G app -h /home/app -D app
COPY --from=build /out/worker /usr/local/bin/worker
ENV NP_PACKAGE_NAME=parameters \
    NP_AGENT_PLUGIN=np-agent-v1 \
    HOME=/home/app
# Numeric, so runAsNonRoot admission can verify it.
USER 10001:10001
EXPOSE 50051
ENTRYPOINT ["worker"]
