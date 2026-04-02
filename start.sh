#!/usr/bin/env bash
# start.sh
# Start the Harbor stack on macOS (Apple Silicon / M-series CPU).
# Open WebUI will be pre-wired to the LM Studio local server running
# on the base macOS host.
#
# Usage:
#   chmod +x start.sh
#   ./start.sh [extra harbor services…]
#
# Examples:
#   ./start.sh                 # Open WebUI only (talks to LM Studio)
#   ./start.sh searxng         # + web search
#   ./start.sh searxng speach  # + web search + voice I/O
#
# Run ./setup.sh first if you haven't already.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────
# Configuration (mirrors setup.sh defaults)
# ──────────────────────────────────────────────
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
LM_STUDIO_API_KEY="${LM_STUDIO_API_KEY:-lm-studio}"
WEBUI_PORT="${WEBUI_PORT:-8080}"

# ──────────────────────────────────────────────
# Locate harbor binary
# ──────────────────────────────────────────────
if command -v harbor &>/dev/null; then
  HARBOR_BIN="$(command -v harbor)"
elif [[ -x "${HARBOR_HOME:-$HOME/harbor}/harbor.sh" ]]; then
  HARBOR_BIN="${HARBOR_HOME:-$HOME/harbor}/harbor.sh"
else
  error "Harbor is not installed. Run ./setup.sh first."
fi

harbor() { "$HARBOR_BIN" "$@"; }

# ──────────────────────────────────────────────
# Pre-flight: Docker must be running
# ──────────────────────────────────────────────
if ! docker info &>/dev/null; then
  error "Docker Desktop is not running. Please start it and try again."
fi

# ──────────────────────────────────────────────
# Check LM Studio reachability
# ──────────────────────────────────────────────
info "Checking LM Studio API on port ${LM_STUDIO_PORT}…"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 \
  -H "Authorization: Bearer ${LM_STUDIO_API_KEY}" \
  "http://localhost:${LM_STUDIO_PORT}/v1/models" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  success "LM Studio API is up (HTTP $HTTP_STATUS)."
else
  warn "LM Studio returned HTTP $HTTP_STATUS (expected 200)."
  warn "Models from LM Studio won't be available until its server is started."
  warn "  LM Studio → Local Server tab → Start Server"
fi

# ──────────────────────────────────────────────
# Start Harbor
# ──────────────────────────────────────────────
EXTRA_SERVICES=("$@")   # any extra services passed on the command line

if [[ ${#EXTRA_SERVICES[@]} -gt 0 ]]; then
  info "Starting Harbor with services: webui ${EXTRA_SERVICES[*]}"
  harbor up webui "${EXTRA_SERVICES[@]}"
else
  info "Starting Harbor with Open WebUI…"
  harbor up webui
fi

# ──────────────────────────────────────────────
# Post-start info
# ──────────────────────────────────────────────
success "Harbor is running."
echo ""
echo "  Open WebUI  → http://localhost:${WEBUI_PORT}"
echo "  LM Studio   → http://localhost:${LM_STUDIO_PORT} (on your Mac)"
echo ""
echo "  In Open WebUI, LM Studio models appear under:"
echo "    Settings → Connections → OpenAI API"
echo "    (URL: http://host.docker.internal:${LM_STUDIO_PORT}/v1)"
echo ""
echo "  To stop: harbor down"
echo "  Logs:    harbor logs webui"
echo ""
