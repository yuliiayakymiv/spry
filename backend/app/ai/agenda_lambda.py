"""agenda-parser Lambda (infra/ai.tf): same image as the API, different handler.

Outside the VPC: it needs no database, only Bedrock and Cognito's public keys, both reached
over the internet. POST {"text", "today", "tz"} with a Cognito access token → the parsed agenda.
It never writes anything; Save goes through the API.
"""

import base64
import json
import logging
import time
from datetime import date
from zoneinfo import ZoneInfo

from fastapi import HTTPException

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda
from app.auth import verify_access_token
from app.config import settings

log = logging.getLogger("agenda-parser")
log.setLevel(logging.INFO)


def _response(status: int, body: dict) -> dict:
    # CORS headers are added by the function URL itself (infra/ai.tf).
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _error(status: int, code: str, message: str) -> dict:
    return _response(status, {"error": code, "message": message})


def _bearer(event: dict) -> str:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    value = headers.get("authorization", "")
    return value[7:] if value.lower().startswith("bearer ") else ""


def _is_throttled(exc: Exception) -> bool:
    # anthropic SDK: RateLimitError / 429; boto3 (Converse): ClientError ThrottlingException.
    code = getattr(exc, "response", None)
    code = code.get("Error", {}).get("Code") if isinstance(code, dict) else None
    return (
        getattr(exc, "status_code", None) == 429
        or type(exc).__name__ == "RateLimitError"
        or code == "ThrottlingException"
    )


def handler(event: dict, context: object) -> dict:
    # Every call costs money, so no token = no model call.
    token = _bearer(event)
    if not token:
        return _error(401, "unauthorized", "Sign in required")
    try:
        user = verify_access_token(token)["sub"]
    except HTTPException as exc:
        return _error(401, "unauthorized", str(exc.detail))

    try:
        raw = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        body = json.loads(raw)
        text = str(body["text"])
        today = date.fromisoformat(body["today"])
        tz = str(body["tz"])
        ZoneInfo(tz)  # the browser's zone, e.g. Europe/Kyiv; unknown → 400
    except ValueError, KeyError, TypeError:
        return _error(400, "bad_request", 'Expected JSON {"text", "today", "tz"}')

    if not text.strip():
        return _error(400, "bad_request", "The text is empty")
    # Checked before the model call: a long paste is refused for free.
    if len(text) > settings.parser_max_chars:
        return _error(
            413, "too_long", f"The text is longer than {settings.parser_max_chars} characters"
        )

    started = time.monotonic()
    try:
        agenda, usage = parse_agenda(text, today, tz)
    except AgendaParseError as exc:
        log.info(json.dumps({"event": "agenda_not_parsed", "user": user, "reason": str(exc)}))
        return _error(422, "no_agenda", str(exc))
    except Exception as exc:
        if _is_throttled(exc):
            log.warning(json.dumps({"event": "agenda_throttled", "user": user}))
            return _error(429, "busy", "The model is busy, try again in a minute")
        log.exception("agenda parse failed")
        return _error(502, "model_error", "The model is unavailable right now")

    # One line per parse: what it cost and how long it took. Never the pasted text itself.
    log.info(
        json.dumps(
            {
                "event": "agenda_parsed",
                "user": user,
                "model": settings.parser_model,
                "prompt_version": PROMPT_VERSION,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(settings.parser_model, usage),
            }
        )
    )
    return _response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": settings.parser_model,
            "prompt_version": PROMPT_VERSION,
        },
    )
