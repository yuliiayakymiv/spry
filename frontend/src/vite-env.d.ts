/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** API origin baked in at build time, e.g. "https://api.example.com". Empty = same origin. */
  readonly VITE_API_URL?: string
}
