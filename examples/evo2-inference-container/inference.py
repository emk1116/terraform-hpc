"""Example inference container entrypoint for titan-hpc.

This script demonstrates the contract between the model container and the
titan-hpc job script template:

    docker run --gpus all \
        -v /fsx/models/evo2/evo2-7b.pt:/models:ro \
        -v $WORK/input:/data/input:ro \
        -v $WORK/output:/data/output \
        <image> \
        --weights /models \
        --input /data/input/sequences.fasta \
        --output /data/output/

Your real model script replaces the mock inference below.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--weights", type=Path, required=True,
                   help="Path to weights file or directory (mounted from FSx)")
    p.add_argument("--input", type=Path, required=True,
                   help="Input file")
    p.add_argument("--output", type=Path, required=True,
                   help="Output directory")
    p.add_argument("--batch-size", type=int, default=8)
    return p.parse_args()


def main():
    args = parse_args()

    print(f"[inference] starting")
    print(f"[inference] weights: {args.weights}")
    print(f"[inference] input:   {args.input}")
    print(f"[inference] output:  {args.output}")

    # Validate
    if not args.weights.exists():
        print(f"ERROR: weights path {args.weights} not found", file=sys.stderr)
        sys.exit(1)
    if not args.input.exists():
        print(f"ERROR: input file {args.input} not found", file=sys.stderr)
        sys.exit(1)
    args.output.mkdir(parents=True, exist_ok=True)

    # Verify GPU
    try:
        import torch
        n_gpu = torch.cuda.device_count()
        print(f"[inference] torch sees {n_gpu} GPU(s)")
        if n_gpu == 0:
            print("ERROR: no GPUs visible to container", file=sys.stderr)
            sys.exit(1)
        for i in range(n_gpu):
            props = torch.cuda.get_device_properties(i)
            print(f"[inference]   GPU {i}: {props.name}, "
                  f"{props.total_memory / 1e9:.1f} GB")
    except ImportError:
        print("WARN: torch not importable; skipping GPU check")

    # === Your real inference logic goes here ===
    # Below is a mock that just reads the input, writes a result JSON, and
    # "thinks" for a couple seconds.
    input_size = args.input.stat().st_size
    print(f"[inference] input file is {input_size} bytes")

    # Example: read input, do a fake computation
    n_lines = sum(1 for _ in args.input.open("rb"))
    print(f"[inference] processing {n_lines} lines")

    time.sleep(3)  # simulate work

    # Write results
    result = {
        "input_file": str(args.input),
        "input_size_bytes": input_size,
        "input_line_count": n_lines,
        "weights_path": str(args.weights),
        "model_version": os.environ.get("MODEL_VERSION", "demo"),
        "predictions": [{"sequence_id": i, "score": 0.5} for i in range(min(10, n_lines))],
    }

    out_file = args.output / "predictions.json"
    with out_file.open("w") as f:
        json.dump(result, f, indent=2)
    print(f"[inference] wrote {out_file}")

    # Summary file
    with (args.output / "summary.txt").open("w") as f:
        f.write(f"Processed {n_lines} lines from {args.input.name}\n")
        f.write(f"Produced {len(result['predictions'])} predictions\n")

    print(f"[inference] complete")


if __name__ == "__main__":
    main()
