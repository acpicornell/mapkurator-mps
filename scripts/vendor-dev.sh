#!/usr/bin/env bash
# Get a writable checkout of the upstream spotter at the pinned commit with the
# Apple/MPS patch applied, for iterating on the patch itself.
#
#   scripts/vendor-dev.sh
#
# Edit files under ./vendor/mapkurator-spotter, then regenerate the patch with:
#   git -C vendor/mapkurator-spotter diff > patches/apple-mps.patch
#
# ./vendor is git-ignored. The reproducible build (nix) does NOT use it; it
# patches the pinned flake input directly. This is only a developer convenience.
set -euo pipefail

# Keep in sync with the `mapkurator-spotter` input rev in flake.nix.
PIN="4686d2e666f923303a4c8c9a609a77e1ac57234c"
REPO_URL="https://github.com/knowledge-computing/mapkurator-spotter.git"
DEST="vendor/mapkurator-spotter"
PATCH="patches/apple-mps.patch"

if [[ -d "${DEST}/.git" ]]; then
  echo "Already checked out at ${DEST} (remove it to re-vendor)."
  exit 0
fi

mkdir -p vendor
echo "Fetching mapkurator-spotter @ ${PIN} ..."
git init -q "${DEST}"
git -C "${DEST}" remote add origin "${REPO_URL}"
git -C "${DEST}" fetch -q --depth 1 origin "${PIN}"
git -C "${DEST}" checkout -q FETCH_HEAD

echo "Applying ${PATCH} ..."
git -C "${DEST}" apply "../../${PATCH}"
echo "Writable checkout ready at ${DEST}."
