import { LogInIcon, LogOutIcon } from 'lucide-react'
import { useAuth } from 'react-oidc-context'

import { Button } from '@/components/ui/button'
import { cognitoLogoutUrl } from '@/lib/auth'

/** Header corner: "Sign in", or the signed-in email with "Sign out". */
export function AuthStatus() {
  const auth = useAuth()

  if (auth.isLoading || auth.activeNavigator) {
    return <span className="text-sm text-muted-foreground">Checking sign-in…</span>
  }

  if (auth.isAuthenticated) {
    const email = auth.user?.profile.email ?? auth.user?.profile.sub
    const signOut = async () => {
      await auth.removeUser()
      window.location.assign(cognitoLogoutUrl())
    }
    return (
      <div className="flex items-center gap-3">
        <span className="text-sm text-muted-foreground">
          Signed in as <strong className="font-semibold text-foreground">{email}</strong>
        </span>
        <Button variant="outline" size="sm" onClick={signOut}>
          <LogOutIcon />
          Sign out
        </Button>
      </div>
    )
  }

  return (
    <div className="flex items-center gap-3">
      {auth.error && (
        <span className="text-sm text-destructive">Sign-in failed: {auth.error.message}</span>
      )}
      <Button variant="outline" size="sm" onClick={() => void auth.signinRedirect()}>
        <LogInIcon />
        Sign in
      </Button>
    </div>
  )
}
