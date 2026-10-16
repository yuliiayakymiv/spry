"""agenda and ai_suggestion on meetings (Lab 6: Paste an agenda)

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-15

Both columns are nullable: existing meetings simply have no agenda yet. Adding a nullable column
is a metadata-only change in PostgreSQL, so it is safe while the old API version still runs.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("meetings", sa.Column("agenda", postgresql.JSONB(), nullable=True))
    op.add_column("meetings", sa.Column("ai_suggestion", postgresql.JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("meetings", "ai_suggestion")
    op.drop_column("meetings", "agenda")
