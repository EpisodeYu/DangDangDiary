"""Custom routines; preserve all existing grooming settings and history."""
from alembic import op
import sqlalchemy as sa

revision = "c9d0e1f2a3b4"
down_revision = "b8c9d0e1f2a3"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "routine_items",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("pet_id", sa.BigInteger(), sa.ForeignKey("pets.id", ondelete="CASCADE"), nullable=False),
        sa.Column("routine_type", sa.String(64), nullable=False),
        sa.Column("name", sa.String(20), nullable=False),
        sa.Column("cycle_days", sa.Integer(), nullable=True),
        sa.Column("reminder_enabled", sa.Boolean(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("pet_id", "routine_type"),
    )
    op.create_index("ix_routine_items_pet_id", "routine_items", ["pet_id"])
    op.execute(sa.text("""
        INSERT INTO routine_items (pet_id, routine_type, name, cycle_days, reminder_enabled, created_at)
        SELECT id, 'grooming', '梳毛', grooming_cycle_days, grooming_reminder_enabled,
            timezone('UTC', CURRENT_TIMESTAMP)
        FROM pets
    """))
    op.alter_column(
        "routines", "routine_type", type_=sa.String(64),
        postgresql_using="lower(routine_type::text)", existing_nullable=False,
    )
    # Keep the old enum and pet grooming columns for compatibility/rollback.


def downgrade():
    # Never silently discard custom history or renamed/deleted settings.
    connection = op.get_bind()
    changed = connection.execute(sa.text("""
        SELECT count(*) FROM routine_items
        WHERE routine_type <> 'grooming' OR name <> '梳毛' OR deleted_at IS NOT NULL
    """)).scalar()
    if changed:
        raise RuntimeError("Custom routine data exists; restore a backup instead of a lossy downgrade")
    op.execute(sa.text("""
        UPDATE pets SET grooming_cycle_days = i.cycle_days,
            grooming_reminder_enabled = i.reminder_enabled
        FROM routine_items i WHERE pets.id = i.pet_id AND i.routine_type = 'grooming'
    """))
    op.alter_column(
        "routines", "routine_type",
        type_=sa.Enum("BATH", "NAIL_TRIM", "GROOMING", name="routinetype"),
        postgresql_using="upper(routine_type)::routinetype", existing_nullable=False,
    )
    op.drop_table("routine_items")
