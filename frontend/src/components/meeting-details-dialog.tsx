import { useRef } from 'react'
import {
  ClockIcon,
  ListChecksIcon,
  MapPinIcon,
  PencilIcon,
  Trash2Icon,
  UsersIcon,
} from 'lucide-react'

import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import type { Meeting } from '@/lib/api'
import { formatWhen } from '@/lib/format'

function isUrl(value: string): boolean {
  return /^https?:\/\/\S+$/.test(value)
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onEdit: (meeting: Meeting) => void
  onDelete: (meeting: Meeting) => void
  onAgenda: (meeting: Meeting) => void
}

export function MeetingDetailsDialog({
  meeting,
  open,
  onOpenChange,
  onEdit,
  onDelete,
  onAgenda,
}: Props) {
  const editButtonRef = useRef<HTMLButtonElement>(null)

  return (
    <Dialog open={open && meeting !== null} onOpenChange={onOpenChange}>
      <DialogContent
        className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-lg"
        // Radix would focus the first button (Delete); start on Edit instead.
        onOpenAutoFocus={(event) => {
          event.preventDefault()
          editButtonRef.current?.focus()
        }}
      >
        {meeting && (
          <>
            <DialogHeader>
              <DialogTitle className="pr-8 text-3xl leading-tight">{meeting.title}</DialogTitle>
              <DialogDescription className="flex items-center gap-2">
                <ClockIcon className="size-4 shrink-0" />
                {formatWhen(meeting)}
              </DialogDescription>
            </DialogHeader>

            <div className="-mx-6 flex flex-col gap-5 overflow-y-auto px-6">
              <div className="flex items-start gap-2">
                <MapPinIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                {isUrl(meeting.place) ? (
                  <a
                    href={meeting.place}
                    target="_blank"
                    rel="noreferrer"
                    className="break-all underline underline-offset-4 hover:text-hover"
                  >
                    {meeting.place}
                  </a>
                ) : (
                  <span className="break-words">{meeting.place}</span>
                )}
              </div>

              {meeting.description && (
                <>
                  <div className="hairline" />
                  <p className="font-serif text-lg leading-snug whitespace-pre-line">
                    {meeting.description}
                  </p>
                </>
              )}

              <div className="hairline" />
              <AgendaView meeting={meeting} onAgenda={onAgenda} />

              <div className="hairline" />
              <div className="flex flex-col gap-3">
                <h3 className="flex items-center gap-2 text-lg">
                  <UsersIcon className="size-4" />
                  Participants
                  <span className="font-sans text-sm text-muted-foreground">
                    {meeting.participants.length}
                  </span>
                </h3>
                {meeting.participants.length === 0 ? (
                  <p className="text-muted-foreground">No participants yet.</p>
                ) : (
                  <ul className="flex flex-col gap-2">
                    {meeting.participants.map((p) => (
                      <li key={p.id} className="flex flex-wrap items-baseline gap-x-2">
                        <span className="font-semibold">{p.name}</span>
                        <a
                          href={`mailto:${p.email}`}
                          className="text-sm text-muted-foreground hover:text-hover"
                        >
                          {p.email}
                        </a>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </div>

            <DialogFooter className="sm:justify-between">
              <Button variant="ghost" onClick={() => onDelete(meeting)}>
                <Trash2Icon />
                Delete
              </Button>
              <Button ref={editButtonRef} onClick={() => onEdit(meeting)}>
                <PencilIcon />
                Edit
              </Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}

function AgendaView({
  meeting,
  onAgenda,
}: {
  meeting: Meeting
  onAgenda: (meeting: Meeting) => void
}) {
  const agenda = meeting.agenda
  const empty = !agenda || (agenda.items.length === 0 && agenda.action_items.length === 0)
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-lg">
          <ListChecksIcon className="size-4" />
          Agenda
        </h3>
        <Button variant="outline" size="sm" onClick={() => onAgenda(meeting)}>
          {empty ? 'Add agenda' : 'Edit agenda'}
        </Button>
      </div>
      {empty ? (
        <p className="text-muted-foreground">No agenda yet.</p>
      ) : (
        <>
          {agenda.items.length > 0 && (
            <ol className="flex list-decimal flex-col gap-1 pl-5">
              {agenda.items.map((item, i) => (
                <li key={i}>
                  <span className="font-semibold">{item.topic}</span>
                  {(item.owner || item.minutes) && (
                    <span className="text-sm text-muted-foreground">
                      {' — '}
                      {[item.owner, item.minutes && `${item.minutes} min`]
                        .filter(Boolean)
                        .join(', ')}
                    </span>
                  )}
                </li>
              ))}
            </ol>
          )}
          {agenda.action_items.length > 0 && (
            <div className="flex flex-col gap-1">
              <p className="text-sm font-semibold">Action items</p>
              <ul className="flex list-disc flex-col gap-1 pl-5">
                {agenda.action_items.map((a, i) => (
                  <li key={i}>
                    {a.task}
                    {(a.owner || a.due) && (
                      <span className="text-sm text-muted-foreground">
                        {' — '}
                        {[a.owner, a.due && `by ${a.due}`].filter(Boolean).join(', ')}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  )
}
