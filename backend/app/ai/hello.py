"""make llm-hello: the first call from Lab 6, Step 1. Prints the answer, stop_reason and usage."""

from app.ai.agenda import uses_converse
from app.config import settings

QUESTION = "In one sentence: what is an ISO week?"


def main() -> None:
    if uses_converse(settings.parser_model):
        import boto3

        brt = boto3.client("bedrock-runtime", region_name=settings.bedrock_region)
        resp = brt.converse(
            modelId=settings.parser_model,
            messages=[{"role": "user", "content": [{"text": QUESTION}]}],
            inferenceConfig={"maxTokens": 200},
        )
        print(resp["output"]["message"]["content"][0]["text"])
        print(resp["stopReason"], resp["usage"])
        return

    from anthropic import AnthropicBedrockMantle

    client = AnthropicBedrockMantle(aws_region=settings.bedrock_region)
    msg = client.messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": "low"},
        messages=[{"role": "user", "content": QUESTION}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


if __name__ == "__main__":
    main()
