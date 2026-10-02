"""Insert sample participants and meetings for the local user (auth off). Safe to re-run."""

import asyncio
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.auth import LOCAL_USER
from app.db import SessionLocal, engine
from app.models import Meeting, Participant

PARTICIPANTS = [
    ("Olena Koval", "olena@example.com"),
    ("Taras Shevchuk", "taras@example.com"),
    ("Iryna Bondar", "iryna@example.com"),
    ("Andrii Melnyk", "andrii@example.com"),
]


async def seed() -> None:
    async with SessionLocal() as session:
        existing = {
            p.email: p
            for p in await session.scalars(
                select(Participant).where(Participant.owner_id == LOCAL_USER)
            )
        }
        for name, email in PARTICIPANTS:
            if email not in existing:
                existing[email] = Participant(owner_id=LOCAL_USER, name=name, email=email)
                session.add(existing[email])

        if (
            await session.scalar(select(Meeting.id).where(Meeting.owner_id == LOCAL_USER).limit(1))
            is None
        ):
            people = [existing[email] for _, email in PARTICIPANTS]
            base = datetime.now(UTC).replace(hour=9, minute=0, second=0, microsecond=0)
            session.add_all(
                [
                    Meeting(
                        owner_id=LOCAL_USER,
                        title="Sprint planning",
                        description="Plan the work for the next sprint.",
                        starts_at=base + timedelta(days=1),
                        ends_at=base + timedelta(days=1, hours=1),
                        place="Room 204",
                        participants=people[:3],
                    ),
                    Meeting(
                        owner_id=LOCAL_USER,
                        title="Design review",
                        description="Walk through the new meeting form.",
                        starts_at=base + timedelta(days=2, hours=4),
                        ends_at=base + timedelta(days=2, hours=5),
                        place="https://meet.example.com/design",
                        participants=[people[0], people[3]],
                    ),
                    Meeting(
                        owner_id=LOCAL_USER,
                        title="Retrospective",
                        starts_at=base + timedelta(days=5, hours=6),
                        ends_at=base + timedelta(days=5, hours=7, minutes=30),
                        place="Main hall",
                        participants=people,
                    ),
                ]
            )
        await session.commit()
    await engine.dispose()
    print("Seed data inserted.")


if __name__ == "__main__":
    asyncio.run(seed())
