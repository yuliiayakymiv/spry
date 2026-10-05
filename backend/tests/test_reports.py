import csv
import io
from datetime import date, datetime, timedelta

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Base, Meeting, Participant
from app.reports.lambda_handler import detect_trigger
from app.reports.weekly import REPORT_TZ, build_report_csv, previous_week, report_key


@pytest.fixture
async def session(engine):
    async with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            await conn.execute(table.delete())
    async with AsyncSession(engine, expire_on_commit=False) as session:
        yield session


def meeting(title, day, hour, hours, people=()):
    start = datetime(2026, 9, day, hour, tzinfo=REPORT_TZ)
    return Meeting(
        owner_id="u",
        title=title,
        place="Room",
        starts_at=start,
        ends_at=start + timedelta(hours=hours),
        participants=list(people),
    )


def rows(data: bytes) -> list[list[str]]:
    return list(csv.reader(io.StringIO(data.decode("utf-8-sig"))))


async def test_weekly_report(session):
    ann = Participant(owner_id="u", name="Ann", email="ann@example.com")
    bob = Participant(owner_id="u", name="Bob", email="bob@example.com")
    session.add_all(
        [
            # 2026-W40 is Mon 28 Sep .. Sun 4 Oct (Kyiv time).
            meeting("Planning", 28, 10, 2, [ann, bob]),
            meeting("Retro", 30, 15, 1.5, [ann]),
            meeting("Standup", 29, 9, 0.25),
            # Sunday 23:30 Kyiv of W39 is already Sunday 20:30 UTC: still W39.
            meeting("Late call", 27, 23, 1, [bob]),
            meeting("Old", 21, 9, 3),
        ]
    )
    await session.commit()

    table = rows(await build_report_csv(session, "2026-W40"))

    assert table[0] == ["Spry weekly meetings report", "2026-W40"]
    assert table[4] == ["Meetings", "3", "2", "+1"]
    assert table[5] == ["Hours", "3.75", "4.00", "-0.25"]
    longest = table[9:12]
    assert [r[0] for r in longest] == ["Planning", "Retro", "Standup"]
    assert longest[0] == ["Planning", "2026-09-28 10:00", "2.00", "2"]
    per_person = table[table.index(["Per participant"]) + 2 :]
    assert per_person == [
        ["Ann", "ann@example.com", "2", "3.50"],
        ["Bob", "bob@example.com", "1", "2.00"],
    ]


async def test_same_week_same_bytes(session):
    assert await build_report_csv(session, "2026-W40") == await build_report_csv(
        session, "2026-W40"
    )


def test_week_helpers():
    assert report_key("2026-W40") == "reports/2026-W40.csv"
    assert previous_week(date(2026, 10, 5)) == "2026-W40"  # Monday
    assert previous_week(date(2026, 10, 11)) == "2026-W40"  # Sunday
    assert previous_week(date(2026, 1, 1)) == "2025-W52"
    with pytest.raises(ValueError):
        report_key("last week")


def test_detect_trigger():
    assert detect_trigger({"Records": [{"eventSource": "aws:sqs", "body": "{}"}]}) == "sqs"
    assert detect_trigger({"source": "schedule"}) == "schedule"
    assert detect_trigger({}) == "invoke"
