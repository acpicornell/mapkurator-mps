#!/usr/bin/env bash
# Freeze mapkurator-mps into a single self-contained tar.gz "time capsule".
#
# The archive rebuilds and runs OFFLINE — no GitHub, no Nix binary cache —
# on the same platform it was built on (aarch64-darwin: Apple Silicon macOS).
# It bundles:
#   1. store-closure.nar.gz  — the full Nix closure of the `.#default` CLI
#      (torch, detectron2, python, the patched spotter, the crop/stitch
#      scripts — everything, ~3.3 GiB uncompressed).
#   2. repo/                 — the git source of truth (flake, patch, scripts,
#      docs) so the port can be inspected, edited and rebuilt from scratch.
#   3. weights/model_v2_en.pth — the model checkpoint (not in the closure by
#      design; fetched separately via gdown, so we snapshot it here).
#   4. RESTORE.md            — how to bring it back to life.
#
# Usage:
#   scripts/archive.sh [OUTPUT_DIR]
#   (default OUTPUT_DIR: the repo's parent directory)

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${1:-$(dirname "$repo")}"
stamp="$(date +%Y-%m-%d)"
name="mapkurator-mps-archive-$stamp"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stage="$work/$name"
mkdir -p "$stage"

echo "[1/4] building .#default and .#src (reuses the Nix store if present)..." >&2
nix build "$repo#default" "$repo#src" --no-link

cli_path="$(nix path-info "$repo#default")"

echo "[2/4] exporting the full store closure (~3.3 GiB) -> gzip..." >&2
nix-store --export $(nix-store -qR "$cli_path") | gzip > "$stage/store-closure.nar.gz"

echo "[3/4] snapshotting repo + weights..." >&2
git -C "$repo" archive --format=tar --prefix=repo/ HEAD | tar -x -C "$stage"
if [[ -f "$repo/weights/model_v2_en.pth" ]]; then
  mkdir -p "$stage/weights"
  cp "$repo/weights/model_v2_en.pth" "$stage/weights/"
else
  echo "  (no weights/model_v2_en.pth found — skipping)" >&2
fi

# Record the exact store path so RESTORE can point straight at the binary.
echo "$cli_path" > "$stage/cli-store-path.txt"

cat > "$stage/RESTORE.md" <<EOF
# Restoring mapkurator-mps from this archive

Built: $stamp
Platform: $(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null || echo aarch64-darwin)
CLI store path: $cli_path

This archive runs OFFLINE — no GitHub, no Nix binary cache needed — on the
same platform it was built on (Apple Silicon macOS). It only needs Nix
installed.

## Fastest path — run the exact binary that was frozen

    gunzip -c store-closure.nar.gz | nix-store --import
    "$cli_path/bin/mapkurator-mps" \\
        --input ./map.png --output ./out \\
        --weights ./weights/model_v2_en.pth

\`nix-store --import\` unpacks all 249 store paths (torch, detectron2, the
patched spotter, the crop/stitch scripts) back into /nix/store. The closure is
self-contained, so the binary just works.

## Rebuild from source instead (e.g. to edit the patch)

The closure also contains the pinned source inputs, so even a \`nix build\`
inside repo/ resolves from the local store without touching the network:

    gunzip -c store-closure.nar.gz | nix-store --import
    cd repo && nix build .#default

## Notes

- The closure is platform-specific (aarch64-darwin). To revive on Linux or
  Intel you must rebuild from repo/ with network access to GitHub + the Nix
  cache, or re-run scripts/archive.sh on that platform.
- weights/model_v2_en.pth is CC BY-NC (non-commercial, attribution). See
  repo/NOTICE.
EOF

echo "[4/4] packing $name.tar.gz ..." >&2
tar -czf "$out_dir/$name.tar.gz" -C "$work" "$name"

echo >&2
echo "Done: $out_dir/$name.tar.gz" >&2
ls -lh "$out_dir/$name.tar.gz" >&2
