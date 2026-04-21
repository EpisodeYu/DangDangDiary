"""LLM latency + quality benchmark for voice-intake intent extraction.

Compares three Qwen models on the DashScope **Singapore** OpenAI-compatible
endpoint (`dashscope-intl.aliyuncs.com/compatible-mode/v1`) using the
production `voice_intake` system prompt verbatim:

* `qwen-plus`       — current production alias (now Qwen 3.5 under the hood)
* `qwen-flash`      — smaller/faster variant
* `qwen3.6-plus`    — newest Qwen-3.6 tier

Each model is fed the same 6 golden transcripts (4 intents + ambiguous +
unknown), N iterations each. We report per-model latency percentiles plus
field-level correctness vs a hand-labeled expected draft.

Usage:
    cd backend && source .venv/bin/activate
    python scripts/llm_bench.py [-n 3]
    python scripts/llm_bench.py --models qwen-plus qwen-flash
    python scripts/llm_bench.py --region beijing     # benchmark BJ instead
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Load .env so we don't depend on the app bootstrap.
BACKEND_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = BACKEND_DIR / ".env"
if ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip())

sys.path.insert(0, str(BACKEND_DIR))
from app.services.llm import SYSTEM_PROMPT, _build_user_message  # noqa: E402

DASHSCOPE_KEY_BJ = os.environ["DASHSCOPE_API_KEY"]
DASHSCOPE_KEY_SG = os.environ["DASHSCOPE_API_KEY_SAG"]

REGIONS = {
    "singapore": (DASHSCOPE_KEY_SG, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
    "beijing":   (DASHSCOPE_KEY_BJ, "https://dashscope.aliyuncs.com/compatible-mode/v1"),
}


# ----------------------------------------------------- golden dataset

@dataclass(frozen=True)
class GoldenCase:
    """One test transcript with the fields we expect the LLM to pull out.

    A field is counted as "correct" iff the LLM's value matches `expected`
    exactly (after stripping). Unspecified expected fields are ignored
    (they may or may not appear in the output).
    """
    name: str
    transcript: str
    known_pets: list[str]
    default_pet: str | None
    expected: dict[str, Any]


# Known-pets is ["咪咪", "小白"] for most cases so we can exercise
# closed-set matching and the homophone case ("米米" → should map to
# "咪咪"). Default pet is None unless noted.
GOLDEN: list[GoldenCase] = [
    GoldenCase(
        name="deworming_simple",
        transcript="今天给咪咪做了体内驱虫",
        known_pets=["咪咪", "小白"],
        default_pet=None,
        expected={
            "intent": "deworming",
            "pet_name": "咪咪",
            "deworming_type": "internal",
            "dewormed_at": "today",
        },
    ),
    GoldenCase(
        name="vaccination_yesterday",
        transcript="昨天给小白打了狂犬疫苗",
        known_pets=["咪咪", "小白"],
        default_pet=None,
        expected={
            "intent": "vaccination",
            "pet_name": "小白",
            "vaccine_name": "狂犬",  # substring match below
            "vaccinated_at": "yesterday",
        },
    ),
    GoldenCase(
        name="weight_with_decimal",
        transcript="咪咪今天称了 4.2 公斤",
        known_pets=["咪咪", "小白"],
        default_pet=None,
        expected={
            "intent": "weight",
            "pet_name": "咪咪",
            "weight_kg": 4.2,
            "weighed_at": "today",
        },
    ),
    GoldenCase(
        name="routine_bath_3days_ago",
        transcript="三天前给小白洗了个澡",
        known_pets=["咪咪", "小白"],
        default_pet=None,
        expected={
            "intent": "routine",
            "pet_name": "小白",
            "routine_type": "bath",
            "routine_at": "N_days_ago:3",
        },
    ),
    GoldenCase(
        name="homophone_mimi",
        # STT often mis-hears 咪咪 as 米米; the closed-set match must fix it.
        transcript="今天给米米做了外驱",
        known_pets=["咪咪", "小白"],
        default_pet="咪咪",
        expected={
            "intent": "deworming",
            "pet_name": "咪咪",
            "deworming_type": "external",
            "dewormed_at": "today",
        },
    ),
    GoldenCase(
        name="unknown_small_talk",
        transcript="今天天气真好啊",
        known_pets=["咪咪", "小白"],
        default_pet=None,
        expected={
            "intent": "unknown",
        },
    ),
]


# ------------------------------------------------------------- scoring

def _field_match(expected: Any, actual: Any, *, field: str) -> bool:
    if expected is None:
        return actual is None
    if field == "vaccine_name" and isinstance(expected, str) and isinstance(actual, str):
        # Accept any vaccine name that contains the expected substring
        # (e.g. "狂犬" matches "狂犬疫苗" / "狂犬病疫苗").
        return expected in actual
    if field == "weight_kg":
        try:
            return abs(float(expected) - float(actual)) < 1e-6
        except (TypeError, ValueError):
            return False
    if isinstance(expected, str) and isinstance(actual, str):
        return expected.strip() == actual.strip()
    return expected == actual


def _score_case(expected: dict[str, Any], actual: dict[str, Any]) -> tuple[int, int, list[str]]:
    hits = 0
    misses: list[str] = []
    for k, v in expected.items():
        if _field_match(v, actual.get(k), field=k):
            hits += 1
        else:
            misses.append(f"{k}={actual.get(k)!r} expected={v!r}")
    return hits, len(expected), misses


# ------------------------------------------------------------- runner

async def _call(client, model: str, case: GoldenCase) -> tuple[float, dict[str, Any], str | None]:
    user_msg = _build_user_message(
        case.transcript,
        known_pet_names=case.known_pets,
        default_pet_name=case.default_pet,
    )

    # qwen3.x models default to thinking-mode, which makes them 10x
    # slower and wraps the response in a reasoning block. Disable it
    # explicitly so we measure the realistic production path.
    extra_body: dict[str, Any] = {}
    if model.startswith("qwen3") or model.startswith("qwq"):
        extra_body["enable_thinking"] = False

    t0 = time.perf_counter()
    try:
        resp = await client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_msg},
            ],
            response_format={"type": "json_object"},
            temperature=0,
            top_p=1,
            max_tokens=300,
            seed=42,
            extra_body=extra_body or None,
        )
    except Exception as e:  # noqa: BLE001
        return time.perf_counter() - t0, {}, f"{type(e).__name__}: {e}"

    dt = time.perf_counter() - t0
    raw = resp.choices[0].message.content or "{}"
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return dt, {}, f"bad_json: {raw[:200]!r}"
    if not isinstance(parsed, dict):
        return dt, {}, "not_object"
    return dt, parsed, None


def _pct(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


async def bench_model(
    model: str, *, region: str, n: int,
) -> None:
    from openai import AsyncOpenAI

    api_key, base_url = REGIONS[region]
    client = AsyncOpenAI(api_key=api_key, base_url=base_url)

    print(f"\n{'='*78}\n== {model}  @ {region}  (N={n} per case, {len(GOLDEN)} cases)\n{'='*78}")

    all_lat: list[float] = []
    total_hits = 0
    total_expected = 0
    errors = 0
    per_case_rows: list[tuple[str, list[float], int, int, list[str]]] = []

    for case in GOLDEN:
        case_lat: list[float] = []
        case_hits_sum = 0
        case_expected_sum = 0
        last_misses: list[str] = []
        for i in range(n):
            dt, parsed, err = await _call(client, model, case)
            if err is not None:
                print(f"  [{case.name:28s}] iter {i+1}/{n}  FAIL  {dt:5.2f}s  {err}")
                errors += 1
                continue
            parsed.pop("_raw", None)
            hits, expected_n, misses = _score_case(case.expected, parsed)
            case_lat.append(dt)
            case_hits_sum += hits
            case_expected_sum += expected_n
            last_misses = misses
            print(
                f"  [{case.name:28s}] iter {i+1}/{n}  {dt:5.2f}s  "
                f"fields {hits}/{expected_n}"
                + (f"  miss={misses}" if misses else "")
            )
        all_lat.extend(case_lat)
        total_hits += case_hits_sum
        total_expected += case_expected_sum
        per_case_rows.append(
            (case.name, case_lat, case_hits_sum, case_expected_sum, last_misses)
        )

    print("\n-- summary --")
    print(f"  {'case':30s} {'runs':>4s}  {'avg':>6s}  {'p50':>6s}  {'p90':>6s}  fields")
    for name, lat, h, e, _ in per_case_rows:
        if lat:
            print(
                f"  {name:30s} {len(lat):>4d}  "
                f"{statistics.mean(lat):>5.2f}s  {_pct(lat,0.5):>5.2f}s  "
                f"{_pct(lat,0.9):>5.2f}s  {h}/{e}"
            )
        else:
            print(f"  {name:30s} {0:>4d}  (all failed)")
    if all_lat:
        print(
            f"\n  OVERALL  runs={len(all_lat)} errors={errors}  "
            f"min={min(all_lat):.2f}s  avg={statistics.mean(all_lat):.2f}s  "
            f"p50={_pct(all_lat,0.5):.2f}s  p90={_pct(all_lat,0.9):.2f}s  "
            f"max={max(all_lat):.2f}s"
        )
        print(
            f"  FIELD ACCURACY  {total_hits}/{total_expected} "
            f"= {100*total_hits/total_expected:.1f}%"
        )
    else:
        print(f"\n  all {errors} calls failed")


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--iterations", type=int, default=3,
                    help="iterations per golden case (default 3)")
    ap.add_argument(
        "--models",
        nargs="+",
        default=["qwen-plus", "qwen-flash", "qwen3.6-plus"],
    )
    ap.add_argument("--region", choices=list(REGIONS), default="singapore")
    args = ap.parse_args()

    print(f"region={args.region}  iterations={args.iterations}  models={args.models}")

    for m in args.models:
        await bench_model(m, region=args.region, n=args.iterations)

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
