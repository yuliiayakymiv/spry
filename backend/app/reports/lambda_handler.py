"""report-builder Lambda: same image as the API, different handler (infra/reports.yml).

Accepts a direct invocation ({"week": ..., "source": ...}) or an SQS event whose record bodies
have the same shape. Writes reports/<week>.csv to S3; the mailer reacts to that upload.
"""

import json
import logging
import os

import boto3

from app.reports.weekly import build_weekly_report, previous_week, report_key

log = logging.getLogger("report-builder")
log.setLevel(logging.INFO)

s3 = boto3.client("s3")


def detect_trigger(event: dict) -> str:
    records = event.get("Records") or []
    if records and records[0].get("eventSource") == "aws:sqs":
        return "sqs"
    return event.get("source") or "invoke"


def _requests(event: dict) -> list[dict]:
    if detect_trigger(event) == "sqs":
        return [json.loads(record["body"] or "{}") for record in event["Records"]]
    return [event]


def handler(event: dict, context: object) -> dict:
    trigger = detect_trigger(event)
    built = []
    for request in _requests(event):
        week = request.get("week") or previous_week()
        source = request.get("source", "unknown")
        log.info(
            "report-builder triggered trigger=%s source=%s week=%s",
            trigger,
            source,
            week,
            extra={"trigger": trigger, "source": source, "week": week},
        )
        # Fault injection for the DLQ exercise: set REPORT_FAIL_WEEK on the function.
        if week == os.environ.get("REPORT_FAIL_WEEK"):
            raise RuntimeError(f"REPORT_FAIL_WEEK={week}: failing on purpose")

        key = report_key(week)
        body = build_weekly_report(week)
        s3.put_object(
            Bucket=os.environ["REPORTS_BUCKET"],
            Key=key,
            Body=body,
            ContentType="text/csv; charset=utf-8",
        )
        log.info("report saved key=%s bytes=%d", key, len(body))
        built.append(key)
    return {"built": built}
