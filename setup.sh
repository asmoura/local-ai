#!/usr/bin/env bash
# setup.sh
# One-time setup for Harbor on macOS (Apple Silicon / M-series CPU).
# Installs Harbor, then wires Open WebUI to the LM Studio server
# running on the base macOS host so that MLX-accelerated models are
# available inside the Harbor stack.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# Environment overrides (all optional):
#   HARBOR_HOME        Path where Harbor is / will be installed (default: ~/harbor)
#   LM_STUDIO_HOST     Hostname for LM Studio from inside Docker  (default: host.docker.internal)
#   LM_STUDIO_PORT     LM Studio server port                       (default: 1234)
#   LM_STUDIO_API_KEY  API key sent to LM Studio                   (default: lm-studio)

set -euo pipefail

# ──────────────────────────────────────────────
# Colours
# ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
HARBOR_HOME="${HARBOR_HOME:-$HOME/harbor}"

# On macOS with Docker Desktop, the host machine is always reachable
# from inside any container via the special DNS name host.docker.internal.
LM_STUDIO_HOST="${LM_STUDIO_HOST:-host.docker.internal}"
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
LM_STUDIO_API_KEY="${LM_STUDIO_API_KEY:-lm-studio}"

LM_STUDIO_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1"

# ──────────────────────────────────────────────
# 1. Pre-flight checks
# ──────────────────────────────────────────────
info "Checking prerequisites…"

# macOS only
if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This script is intended for macOS (Apple Silicon). Detected: $(uname -s)"
fi

# Apple Silicon
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  warn "Expected arm64 (Apple Silicon) but detected: $ARCH. Continuing anyway."
fi

# Docker Desktop
if ! command -v docker &>/dev/null; then
  error "Docker is not installed or not in PATH.\nInstall Docker Desktop for Mac: https://www.docker.com/products/docker-desktop/"
fi

if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Please start Docker Desktop and retry."
fi

# Homebrew (used to install harbor if needed)
if ! command -v brew &>/dev/null; then
  error "Homebrew is required but not found.\nInstall it from: https://brew.sh"
fi

success "All prerequisites satisfied."

# ──────────────────────────────────────────────
# 2. Install / locate Harbor
# ──────────────────────────────────────────────
info "Checking Harbor installation…"

HARBOR_BIN=""

# Priority 1: already on PATH
if command -v harbor &>/dev/null; then
  HARBOR_BIN="$(command -v harbor)"
  success "Harbor already on PATH: $HARBOR_BIN"

# Priority 2: cloned to HARBOR_HOME
elif [[ -x "$HARBOR_HOME/harbor.sh" ]]; then
  HARBOR_BIN="$HARBOR_HOME/harbor.sh"
  success "Harbor found at: $HARBOR_BIN"

# Priority 3: install via Homebrew tap
else
  info "Harbor not found. Installing via Homebrew…"
  brew tap av/harbor 2>/dev/null || true
  brew install harbor-stack

  if command -v harbor &>/dev/null; then
    HARBOR_BIN="$(command -v harbor)"
    success "Harbor installed: $HARBOR_BIN"
  else
    error "Homebrew installation finished but 'harbor' is still not on PATH."
  fi
fi

# Convenience wrapper so the rest of the script can always call `harbor`
harbor() { "$HARBOR_BIN" "$@"; }

# ──────────────────────────────────────────────
# 3. Verify LM Studio is reachable
# ──────────────────────────────────────────────
info "Verifying LM Studio API at http://localhost:${LM_STUDIO_PORT}/v1/models …"

# We test from the macOS host (localhost), not from inside Docker.
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 \
  -H "Authorization: Bearer ${LM_STUDIO_API_KEY}" \
  "http://localhost:${LM_STUDIO_PORT}/v1/models" 2>/dev/null || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  success "LM Studio API is reachable (HTTP $HTTP_STATUS)."
else
  warn "LM Studio API returned HTTP $HTTP_STATUS (expected 200)."
  warn "Make sure LM Studio is running and its local server is enabled."
  warn "  • Open LM Studio → Local Server tab → Start Server"
  warn "Continuing setup – you can start LM Studio later."
fi

# ──────────────────────────────────────────────
# 4. Configure Harbor for Apple Silicon
#    (CPU/Metal inference – no NVIDIA flags)
# ──────────────────────────────────────────────
info "Applying Apple Silicon configuration…"

