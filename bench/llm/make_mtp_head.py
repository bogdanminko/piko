# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx>=0.32", "huggingface-hub>=0.30"]
# ///
"""Graft a Qwen3.5 MTP head onto an already-converted MLX 4-bit checkpoint.

mlx-lm 0.31.3 drops the multi-token-prediction weights during conversion — one
line in ``qwen3_5.py``'s ``sanitize()`` — so every ``mlx-community/Qwen3.5-*``
repo declares ``mtp_num_hidden_layers: 1`` in its config and ships zero
``mtp.*`` tensors. The head is 15 tensors, and safetensors stores byte offsets
in its header, so we fetch exactly those byte ranges out of the upstream bf16
checkpoint: 487 MB for 9B instead of a 19 GB download.

Two things have to match the base checkpoint or the head is silently wrong:

* **Norms.** Raw HF norm weights need a ``+1`` shift, which the base already got
  at conversion time. The loader decides whether to shift by looking for an
  unsanitized ``conv1d``, which an already-converted directory does not have —
  so the shift has to happen here instead.
* **Quantization.** ``load_model`` quantizes a module iff ``<path>.scales`` is
  present in the weights, so writing scales/biases is what opts each projection
  in. Norms carry none and stay bf16, matching the base.

Output is a model directory whose big shards are symlinks to the HF cache plus
one real file, ``model-mtp.safetensors`` (the ``model*`` prefix is required:
``load_model`` globs ``model*.safetensors``).

Usage:
  uv run --script bench/llm/make_mtp_head.py --size 9B
  uv run --script bench/llm/make_mtp_head.py --size 4B --head-dtype bf16
"""

import argparse
import json
import struct
import sys
import urllib.request
from pathlib import Path

import mlx.core as mx
from huggingface_hub import snapshot_download

BENCH = Path(__file__).parent
OUT_ROOT = BENCH / "vendor" / "models"

SIZES = {
    "4B": ("Qwen/Qwen3.5-4B", "mlx-community/Qwen3.5-4B-4bit"),
    "9B": ("Qwen/Qwen3.5-9B", "mlx-community/Qwen3.5-9B-4bit"),
}

# Every norm the loader would shift by +1 on a raw HF checkpoint, restricted to
# the ones that live inside the MTP head (see sanitize()'s norm_keys).
NORM_SUFFIXES = (
    ".input_layernorm.weight",
    ".post_attention_layernorm.weight",
    ".q_norm.weight",
    ".k_norm.weight",
    ".pre_fc_norm_hidden.weight",
    ".pre_fc_norm_embedding.weight",
    "mtp.norm.weight",
)

DTYPE_BYTES = {"BF16": 2, "F16": 2, "F32": 4}
MX_DTYPE = {"BF16": mx.bfloat16, "F16": mx.float16, "F32": mx.float32}


def _fetch(url: str, start: int, end: int) -> bytes:
    """One HTTP range request, verified to actually be a partial response."""
    want = end - start + 1
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req) as resp:
        if resp.status != 206:
            raise RuntimeError(f"server ignored Range ({resp.status}) for {url}")
        buf = resp.read(want)
    if len(buf) != want:
        raise RuntimeError(f"short read: got {len(buf)} of {want} bytes")
    return buf


def read_header(url: str) -> tuple[dict, int]:
    """Safetensors header plus the offset where tensor data starts."""
    n = struct.unpack("<Q", _fetch(url, 0, 7))[0]
    return json.loads(_fetch(url, 8, 8 + n - 1)), 8 + n


