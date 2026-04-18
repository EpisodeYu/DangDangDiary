from datetime import datetime, timezone


def utcnow() -> datetime:
    """Return a naive UTC datetime, compatible with existing naive DateTime columns."""
    return datetime.now(timezone.utc).replace(tzinfo=None)
