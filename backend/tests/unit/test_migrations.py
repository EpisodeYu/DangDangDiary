"""Catch migration revision collisions when independently developed work merges."""
from pathlib import Path
import warnings

from alembic.script import ScriptDirectory


def test_migrations_have_unique_revisions_and_one_complete_chain():
    directory = Path(__file__).parents[2] / "alembic"
    scripts = ScriptDirectory(str(directory))
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        heads = scripts.get_heads()
        revisions = list(scripts.walk_revisions())

    assert len(heads) == 1
    assert len(revisions) == len(list((directory / "versions").glob("*.py")))
    ids = [revision.revision for revision in revisions]
    assert len(ids) == len(set(ids))
    assert ids.index("d0e1f2a3b4c5") < ids.index("c9d0e1f2a3b4")
