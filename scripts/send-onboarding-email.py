#!/usr/bin/env python3
"""
send-onboarding-email.py — Send a developer onboarding email via AWS SES.

Uses only Python stdlib (email.mime.*, subprocess, argparse, tempfile, os).
Sends the raw MIME message via `aws ses send-raw-email`.

Usage (installer URL — no attachments):
  python3 send-onboarding-email.py \\
    --to alice@example.com \\
    --from admin@example.com \\
    --username alice \\
    --project fre-aws \\
    --role user \\
    --aws-profile claude-code \\
    --aws-region us-east-1 \\
    --aws-cli-profile claude-code \\
    --ses-region us-east-1 \\
    --sso-start-url https://... \\
    --user-email alice@example.com \\
    --installer-url "https://s3.amazonaws.com/..."

Usage (fallback with file attachments):
  python3 send-onboarding-email.py \\
    --to alice@example.com \\
    ... \\
    [--attachment /path/to/fre-claude:fre-claude] \\
    --attachment /path/to/aws-config:aws-config \\
    --attachment /path/to/user.env:user.env
"""

import argparse
import base64
import os
import subprocess
import sys
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


def build_body_app_link(username: str, project: str, app_url: str) -> str:
    lines = [
        f"Hi {username},",
        "",
        f"Your {project} development environment is ready.",
        "",
        "No install required — just click the link below to open your instance in a browser:",
        "",
        f"  {app_url}",
        "",
        "The link expires in 72 hours. If it has expired, contact your project admin for a new one.",
        "",
        "—",
        f"{project} automated onboarding",
    ]
    return "\n".join(lines)


def build_body_installer_url(username: str, project: str, role: str,
                             has_private_key: bool,
                             sso_start_url: str, user_email: str,
                             installer_url: str) -> str:
    lines = [
        f"Hi {username},",
        "",
        f"You have been provisioned as a {role} in the {project} environment.",
        "",
        "Setup instructions:",
        "",
    ]

    step = 1

    # Account activation
    lines += [
        f"  {step}. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        "     b. Click \"Forgot password\"",
        f"     c. Enter your email address: {user_email}",
        "     d. Check your inbox for a verification email from AWS and",
        "        follow the link to set your password.",
        f"     NOTE: Your AWS login name is '{username}' — not your email address.",
        "           You will need this when logging in after activation.",
        "",
    ]
    step += 1

    # Installer (URL expires in 72 hours)
    lines += [
        f"  {step}. Download and run the installer (link expires in 72 hours):",
        "",
        f"     curl -fsSL '{installer_url}' -o /tmp/fre-setup.zip",
        "     unzip -d /tmp/fre-setup /tmp/fre-setup.zip",
        "     bash /tmp/fre-setup/install.sh",
        "",
    ]
    step += 1

    if has_private_key:
        lines += [
            f"     The installer will place your SSH key at ~/.ssh/fre-claude.",
            "     Then add the public key to GitHub so git push/pull works:",
            "       ssh-keygen -y -f ~/.ssh/fre-claude | pbcopy",
            "       GitHub: Settings → SSH and GPG keys → New SSH key → paste it",
            "",
        ]

    lines += [
        f"  {step}. Log in to AWS (a browser window will open):",
        "     ~/fre-aws/user.sh sso-login",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Connect to your development instance:",
        "     ~/fre-aws/user.sh connect",
        "",
        "Daily use:",
        "  ~/fre-aws/user.sh sso-login   # re-authenticate (once per day)",
        "  ~/fre-aws/user.sh start       # start your instance if it's stopped",
        "  ~/fre-aws/user.sh connect     # connect to your instance",
        "  ~/fre-aws/user.sh stop        # stop your instance when done",
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


def build_body_attachments(username: str, project: str, role: str,
                           aws_profile: str, aws_region: str,
                           has_private_key: bool,
                           sso_start_url: str, user_email: str) -> str:
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
        "  - user.env         : your environment settings",
        "",
        "Setup instructions:",
        "",
    ]

    step = 1

    # Account activation
    lines += [
        f"  {step}. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        "     b. Click \"Forgot password\"",
        f"     c. Enter your email address: {user_email}",
        "     d. Check your inbox for a verification email from AWS and",
        "        follow the link to set your password.",
        f"     NOTE: Your AWS login name is '{username}' — not your email address.",
        "           You will need this when logging in after activation.",
        "",
    ]
    step += 1

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
    raw_b64 = base64.b64encode(msg.as_bytes()).decode("ascii")
    result = subprocess.run(
        [
            "aws", "ses", "send-raw-email",
            "--region", ses_region,
            "--profile", aws_cli_profile,
            "--raw-message", f"Data={raw_b64}",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: SES send-raw-email failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)


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
    parser.add_argument("--sso-start-url", required=True,
                        help="IAM Identity Center portal URL for account activation")
    parser.add_argument("--user-email", required=True,
                        help="User's email address (shown in activation instructions)")
    parser.add_argument("--installer-url", default=None,
                        help="Pre-signed S3 URL for the installer zip (72-hour expiry). "
                             "When provided, no file attachments are sent.")
    parser.add_argument("--attachment", action="append", default=[],
                        metavar="PATH:FILENAME",
                        help="File attachment as path:filename (repeatable). "
                             "Fallback when --installer-url is not available.")
    parser.add_argument("--app-url", default=None,
                        help="Browser app magic-link URL (72-hour expiry). "
                             "When provided, sends a minimal app-link email instead of "
                             "the full installer onboarding email.")

    args = parser.parse_args()

    attachments = [parse_attachment(a) for a in args.attachment]

    if args.app_url:
        # App link flow: simple email with just the magic link
        body = build_body_app_link(
            username=args.username,
            project=args.project,
            app_url=args.app_url,
        )
        subject = f"[{args.project}] Your development environment is ready"
        msg = build_message(args.to, args.from_addr, subject, body, [])
        send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
        print(f"  App link email sent to {args.to}")
        return

    if args.installer_url:
        # New flow: installer URL, no attachments
        has_private_key = any(fname == "fre-claude" for _, fname in attachments)
        body = build_body_installer_url(
            username=args.username,
            project=args.project,
            role=args.role,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            user_email=args.user_email,
            installer_url=args.installer_url,
        )
        # No attachments when using installer URL
        effective_attachments = []
    else:
        # Fallback flow: file attachments
        has_private_key = any(fname == "fre-claude" for _, fname in attachments)
        for path, filename in attachments:
            if not os.path.exists(path):
                print(f"ERROR: Attachment not found: {path}", file=sys.stderr)
                sys.exit(1)
        body = build_body_attachments(
            username=args.username,
            project=args.project,
            role=args.role,
            aws_profile=args.aws_profile,
            aws_region=args.aws_region,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            user_email=args.user_email,
        )
        effective_attachments = attachments

    subject = f"[{args.project}] Your development environment credentials"
    msg = build_message(args.to, args.from_addr, subject, body, effective_attachments)
    send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)

    print(f"  Onboarding email sent to {args.to}")


if __name__ == "__main__":
    main()
