from httpx import AsyncClient

from tests.test_api import meeting_payload

AGENDA = {
    "items": [
        {"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15},
        {"topic": "Фідбек від клієнтів", "owner": "Taras"},
    ],
    "action_items": [{"task": "Порівняння з конкурентами", "owner": "Taras", "due": "2026-10-16"}],
}


async def _meeting(client: AsyncClient) -> dict:
    response = await client.post("/api/meetings", json=meeting_payload())
    assert response.status_code == 201, response.text
    return response.json()


async def test_new_meeting_has_no_agenda(client: AsyncClient) -> None:
    meeting = await _meeting(client)
    assert meeting["agenda"] is None


async def test_save_agenda_typed_by_hand(client: AsyncClient) -> None:
    meeting = await _meeting(client)

    response = await client.put(f"/api/meetings/{meeting['id']}/agenda", json={"agenda": AGENDA})

    assert response.status_code == 200, response.text
    saved = response.json()["agenda"]
    assert saved["items"][0] == {"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15}
    assert saved["items"][1]["minutes"] is None
    assert saved["action_items"][0]["due"] == "2026-10-16"


async def test_save_agenda_keeps_the_ai_suggestion(client: AsyncClient, engine) -> None:
    meeting = await _meeting(client)
    suggestion = {
        "agenda": {"items": [{"topic": "нові тарифи Pro", "owner": "Олена", "minutes": 15}]},
        "model": "anthropic.claude-opus-5-5",
        "prompt_version": "agenda-v1",
    }

    response = await client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"agenda": AGENDA, "ai_suggestion": suggestion},
    )

    assert response.status_code == 200, response.text
    # Not part of the API response, but stored for evaluating the prompt later.
    assert "ai_suggestion" not in response.json()
    async with engine.connect() as conn:
        stored = (
            await conn.exec_driver_sql(
                "SELECT ai_suggestion FROM meetings WHERE id = $1", (meeting["id"],)
            )
        ).scalar_one()
    assert stored["prompt_version"] == "agenda-v1"

    # A later edit by hand keeps what the model originally suggested.
    await client.put(f"/api/meetings/{meeting['id']}/agenda", json={"agenda": {"items": []}})
    async with engine.connect() as conn:
        stored = (
            await conn.exec_driver_sql(
                "SELECT ai_suggestion FROM meetings WHERE id = $1", (meeting["id"],)
            )
        ).scalar_one()
    assert stored["model"] == "anthropic.claude-opus-5-5"


async def test_editing_the_meeting_keeps_its_agenda(client: AsyncClient) -> None:
    meeting = await _meeting(client)
    await client.put(f"/api/meetings/{meeting['id']}/agenda", json={"agenda": AGENDA})

    response = await client.put(
        f"/api/meetings/{meeting['id']}", json=meeting_payload(title="Renamed")
    )

    assert response.status_code == 200
    assert response.json()["agenda"]["items"][0]["topic"] == "Нові тарифи Pro"


async def test_agenda_is_validated_like_any_form(client: AsyncClient) -> None:
    meeting = await _meeting(client)

    response = await client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"agenda": {"items": [{"topic": "  ", "minutes": 0}]}},
    )

    assert response.status_code == 422


async def test_agenda_for_unknown_meeting_is_404(client: AsyncClient) -> None:
    response = await client.put(
        "/api/meetings/00000000-0000-0000-0000-000000000000/agenda", json={"agenda": AGENDA}
    )
    assert response.status_code == 404
