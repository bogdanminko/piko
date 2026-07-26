# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-audio"]
# ///
"""mlx-audio STT benchmark runner.

Usage: uv run --script bench_mlx_audio.py <audio.wav> [model_repo] [dtype]

dtype: "bf16" | "fp16" | omitted.
- parakeet models: omitted = mlx-audio's public `load_model` path, which keeps
  checkpoint dtype (fp32!); "bf16" loads via the vendored `Model.from_pretrained`
  with a bfloat16 cast. Chunking 120 s / 15 s overlap (single pass OOMs Metal
  on 30 min).
- whisper models: loaded via `Model.from_pretrained` with the requested dtype
  (default fp16, the model's native default); whisper has its own 30 s window
  loop, so no chunk kwargs.

Emits one JSON line to stdout.
"""

import json
import sys
import time
import warnings


def main() -> None:
    audio = sys.argv[1]
    model_repo = sys.argv[2] if len(sys.argv) > 2 else "mlx-community/parakeet-tdt-0.6b-v3"
    dtype_arg = sys.argv[3] if len(sys.argv) > 3 else None

    import mlx.core as mx

    is_whisper = "whisper" in model_repo.lower()
    dtypes = {"bf16": mx.bfloat16, "fp16": mx.float16}

    warnings.simplefilter("ignore", DeprecationWarning)
    t0 = time.perf_counter()
    if is_whisper:
        # The deprecated whisper Model.from_pretrained can't read HF-layout repos
        # (only sanitize() in the public load path remaps `model.encoder.*` keys),
        # so load fp16 via the public API and re-cast parameters afterwards.
        from mlx.utils import tree_map
        from mlx_audio.stt.utils import load_model

        model = load_model(model_repo)
        want = dtypes.get(dtype_arg, mx.float16)
        if want != mx.float16:
            model.update(
                tree_map(
                    lambda p: p.astype(want) if mx.issubdtype(p.dtype, mx.floating) else p,
                    model.parameters(),
                )
            )
            model.dtype = want
            # sinusoidal positional embedding is a plain attribute, not a parameter
            enc = model.encoder
            if hasattr(enc, "_positional_embedding"):
                enc._positional_embedding = enc._positional_embedding.astype(want)
            # mlx-audio's whisper decoder hardcodes fp16: it casts the mel to fp16
            # and asserts the encoder output is fp16/fp32, so bf16 weights raise a
            # TypeError. Patch the method to follow the model dtype instead.
            from mlx_audio.stt.models.whisper import decoding

            def _get_audio_features(self, mel):
                mel = mel.astype(self.model.dtype)
                if mel.shape[-2:] == (
                    self.model.dims.n_audio_ctx,
                    self.model.dims.n_audio_state,
                ):
                    return mel
                return self.model.encoder(mel)

            decoding.DecodingTask._get_audio_features = _get_audio_features
        mx.eval(model.parameters())
    elif dtype_arg in dtypes:
        from mlx_audio.stt.models.parakeet.parakeet import Model

        model = Model.from_pretrained(model_repo, dtype=dtypes[dtype_arg])
        mx.eval(model.parameters())
    else:
        from mlx_audio.stt.utils import load_model

        model = load_model(model_repo)
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    if is_whisper:
        result = model.generate(audio, language="ru")
    else:
        result = model.generate(audio, chunk_duration=120.0, overlap_duration=15.0)
    transcribe_s = time.perf_counter() - t1

    text = getattr(result, "text", None)
    if text is None:
        text = str(result)

    json.dump(
        {
            "engine": "mlx-audio" + (f"-{dtype_arg}" if dtype_arg else ""),
            "model": model_repo,
            "load_s": load_s,
            "transcribe_s": transcribe_s,
            "text": text,
        },
        sys.stdout,
        ensure_ascii=False,
    )
    print()


if __name__ == "__main__":
    main()
