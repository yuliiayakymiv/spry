import { StrictMode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createRoot } from 'react-dom/client'
import { AuthProvider } from 'react-oidc-context'

import { AuthGate } from '@/components/auth-gate'
import { Toaster } from '@/components/ui/sonner'
import { authEnabled, oidcConfig } from '@/lib/auth'
import App from './App.tsx'
import { LoginPage } from './login-page.tsx'
import './index.css'

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } },
})

// Two routes only, so no router: /login/ starts the sign-in, everything else is the app,
// which is shown only after sign-in (AuthGate). Each user sees only their own meetings.
// CloudFront serves index.html for /login/ (CloudFront Function in infra/aws/07-auth.sh).
const isLoginRoute = window.location.pathname.replace(/\/+$/, '') === '/login'

const page = (
  <QueryClientProvider client={queryClient}>
    {!authEnabled ? (
      <App />
    ) : isLoginRoute ? (
      <LoginPage />
    ) : (
      <AuthGate>
        <App />
      </AuthGate>
    )}
    <Toaster position="top-right" />
  </QueryClientProvider>
)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {authEnabled ? <AuthProvider {...oidcConfig}>{page}</AuthProvider> : page}
  </StrictMode>,
)
