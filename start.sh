#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# ── GBrain setup ──────────────────────────────────────────────────────────────
# Install Bun and GBrain on first boot. Persisted under /data so it survives
# redeploys. GBRAIN_DATABASE_URL and OPENAI_API_KEY come from Railway env vars.
BUN_BIN="/data/.bun/bin/bun"
GBRAIN_BIN="/data/.bun/bin/gbrain"
GBRAIN_DIR="/data/.gbrain_install"
BRAIN_REPO="/data/.hermes/brain"

if [ ! -f "$BUN_BIN" ]; then
  echo "[gbrain] Installing Bun..."
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/data/.bun bash
fi

export PATH=/data/.bun/bin:$PATH

if [ ! -f "$GBRAIN_BIN" ] && [ -f "$BUN_BIN" ]; then
  echo "[gbrain] Cloning and linking GBrain..."
  mkdir -p "$GBRAIN_DIR"
  git clone --depth 1 https://github.com/garrytan/gbrain.git "$GBRAIN_DIR"
  cd "$GBRAIN_DIR" && bun install && bun link
  cd /
fi

if [ -n "$GBRAIN_DATABASE_URL" ] && [ -f "$GBRAIN_BIN" ]; then
  echo "[gbrain] Initialising brain schema..."
  "$GBRAIN_BIN" init 2>/dev/null || true

  if [ ! -d "$BRAIN_REPO" ]; then
    echo "[gbrain] Creating brain repo..."
    mkdir -p "$BRAIN_REPO"
    git -C "$BRAIN_REPO" init -b main
    git -C "$BRAIN_REPO" config user.email "hermes@flowdesk.ai"
    git -C "$BRAIN_REPO" config user.name "Hermes"
  fi

  echo "[gbrain] Syncing and embedding brain..."
  "$GBRAIN_BIN" sync --repo "$BRAIN_REPO" 2>/dev/null || true
  "$GBRAIN_BIN" embed --stale 2>/dev/null || true
fi
# ─────────────────────────────────────────────────────────────────────────────

exec python /app/server.py
