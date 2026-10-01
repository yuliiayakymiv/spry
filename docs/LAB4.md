# Lab 4 — Sign-in with Cognito (email + password and Google)

Region: **eu-central-1** (course rule). The site stays on the Lab 2 stack (CloudFront → S3 + ALB → Fargate → RDS);
sign-in is added on top. No custom domain: the site is `https://<id>.cloudfront.net`.

```
browser ──▶ CloudFront ──┬─ /*     ─(Function: app routes → /index.html)─▶ S3
   │                     └─ /api/* ─▶ ALB ─▶ Fargate ─▶ RDS
   │ /login/ → signinRedirect (state + PKCE kept in the browser)
   ▼
Cognito managed login (spry-<prefix>.auth.eu-central-1.amazoncognito.com) ──federates──▶ Google
   │ ?code=… back to https://<id>.cloudfront.net/  → token exchange (PKCE, no secret) → email in header
```

## What the commit adds

| File | What |
|---|---|
| `infra/auth.yml` | CloudFormation: user pool (Essentials, email sign-in, self sign-up on), Google IdP with attribute mapping, public app client (code + PKCE, no secret), prefix domain v2, managed login branding |
| `infra/aws/07-auth.sh` · `make deploy-auth` | Deploys the stack, adds a CloudFront Function so `/login/` returns the SPA, lets the GitHub deploy role read the stack outputs, rebuilds the frontend |
| `infra/aws/deploy-frontend.sh` | Reads `Authority`, `UserPoolClientId`, `CognitoDomain` from the stack outputs and passes them to the build as `VITE_COGNITO_*` (locally and in CI — no copy-paste) |
| `frontend/src/lib/auth.ts`, `login-page.tsx`, `components/auth-status.tsx`, `main.tsx`, `App.tsx` | `react-oidc-context`; `/login/` calls `signinRedirect()` on load; header shows **Sign in**, or the email + **Sign out** (local session cleared, then Cognito `/logout`) |
| `infra/aws/teardown.sh` | Deletes the auth stack too |

Without the `VITE_COGNITO_*` values (e.g. `docker compose up`) the app builds and runs exactly as before, with no sign-in.

## Runbook (~30 min)

1. **Pick the Cognito domain prefix** — globally unique, e.g. `spry-yuliia`. Everything Google needs points at it.
2. **Google Cloud console** (own project) → Google Auth Platform:
   - Branding / Audience: User type **External**, scopes **openid, email, profile** only, then **Publish app** → *In production*.
   - Clients → Create client → *Web application*:
     - Authorised JavaScript origin: `https://<prefix>.auth.eu-central-1.amazoncognito.com`
     - Authorised redirect URI: `https://<prefix>.auth.eu-central-1.amazoncognito.com/oauth2/idpresponse`
3. **Repo-root `.env`** (git-ignored — check with `git status` that it never shows up):
   ```
   COGNITO_DOMAIN_PREFIX=spry-yuliia
   GOOGLE_CLIENT_ID=….apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=…
   ```
4. **Git Bash:** `make deploy-auth`. The secret goes to CloudFormation as a `NoEcho` parameter; it is never in the repo or the JS bundle.
5. Wait ~5 min for CloudFront to roll out the function, then test as a stranger:
   - Private window → `https://<id>.cloudfront.net/login/` → *Sign up* with an email you can read → code → back on the site with the email in the header → **screenshot 1**. Sign out, sign in again.
   - New private window → `/login/` → *Continue with Google* with an account that is **not** a test user → **screenshot 2**.
   - Console → Cognito → user pool → Users: the Google user is `google_…`, a separate user from the password one.
6. Commit and push to `main`; CI redeploys the frontend with the same values (it now reads the stack outputs itself).
7. **Submit:** `https://<id>.cloudfront.net/login/`, the two screenshots, the commit link.

Local dev with sign-in: put the three `VITE_COGNITO_*` stack outputs into `frontend/.env.local`, `make dev-frontend`, open `http://localhost:5173/login/` (the callback list already contains `http://localhost:5173/`).

**Gotchas**
- Callback URL is the site root **with** the trailing slash: `https://<id>.cloudfront.net/`. The app sends `window.location.origin + '/'`, so they match.
- Cognito's built-in email sender: 50 emails/day per account. Enough for us, not for 90 students in one evening.
- If `/login/` shows *AccessDenied* XML, the CloudFront Function is not live yet — wait, or re-run `make deploy-auth`.
- *Error 400: redirect_uri_mismatch* from Google = the redirect URI in step 2 does not match the prefix/region exactly.
- *Access blocked: app not verified / only test users* = the Google app is still in *Testing*.

---

## Class discussion — our answers

