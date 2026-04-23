"""Benchmark DashScope real-time ASR (WebSocket streaming mode).

Unlike ``stt_bench.py`` which tests the async file-transcription API,
this script streams a local WAV/PCM file over the WebSocket-based
``Recognition`` class of the ``dashscope`` SDK. It's the mode
``paraformer-realtime-v2`` / ``fun-asr-realtime`` were designed for.

Two feed strategies are measured:

1. ``fast`` — send all PCM chunks back-to-back, no pacing. This is the
   theoretical lower bound for "user already finished speaking" case;
   the server processes as fast as it can.
2. ``realtime`` — send chunks paced at 100ms/chunk (matches the docs'
   example loop with ``time.sleep(0.1)``). Lower bound is then ≈ the
   audio clip's length.

Metrics printed per iteration:

* ``total`` — wall-clock seconds from ``recognition.start()`` to
  ``on_complete`` fired.
* ``first_pkg`` — ``recognition.get_first_package_delay()`` in ms.
* ``last_pkg`` — ``recognition.get_last_package_delay()`` in ms.
* ``stop`` — seconds the blocking ``recognition.stop()`` call took
  after the final chunk was sent (this is the latency the user
  actually sees in a "send-then-wait" product like ours).

Usage
-----
    cd backend && source .venv/bin/activate
    python scripts/stt_realtime_bench.py [-n 5]
"""
from __future__ import annotations

import argparse
import os
import statistics
import sys
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

BACKEND_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = BACKEND_DIR / ".env"
if ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip())


DASHSCOPE_KEY_BJ = os.environ["DASHSCOPE_API_KEY"]
DASHSCOPE_KEY_SG = os.environ["DASHSCOPE_API_KEY_SAG"]

# Both WebSocket entry points. The realtime models differ per region:
# SG exposes `fun-asr-realtime` (and nothing else); BJ exposes both
# `paraformer-realtime-v2` and `fun-asr-realtime`.
WS_URL_BJ = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
WS_URL_SG = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


@dataclass
class Sample:
    total: float
    stop_wait: float
    first_pkg_ms: int
    last_pkg_ms: int
    text: str


def summarize(name: str, samples: list[Sample], errors: list[str]) -> None:
    print(f"\n== {name} ==")
    if not samples:
        print(f"  all {len(errors)} runs failed:")
        for e in errors[:3]:
            print(f"    - {e}")
        return
    totals = [s.total for s in samples]
    stops = [s.stop_wait for s in samples]
    firsts = [float(s.first_pkg_ms) for s in samples]
    print(
        f"  ok={len(samples)}/{len(samples)+len(errors)}  "
        f"total  min={min(totals):.2f}s  p50={pct(totals,0.5):.2f}s  "
        f"p90={pct(totals,0.9):.2f}s  max={max(totals):.2f}s"
    )
    print(
        f"  stop_wait (user-perceived after last chunk)  "
        f"min={min(stops):.2f}s  p50={pct(stops,0.5):.2f}s  "
        f"p90={pct(stops,0.9):.2f}s  max={max(stops):.2f}s"
    )
    print(
        f"  first_pkg_delay  "
        f"min={min(firsts):.0f}ms  p50={pct(firsts,0.5):.0f}ms  "
        f"max={max(firsts):.0f}ms"
    )
    print(f"  samples: {[f'{s.total:.2f}s/stop={s.stop_wait:.2f}s' for s in samples]}")
    if errors:
        print(f"  errors ({len(errors)}):")
        for e in errors[:3]:
            print(f"    - {e}")


def _read_pcm_from_wav(path: Path) -> tuple[bytes, int]:
    with wave.open(str(path), "rb") as wf:
        if wf.getsampwidth() != 2 or wf.getnchannels() != 1:
            raise RuntimeError("bench expects 16-bit mono PCM WAV")
        sample_rate = wf.getframerate()
        data = wf.readframes(wf.getnframes())
    return data, sample_rate


