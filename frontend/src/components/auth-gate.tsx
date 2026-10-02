import { useEffect, type ReactNode } from 'react'
import { CalendarHeartIcon, LogInIcon } from 'lucide-react'
import { useAuth } from 'react-oidc-context'

import { Button } from '@/components/ui/button'
import { SESSION_EXPIRED_EVENT } from '@/lib/auth'

function Screen({ children }: { children: ReactNode }) {
  return (
    <div className="paper mx-auto my-4 flex min-h-[calc(100svh-2rem)] max-w-6xl flex-col items-center justify-center gap-6 px-5 py-10 text-center md:my-8 md:min-h-[calc(100svh-4rem)]">
      {children}
    </div>
  )
}

/** Shows the calendar only to a signed-in user; everyone else gets a "please sign in" screen. */
export function AuthGate({ children }: { children: ReactNode }) {
  const auth = useAuth()

  // The API said 401 (token expired or revoked): forget the session, show the sign-in screen.
  useEffect(() => {
    const onExpired = () => void auth.removeUser()
    window.addEventListener(SESSION_EXPIRED_EVENT, onExpired)
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, onExpired)
  }, [auth])

  if (auth.isLoading || auth.activeNavigator) {
    return (
      <Screen>
        <p className="font-serif text-xl text-muted-foreground italic">Checking sign-in…</p>
      </Screen>
    )
  }

  if (auth.isAuthenticated) return children

  return (
    <Screen>
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
      <CalendarHeartIcon className="size-12 text-[#8a6fb3]" aria-hidden="true" />
      <div className="flex max-w-md flex-col gap-2">
        <p className="font-serif text-2xl">Sign in to see your calendar</p>
        <p className="text-muted-foreground">
          Every account has its own meetings and participants. Use your email and a password, or
          continue with Google.
        </p>
      </div>
      {auth.error && (
        <p className="text-sm text-destructive">Sign-in failed: {auth.error.message}</p>
      )}
      <Button
        size="lg"
        onClick={() => void auth.signinRedirect()}
        className="border border-[#c9a96a] bg-gradient-to-r from-[#5f78b0] to-[#8a6fb3] shadow-[0_6px_20px_rgb(95_120_176/0.35)] hover:brightness-110"
      >
        <LogInIcon />
        Sign in
      </Button>
    </Screen>
  )
}
