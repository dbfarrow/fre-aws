#!/usr/bin/env python3
"""
send-onboarding-email.py — Send a developer onboarding email via AWS SES.

Uses only Python stdlib (email.mime.*, subprocess, argparse, tempfile, os).
Sends the raw MIME message via `aws ses send-raw-email`.

Usage:
  python3 send-onboarding-email.py \\
    --to alice@example.com \\
    --from admin@example.com \\
    --username alice \\
    --project fre-aws \\
    --role developer \\
    --aws-profile claude-code \\
    --aws-region us-east-1 \\
    --aws-cli-profile claude-code \\
    --ses-region us-east-1 \\
    [--attachment /path/to/fre-claude:fre-claude] \\
    --attachment /path/to/aws-config:aws-config \\
    --attachment /path/to/user.env:user.env
"""

import argparse
import os
import subprocess
import sys
import tempfile
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


def build_body(username: str, project: str, role: str,
               aws_profile: str, aws_region: str,
               has_private_key: bool) -> str:
    lines = [
        f"Hi {username},",
        "",
        f"You have been provisioned as a {role} in the {project} environment.",
        "",
        "Attached to this email:",
    ]

    if has_private_key:
        lines.append("  - fre-claude       : your SSH private key")
    lines += [
        "  - aws-config       : your AWS CLI configuration",
        "  - user.env    : your environment settings",
        "",
        "Setup instructions:",
        "",
    ]

    step = 1
    if has_private_key:
        lines += [
            f"  {step}. Save your SSH key:",
            "     cp fre-claude ~/.ssh/fre-claude",
            "     chmod 600 ~/.ssh/fre-claude",
            "",
        ]
        step += 1

    lines += [
        f"  {step}. Save your AWS config:",
        "     mkdir -p ~/.aws",
        "     cp aws-config ~/.aws/config",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Save your environment file:",
        "     cp user.env <project-repo>/config/user.env",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Log in to AWS SSO (a browser window will open):",
        "     ./user.sh sso-login",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Connect to your development instance:",
        "     ./user.sh connect",
        "",
        "For full documentation, see README-user.md in the project repository.",
        "",
    ]

    if has_private_key:
        lines += [
            "Want to use your own SSH key instead of the generated one?",
            f"Ask your admin to run: ./admin.sh update-user-key {username}",
            "",
        ]

    lines += [
        "Questions? Contact your project admin.",
        "",
        "—",
        f"{project} automated onboarding",
    ]

    return "\n".join(lines)


def build_message(to_addr: str, from_addr: str, subject: str,
                  body: str, attachments: list) -> MIMEMultipart:
    msg = MIMEMultipart()
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg["Subject"] = subject

    msg.attach(MIMEText(body, "plain"))

    for path, filename in attachments:
        with open(path, "rb") as fh:
            part = MIMEApplication(fh.read(), Name=filename)
        part["Content-Disposition"] = f'attachment; filename="{filename}"'
        msg.attach(part)

    return msg


def send_via_ses(msg: MIMEMultipart, ses_region: str,
                 aws_cli_profile: str) -> None:
    raw_bytes = msg.as_bytes()

    with tempfile.NamedTemporaryFile(delete=False, suffix=".eml") as tmp:
        tmp.write(raw_bytes)
        tmp_path = tmp.name

    try:
        result = subprocess.run(
            [
                "aws", "ses", "send-raw-email",
                "--region", ses_region,
                "--profile", aws_cli_profile,
                "--raw-message", f"Data=fileb://{tmp_path}",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"ERROR: SES send-raw-email failed:\n{result.stderr}", file=sys.stderr)
            sys.exit(1)
    finally:
        os.unlink(tmp_path)


def parse_attachment(value: str) -> tuple:
    """Parse 'path:filename' into (path, filename)."""
    if ":" in value:
        path, _, filename = value.partition(":")
    else:
        path = value
        filename = os.path.basename(value)
    return path, filename


def main() -> None:
    parser = argparse.ArgumentParser(description="Send user onboarding email via SES")
    parser.add_argument("--to", required=True, help="Developer email address")
    parser.add_argument("--from", dest="from_addr", required=True,
                        help="Verified SES sender email")
    parser.add_argument("--username", required=True, help="Developer username")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--role", required=True, choices=["user", "admin"],
                        help="Developer role")
    parser.add_argument("--aws-profile", required=True,
                        help="AWS profile name for the developer")
    parser.add_argument("--aws-region", required=True, help="AWS region")
    parser.add_argument("--aws-cli-profile", required=True,
                        help="AWS CLI profile to use for SES API call")
    parser.add_argument("--ses-region", required=True,
                        help="AWS region where SES is configured")
    parser.add_argument("--attachment", action="append", default=[],
                        metavar="PATH:FILENAME",
                        help="File attachment as path:filename (repeatable)")

    args = parser.parse_args()

    attachments = [parse_attachment(a) for a in args.attachment]
    has_private_key = any(fname == "fre-claude" for _, fname in attachments)

    for path, filename in attachments:
        if not os.path.exists(path):
            print(f"ERROR: Attachment not found: {path}", file=sys.stderr)
            sys.exit(1)

    subject = f"[{args.project}] Your development environment credentials"
    body = build_body(
        username=args.username,
        project=args.project,
        role=args.role,
        aws_profile=args.aws_profile,
        aws_region=args.aws_region,
        has_private_key=has_private_key,
    )

    msg = build_message(args.to, args.from_addr, subject, body, attachments)
    send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)

    print(f"  Onboarding email sent to {args.to}")


if __name__ == "__main__":
    main()
