#!/usr/bin/env bash
# =====================================================================
#  ONE-COMMAND UNINSTALLER — Custom Node Upload for self-hosted n8n
#
#  Thin wrapper: fetches the main installer and runs it with --uninstall.
#  Equivalent to:
#    curl -fsSL <raw>/install-custom-node-upload.sh | bash -s -- --uninstall
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/uninstall-custom-node-upload.sh | bash
# =====================================================================
set -euo pipefail

# Resolve the raw base URL of this repo so the wrapper works no matter
# what account/repo it is hosted under (override with N8N_CNU_BASE if needed).
BASE="${N8N_CNU_BASE:-https://raw.githubusercontent.com/AakashKhambhaliya/n8n-custom-node-upload/main}"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$BASE/install-custom-node-upload.sh" | bash -s -- --uninstall
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$BASE/install-custom-node-upload.sh" | bash -s -- --uninstall
else
  echo "[ERROR] Need curl or wget to fetch the installer." >&2
  exit 1
fi
