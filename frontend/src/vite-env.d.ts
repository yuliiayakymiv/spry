/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** API origin baked in at build time, e.g. "https://api.example.com". Empty = same origin. */
  readonly VITE_API_URL?: string
  /** OIDC issuer, https://cognito-idp.<region>.amazonaws.com/<user pool id>. Empty = no sign-in. */
  readonly VITE_COGNITO_AUTHORITY?: string
  /** Public app client id (no secret). */
  readonly VITE_COGNITO_CLIENT_ID?: string
  /** Managed login base URL, https://<prefix>.auth.<region>.amazoncognito.com */
  readonly VITE_COGNITO_DOMAIN?: string
}
