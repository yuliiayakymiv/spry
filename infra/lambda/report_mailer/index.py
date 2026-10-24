"""report-mailer (Lab 5): emails a new reports/*.csv through SES.

Was inline (ZipFile) in infra/reports.yml; Terraform zips this file (archive_file in reports.tf).
"""

import logging, os, urllib.parse
from email.message import EmailMessage
import boto3

log = logging.getLogger("report-mailer")
log.setLevel(logging.INFO)
s3 = boto3.client("s3")
ses = boto3.client("sesv2")

def handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        log.info("report-mailer triggered trigger=s3 event=%s key=%s",
                 record["eventName"], key)
        data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        week = key.rsplit("/", 1)[-1].removesuffix(".csv")
        recipients = [r.strip() for r in os.environ["RECIPIENTS"].split(",") if r.strip()]
        # The summary block (first six lines) goes into the body, the full CSV is attached.
        summary = "\n".join(data.decode("utf-8-sig").splitlines()[:6])
        msg = EmailMessage()
        msg["Subject"] = f"Spry weekly meetings report {week}"
        msg["From"] = os.environ["SENDER"]
        msg["To"] = ", ".join(recipients)
        msg.set_content(f"Your meetings report for {week} is attached.\n\n{summary}\n")
        msg.add_attachment(data, maintype="text", subtype="csv", filename=f"{week}.csv")
        ses.send_email(
            FromEmailAddress=os.environ["SENDER"],
            Destination={"ToAddresses": recipients},
            Content={"Raw": {"Data": msg.as_bytes()}},
        )
        log.info("report emailed key=%s to=%d recipient(s)", key, len(recipients))