def _run_realtime_once(
    *,
    api_key: str,
    ws_url: str,
    model: str,
    pcm: bytes,
    sample_rate: int,
    pace: str,  # "fast" | "realtime"
    chunk_bytes: int = 3200,  # 100ms @ 16kHz 16-bit
) -> Sample:
    import dashscope
    from dashscope.audio.asr import (
        Recognition,
        RecognitionCallback,
        RecognitionResult,
    )

    dashscope.api_key = api_key
    dashscope.base_websocket_api_url = ws_url

    captured: list[str] = []
    complete_evt = threading.Event()
    error_box: list[str] = []

    class _CB(RecognitionCallback):
        def on_open(self) -> None:
            pass

        def on_close(self) -> None:
            pass

        def on_complete(self) -> None:
            complete_evt.set()

        def on_error(self, message) -> None:  # type: ignore[override]
            error_box.append(f"{getattr(message, 'request_id', '?')}: "
                             f"{getattr(message, 'message', message)}")
            complete_evt.set()

        def on_event(self, result) -> None:  # type: ignore[override]
            sent = result.get_sentence()
            if isinstance(sent, dict) and "text" in sent:
                if RecognitionResult.is_sentence_end(sent):
                    captured.append(sent["text"])

    cb = _CB()
    recognition = Recognition(
        model=model,
        format="pcm",
        sample_rate=sample_rate,
        callback=cb,
    )

    t0 = time.perf_counter()
    recognition.start()

    offset = 0
    while offset < len(pcm):
        remaining = len(pcm) - offset
        n = min(chunk_bytes, remaining)
        recognition.send_audio_frame(pcm[offset:offset + n])
        offset += n
        if pace == "realtime":
            time.sleep(0.1)
        # "fast": no sleep — as fast as the uplink allows

    last_chunk_sent_at = time.perf_counter()

    # `recognition.stop()` blocks until the server flushes its final
    # transcription result. Use a wall-clock fence rather than waiting
    # on the complete event because on SG the complete event is
    # sometimes fired from inside stop() itself.
    recognition.stop()
    t_stop_done = time.perf_counter()

    # Give a short grace window for any trailing `on_complete` that
    # arrives just after stop() returns.
    complete_evt.wait(timeout=2.0)

    if error_box:
        raise RuntimeError(f"realtime err: {error_box[0]}")

    total = t_stop_done - t0
    stop_wait = t_stop_done - last_chunk_sent_at
    first_pkg = int(recognition.get_first_package_delay() or 0)
    last_pkg = int(recognition.get_last_package_delay() or 0)
    text = "".join(captured).strip()
    return Sample(
        total=total,
        stop_wait=stop_wait,
        first_pkg_ms=first_pkg,
        last_pkg_ms=last_pkg,
        text=text,
    )


def run(name: str, n: int, fn: Callable[[], Sample]) -> None:
    samples: list[Sample] = []
    errors: list[str] = []
    print(f"\n>>> {name}: running {n} iterations ...")
    for i in range(n):
        try:
            s = fn()
        except Exception as e:  # noqa: BLE001
            msg = f"iter#{i+1} {type(e).__name__}: {e}"
            print(f"  [{i+1}/{n}] FAIL  {msg}")
            errors.append(msg)
            continue
        snippet = (s.text or "")[:40].replace("\n", " ")
        print(
            f"  [{i+1}/{n}] ok  total={s.total:.2f}s  "
            f"stop_wait={s.stop_wait:.2f}s  "
            f"first_pkg={s.first_pkg_ms}ms  last_pkg={s.last_pkg_ms}ms  "
            f"text={snippet!r}"
        )
        samples.append(s)
    summarize(name, samples, errors)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--iterations", type=int, default=5)
    ap.add_argument(
        "--audio",
        type=Path,
        default=Path("/tmp/stt_bench/nls-sample-16k.wav"),
    )
    ap.add_argument(
        "--only",
        choices=[
            "bj-paraformer-fast", "bj-paraformer-realtime",
            "bj-funasr-fast", "bj-funasr-realtime",
            "sg-funasr-fast", "sg-funasr-realtime",
            "all",
        ],
        default="all",
    )
    args = ap.parse_args()

    if not args.audio.exists():
        print(f"audio missing: {args.audio}", file=sys.stderr)
        return 2

    pcm, sr = _read_pcm_from_wav(args.audio)
    clip_sec = len(pcm) / (sr * 2)
    print(f"audio: {args.audio}  size={len(pcm)/1024:.1f}KB  "
          f"rate={sr}Hz  duration={clip_sec:.2f}s")
    print(f"iterations per case: {args.iterations}")

    cases = [
        ("bj-paraformer-fast",
         "BJ paraformer-realtime-v2 (fast feed)",
         WS_URL_BJ, DASHSCOPE_KEY_BJ, "paraformer-realtime-v2", "fast"),
        ("bj-paraformer-realtime",
         "BJ paraformer-realtime-v2 (100ms pacing)",
         WS_URL_BJ, DASHSCOPE_KEY_BJ, "paraformer-realtime-v2", "realtime"),
        ("bj-funasr-fast",
         "BJ fun-asr-realtime (fast feed)",
         WS_URL_BJ, DASHSCOPE_KEY_BJ, "fun-asr-realtime", "fast"),
        ("bj-funasr-realtime",
         "BJ fun-asr-realtime (100ms pacing)",
         WS_URL_BJ, DASHSCOPE_KEY_BJ, "fun-asr-realtime", "realtime"),
        ("sg-funasr-fast",
         "SG fun-asr-realtime (fast feed)",
         WS_URL_SG, DASHSCOPE_KEY_SG, "fun-asr-realtime", "fast"),
        ("sg-funasr-realtime",
         "SG fun-asr-realtime (100ms pacing)",
         WS_URL_SG, DASHSCOPE_KEY_SG, "fun-asr-realtime", "realtime"),
    ]

    for flag, label, ws_url, api_key, model, pace in cases:
        if args.only not in (flag, "all"):
            continue
        run(
            label,
            args.iterations,
            lambda a=api_key, u=ws_url, m=model, p=pace: _run_realtime_once(
                api_key=a, ws_url=u, model=m,
                pcm=pcm, sample_rate=sr, pace=p,
            ),
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