def fetch_mtp_tensors(repo: str) -> dict[str, mx.array]:
    """Pull every mtp.* tensor out of an upstream repo by byte range."""
    base = f"https://huggingface.co/{repo}/resolve/main/"
    index = json.load(urllib.request.urlopen(base + "model.safetensors.index.json"))
    shards: dict[str, list[str]] = {}
    for key, shard in index["weight_map"].items():
        if key.startswith("mtp."):
            shards.setdefault(shard, []).append(key)

    out: dict[str, mx.array] = {}
    total = 0
    for shard, keys in sorted(shards.items()):
        url = base + shard
        header, data_start = read_header(url)
        for key in sorted(keys):
            spec = header[key]
            dtype = spec["dtype"]
            if dtype not in MX_DTYPE:
                raise RuntimeError(f"unexpected dtype {dtype} for {key}")
            beg, end = spec["data_offsets"]
            raw = _fetch(url, data_start + beg, data_start + end - 1)
            total += len(raw)
            # No numpy bf16: read as uint16 and reinterpret.
            width = DTYPE_BYTES[dtype]
            words = mx.array(memoryview(raw).cast("H" if width == 2 else "I"))
            out[key] = words.view(MX_DTYPE[dtype]).reshape(spec["shape"])
            print(f"  {key:<46s} {dtype:<5s} {str(spec['shape']):<16s} "
                  f"{len(raw) / 1e6:7.2f} MB", flush=True)
    print(f"  fetched {len(out)} tensors, {total / 1e6:.1f} MB total", flush=True)
    return out


def build(size: str, head_dtype: str, force: bool) -> Path:
    repo, base_repo = SIZES[size]
    suffix = "-mtp" if head_dtype == "quant" else f"-mtp-{head_dtype}head"
    out = OUT_ROOT / (base_repo.split("/")[-1] + suffix)
    sidecar = out / "model-mtp.safetensors"
    if sidecar.exists() and not force:
        print(f"{sidecar} exists (use --force to rebuild)")
        return out

    print(f"resolving base {base_repo} ...", flush=True)
    base_dir = Path(snapshot_download(base_repo))
    config = json.loads((base_dir / "config.json").read_text())
    quant = config.get("quantization")
    if not quant:
        sys.exit(f"{base_repo} is not a quantized checkpoint")
    print(f"  base quantization: {quant}", flush=True)

    print(f"fetching MTP head from {repo} ...", flush=True)
    weights = fetch_mtp_tensors(repo)

    shifted = 0
    for key in list(weights):
        if key.endswith(NORM_SUFFIXES) and weights[key].ndim == 1:
            weights[key] = weights[key] + 1.0
            shifted += 1
    print(f"applied the +1 norm shift to {shifted} tensors", flush=True)

    if head_dtype == "quant":
        packed: dict[str, mx.array] = {}
        for key, w in weights.items():
            if key.endswith(NORM_SUFFIXES) or w.ndim != 2:
                packed[key] = w
                continue
            wq, scales, biases = mx.quantize(
                w,
                group_size=quant["group_size"],
                bits=quant["bits"],
                mode=quant.get("mode", "affine"),
            )
            stem = key.removesuffix(".weight")
            packed[key] = wq
            packed[f"{stem}.scales"] = scales
            packed[f"{stem}.biases"] = biases
        n_quant = sum(1 for k in packed if k.endswith(".scales"))
        print(f"quantized {n_quant} projections at "
              f"{quant['bits']}-bit/g{quant['group_size']}", flush=True)
        weights = packed
    else:
        print("leaving the head in bf16 (no .scales -> loader keeps nn.Linear)",
              flush=True)

    out.mkdir(parents=True, exist_ok=True)
    for src in sorted(base_dir.iterdir()):
        if src.name.startswith("."):
            continue
        dst = out / src.name
        if dst.is_symlink() or dst.exists():
            dst.unlink()
        dst.symlink_to(src.resolve())
    mx.save_safetensors(str(sidecar), weights, metadata={"format": "mlx"})

    size_mb = sidecar.stat().st_size / 1e6
    print(f"\n-> {out}\n   model-mtp.safetensors  {size_mb:.1f} MB "
          f"({len(weights)} tensors), everything else symlinked to the HF cache")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", choices=sorted(SIZES), default="9B")
    ap.add_argument("--head-dtype", choices=["quant", "bf16"], default="quant",
                    help="quant: match the base (4-bit). bf16: test whether "
                         "quantizing the head costs acceptance.")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    build(args.size, args.head_dtype, args.force)


if __name__ == "__main__":
    main()
