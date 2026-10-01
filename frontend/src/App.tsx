import { useState } from 'react'
import { PlusIcon } from 'lucide-react'

import { DeleteMeetingDialog } from '@/components/delete-meeting-dialog'
import { MeetingDetailsDialog } from '@/components/meeting-details-dialog'
import { MeetingFormDialog } from '@/components/meeting-form-dialog'
import { MeetingList } from '@/components/meeting-list'
import { Button } from '@/components/ui/button'
import { useMeetings } from '@/hooks/queries'
import type { Meeting } from '@/lib/api'

export default function App() {
  const meetings = useMeetings()
  const [formOpen, setFormOpen] = useState(false)
  // Kept after the form closes so the dialog doesn't flip to "Add meeting" while fading out.
  const [meetingToEdit, setMeetingToEdit] = useState<Meeting | null>(null)
  const [detailsOpen, setDetailsOpen] = useState(false)
  const [viewedId, setViewedId] = useState<string | null>(null)
  const [meetingToDelete, setMeetingToDelete] = useState<Meeting | null>(null)

  // Look the meeting up in the list so the details stay fresh after an edit.
  const viewedMeeting = meetings.data?.find((m) => m.id === viewedId) ?? null

  const openCreate = () => {
    setMeetingToEdit(null)
    setFormOpen(true)
  }
  const openEdit = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToEdit(meeting)
    setFormOpen(true)
  }
  const openDetails = (meeting: Meeting) => {
    setViewedId(meeting.id)
    setDetailsOpen(true)
  }
  const openDelete = (meeting: Meeting) => {
    setDetailsOpen(false)
    setMeetingToDelete(meeting)
  }

  return (
    <div className="mx-auto flex min-h-svh max-w-6xl flex-col gap-8 px-4 py-10 md:py-14">
      <header className="flex flex-col gap-6 text-center">
        <p className="flex items-center justify-center gap-3 text-xs font-semibold tracking-[0.35em] text-cyan-200 uppercase">
          <span className="dot" />
          Calendar
          <span className="dot" />
        </p>
        <h1 className="magic-text font-heading text-6xl leading-none font-bold md:text-7xl">
          Meetings
        </h1>
        <div className="ornament text-2xl" aria-hidden="true">
          ✦
        </div>
        <div className="flex flex-wrap items-center justify-between gap-4">
          <p className="text-lg text-violet-100">Upcoming meetings, soonest first.</p>
          <Button
            size="lg"
            onClick={openCreate}
            className="bg-gradient-to-r from-pink-500 via-fuchsia-500 to-violet-500 shadow-[0_0_24px_rgb(255_79_163/0.6)] hover:brightness-110"
          >
            <PlusIcon />
            Add meeting
          </Button>
        </div>
      </header>

      <main>
        <MeetingList
          onAdd={openCreate}
          onOpen={openDetails}
          onEdit={openEdit}
          onDelete={openDelete}
        />
      </main>

      <MeetingFormDialog open={formOpen} onOpenChange={setFormOpen} meeting={meetingToEdit} />
      <MeetingDetailsDialog
        meeting={viewedMeeting}
        open={detailsOpen}
        onOpenChange={setDetailsOpen}
        onEdit={openEdit}
        onDelete={openDelete}
      />
      <DeleteMeetingDialog meeting={meetingToDelete} onClose={() => setMeetingToDelete(null)} />
    </div>
  )
}
