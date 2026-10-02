import { useState } from 'react'
import { PlusIcon } from 'lucide-react'

import { AuthStatus } from '@/components/auth-status'
import { DeleteMeetingDialog } from '@/components/delete-meeting-dialog'
import { MeetingDetailsDialog } from '@/components/meeting-details-dialog'
import { MeetingFormDialog } from '@/components/meeting-form-dialog'
import { MeetingList } from '@/components/meeting-list'
import { Button } from '@/components/ui/button'
import { useMeetings } from '@/hooks/queries'
import { authEnabled } from '@/lib/auth'
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
    <div className="paper mx-auto my-4 flex min-h-[calc(100svh-2rem)] max-w-6xl flex-col gap-8 px-5 pt-6 pb-10 md:my-8 md:min-h-[calc(100svh-4rem)] md:px-10 md:pt-8 md:pb-14">
      <header className="relative flex flex-col gap-6 text-center">
        {/* On wide screens the account corner floats top-right, so the title sits higher. */}
        {authEnabled && (
          <div className="flex justify-end lg:absolute lg:top-0 lg:right-0">
            <AuthStatus />
          </div>
        )}
        <p className="flex items-center justify-center gap-3 text-xs font-semibold tracking-[0.35em] text-[#8a6a2f] uppercase">
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
          <p className="font-serif text-xl text-muted-foreground italic">
            Upcoming meetings, soonest first.
          </p>
          <Button
            size="lg"
            onClick={openCreate}
            className="border border-[#c9a96a] bg-gradient-to-r from-[#5f78b0] to-[#8a6fb3] shadow-[0_6px_20px_rgb(95_120_176/0.35)] hover:brightness-110"
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
