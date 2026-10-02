"""Who is calling? Verifies the Cognito access token sent as `Authorization: Bearer <token>`.

The frontend only *shows* a signed-in user; anyone can call the API with curl. This check is
what actually protects the data: no valid token, no meetings.
"""

from functools import lru_cache
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings

LOCAL_USER = "local"  # the single user when auth is off (docker compose, tests)

_bearer = HTTPBearer(auto_error=False)


@lru_cache
def _jwks_client() -> jwt.PyJWKClient:
    # Downloads the user pool's public keys once and caches them (refetches on an unknown kid).
    return jwt.PyJWKClient(
        f"{settings.cognito_issuer}/.well-known/jwks.json", cache_keys=True, lifespan=3600
    )


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"}
    )


def verify_access_token(token: str) -> dict:
    """Signature (JWKS), expiry, issuer, token_use and client_id — or 401."""
    try:
        key = _jwks_client().get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            issuer=settings.cognito_issuer,
            options={"require": ["exp", "iss", "sub"], "verify_aud": False},
            leeway=30,
        )
    except jwt.PyJWTError as exc:
        raise _unauthorized(f"Invalid token: {exc}") from None
    # Cognito access tokens carry client_id instead of aud; ID tokens are not accepted here.
    if claims.get("token_use") != "access":
        raise _unauthorized("Expected an access token")
    if claims.get("client_id") != settings.cognito_client_id:
        raise _unauthorized("Token was issued for another app client")
    return claims


# Sync on purpose: FastAPI runs it in a thread, so a JWKS download never blocks the event loop.
def current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> str:
    """The Cognito `sub` of the caller (stable per user), used as owner_id."""
    if not settings.cognito_issuer:
        return LOCAL_USER
    if credentials is None:
        raise _unauthorized("Sign in required")
    return verify_access_token(credentials.credentials)["sub"]


UserDep = Annotated[str, Depends(current_user)]
