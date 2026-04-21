"""STT latency benchmark — compare three STT providers end-to-end.

Runs each provider N times against the same 3.1s 16kHz WAV clip and
reports min / avg / p50 / p90 / max wall-clock elapsed time.

Providers compared
------------------
1. DashScope (Beijing) paraformer-v1     — current production config
2. DashScope (Beijing) fun-asr           — newer model, same region
3. DashScope (Singapore) fun-asr         — SAG key + intl endpoint
4. Aliyun FlashRecognizer (Shanghai)     — 录音文件识别极速版, RESTful

Usage:
    cd backend && source .venv/bin/activate
    python scripts/stt_bench.py [-n 5] [--audio /tmp/stt_bench/nls-sample-16k.wav]

All credentials are read from backend/.env.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from http import HTTPStatus
from pathlib import Path
from typing import Callable
from urllib import request as urllib_request

# Load .env manually so we don't depend on the app bootstrapping order.
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
ALIYUN_AK_ID = os.environ["ALIYUN_ACCESS_KEY_ID"]
ALIYUN_AK_SECRET = os.environ["ALIYUN_ACCESS_KEY_SECRET"]
ALIYUN_STT_APP_KEY = os.environ["ALIYUN_STT_APP_KEY"]

# Public CDN sample — reachable from both BJ and SG DashScope. Used only
# for the URL-based (async) DashScope path.
PUBLIC_SAMPLE_URL = (
    "https://gw.alipayobjects.com/os/bmw-prod/"
    "0574ee2e-f494-45a5-820f-63aee583045a.wav"
)


# ------------------------------------------------------------------ utils

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


def summarize(name: str, samples: list[float], errors: list[str]) -> None:
    print(f"\n== {name} ==")
    if not samples:
        print(f"  all {len(errors)} runs failed:")
        for e in errors[:3]:
            print(f"    - {e}")
        return
    print(
        f"  ok={len(samples)}/{len(samples)+len(errors)}  "
        f"min={min(samples):.2f}s  avg={statistics.mean(samples):.2f}s  "
        f"p50={pct(samples,0.5):.2f}s  p90={pct(samples,0.9):.2f}s  "
        f"max={max(samples):.2f}s"
    )
    print(f"  samples: {[f'{x:.2f}' for x in samples]}")
    if errors:
        print(f"  errors ({len(errors)}):")
        for e in errors[:3]:
            print(f"    - {e}")


def run(name: str, n: int, fn: Callable[[], str]) -> None:
    samples: list[float] = []
    errors: list[str] = []
    print(f"\n>>> {name}: running {n} iterations ...")
    for i in range(n):
        t0 = time.perf_counter()
        try:
            text = fn()
        except Exception as e:  # noqa: BLE001
            dt = time.perf_counter() - t0
            msg = f"iter#{i+1} fail={type(e).__name__}: {e} (elapsed {dt:.2f}s)"
            print(f"  [{i+1}/{n}] FAIL {dt:.2f}s  {type(e).__name__}: {e}")
            errors.append(msg)
            continue
        dt = time.perf_counter() - t0
        snippet = (text or "")[:40].replace("\n", " ")
        print(f"  [{i+1}/{n}] ok   {dt:.2f}s  text={snippet!r}")
        samples.append(dt)
    summarize(name, samples, errors)


# ---------------------------------------------------- DashScope providers

def _dashscope_transcribe(api_key: str, base_url: str, model: str) -> str:
    """Async file-transcription path — mirrors app/services/stt.py."""
    import dashscope
    from dashscope.audio.asr import Transcription

    dashscope.api_key = api_key
    dashscope.base_http_api_url = base_url

    submit = Transcription.async_call(
        model=model,
        file_urls=[PUBLIC_SAMPLE_URL],
        language_hints=["zh", "en"],
    )
    if submit.status_code != HTTPStatus.OK:
        raise RuntimeError(f"submit {submit.status_code} {submit.message}")
    task_id = submit.output["task_id"]

    result = Transcription.wait(task=task_id, timeout=40)
    if result.status_code != HTTPStatus.OK:
        raise RuntimeError(f"wait {result.status_code} {result.message}")
    out = dict(result.output)
    if out.get("task_status") != "SUCCEEDED":
        raise RuntimeError(f"task_status={out.get('task_status')}")

    first = out["results"][0]
    if first.get("subtask_status") != "SUCCEEDED":
        raise RuntimeError(
            f"subtask={first.get('subtask_status')} {first.get('message')}"
        )
    doc = json.loads(
        urllib_request.urlopen(first["transcription_url"], timeout=10).read().decode("utf-8")
    )
    parts: list[str] = []
    for tr in doc.get("transcripts") or []:
        t = tr.get("text")
        if t:
            parts.append(t.strip())
    return " ".join(parts)


# ---------------------------------------------- Aliyun FlashRecognizer

def _get_nls_token() -> str:
    """Fetch a fresh NLS token via CreateToken (valid ~24h)."""
    from aliyunsdkcore.client import AcsClient
    from aliyunsdkcore.request import CommonRequest

    client = AcsClient(ALIYUN_AK_ID, ALIYUN_AK_SECRET, "cn-shanghai")
    req = CommonRequest()
    req.set_method("POST")
    req.set_domain("nls-meta.cn-shanghai.aliyuncs.com")
    req.set_version("2019-02-28")
    req.set_action_name("CreateToken")
    resp = client.do_action_with_exception(req)
    data = json.loads(resp.decode("utf-8"))
    token = data["Token"]["Id"]
    return token


def _flash_recognize_binary(audio_path: Path, token: str, region: str) -> str:
    """Aliyun 录音文件识别极速版 — binary upload, sync response."""
    import httpx

    url = (
        f"https://nls-gateway-cn-{region}.aliyuncs.com/stream/v1/FlashRecognizer"
        f"?appkey={ALIYUN_STT_APP_KEY}&token={token}"
        f"&format=wav&sample_rate=16000"
    )
    data = audio_path.read_bytes()
    headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": str(len(data)),
    }
    with httpx.Client(timeout=httpx.Timeout(60.0, connect=15.0)) as c:
        r = c.post(url, content=data, headers=headers)
    r.raise_for_status()
    body = r.json()
    if body.get("status") != 20000000:
        raise RuntimeError(f"status={body.get('status')} msg={body.get('message')}")
    sentences = (body.get("flash_result") or {}).get("sentences") or []
    return "".join(s.get("text", "") for s in sentences)


def _flash_recognize_url(audio_url: str, token: str, region: str) -> str:
    """Aliyun 录音文件识别极速版 — audio_address (URL) mode."""
    import httpx
    from urllib.parse import quote

    url = (
        f"https://nls-gateway-cn-{region}.aliyuncs.com/stream/v1/FlashRecognizer"
        f"?appkey={ALIYUN_STT_APP_KEY}&token={token}"
        f"&format=wav&sample_rate=16000"
        f"&audio_address={quote(audio_url, safe='')}"
    )
    headers = {"Content-Type": "application/text"}
    with httpx.Client(timeout=httpx.Timeout(60.0, connect=15.0)) as c:
        r = c.post(url, headers=headers)
    r.raise_for_status()
    body = r.json()
    if body.get("status") != 20000000:
        raise RuntimeError(f"status={body.get('status')} msg={body.get('message')}")
    sentences = (body.get("flash_result") or {}).get("sentences") or []
    return "".join(s.get("text", "") for s in sentences)


# --------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--iterations", type=int, default=5)
    ap.add_argument(
        "--audio",
        type=Path,
        default=Path("/tmp/stt_bench/nls-sample-16k.wav"),
        help="Local WAV file (16k mono) for FlashRecognizer binary upload",
    )
    ap.add_argument(
        "--only",
        choices=[
            "bj-paraformer", "bj-funasr", "sg-funasr",
            "flash-sh", "flash-bj", "flash-sz",
            "flash-sh-url", "flash-bj-url", "flash-sz-url",
            "all",
        ],
        default="all",
    )
    args = ap.parse_args()

    if not args.audio.exists():
        print(f"audio file missing: {args.audio}", file=sys.stderr)
        return 2

    print(f"config: iterations={args.iterations}  audio={args.audio} "
          f"({args.audio.stat().st_size/1024:.1f} KB)")
    print(f"        public_url={PUBLIC_SAMPLE_URL}")

    if args.only in ("bj-paraformer", "all"):
        run(
            "DashScope Beijing paraformer-v1 (current prod)",
            args.iterations,
            lambda: _dashscope_transcribe(
                DASHSCOPE_KEY_BJ,
                "https://dashscope.aliyuncs.com/api/v1",
                "paraformer-v1",
            ),
        )

    if args.only in ("bj-funasr", "all"):
        run(
            "DashScope Beijing fun-asr",
            args.iterations,
            lambda: _dashscope_transcribe(
                DASHSCOPE_KEY_BJ,
                "https://dashscope.aliyuncs.com/api/v1",
                "fun-asr",
            ),
        )

    if args.only in ("sg-funasr", "all"):
        run(
            "DashScope Singapore fun-asr (SAG key)",
            args.iterations,
            lambda: _dashscope_transcribe(
                DASHSCOPE_KEY_SG,
                "https://dashscope-intl.aliyuncs.com/api/v1",
                "fun-asr",
            ),
        )

    need_flash = args.only == "all" or args.only.startswith("flash-")
    if need_flash:
        print("\n>>> fetching NLS token for FlashRecognizer ...")
        t0 = time.perf_counter()
        token = _get_nls_token()
        print(f"    token obtained in {time.perf_counter()-t0:.2f}s "
              f"(head={token[:8]}... len={len(token)})")
    else:
        token = ""

    for region, flag in (("shanghai", "flash-sh"), ("beijing", "flash-bj"), ("shenzhen", "flash-sz")):
        if args.only in (flag, "all"):
            run(
                f"Aliyun FlashRecognizer ({region}, binary upload)",
                args.iterations,
                lambda r=region: _flash_recognize_binary(args.audio, token, r),
            )

    for region, flag in (("shanghai", "flash-sh-url"), ("beijing", "flash-bj-url"), ("shenzhen", "flash-sz-url")):
        if args.only in (flag, "all"):
            run(
                f"Aliyun FlashRecognizer ({region}, audio_address URL)",
                args.iterations,
                lambda r=region: _flash_recognize_url(PUBLIC_SAMPLE_URL, token, r),
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
