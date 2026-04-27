#!/bin/bash
set -e

mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# ── GBrain setup (background) ─────────────────────────────────────────────────
(
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

    # Wire GBrain as MCP server in Hermes config
    if [ -f /data/.hermes/config.yaml ] && ! grep -q "gbrain" /data/.hermes/config.yaml; then
      echo "[gbrain] Wiring GBrain MCP server into Hermes config..."
      cat >> /data/.hermes/config.yaml << EOF

# GBrain — personal knowledge base as MCP tool set
mcp_servers:
  gbrain:
    command: /data/.bun/bin/gbrain
    args: ["serve"]
    env:
      GBRAIN_DATABASE_URL: "${GBRAIN_DATABASE_URL}"
      OPENAI_API_KEY: "${OPENAI_API_KEY}"
EOF
    fi

    # Add brain-ops skill so Hermes knows to use GBrain
    mkdir -p /data/.hermes/skills/gbrain
    cat > /data/.hermes/skills/gbrain/DESCRIPTION.md << 'EOF'
---
description: GBrain personal knowledge base. Brain-first lookup before any external API call.
---

# GBrain Brain-Ops

GBrain is your long-term memory. Check it before web search or any external API.

## Brain-First Lookup (mandatory before external research)
1. Use `gbrain_search` — keyword search
2. Use `gbrain_query` — hybrid vector search
3. Use `gbrain_get` — read full page if slug known

## Signal Capture (every non-operational message)
- Capture user's original ideas with exact phrasing
- Detect entity mentions (people, companies) — create/enrich brain pages
- Back-link all entity mentions (Iron Law)

## READ → ENRICH → WRITE
1. Read existing brain context on mentioned entities
2. Enrich from external sources where brain has gaps
3. Write with citations `[Source: ..., YYYY-MM-DD]`

## Iron Laws
- Every person/company mention WITH a brain page → back-link from their page
- Every written fact → inline citation
- Notability gate before creating new pages
EOF


    # Add Clawvisor skill so Hermes knows to use the gateway
    mkdir -p /data/.hermes/skills/clawvisor
    cat > /data/.hermes/skills/clawvisor/DESCRIPTION.md << 'EOF'
---
description: Clawvisor trusted gateway for Gmail and Google Calendar. Route all external service calls through Clawvisor — never call APIs directly.
---

# Clawvisor — Trusted Service Gateway

Route ALL Gmail and Calendar calls through Clawvisor. Never use direct API keys.

**Base URL:** $CLAWVISOR_URL  
**Auth:** Bearer $CLAWVISOR_AGENT_TOKEN

## Workflow
1. POST /api/tasks?wait=true — declare scope + purpose
2. POST /api/gateway/request?wait=true — execute with task_id
3. POST /api/tasks/{id}/complete — clean up

## Services
- google.gmail:ben@flowdesk.ai — list_messages, get_message, get_thread, send_message, create_draft
- google.calendar:ben@flowdesk.ai — list_events, get_event, create_event, update_event

## Status codes
- executed: use result.data
- pending: poll /api/gateway/request/{id}/execute?wait=true  
- blocked: do not retry
- pending_scope_expansion: call /api/tasks/{id}/expand?wait=true
EOF

    echo "[gbrain] Brain ready."
  fi
) &
# ─────────────────────────────────────────────────────────────────────────────

exec python /app/server.py