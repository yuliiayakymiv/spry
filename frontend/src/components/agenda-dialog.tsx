import { useEffect, useRef, useState } from 'react'
import { LoaderCircleIcon, PlusIcon, SparklesIcon, XIcon } from 'lucide-react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { FieldError } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useSaveAgenda } from '@/hooks/queries'
import {
  PARSER_MAX_CHARS,
  PARSER_URL,
  ParseError,
  parseAgenda,
  type Agenda,
  type AiSuggestion,
  type Meeting,
  type ParsedAgenda,
} from '@/lib/api'
import { cn } from '@/lib/utils'

// One editable row. `suggested` marks fields the model filled and the user has not touched yet.
type Row<F extends string> = {
  key: number
  values: Record<F, string>
  suggested: Partial<Record<F, boolean>>
}
type ItemField = 'topic' | 'owner' | 'minutes'
type ActionField = 'task' | 'owner' | 'due'

let nextKey = 1
function row<F extends string>(values: Record<F, string>, suggested = false): Row<F> {
  const marks: Partial<Record<F, boolean>> = {}
  if (suggested) {
    for (const field of Object.keys(values) as F[]) marks[field] = values[field] !== ''
  }
  return { key: nextKey++, values, suggested: marks }
}

const str = (value: string | number | null | undefined) => (value == null ? '' : String(value))

function itemRows(agenda: Agenda | null, suggested: boolean): Row<ItemField>[] {
  return (agenda?.items ?? []).map((i) =>
    row({ topic: str(i.topic), owner: str(i.owner), minutes: str(i.minutes) }, suggested),
  )
}

function actionRows(agenda: Agenda | null, suggested: boolean): Row<ActionField>[] {
  return (agenda?.action_items ?? []).map((a) =>
    row({ task: str(a.task), owner: str(a.owner), due: str(a.due) }, suggested),
  )
}

