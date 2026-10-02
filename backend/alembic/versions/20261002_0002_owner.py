"""per-user data: owner_id (Cognito sub) on meetings and participants

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-02

Rows created before sign-in existed get owner_id "local": the auth-off user. With sign-in on,
nobody's token has that sub, so old shared demo data simply disappears from every account.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    for table in ("participants", "meetings"):
        op.add_column(
            table, sa.Column("owner_id", sa.String(128), nullable=False, server_default="local")
        )
        op.alter_column(table, "owner_id", server_default=None)
        op.create_index(f"ix_{table}_owner_id", table, ["owner_id"])
    # The same email may now exist once per user, not once globally.
    op.drop_constraint("participants_email_key", "participants", type_="unique")
    op.create_unique_constraint(
        "uq_participants_owner_email", "participants", ["owner_id", "email"]
    )


def downgrade() -> None:
    op.drop_constraint("uq_participants_owner_email", "participants", type_="unique")
    op.create_unique_constraint("participants_email_key", "participants", ["email"])
    for table in ("meetings", "participants"):
        op.drop_index(f"ix_{table}_owner_id", table_name=table)
        op.drop_column(table, "owner_id")
