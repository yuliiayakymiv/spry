# ADR 0006 — Parse pasted agendas with Claude on Bedrock, outside the VPC

- Status: accepted
- Date: 2026-10-15
- Lab: 6 (Paste an agenda)

## Context

Agendas reach people as emails, chat messages and notes, often in Ukrainian and English mixed,
not as forms. *Paste an agenda* lets a user paste that text into a meeting and get the agenda
form pre-filled; the user checks it and saves.

Constraints:

- **No NAT.** Spry runs in the default VPC. The API runs on ECS Fargate, RDS is private, and the
  Lab 5 report builder Lambda sits in the VPC with no route to the internet. A NAT gateway
  (~$32/month + traffic) or an interface endpoint (~$7.30/month each) would be new standing cost.
- **Cost per call.** Every parse costs tokens, so the endpoint must be authenticated and limited.
- **Text from outside.** Pasted text can contain instructions ("ignore your instructions and…").
  It is data, never instructions, and the model must not be able to change anything.
- **The model can be wrong with a 200 status.** It may invent a value that is not in the text.

## Decision

1. **Model:** Claude Opus 5.5 (`anthropic.claude-opus-5-5`) through the Anthropic Messages API on
   Amazon Bedrock (`bedrock-mantle`), `effort: low`. The model id is configuration
   (`PARSER_MODEL`), so Haiku 5.5 can be measured on the same inputs and swapped in without a
   code change.
2. **The parser is a separate Lambda outside the VPC** (`spry-agenda-parser`, `infra/ai.yml`),
   built from the backend image with another handler, behind a public function URL. It needs no
   database: text in, JSON out. Outside the VPC it reaches Bedrock and Cognito's JWKS over the
   internet with no NAT and no endpoint, and costs $0 while nobody uses it.
3. **The model never writes.** It answers by calling one tool, `record_agenda`, whose schema is
   `ParsedAgenda`. The handler validates it (one retry with the validation error, then 422) and
   returns it to the browser. The user edits the pre-filled form; *Save* goes through the
   existing API (`PUT /api/meetings/{id}/agenda`) with its usual validation and owner check.
   The parser's IAM role can call Bedrock and write logs, nothing else.
4. **Guard rails on the endpoint:** Cognito access token required (401 before any model call),
   text over 10,000 characters → 413 before any model call, CORS limited to the site and the
   Vite dev origin, POST only.
5. **Keep the suggestion.** The save request carries what the model suggested plus model and
   prompt version; the API stores it in `meetings.ai_suggestion` (JSONB) next to the saved
   `meetings.agenda`. Suggested vs saved is the quality signal for the prompt.
6. **Region:** the stack is in `eu-central-1` with the rest of Spry; the model is called in
   `us-east-1` (`BEDROCK_REGION`), where the lab's Claude endpoint is.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| **Call Bedrock from the API (ECS, in the VPC) through a `bedrock-mantle` interface endpoint** | ~$7.30/month per endpoint per AZ even with zero parses, which breaks "$0 when idle". It also puts a slow (2–8 s) call that is driven by untrusted text inside the process that holds the database credentials and serves every other request. |
| **Claude API directly (api.anthropic.com) instead of Bedrock** | Needs an API key stored as a secret and rotated, a second bill outside AWS, and no IAM, CloudTrail or AWS Budgets on the spend. Bedrock gives the same Messages API shape with the Lambda role as the only credential. |
| **A regular-expression parser** | Free and deterministic, but the input has no fixed shape: "1) нові тарифи Pro — Олена, 15 хв", "Taras до п'ятниці", English emails with signatures. Relative dates ("by Friday") need the user's week. A regex either misses most real inputs or grows into an unmaintainable grammar per language. |

## Consequences

- **Cost per parse** with Opus 5.5: ~1,500–2,500 input tokens (system prompt, tool schema, text)
  and ~300–600 output tokens ≈ **$0.01–0.02**. With Haiku 5.5 ≈ $0.0005. Measured numbers are in
  `docs/LAB6.md`. For 20 organisations × 30 agendas a week (~2,600 parses a month): ~$42/month
  with Opus, ~$1/month with Haiku; the parser Lambda itself is within the free tier.
- **Logged:** one JSON line per parse in `/aws/lambda/spry-agenda-parser`: user (Cognito `sub`),
  model, prompt version, input/output tokens, latency, cost in dollars. **The pasted text is
  never logged.**
- **When Bedrock is down or throttling:** the parser returns 502 or 429, the screen says so, and
  the user types the agenda by hand in the same form. Everything else in Spry (meetings, sign-in,
  the weekly report) does not depend on Bedrock and keeps working.
- **Data residency:** pasted text (names, topics) is processed in `us-east-1`. Bedrock does not
  store it, and Spry stores only what the user saves. For EU customers in a real product this
  would move to an EU region or an EU inference profile.
- **Deploys:** the parser runs the backend image but is not updated by the ECS deploy; after a
  change in `backend/app/ai/` run `make deploy-ai` again.
- **Budget:** an AWS Budgets alert (`spry-monthly`) emails the owner when the month's cost passes
  `BudgetUsd` (default $5, as the lab asks). The Lab 2–5 stack alone already costs more than
  that, so the alert fires early in the month; raise `BUDGET_USD` to a real ceiling if needed.
