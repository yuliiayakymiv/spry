import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import AsyncClient

from app import auth
from app.auth import current_user
from app.config import settings
from app.main import app

ISSUER = "https://cognito-idp.eu-central-1.amazonaws.com/eu-central-1_TEST"
CLIENT_ID = "test-client"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

MEETING = {
    "title": "Standup",
    "starts_at": "2026-10-05T09:00:00Z",
    "ends_at": "2026-10-05T09:15:00Z",
    "place": "Room 1",
}


def make_token(key=KEY, **overrides) -> str:
    claims = {
        "sub": "user-a",
        "iss": ISSUER,
        "client_id": CLIENT_ID,
        "token_use": "access",
        "exp": int(time.time()) + 600,
    } | overrides
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "k1"})


@pytest.fixture
def cognito(monkeypatch):
    """Auth on, with the JWKS download replaced by our test key."""
    monkeypatch.setattr(settings, "cognito_issuer", ISSUER)
    monkeypatch.setattr(settings, "cognito_client_id", CLIENT_ID)
    stub = SimpleNamespace(
        get_signing_key_from_jwt=lambda _t: SimpleNamespace(key=KEY.public_key())
    )
    monkeypatch.setattr(auth, "_jwks_client", lambda: stub)


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def test_health_needs_no_token(client: AsyncClient, cognito) -> None:
    assert (await client.get("/api/health")).status_code == 200


async def test_no_token_is_401(client: AsyncClient, cognito) -> None:
    for path in ("/api/meetings", "/api/participants"):
        response = await client.get(path)
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"


async def test_valid_access_token(client: AsyncClient, cognito) -> None:
    response = await client.post("/api/meetings", json=MEETING, headers=bearer(make_token()))
    assert response.status_code == 201
    listed = await client.get("/api/meetings", headers=bearer(make_token()))
    assert [m["title"] for m in listed.json()] == ["Standup"]


@pytest.mark.parametrize(
    "token",
    [
        pytest.param(lambda: make_token(exp=int(time.time()) - 120), id="expired"),
        pytest.param(lambda: make_token(client_id="someone-else"), id="other-client"),
        pytest.param(lambda: make_token(token_use="id"), id="id-token"),
        pytest.param(lambda: make_token(iss="https://evil.example.com"), id="other-issuer"),
        pytest.param(lambda: make_token(key=OTHER_KEY), id="bad-signature"),
        pytest.param(lambda: "not-a-jwt", id="garbage"),
    ],
)
async def test_rejected_tokens(client: AsyncClient, cognito, token) -> None:
    response = await client.get("/api/meetings", headers=bearer(token()))
    assert response.status_code == 401


@pytest.fixture
def as_user():
    def switch(sub: str) -> None:
        app.dependency_overrides[current_user] = lambda: sub

    return switch


async def test_users_see_only_their_own_data(client: AsyncClient, as_user) -> None:
    as_user("alice")
    alice_person = (
        await client.post("/api/participants", json={"name": "Ann", "email": "ann@x.com"})
    ).json()
    alice_meeting = (
        await client.post("/api/meetings", json=MEETING | {"participant_ids": [alice_person["id"]]})
    ).json()

    as_user("bob")
    assert (await client.get("/api/meetings")).json() == []
    assert (await client.get("/api/participants")).json() == []
    mid = alice_meeting["id"]
    assert (await client.get(f"/api/meetings/{mid}")).status_code == 404
    assert (await client.put(f"/api/meetings/{mid}", json=MEETING)).status_code == 404
    assert (await client.delete(f"/api/meetings/{mid}")).status_code == 404
    # Bob can't attach Alice's participant to his own meeting.
    stolen = await client.post(
        "/api/meetings", json=MEETING | {"participant_ids": [alice_person["id"]]}
    )
    assert stolen.status_code == 422
    # The same email is fine in another user's list.
    mine = await client.post("/api/participants", json={"name": "Ann", "email": "ann@x.com"})
    assert mine.status_code == 201

    as_user("alice")
    assert [m["id"] for m in (await client.get("/api/meetings")).json()] == [mid]
