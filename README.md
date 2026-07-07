# mapkurator-spotter-mps

Run the [mapKurator **spotter-v2**](https://github.com/knowledge-computing/mapkurator-spotter)
text spotter **natively on Apple Silicon** (Metal / MPS), with **no CUDA** and no
NVIDIA GPU. Packaged as a reproducible Nix flake.

The upstream spotter ships as a CUDA Docker image with a compiled custom op. On a
Mac that is a dead end: Docker on macOS runs a Linux VM with **no access to
Metal/MPS**, so a container can only ever use the CPU. This project takes the
other route — a small source patch that removes the CUDA dependency, plus Nix
packaging — so the model runs on the Apple GPU directly.

## What the port actually is

spotter-v2 is a Deformable-DETR + TESTR text spotter. Its only custom op is
multi-scale deformable attention (`adet._C`), a CUDA kernel. The patch
(`patches/apple-mps.patch`, two files) does two things:

1. **Deformable attention → pure PyTorch.** Route `MSDeformAttn.forward` through
   the numerically-equivalent `ms_deform_attn_core_pytorch` reference
   (`F.grid_sample` based) whenever the compiled CUDA op is unavailable or the
   tensors are not on CUDA. Nothing is compiled; MPS/CPU just work.
2. **MPS-safe dtype API.** Replace the legacy `Tensor.type('torch.…')` calls in
   the positional encoding with `.to(dtype)`, which the MPS backend accepts.

Everything else (ResNet backbone, transformer) is stock PyTorch that already runs
on MPS/CPU.

## Requirements

- macOS on Apple Silicon (for MPS). CPU also works here and on Linux.
- [Nix](https://nixos.org) with flakes enabled.

All Python dependencies — including `torch` and `detectron2` — come prebuilt from
the Nix binary cache; nothing compiles from source.

## Usage

```sh
# 1. Fetch a checkpoint (not bundled — see NOTICE for licensing)
nix develop --command scripts/get-weights.sh        # -> weights/model_v2_en.pth

# 2a. End-to-end: a whole map image -> one GeoJSON
nix run . -- \
  --input  ./map.png \
  --output ./out \
  --weights weights/model_v2_en.pth
# -> ./out/map.geojson

# 2b. Tile directory: spot pre-cut tiles -> per-tile JSON
nix run . -- \
  --input  ./tiles \
  --output ./out \
  --weights weights/model_v2_en.pth
```

The tool auto-detects the input:

- **A single image file** runs the full extraction pipeline — crop into 1000px
  tiles (mapKurator **M1**), spot each tile (**M2**), and stitch the detections
  back into one `<output>/<map_name>.geojson` in whole-image pixel coordinates
  (**M3**). The GeoJSON opens directly in QGIS (Y is flipped negative for it).
- **A directory of tiles** spots each tile and writes one JSON per tile into
  `--output`, with columns `polygon_x`, `polygon_y`, `text`, `score`.

Only the GPU/CUDA-bound module (M2) needed porting; M1 and M3 are stock
CPU-only Python. The heavier mapKurator modules — M4 post-OCR (needs
Elasticsearch + an indexed OSM vocabulary), M5 geocoordinate conversion (GDAL +
per-map ground control points), and M6 entity linking (PostGIS/Elasticsearch) —
are intentionally **not** included: they require external services/data and
belong in the georeferencing project that consumes this flake.

### Options

| Flag          | Default                          | Meaning                                  |
|---------------|----------------------------------|------------------------------------------|
| `--input`     | (required)                       | A map image file, or a directory of tiles |
| `--output`    | (required)                       | Output directory (GeoJSON, or per-tile JSON) |
| `--weights`   | `$MAPKURATOR_WEIGHTS`            | Checkpoint `.pth`                        |
| `--device`    | `mps` on macOS, else `cpu`       | `mps` \| `cpu` \| `cuda`                 |
| `--config`    | bundled `inference_en_test.yaml` | Detectron2 config                        |
| `--threshold` | `0.3`                            | Detection score threshold                |

> The spotter detects and boxes words; its own text reading is rough on
> historical/non-English maps. In a larger pipeline the boxes are the product and
> a separate reading step transcribes them.

## Reproducibility

- `nixpkgs` and both upstream sources (`mapkurator-spotter` for M2, and
  `mapkurator-system` for the M1/M3 crop and stitch scripts) are pinned in
  `flake.lock`.
- Upstream sources are consumed as `flake = false` inputs; the spotter is patched
  in a derivation (`applyPatches`) and the two system scripts are used as-is. No
  upstream code is vendored into this repo.
- Weights are runtime data, kept out of the Nix store and out of git.

## Developing the patch

```sh
scripts/vendor-dev.sh                                   # writable checkout in ./vendor
# edit vendor/mapkurator-spotter/spotter-v2/...
git -C vendor/mapkurator-spotter diff > patches/apple-mps.patch
```

## License

Derivative of `mapkurator-spotter`, which is **CC BY-NC 2.0**
(Attribution-NonCommercial). This repository and its patch are therefore for
**non-commercial** use and retain attribution to the upstream authors. See
[`NOTICE`](./NOTICE) for full provenance and the licenses of bundled-by-reference
components (Deformable-DETR and AdelaiDet/Detectron2 are Apache-2.0).
