import { format, isSameDay } from 'date-fns'

import type { Meeting } from '@/lib/api'

export function formatWhen(meeting: Meeting): string {
  const start = new Date(meeting.starts_at)
  const end = new Date(meeting.ends_at)
  const day = format(start, 'EEE, d MMM yyyy')
  if (isSameDay(start, end)) {
    return `${day} · ${format(start, 'HH:mm')}–${format(end, 'HH:mm')}`
  }
  return `${day} ${format(start, 'HH:mm')} – ${format(end, 'EEE, d MMM HH:mm')}`
}
