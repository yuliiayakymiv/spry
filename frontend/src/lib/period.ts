import { endOfDay, endOfMonth, endOfWeek, startOfDay, startOfMonth, startOfWeek } from 'date-fns'

import type { Meeting } from '@/lib/api'

export type Period = 'all' | 'today' | 'week' | 'month'

export const PERIODS: { value: Period; label: string; empty: string }[] = [
  { value: 'all', label: 'All', empty: 'No meetings yet' },
  { value: 'today', label: 'Today', empty: 'Nothing planned for today' },
  { value: 'week', label: 'This week', empty: 'Nothing planned this week' },
  { value: 'month', label: 'This month', empty: 'Nothing planned this month' },
]

function range(period: Exclude<Period, 'all'>, now: Date): [Date, Date] {
  switch (period) {
    case 'today':
      return [startOfDay(now), endOfDay(now)]
    case 'week': // Monday to Sunday
      return [startOfWeek(now, { weekStartsOn: 1 }), endOfWeek(now, { weekStartsOn: 1 })]
    case 'month':
      return [startOfMonth(now), endOfMonth(now)]
  }
}

/** Meetings that overlap the period, in the user's local time zone. */
export function inPeriod(meetings: Meeting[], period: Period, now = new Date()): Meeting[] {
  if (period === 'all') return meetings
  const [from, to] = range(period, now)
  return meetings.filter((m) => new Date(m.starts_at) <= to && new Date(m.ends_at) >= from)
}