### The migration
1. **Hourly resources in Stage 0 → Stage 2.** ALB → gone, the Lambda function URL is its own HTTPS endpoint. Public IPv4 ×3 → gone, Lambda ENIs are private. Fargate task → Lambda, billed per request. RDS db.t3.micro → Aurora Serverless v2 that pauses to 0 ACU. (RDS storage still bills, but per GB, not per hour of compute.)
2. **ALB + IPv4 buy reachability, not computation:** a permanently listening, highly available public endpoint, TLS termination and health checks, plus scarce public addresses — whether or not a single request arrives.
3. **Aurora's 15 s resume** is paid by the first user after a quiet period, so the company saves money by spending that user's time. Fine for demos, internal tools, staging. A bug for anything user-facing with a latency promise — for Spry, NFR-3 (< 2 s p95) would be broken.
4. **CORS:** Stage 0 served `/` and `/api/*` from one CloudFront hostname; Stage 2 calls `*.lambda-url…on.aws` directly — a second origin. To get back to one origin: add the function URL as a second CloudFront origin on `/api/*` (with OAC for Lambda so the URL cannot be called directly).
5. **Build-time cycle:** `make aws-deploy` deploys the backend first (CORS `*` on the very first run), builds the frontend with the API URL, and the next backend deploy narrows CORS. **Same cycle here:** the Cognito client needs the site URL as a callback, the site needs the client id at build time; and the Google client needs the Cognito domain. We break it the same way — the site URL already exists (Lab 2), so the stack is created first and the frontend is built from its outputs.
6. **No NAT gateway** because it costs ~$33/month, more than the whole stack. The day the function must call an LLM provider, Google or any external API, the call times out. Fixes: NAT gateway (pay), a second function outside the VPC, or VPC endpoints for AWS services only.
7. **us-east-1 for Ukraine:** ~120 ms vs ~30 ms per API round trip. For a company with EU customers it is a GDPR question — personal data leaves the EU, needing a transfer mechanism and disclosure. For Spry this contradicts NFR-7, which is why our course stays in eu-central-1.

### The cost
1. **Our Lab 2 deployment** (Fargate + ALB + RDS, Frankfurt) is the Stage 0 column: ~$52/month list price in us-east-1, a bit more in Frankfurt, regardless of traffic — every row of the table is the same for us. That is why we tear it down after grading.
2. **Our `/health` runs `SELECT 1`** (`backend/app/main.py`). On Stage 0 that costs nothing extra. On Stage 2, a 1-minute monitor keeps Aurora awake 730 h/month: ~$44 at 0.5 ACU, ~$88 at 1 ACU. Fix: split `/health` (liveness, no DB — what the monitor hits) from `/ready` (checks the DB, called by deploys/humans only).
3. **Move back to containers + RDS** when Aurora is awake > ~35 % of the month (~257 h at 0.5 ACU), or Lambda passes ~42 M requests/month (~16 req/s sustained). Watch in Cost Explorer, filtered by tag `PROJECT_NAME`: Aurora `ServerlessV2Usage` (ACU-hours) per day and Lambda request/GB-second cost.
4. **Free Tier is a bad basis** because it expires after 12 months (or $200 of credits), only covers one micro instance, and hides the real hourly price. The architecture outlives the discount; decide on list prices.

### Authentication
1. **ID token** — proves *who* signed in, for the client (email, name; `aud` = client id). **Access token** — permission to call an API (scopes, `client_id`, short-lived). The **access token** goes to the API; the ID token stays in the frontend.
2. **Public client + PKCE:** a secret in browser JS is public by definition. PKCE replaces it with a one-time secret per login: the app sends a hash of a random `code_verifier` and must present the verifier when exchanging the code. An intercepted authorization code (leaked via redirect, history, a malicious app) is useless without the verifier — the same protection a client secret would give.
3. **Cognito Essentials at 50,000 MAU:** 40,000 billable × ~$0.015 ≈ **$600/month** (list price — check the pricing page). Own authentication only becomes worth it when that bill exceeds the cost of an engineer maintaining password storage, MFA, recovery, email deliverability and security patches — realistically hundreds of thousands of MAU, or when Cognito's limits block a product need. For Spry (Lab 1, A-3) users sign in only with Google anyway.
4. **Two users, same email:** every table keyed by Cognito `sub` (owner of meetings, memberships, roles, audit log) splits one person into two with separate data and permissions. Link with `AdminLinkProviderForUser` (Google identity → existing native user) after the person proves both: signed in with the password **and** completed Google. Auto-linking on email alone is dangerous: an attacker who controls an identity with an unverified or recycled email equal to the victim's would take over the victim's account.
5. **Secrets:** Cognito is a server — it can keep Google's client secret private and use it in a back-channel token exchange. Our app client runs in every visitor's browser, where any value is readable in DevTools, so it gets no secret and uses PKCE instead.
6. **Google's consent screen** shows the app name, logo and the domain the user is signing in to — here `<prefix>.auth.eu-central-1.amazoncognito.com`, not our site. Users learn to trust that screen; a lookalike app name or a random domain is exactly what phishing exploits, so the name and authorised domain must be ours and recognisable (this is also why Google verifies branding for published apps).

### Stretch (not built) — protect the API
- **Why backend:** frontend checks are UI only. The API URL is in the JS; anyone can `curl` it and read or delete every meeting. Only the server can enforce access, by verifying the JWT signature (JWKS, cached), `exp`, `iss` and `client_id` and returning 401 otherwise.
- **Why not `AuthType: AWS_IAM`:** it requires SigV4-signed requests with AWS credentials. Browser users have Cognito JWTs, not AWS keys; adding an identity pool just to sign requests is far more machinery.
- **JWT authorizer on API Gateway:** removes the verification code (JWKS fetch, caching, claim checks) from our app and rejects bad tokens before they reach compute. Adds API Gateway to the bill (HTTP API ≈ $1 per million requests) and another component to configure.
