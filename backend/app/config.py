from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://meetings:meetings@localhost:5432/meetings"
    # Cognito sign-in (Lab 4). Empty issuer = auth off: every request acts as one local user
    # (docker compose, tests). In AWS both are set, and every /api call needs a valid token.
    cognito_issuer: str = ""  # https://cognito-idp.<region>.amazonaws.com/<user pool id>
    cognito_client_id: str = ""
    # Lab 6 agenda parser. The model id lives in configuration, never in code.
    parser_model: str = "anthropic.claude-opus-5-5"
    # Claude on Bedrock (the bedrock-mantle endpoint) is called in us-east-1, as the lab asks,
    # even though the rest of Spry runs in eu-central-1.
    bedrock_region: str = "us-east-1"
    parser_max_chars: int = 10_000
    cors_origins: Annotated[list[str], NoDecode] = [
        "http://localhost:5173",
        "http://localhost:3000",
    ]

    @field_validator("cors_origins", mode="before")
    @classmethod
    def split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [origin.strip() for origin in value.split(",") if origin.strip()]
        return value


settings = Settings()
