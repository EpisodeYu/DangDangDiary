"""SQLite compatibility shims for the test suite.

SQLite only auto-increments `INTEGER PRIMARY KEY` columns — columns declared
as `BigInteger` render as `BIGINT`, which breaks autoincrement under SQLite.
Remap `BIGINT` to `INTEGER` for the in-memory SQLite engine used by the
SQLite-based test fixtures.

Call :func:`apply_sqlite_compat` from inside a SQLite-only fixture. Do NOT
import this at module load time — that would patch `SQLiteTypeCompiler`
globally, which is undesirable once we add a Postgres integration fixture.
"""
from __future__ import annotations

_APPLIED = False


def apply_sqlite_compat() -> None:
    global _APPLIED
    if _APPLIED:
        return
    from sqlalchemy.dialects.sqlite.base import SQLiteTypeCompiler

    SQLiteTypeCompiler.visit_big_integer = SQLiteTypeCompiler.visit_integer  # type: ignore[assignment]
    SQLiteTypeCompiler.visit_BIGINT = SQLiteTypeCompiler.visit_INTEGER  # type: ignore[assignment]
    _APPLIED = True
