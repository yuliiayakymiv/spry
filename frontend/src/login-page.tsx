import { useEffect, useRef } from 'react'
import { useAuth } from 'react-oidc-context'

/**
 * /login/ — the URL submitted for the lab. Starting the login here (not from a copied Cognito
 * URL) lets the library store state + the PKCE code_verifier before redirecting.
 */
export function LoginPage() {
  const auth = useAuth()
  const started = useRef(false) // StrictMode runs effects twice in dev

  useEffect(() => {
    if (auth.isLoading || auth.activeNavigator || auth.error) return
    if (auth.isAuthenticated) {
      window.location.replace('/')
      return
    }
    if (!started.current) {
      started.current = true
      void auth.signinRedirect()
    }
  }, [auth])

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4 p-6 text-center">
      {auth.error ? (
        <>
          <p className="text-destructive">Sign-in failed: {auth.error.message}</p>
          <a className="underline" href="/login/">
            Try again
          </a>
        </>
      ) : (
        <p className="font-serif text-xl text-muted-foreground italic">Redirecting to sign-in…</p>
      )}
    </div>
  )
}
