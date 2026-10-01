import { WebStorageStateStore } from 'oidc-client-ts'
import type { AuthProviderProps } from 'react-oidc-context'

// Baked in at build time from the spry-auth stack outputs (infra/aws/deploy-frontend.sh).
// None of these is a secret: the app client is public and relies on PKCE.
const authority = import.meta.env.VITE_COGNITO_AUTHORITY ?? ''
const clientId = import.meta.env.VITE_COGNITO_CLIENT_ID ?? ''
const cognitoDomain = (import.meta.env.VITE_COGNITO_DOMAIN ?? '').replace(/\/$/, '')

/** False when the build has no Cognito settings (e.g. docker compose): the app runs without sign-in. */
export const authEnabled = Boolean(authority && clientId && cognitoDomain)

// Must match a CallbackURL / LogoutURL in infra/auth.yml exactly, trailing slash included.
const appRoot = `${window.location.origin}/`

export const oidcConfig: AuthProviderProps = {
  authority,
  client_id: clientId,
  redirect_uri: appRoot,
  post_logout_redirect_uri: appRoot,
  response_type: 'code',
  scope: 'openid email profile',
  userStore: new WebStorageStateStore({ store: window.sessionStorage }),
  // Drop ?code=…&state=… from the address bar once the tokens are in.
  onSigninCallback: () => window.history.replaceState({}, document.title, '/'),
}

/**
 * Cognito has no OIDC end_session endpoint: clear the local session, then send the browser
 * to Cognito's own /logout so its session cookie is cleared too.
 */
export function cognitoLogoutUrl(): string {
  const params = new URLSearchParams({ client_id: clientId, logout_uri: appRoot })
  return `${cognitoDomain}/logout?${params}`
}