/** What the text said beyond the agenda itself; shown as a hint, never saved over the meeting. */
function detectedSummary(parsed: ParsedAgenda): string | null {
  const parts = [
    parsed.title,
    parsed.starts_at &&
      new Date(parsed.starts_at).toLocaleString(undefined, {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        hour: '2-digit',
        minute: '2-digit',
      }),
    parsed.duration_minutes && `${parsed.duration_minutes} min`,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : null
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AgendaDialog({ meeting, open, onOpenChange }: Props) {
  const saveAgenda = useSaveAgenda()
  // Fresh state for every opening: App remounts this dialog with a new `key`.
  const [text, setText] = useState('')
  const [parsing, setParsing] = useState(false)
  const [parseError, setParseError] = useState<string | null>(null)
  const [suggestion, setSuggestion] = useState<AiSuggestion | null>(null)
  const [items, setItems] = useState(() => itemRows(meeting?.agenda ?? null, false))
  const [actions, setActions] = useState(() => actionRows(meeting?.agenda ?? null, false))
  const [formError, setFormError] = useState<string | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  // Closing the dialog mid-parse stops the request: every token costs money.
  useEffect(() => {
    if (!open) abortRef.current?.abort()
  }, [open])

  const onParse = async () => {
    const controller = new AbortController()
    abortRef.current = controller
    setParsing(true)
    setParseError(null)
    try {
      const result = await parseAgenda(text, controller.signal)
      setSuggestion(result)
      setItems(itemRows(result.agenda, true))
      setActions(actionRows(result.agenda, true))
      setFormError(null)
    } catch (error) {
      const parseFailure = error instanceof ParseError ? error : null
      if (parseFailure?.code !== 'cancelled') {
        setParseError(parseFailure?.message ?? 'The parser failed. Type the agenda by hand.')
      }
    } finally {
      setParsing(false)
      abortRef.current = null
    }
  }

  const onSave = () => {
    if (!meeting) return
    const agenda: Agenda = { items: [], action_items: [] }
    for (const { values } of items) {
      if (!values.topic.trim() && !values.owner.trim() && !values.minutes.trim()) continue
      const minutes = values.minutes.trim() === '' ? null : Number(values.minutes)
      if (!values.topic.trim()) return setFormError('Every agenda item needs a topic.')
      if (minutes !== null && !(Number.isInteger(minutes) && minutes >= 1 && minutes <= 480)) {
        return setFormError('Minutes must be a whole number from 1 to 480.')
      }
      agenda.items.push({ topic: values.topic.trim(), owner: values.owner.trim() || null, minutes })
    }
    for (const { values } of actions) {
      if (!values.task.trim() && !values.owner.trim() && !values.due) continue
      if (!values.task.trim()) return setFormError('Every action item needs a task.')
      agenda.action_items.push({
        task: values.task.trim(),
        owner: values.owner.trim() || null,
        due: values.due || null,
      })
    }
    setFormError(null)
    // The suggestion goes along so the API can store suggested vs saved (the quality signal).
    saveAgenda.mutate(
      { id: meeting.id, agenda, ai_suggestion: suggestion },
      {
        onSuccess: () => {
          toast.success('Agenda saved')
          onOpenChange(false)
        },
        onError: (error: Error) => setFormError(error.message),
      },
    )
  }

  const hasSuggested = [...items, ...actions].some((r) => Object.values(r.suggested).some(Boolean))
  const detected = suggestion && detectedSummary(suggestion.agenda)

  return (
    <Dialog open={open && meeting !== null} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Agenda</DialogTitle>
          <DialogDescription>{meeting?.title}</DialogDescription>
        </DialogHeader>

        <div className="-mx-6 flex flex-col gap-6 overflow-y-auto px-6 py-1">
          {PARSER_URL && (
            <section className="flex flex-col gap-2" aria-labelledby="paste-agenda">
              <h3 id="paste-agenda" className="flex items-center gap-2 text-lg">
                <SparklesIcon className="size-4" />
                Paste an agenda
              </h3>
              <p className="text-sm text-muted-foreground">
                Paste an email, a chat message or notes. The model fills in the form below; you
                check it and save.
              </p>
              <Textarea
                rows={5}
                value={text}
                onChange={(e) => setText(e.target.value)}
                disabled={parsing}
                placeholder="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв …"
                aria-label="Pasted agenda text"
              />
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span
                  className={cn(
                    'text-xs text-muted-foreground',
                    text.length > PARSER_MAX_CHARS && 'text-destructive',
                  )}
                >
                  {text.length.toLocaleString()} / {PARSER_MAX_CHARS.toLocaleString()}
                </span>
                {parsing ? (
                  <div className="flex items-center gap-3" role="status">
                    <LoaderCircleIcon className="size-4 animate-spin" />
                    <span className="text-sm">Reading the agenda… a few seconds</span>
                    <Button variant="outline" size="sm" onClick={() => abortRef.current?.abort()}>
                      Cancel
                    </Button>
                  </div>
                ) : (
                  <Button
                    size="sm"
                    onClick={onParse}
                    disabled={!text.trim() || text.length > PARSER_MAX_CHARS}
                  >
                    <SparklesIcon />
                    Parse
                  </Button>
                )}
              </div>
              {parseError && <FieldError>{parseError}</FieldError>}
            </section>
          )}

          {(hasSuggested || detected) && (
            <div className="flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
              {hasSuggested && (
                <Badge variant="outline" className="border-[#c9a96a] bg-amber-50 text-amber-900">
                  <SparklesIcon />
                  suggested
                </Badge>
              )}
              <span>
                Highlighted fields come from the model. Check them before saving.
                {detected && ` The text also mentions: ${detected}.`}
              </span>
            </div>
          )}

          <RowsSection
            title="Agenda items"
            addLabel="Add item"
            rows={items}
            setRows={setItems}
            blank={{ topic: '', owner: '', minutes: '' }}
            fields={[
              { name: 'topic', label: 'Topic', className: 'flex-1 min-w-40' },
              { name: 'owner', label: 'Owner', className: 'w-32' },
              { name: 'minutes', label: 'Min', className: 'w-20', type: 'number' },
            ]}
          />

          <RowsSection
            title="Action items"
            addLabel="Add action item"
            rows={actions}
            setRows={setActions}
            blank={{ task: '', owner: '', due: '' }}
            fields={[
              { name: 'task', label: 'Task', className: 'flex-1 min-w-40' },
              { name: 'owner', label: 'Owner', className: 'w-32' },
              { name: 'due', label: 'Due', className: 'w-40', type: 'date' },
            ]}
          />

          {formError && <FieldError>{formError}</FieldError>}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={onSave} disabled={saveAgenda.isPending || parsing}>
            {saveAgenda.isPending ? 'Saving...' : 'Save agenda'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

type FieldSpec<F extends string> = {
  name: F
  label: string
  className: string
  type?: string
}

function RowsSection<F extends string>({
  title,
  addLabel,
  rows,
  setRows,
  blank,
  fields,
}: {
  title: string
  addLabel: string
  rows: Row<F>[]
  setRows: (update: (rows: Row<F>[]) => Row<F>[]) => void
  blank: Record<F, string>
  fields: FieldSpec<F>[]
}) {
  const update = (key: number, field: F, value: string) =>
    setRows((current) =>
      current.map((r) =>
        r.key === key
          ? {
              ...r,
              values: { ...r.values, [field]: value },
              // Touching a field takes it over from the model.
              suggested: { ...r.suggested, [field]: false },
            }
          : r,
      ),
    )

  return (
    <section className="flex flex-col gap-2">
      <h3 className="text-lg">{title}</h3>
      {rows.length === 0 && <p className="text-sm text-muted-foreground">Nothing yet.</p>}
      <ul className="flex flex-col gap-2">
        {rows.map((r, index) => (
          <li key={r.key} className="flex flex-wrap items-center gap-2">
            {fields.map((f) => (
              <Input
                key={f.name}
                type={f.type ?? 'text'}
                min={f.type === 'number' ? 1 : undefined}
                value={r.values[f.name]}
                placeholder={f.label}
                aria-label={`${title} ${index + 1}: ${f.label}`}
                title={r.suggested[f.name] ? 'Suggested by the model' : undefined}
                data-suggested={r.suggested[f.name] || undefined}
                onChange={(e) => update(r.key, f.name, e.target.value)}
                className={cn(
                  f.className,
                  'data-suggested:border-[#c9a96a] data-suggested:bg-amber-50 dark:data-suggested:bg-amber-950/40',
                )}
              />
            ))}
            <Button
              type="button"
              variant="ghost"
              size="icon"
              aria-label={`Remove ${title.toLowerCase()} ${index + 1}`}
              onClick={() => setRows((current) => current.filter((x) => x.key !== r.key))}
            >
              <XIcon />
            </Button>
          </li>
        ))}
      </ul>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="self-start"
        onClick={() => setRows((current) => [...current, row({ ...blank })])}
      >
        <PlusIcon />
        {addLabel}
      </Button>
    </section>
  )
}
