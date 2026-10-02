import { useState } from 'react'
import { CalendarXIcon, MapPinIcon, PencilIcon, PlusIcon, Trash2Icon } from 'lucide-react'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useMeetings } from '@/hooks/queries'
import type { Meeting, Participant } from '@/lib/api'
import { formatWhen } from '@/lib/format'
import { PERIODS, inPeriod, type Period } from '@/lib/period'

const MAX_BADGES = 3

function ParticipantBadges({ participants }: { participants: Participant[] }) {
  if (participants.length === 0) {
    return <span className="text-sm text-muted-foreground">—</span>
  }
  const shown = participants.slice(0, MAX_BADGES)
  const hidden = participants.slice(MAX_BADGES)
  return (
    <div className="flex flex-wrap gap-1">
      {shown.map((p) => (
        <Badge key={p.id} variant="secondary" title={p.email}>
          {p.name}
        </Badge>
      ))}
      {hidden.length > 0 && (
        <Badge variant="outline" title={hidden.map((p) => p.name).join(', ')}>
          +{hidden.length}
        </Badge>
      )}
    </div>
  )
}

type Props = {
  onAdd: () => void
  onOpen: (meeting: Meeting) => void
  onEdit: (meeting: Meeting) => void
  onDelete: (meeting: Meeting) => void
}

function RowActions({
  meeting,
  onEdit,
  onDelete,
}: { meeting: Meeting } & Pick<Props, 'onEdit' | 'onDelete'>) {
  // stopPropagation: the row itself opens the details view.
  return (
    <div className="flex shrink-0 gap-1">
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={`Edit ${meeting.title}`}
        title="Edit"
        onClick={(event) => {
          event.stopPropagation()
          onEdit(meeting)
        }}
      >
        <PencilIcon />
      </Button>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label={`Delete ${meeting.title}`}
        title="Delete"
        onClick={(event) => {
          event.stopPropagation()
          onDelete(meeting)
        }}
      >
        <Trash2Icon />
      </Button>
    </div>
  )
}

/** Keyboard-reachable title; clicks bubble up to the row/card, which opens the details. */
function MeetingTitle({ meeting }: { meeting: Meeting }) {
  return (
    <button
      type="button"
      className="rounded-sm text-left font-serif text-xl font-medium text-heading transition-colors outline-none group-hover:text-hover focus-visible:ring-3 focus-visible:ring-ring/50"
    >
      {meeting.title}
    </button>
  )
}

function PeriodFilter({ value, onChange }: { value: Period; onChange: (p: Period) => void }) {
  return (
    <div
      role="radiogroup"
      aria-label="Show meetings for"
      className="flex flex-wrap items-center justify-center gap-2"
    >
      {PERIODS.map((p) => (
        <button
          key={p.value}
          type="button"
          role="radio"
          aria-checked={value === p.value}
          onClick={() => onChange(p.value)}
          className={
            value === p.value
              ? 'rounded-full border border-[#c9a96a] bg-[#2f3f6b] px-4 py-1.5 text-sm font-semibold text-[#fffdf8] shadow-sm'
              : 'rounded-full border border-[#c9a96a] bg-card px-4 py-1.5 text-sm font-semibold text-[#2f3f6b] transition-colors hover:bg-[#f6efe1]'
          }
        >
          {p.label}
        </button>
      ))}
    </div>
  )
}

export function MeetingList({ onAdd, onOpen, onEdit, onDelete }: Props) {
  const meetings = useMeetings()
  const [period, setPeriod] = useState<Period>('all')

  if (meetings.isPending) {
    return (
      <div className="flex flex-col gap-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Skeleton key={i} className="h-16 w-full rounded-[20px] bg-card" />
        ))}
      </div>
    )
  }

  if (meetings.isError) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Could not load meetings</AlertTitle>
        <AlertDescription className="flex flex-col items-start gap-2">
          <span>{meetings.error.message}</span>
          <Button variant="outline" size="sm" onClick={() => meetings.refetch()}>
            Retry
          </Button>
        </AlertDescription>
      </Alert>
    )
  }

  if (meetings.data.length === 0) {
    return (
      <div className="flex flex-col items-center gap-4 rounded-[20px] bg-card py-20 text-center">
        <CalendarXIcon className="size-10 stroke-1 text-primary" />
        <h2 className="text-3xl">No meetings yet</h2>
        <p className="font-serif text-lg text-muted-foreground italic">
          Plan the first one — it only takes a minute.
        </p>
        <Button onClick={onAdd}>
          <PlusIcon />
          Add meeting
        </Button>
      </div>
    )
  }

  const shown = inPeriod(meetings.data, period)
  const filter = <PeriodFilter value={period} onChange={setPeriod} />

  if (shown.length === 0) {
    return (
      <div className="flex flex-col gap-4">
        {filter}
        <div className="flex flex-col items-center gap-4 rounded-[20px] bg-card py-16 text-center">
          <CalendarXIcon className="size-10 stroke-1 text-primary" />
          <h2 className="text-3xl">{PERIODS.find((p) => p.value === period)?.empty}</h2>
          <Button variant="outline" onClick={() => setPeriod('all')}>
            Show all meetings
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4">
      {filter}
      {/* Wide screens: table */}
      <div className="hidden rounded-[20px] bg-card px-2 py-1 md:block">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Meeting</TableHead>
              <TableHead>When</TableHead>
              <TableHead>Place</TableHead>
              <TableHead>Participants</TableHead>
              <TableHead className="w-24">
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {shown.map((meeting) => (
              <TableRow
                key={meeting.id}
                className="group cursor-pointer hover:bg-muted"
                onClick={() => onOpen(meeting)}
              >
                <TableCell className="max-w-64 whitespace-normal">
                  <MeetingTitle meeting={meeting} />
                  {meeting.description && (
                    <div
                      className="truncate text-sm text-muted-foreground"
                      title={meeting.description}
                    >
                      {meeting.description}
                    </div>
                  )}
                </TableCell>
                <TableCell>{formatWhen(meeting)}</TableCell>
                <TableCell className="max-w-48 truncate" title={meeting.place}>
                  {meeting.place}
                </TableCell>
                <TableCell className="whitespace-normal">
                  <ParticipantBadges participants={meeting.participants} />
                </TableCell>
                <TableCell>
                  <RowActions meeting={meeting} onEdit={onEdit} onDelete={onDelete} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {/* Narrow screens: cards */}
      <div className="flex flex-col gap-3 md:hidden">
        {shown.map((meeting) => (
          <Card
            key={meeting.id}
            className="group cursor-pointer transition-colors hover:bg-muted"
            onClick={() => onOpen(meeting)}
          >
            <CardContent className="flex flex-col gap-2">
              <div className="flex items-start justify-between gap-2">
                <div className="flex min-w-0 flex-col items-start">
                  <MeetingTitle meeting={meeting} />
                  <div className="text-sm text-muted-foreground">{formatWhen(meeting)}</div>
                </div>
                <RowActions meeting={meeting} onEdit={onEdit} onDelete={onDelete} />
              </div>
              {meeting.description && (
                <p className="line-clamp-2 text-sm text-muted-foreground">{meeting.description}</p>
              )}
              <div className="hairline" />
              <div className="flex items-center gap-1 text-sm">
                <MapPinIcon className="size-3.5 shrink-0 text-muted-foreground" />
                <span className="truncate">{meeting.place}</span>
              </div>
              <ParticipantBadges participants={meeting.participants} />
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  )
}
