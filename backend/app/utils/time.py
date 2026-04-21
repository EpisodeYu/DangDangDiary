from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo


# The product is CN-facing; every "today" the user speaks about is in
# China Standard Time (UTC+8). We fix the calendar TZ here so business
# logic is independent of the host's `TZ` env (container images default
# to UTC, the benchmark machine sits in Tokyo, and the dev box happens
# to be Asia/Shanghai — three conflicting answers from `date.today()`
# around the day boundary).
CN_TZ = ZoneInfo("Asia/Shanghai")


def utcnow() -> datetime:
    """Return a naive UTC datetime, compatible with existing naive DateTime columns."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def today_cn() -> date:
    """Return the current calendar day in China Standard Time (UTC+8).

    Use this anywhere the day must match the user's lived experience —
    voice-intake date anchoring, "今天" shortcuts, retention windows
    spoken about by users. Do **not** use `date.today()` for these:
    it silently follows the host TZ.
    """
    return datetime.now(CN_TZ).date()
