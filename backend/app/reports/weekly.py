"""Weekly meetings report: one ISO week in, one CSV out. No AWS in here.

Run locally against the compose database:
    python -m app.reports.weekly 2026-W40 > 2026-W40.csv
"""

import asyncio
import csv
import io
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.pool import NullPool

from app.config import settings
from app.models import Meeting, Participant, meeting_participants

# Week boundaries are Monday 00:00 in this time zone, not in UTC.
REPORT_TZ = ZoneInfo(os.environ.get("REPORT_TZ", "Europe/Kyiv"))
WEEK_RE = re.compile(r"^(\d{4})-W(\d{2})$")
TOP_N = 5

_hours = func.extract("epoch", Meeting.ends_at - Meeting.starts_at) / 3600


def parse_week(week: str) -> date:
    """ "2026-W40" -> the Monday of that ISO week. Raises ValueError on anything else."""
    match = WEEK_RE.match(week)
    if not match:
        raise ValueError(f"week must look like 2026-W40, got {week!r}")
    return date.fromisocalendar(int(match[1]), int(match[2]), 1)


def format_week(monday: date) -> str:
    year, number, _ = monday.isocalendar()
    return f"{year}-W{number:02d}"


def previous_week(today: date | None = None) -> str:
    """The ISO week before the one containing `today` (default: today in REPORT_TZ)."""
    today = today or datetime.now(REPORT_TZ).date()
    return format_week(today - timedelta(days=today.weekday() + 7))


def report_key(week: str) -> str:
    """One week, one object: rebuilding a week overwrites it instead of adding a second file."""
    return f"reports/{format_week(parse_week(week))}.csv"


def week_bounds(week: str) -> tuple[datetime, datetime]:
    monday = parse_week(week)
    start = datetime.combine(monday, time.min, tzinfo=REPORT_TZ)
    return start, datetime.combine(monday + timedelta(days=7), time.min, tzinfo=REPORT_TZ)


@dataclass
class Totals:
    meetings: int
    hours: float


async def _totals(session: AsyncSession, week: str) -> Totals:
    start, end = week_bounds(week)
    count, hours = (
        await session.execute(
            select(func.count(Meeting.id), func.coalesce(func.sum(_hours), 0)).where(
                Meeting.starts_at >= start, Meeting.starts_at < end
            )
        )
    ).one()
    return Totals(count, float(hours))


async def _longest(session: AsyncSession, week: str) -> list[tuple[str, datetime, float, int]]:
    start, end = week_bounds(week)
    people = (
        select(func.count())
        .where(meeting_participants.c.meeting_id == Meeting.id)
        .scalar_subquery()
    )
    rows = await session.execute(
        select(Meeting.title, Meeting.starts_at, _hours, people)
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .order_by(_hours.desc(), Meeting.starts_at, Meeting.title)
        .limit(TOP_N)
    )
    return [(title, starts, float(hours), n) for title, starts, hours, n in rows]


async def _per_participant(session: AsyncSession, week: str) -> list[tuple[str, str, int, float]]:
    start, end = week_bounds(week)
    rows = await session.execute(
        select(Participant.name, Participant.email, func.count(Meeting.id), func.sum(_hours))
        .join(meeting_participants, meeting_participants.c.participant_id == Participant.id)
        .join(Meeting, Meeting.id == meeting_participants.c.meeting_id)
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .group_by(Participant.id, Participant.name, Participant.email)
        .order_by(func.sum(_hours).desc(), Participant.name)
    )
    return [(name, email, n, float(hours)) for name, email, n, hours in rows]


def _h(hours: float) -> str:
    return f"{hours:.2f}"


def _signed(value: float, fmt=str) -> str:
    return ("+" if value > 0 else "") + fmt(value)


async def build_report_csv(session: AsyncSession, week: str) -> bytes:
    """The report for `week` from an open session. Same data in, same bytes out."""
    week = format_week(parse_week(week))
    before = format_week(parse_week(week) - timedelta(days=7))
    start, end = week_bounds(week)
    this, prev = await _totals(session, week), await _totals(session, before)

    out = io.StringIO()
    w = csv.writer(out, lineterminator="\n")
    w.writerow(["Spry weekly meetings report", week])
    w.writerow(
        ["Period", f"{start:%Y-%m-%d} to {end - timedelta(days=1):%Y-%m-%d}", str(REPORT_TZ)]
    )
    w.writerow([])
    w.writerow(["Metric", week, before, "Change"])
    w.writerow(["Meetings", this.meetings, prev.meetings, _signed(this.meetings - prev.meetings)])
    w.writerow(["Hours", _h(this.hours), _h(prev.hours), _signed(this.hours - prev.hours, _h)])
    w.writerow([])
    w.writerow([f"Longest meetings (top {TOP_N})"])
    w.writerow(["Title", "Start", "Duration (h)", "Participants"])
    for title, starts, hours, people in await _longest(session, week):
        w.writerow([title, f"{starts.astimezone(REPORT_TZ):%Y-%m-%d %H:%M}", _h(hours), people])
    w.writerow([])
    w.writerow(["Per participant"])
    w.writerow(["Name", "Email", "Meetings", "Hours"])
    for name, email, count, hours in await _per_participant(session, week):
        w.writerow([name, email, count, _h(hours)])
    # BOM so Excel reads the Cyrillic titles as UTF-8.
    return out.getvalue().encode("utf-8-sig")


async def _build(week: str, database_url: str) -> bytes:
    # A fresh engine per call: in Lambda every invocation runs its own event loop, and
    # pooled asyncpg connections cannot move between loops.
    engine = create_async_engine(database_url, poolclass=NullPool)
    try:
        async with AsyncSession(engine) as session:
            return await build_report_csv(session, week)
    finally:
        await engine.dispose()


def build_weekly_report(week: str, database_url: str | None = None) -> bytes:
    """Query the meetings of one ISO week (e.g. "2026-W40") and return the CSV."""
    return asyncio.run(_build(week, database_url or settings.database_url))


if __name__ == "__main__":
    sys.stdout.write(
        build_weekly_report(sys.argv[1] if len(sys.argv) > 1 else previous_week()).decode()
    )
