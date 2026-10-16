"""make llm-hello: the first call from Lab 6, Step 1. Prints the answer, stop_reason and usage."""

from anthropic import AnthropicBedrockMantle

from app.config import settings


def main() -> None:
    client = AnthropicBedrockMantle(aws_region=settings.bedrock_region)
    msg = client.messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": "low"},
        messages=[{"role": "user", "content": "In one sentence: what is an ISO week?"}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


if __name__ == "__main__":
    main()
