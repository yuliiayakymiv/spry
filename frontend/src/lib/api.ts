import { SESSION_EXPIRED_EVENT, accessToken } from '@/lib/auth'

export type Participant = {
  id: string
  name: string
  email: string
}

export type AgendaItem = {
  topic: string
  owner: string | null
  minutes: number | null
}

export type ActionItem = {
  task: string
  owner: string | null
  /** YYYY-MM-DD */
  due: string | null
}

export type Agenda = {
  items: AgendaItem[]
  action_items: ActionItem[]
}

/** What the parser Lambda returns (backend/app/ai/agenda.py ParsedAgenda). */
export type ParsedAgenda = Agenda & {
  title: string | null
  starts_at: string | null
  duration_minutes: number | null
  language: string
}

export type AiSuggestion = {
  agenda: ParsedAgenda
  model: string
  prompt_version: string
}

export type Meeting = {
  id: string
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participants: Participant[]
  created_at: string
  agenda: Agenda | null
}

export type MeetingCreate = {
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participant_ids: string[]
}

export type ParticipantCreate = {
  name: string
  email: string
}

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

type ValidationIssue = { loc?: (string | number)[]; msg: string }

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return (detail as ValidationIssue[])
      .map((issue) => {
        const field = issue.loc?.filter((part) => part !== 'body').join('.')
        const msg = issue.msg.replace(/^Value error, /, '')
        return field ? `${field}: ${msg}` : msg
      })
      .join('; ')
  }
  return fallback
}

// Empty (default) = same origin: nginx in Docker, Vite in dev and CloudFront in AWS all
// forward /api to the backend. Set VITE_API_URL at build time to call the API on another
// origin instead, e.g. https://api.example.com.
const API_BASE = (import.meta.env.VITE_API_URL ?? '').replace(/\/$/, '')

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  // The API checks this token and returns only the signed-in user's data.
  const token = accessToken()
  const response = await fetch(`${API_BASE}/api${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...init?.headers,
    },
  })

  if (response.status === 401) window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT))

  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }

  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const api = {
  listMeetings: () => request<Meeting[]>('/meetings'),
  createMeeting: (data: MeetingCreate) =>
    request<Meeting>('/meetings', { method: 'POST', body: JSON.stringify(data) }),
  updateMeeting: ({ id, ...data }: MeetingCreate & { id: string }) =>
    request<Meeting>(`/meetings/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  /** The only write path for an agenda: typed by hand, or a confirmed suggestion. */
  saveAgenda: ({
    id,
    agenda,
    ai_suggestion,
  }: {
    id: string
    agenda: Agenda
    /** Only right after a parse; omitted for hand edits so the stored suggestion stays. */
    ai_suggestion: AiSuggestion | null
  }) =>
    request<Meeting>(`/meetings/${id}/agenda`, {
      method: 'PUT',
      body: JSON.stringify(ai_suggestion ? { agenda, ai_suggestion } : { agenda }),
    }),
  deleteMeeting: (id: string) => request<void>(`/meetings/${id}`, { method: 'DELETE' }),
  listParticipants: () => request<Participant[]>('/participants'),
  createParticipant: (data: ParticipantCreate) =>
    request<Participant>('/participants', { method: 'POST', body: JSON.stringify(data) }),
}

// ---------------------------------------------------------------- Lab 6: Paste an agenda

// The parser's function URL (infra/ai.yml), baked in at build time. Empty = feature hidden.
export const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? '').replace(/\/$/, '')
export const PARSER_MAX_CHARS = 10_000

export type ParseErrorCode =
  'too_long' | 'no_agenda' | 'busy' | 'unauthorized' | 'network' | 'cancelled' | 'failed'

export class ParseError extends Error {
  readonly code: ParseErrorCode

  constructor(code: ParseErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

const parseMessages: Record<ParseErrorCode, string> = {
  too_long: `The text is too long: at most ${PARSER_MAX_CHARS.toLocaleString()} characters.`,
  no_agenda: 'No agenda found in this text. Type the agenda by hand below.',
  busy: 'The model is busy right now. Try again in a minute, or type the agenda by hand.',
  unauthorized: 'Your session has expired. Sign in again.',
  network: 'Network error: the parser could not be reached. Check your connection.',
  cancelled: 'Cancelled.',
  failed: 'The parser failed. Type the agenda by hand, or try again later.',
}

/**
 * Sends the pasted text to the parser Lambda (never to the API: the parser only suggests).
 * `today` and `tz` are the user's, because "Monday" means the user's Monday, not UTC's.
 */
export async function parseAgenda(
  text: string,
  signal: AbortSignal,
): Promise<{ agenda: ParsedAgenda; model: string; prompt_version: string }> {
  if (text.length > PARSER_MAX_CHARS) throw new ParseError('too_long', parseMessages.too_long)
  const now = new Date()
  const today = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
  ].join('-')
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
  const token = accessToken()

  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: 'POST',
      signal,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ text, today, tz }),
    })
  } catch (error) {
    if (signal.aborted) throw new ParseError('cancelled', parseMessages.cancelled)
    console.warn('agenda parser unreachable', error)
    throw new ParseError('network', parseMessages.network)
  }

  if (response.ok) return response.json()
  if (response.status === 401) window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT))
  const code: ParseErrorCode =
    response.status === 413
      ? 'too_long'
      : response.status === 422
        ? 'no_agenda'
        : response.status === 429
          ? 'busy'
          : response.status === 401
            ? 'unauthorized'
            : 'failed'
  throw new ParseError(code, parseMessages[code])
}
