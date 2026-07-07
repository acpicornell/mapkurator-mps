{
  description = "Apple Silicon (MPS/CPU) port of the mapKurator spotter-v2 text spotter — no CUDA required";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Upstream spotter source, pinned by commit (flake.lock). Not a flake, so
    # we consume its source tree directly and patch it in a derivation.
    mapkurator-spotter = {
      url = "github:knowledge-computing/mapkurator-spotter/4686d2e666f923303a4c8c9a609a77e1ac57234c";
      flake = false;
    };

    # Upstream mapKurator *system* source, pinned by commit. Only two small,
    # self-contained, CPU-only scripts are used from it: M1 cropping
    # (m2_detection_recognition/crop_img.py) and M3 stitching
    # (m3_image_geojson/stitch_output.py). The heavy modules (m4/m5/m6, which
    # need Elasticsearch/PostGIS/GDAL) are intentionally not used here.
    mapkurator-system = {
      url = "github:knowledge-computing/mapkurator-system/5b765d99c4898ce07654d904b6f3b608b9e76189";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mapkurator-spotter, mapkurator-system }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Python runtime for the spotter (spotter-v2 = AdelaiDet/Detectron2 text
      # spotter). No CUDA op is compiled; the Apple/MPS patch routes multi-scale
      # deformable attention through the pure-PyTorch reference implementation.
      mkPyEnv = pkgs: pkgs.python3.withPackages (ps: with ps; [
        torch
        torchvision
        detectron2
        # spotter-v2 install_requires (AdelaiDet)
        termcolor
        pillow
        yacs
        tabulate
        cloudpickle
        matplotlib
        tqdm
        tensorboard
        rapidfuzz
        shapely
        scikit-image
        editdistance
        opencv4
        numba
        geojson       # M3 stitching (mapkurator-system/m3_image_geojson)
        # helpers used by tools + detectron2
        pycocotools
        pandas
        numpy
        scipy
        requests
      ]);

      # Upstream source with the Apple/MPS patch applied — reproducible, no
      # mutable checkout. This IS the port.
      mkPatchedSrc = pkgs: pkgs.applyPatches {
        name = "mapkurator-spotter-mps-src";
        src = mapkurator-spotter;
        patches = [ ./patches/apple-mps.patch ];
      };

      mkSpotter = pkgs:
        let
          pyEnv = mkPyEnv pkgs;
          patchedSrc = mkPatchedSrc pkgs;
          # Sensible default backend: Apple GPU on macOS, CPU elsewhere.
          defaultDevice = if pkgs.stdenv.isDarwin then "mps" else "cpu";
        in
        pkgs.writeShellApplication {
          name = "mapkurator-spotter";
          runtimeInputs = [ pyEnv ];
          text = ''
            # Any op missing on the MPS backend falls back to CPU rather than erroring.
            export PYTORCH_ENABLE_MPS_FALLBACK=1

            SPOTTER_DIR="${patchedSrc}/spotter-v2"
            # M1 crop + M3 stitch scripts come from the mapkurator-system source.
            SYSTEM_DIR="${mapkurator-system}"
            # tools/ must be importable (inference.py does `from predictor import ...`).
            export PYTHONPATH="$SPOTTER_DIR:$SPOTTER_DIR/tools''${PYTHONPATH:+:$PYTHONPATH}"

            config="$SPOTTER_DIR/configs/inference_en_test.yaml"
            device="${defaultDevice}"
            threshold="0.3"
            weights="''${MAPKURATOR_WEIGHTS:-}"
            input=""
            output=""

            usage() {
              cat <<'EOF'
            mapkurator-spotter — Apple/MPS port of the mapKurator spotter-v2

            Usage:
              mapkurator-spotter --input PATH --output DIR --weights model.pth [options]

            Two input modes (auto-detected):
              --input IMAGE  End-to-end: crop (M1) → spot (M2) → stitch (M3),
                             writing one GeoJSON  <output>/<map_name>.geojson
              --input DIR    Tile directory: spot each tile, writing per-tile
                             JSON detections into <output>/ (original behavior)

            Required:
              --input   PATH    A map image file, or a directory of image tiles
              --output  DIR     Output directory (GeoJSON, or per-tile JSON)
              --weights PATH    Spotter checkpoint (.pth); or set MAPKURATOR_WEIGHTS

            Options:
              --device  DEV     mps | cpu | cuda   (default: mps on macOS, cpu elsewhere)
              --config  PATH    Detectron2 config  (default: bundled inference_en_test.yaml)
              --threshold N     Detection score threshold (default: 0.3)
              -h, --help        Show this help

            Weights are NOT bundled. Fetch them with scripts/get-weights.sh.
            EOF
            }

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --input)     input="$2";     shift 2 ;;
                --output)    output="$2";    shift 2 ;;
                --weights)   weights="$2";   shift 2 ;;
                --device)    device="$2";    shift 2 ;;
                --config)    config="$2";    shift 2 ;;
                --threshold) threshold="$2"; shift 2 ;;
                -h|--help)   usage; exit 0 ;;
                *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
              esac
            done

            [[ -n "$input"   ]] || { echo "Error: --input is required" >&2;   exit 2; }
            [[ -n "$output"  ]] || { echo "Error: --output is required" >&2;  exit 2; }
            [[ -n "$weights" ]] || { echo "Error: --weights is required (or set MAPKURATOR_WEIGHTS)" >&2; exit 2; }

            # Run the spotter (M2) over a directory of tiles: $1 in-dir, $2 out-dir.
            run_spotter() {
              python "$SPOTTER_DIR/tools/inference.py" \
                --config-file "$config" \
                --output_json \
                --input "$1" \
                --output "$2" \
                --opts \
                  MODEL.WEIGHTS "$weights" \
                  MODEL.DEVICE "$device" \
                  MODEL.TRANSFORMER.INFERENCE_TH_TEST "$threshold"
            }

            # M1/M3 crop and stitch use a fixed 1000px tile/shift grid (no overlap).
            shift_size=1000

            if [[ -d "$input" ]]; then
              # Tile-directory mode (original behavior): per-tile JSON in $output.
              mkdir -p "$output"
              exec run_spotter "$input" "$output"
            elif [[ -f "$input" ]]; then
              # End-to-end mode: whole map image -> single GeoJSON.
              map_name="$(basename "$input")"; map_name="''${map_name%.*}"
              work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

              echo "[M1] cropping $input into ''${shift_size}px tiles..." >&2
              python "$SYSTEM_DIR/m2_detection_recognition/crop_img.py" \
                --img_path "$input" --output_dir "$work/tiles"

              echo "[M2] spotting text on tiles..." >&2
              run_spotter "$work/tiles/$map_name" "$work/json/$map_name"

              mkdir -p "$output"
              out_geojson="$output/$map_name.geojson"
              echo "[M3] stitching tiles into $out_geojson ..." >&2
              python "$SYSTEM_DIR/m3_image_geojson/stitch_output.py" \
                --input_dir "$work/json/$map_name" \
                --output_geojson "$out_geojson" \
                --shift_size "$shift_size"

              echo "Wrote $out_geojson"
            else
              echo "Error: --input '$input' is neither a file nor a directory" >&2
              exit 2
            fi
          '';
        };
    in
    {
      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; }; in
        {
          default = mkSpotter pkgs;
          spotter = mkSpotter pkgs;
          # The patched source tree on its own, for inspection / downstream use.
          src = mkPatchedSrc pkgs;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.spotter}/bin/mapkurator-spotter";
        };
        spotter = self.apps.${system}.default;
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pyEnv = mkPyEnv pkgs;
        in
        {
          default = pkgs.mkShell {
            # pyEnv for running/importing the spotter; gdown to fetch weights.
            packages = [ pyEnv pkgs.git pkgs.python3Packages.gdown ];
            PYTORCH_ENABLE_MPS_FALLBACK = "1";
            shellHook = ''
              echo "mapkurator-spotter-mps dev shell — $(python --version 2>&1)"
              echo "Run: scripts/vendor-dev.sh   to get a writable checkout for editing the patch."
            '';
          };
        });
    };
}