# Disable GPU profiles that assume NVIDIA (CUDA) hardware
harbor config set gpu.driver  none   2>/dev/null || true
harbor config set gpu.enabled false  2>/dev/null || true

success "GPU/CUDA settings disabled (not needed on Apple Silicon)."

# ──────────────────────────────────────────────
# 5. Configure Open WebUI → LM Studio connection
# ──────────────────────────────────────────────
# Harbor exposes two mechanisms for adding an OpenAI-compatible provider
# to Open WebUI:
#
#   A) harbor openai url / harbor openai key
#      Sets OPENAI_API_BASE_URL + OPENAI_API_KEY inside the webui container.
#
#   B) Direct override.env injection
#      Adds OPENAI_API_BASE_URLS / OPENAI_API_KEYS which Open WebUI 0.3+
#      uses for multiple simultaneous providers (semicolon-separated).
#
# We use both so the configuration works with any Harbor / WebUI version.
# ──────────────────────────────────────────────
info "Wiring Open WebUI to LM Studio…"
info "  API URL : $LM_STUDIO_BASE_URL"
info "  API Key : $LM_STUDIO_API_KEY"

# --- Method A: Harbor built-in openai command ---
if harbor openai url "$LM_STUDIO_BASE_URL" 2>/dev/null && \
   harbor openai key "$LM_STUDIO_API_KEY"  2>/dev/null; then
  success "LM Studio set via 'harbor openai' command."
else
  warn "'harbor openai' command not available in this version – falling back to override.env."
fi

# --- Method B: inject directly into webui override.env ---
# Harbor merges this file into the webui container at startup.
OVERRIDE_ENV_DIR="$(harbor config get harbor.home 2>/dev/null || echo "$HARBOR_HOME")/services/webui"
mkdir -p "$OVERRIDE_ENV_DIR"
OVERRIDE_ENV_FILE="$OVERRIDE_ENV_DIR/override.env"

# Preserve any existing content, removing previous LM Studio entries
if [[ -f "$OVERRIDE_ENV_FILE" ]]; then
  # Strip previously injected LM Studio block
  sed -i '' '/# --- LM Studio (injected by setup.sh)/,/# --- end LM Studio/d' \
    "$OVERRIDE_ENV_FILE" 2>/dev/null || true
fi

cat >> "$OVERRIDE_ENV_FILE" <<EOF

# --- LM Studio (injected by setup.sh) ---
# Connects Open WebUI to the LM Studio local server running on the
# macOS host. host.docker.internal resolves to the host from containers.
#
# Single-provider variables (Open WebUI ≤ 0.2):
OPENAI_API_BASE_URL=${LM_STUDIO_BASE_URL}
OPENAI_API_KEY=${LM_STUDIO_API_KEY}
#
# Multi-provider variables (Open WebUI ≥ 0.3):
# Append additional providers by extending these semicolon-separated lists.
OPENAI_API_BASE_URLS=${LM_STUDIO_BASE_URL}
OPENAI_API_KEYS=${LM_STUDIO_API_KEY}
# --- end LM Studio ---
EOF

success "override.env written: $OVERRIDE_ENV_FILE"

# ──────────────────────────────────────────────
# 6. Save a named profile for easy reuse
# ──────────────────────────────────────────────
info "Saving Harbor profile 'macos-lmstudio'…"
harbor profile save macos-lmstudio 2>/dev/null && \
  success "Profile saved. Restore with: harbor profile use macos-lmstudio" || \
  warn "Profile save not supported in this Harbor version (non-critical)."

# ──────────────────────────────────────────────
# 7. Summary
# ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "  LM Studio API URL  : $LM_STUDIO_BASE_URL"
echo "  (host.docker.internal → your Mac's localhost)"
echo ""
echo "  Next steps:"
echo "  1. Ensure LM Studio is running with Local Server enabled."
echo "     LM Studio → Local Server → Start Server (port $LM_STUDIO_PORT)"
echo ""
echo "  2. Start Harbor:"
echo "     ./start.sh"
echo "     — or —"
echo "     harbor up webui"
echo ""
echo "  3. Open WebUI will be available at http://localhost:8080"
echo "     LM Studio models will appear under the OpenAI provider section."
echo ""
