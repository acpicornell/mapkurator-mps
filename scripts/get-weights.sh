#!/usr/bin/env bash
# Download a mapKurator spotter-v2 checkpoint on demand.
#
# The weights are published by the upstream authors on Google Drive and are NOT
# redistributed by this repository. This script fetches them into ./weights/.
#
# Usage (inside the dev shell, which provides gdown):
#   nix develop --command scripts/get-weights.sh          # English model (default)
#
# See NOTICE for provenance and the upstream model cards.
set -euo pipefail

# English text-spotting weight (model card linked in the upstream README).
FILE_ID="1agOzYbhZPDVR-nqRc31_S6xu8yR5G1KQ"
DEST_DIR="weights"
DEST="${DEST_DIR}/model_v2_en.pth"

mkdir -p "${DEST_DIR}"

if [[ -f "${DEST}" ]]; then
  echo "Weights already present: ${DEST}"
  exit 0
fi

if ! command -v gdown >/dev/null 2>&1; then
  echo "gdown not found. Run this inside 'nix develop' (it provides gdown)." >&2
  exit 1
fi

echo "Downloading spotter-v2 English weights to ${DEST} ..."
gdown "https://drive.google.com/uc?id=${FILE_ID}" -O "${DEST}"
echo "Done. Point the CLI at it:  mapkurator-mps --weights ${DEST} ..."
