#!/usr/bin/env python3
"""
send-onboarding-email.py — Send a developer onboarding email via AWS SES.

Uses only Python stdlib (email.mime.*, subprocess, argparse, tempfile, os).
Sends the raw MIME message via `aws ses send-raw-email`.

Email format: multipart/alternative (plain text + HTML) for installer/app-link
flows; plain text only for the attachment fallback.

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
    --installer-url "https://s3.amazonaws.com/..."

Usage (unified — browser link + CLI installer in one email):
  python3 send-onboarding-email.py \\
    ... \\
    --installer-url "https://..." \\
    --app-url "https://..."

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


# ---------------------------------------------------------------------------
# Plain-text body builders
# ---------------------------------------------------------------------------

def build_body_app_link(username, project, app_url):
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


def build_body_installer_url(username, project, role,
                             has_private_key,
                             sso_start_url,
                             installer_url):
    lines = [
        f"Hi {username},",
        "",
        f"You have been provisioned as a {role} in the {project} environment.",
        "",
        "Setup instructions:",
        "",
    ]

    step = 1

    lines += [
        f"  {step}. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        f"     b. Enter your username: {username}",
        "     c. Click \"Forgot password\"",
        "     d. Complete the CAPTCHA",
        "     e. Check your inbox for a password reset email and follow the",
        "        link to set your password.",
        "",
    ]
    step += 1

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
            "     The installer will place your SSH key at ~/.ssh/fre-claude.",
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


def build_body_unified(username, project, role, has_private_key,
                       sso_start_url, installer_url, app_url):
    """Plain-text unified email: browser link first, CLI installer below."""
    lines = [
        f"Hi {username},",
        "",
        f"Your {project} development environment is ready.",
        "",
        "Open in your browser (no install required):",
        "",
        f"  {app_url}",
        "",
        "  The link expires in 72 hours. If it has expired, contact your project admin for a new one.",
        "",
        "---",
        "Prefer the native terminal experience? Follow these steps to install the CLI:",
        "",
    ]

    step = 1

    lines += [
        f"  {step}. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        f"     b. Enter your username: {username}",
        "     c. Click \"Forgot password\"",
        "     d. Complete the CAPTCHA",
        "     e. Check your inbox for a password reset email and follow the",
        "        link to set your password.",
        "",
    ]
    step += 1

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
            "     The installer will place your SSH key at ~/.ssh/fre-claude.",
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


def build_body_attachments(username, project, role,
                           aws_profile, aws_region,
                           has_private_key,
                           sso_start_url):
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

    lines += [
        f"  {step}. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        f"     b. Enter your username: {username}",
        "     c. Click \"Forgot password\"",
        "     d. Complete the CAPTCHA",
        "     e. Check your inbox for a password reset email and follow the",
        "        link to set your password.",
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


# ---------------------------------------------------------------------------
# HTML body builders
# ---------------------------------------------------------------------------

def _html_card(project, logo_url, body_html):
    """Wrap body_html in a styled card with project header."""
    if logo_url:
        header_content = (
            f'<img src="{logo_url}" alt="{project}" '
            'style="max-width:200px;max-height:80px;">'
        )
    else:
        header_content = (
            f'<h2 style="margin:0;color:#333;font-family:Arial,sans-serif;">'
            f'{project}</h2>'
        )
    return f"""\
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="background:#f5f5f5;font-family:Arial,Helvetica,sans-serif;padding:24px;margin:0;color:#333;">
  <div style="max-width:600px;margin:0 auto;background:#ffffff;padding:32px;border-radius:8px;">
    <div style="text-align:center;padding-bottom:20px;border-bottom:1px solid #e0e0e0;margin-bottom:24px;">
      {header_content}
    </div>
    {body_html}
    <hr style="border:none;border-top:1px solid #e0e0e0;margin:24px 0;">
    <p style="color:#999;font-size:12px;font-style:italic;margin:0;">{project} automated onboarding</p>
  </div>
</body>
</html>"""


def _html_pre(code):
    """Wrap code in a styled monospace block."""
    return (
        '<pre style="background:#f5f5f5;border:1px solid #ddd;border-radius:4px;'
        'padding:12px;font-family:monospace;font-size:13px;'
        f'overflow-x:auto;white-space:pre-wrap;">{code}</pre>'
    )


def _html_note(text):
    """Render a highlighted note box."""
    return (
        '<div style="background:#fff9e6;border-left:3px solid #e6ac00;'
        f'padding:10px 14px;margin:12px 0;font-size:13px;">{text}</div>'
    )


def build_html_app_link(username, project, app_url, logo_url):
    body_html = f"""\
    <p>Hi {username},</p>
    <p>Your <strong>{project}</strong> development environment is ready.</p>
    <p>No install required — just click the link below to open your instance in a browser:</p>
    <p style="text-align:center;margin:28px 0;">
      <a href="{app_url}" style="background:#0073bb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:4px;font-weight:bold;display:inline-block;">Open Development Environment</a>
    </p>
    <p style="color:#666;font-size:13px;">The link expires in 72 hours. If it has expired, contact your project admin for a new one.</p>"""
    return _html_card(project, logo_url, body_html)


def _html_cli_steps(username, role, project, has_private_key,
                    sso_start_url, installer_url, step_offset=1):
    """Return HTML for the numbered CLI setup steps starting at step_offset."""
    # Pre-compute multi-line command strings — backslashes are forbidden inside
    # f-string expression parts in Python < 3.12, so these must be variables.
    cmd_install = (
        "curl -fsSL '" + installer_url + "' -o /tmp/fre-setup.zip\n"
        "unzip -d /tmp/fre-setup /tmp/fre-setup.zip\n"
        "bash /tmp/fre-setup/install.sh"
    )
    cmd_github_key = (
        "ssh-keygen -y -f ~/.ssh/fre-claude | pbcopy\n"
        "# GitHub: Settings \u2192 SSH and GPG keys \u2192 New SSH key \u2192 paste it"
    )
    cmd_daily = (
        "~/fre-aws/user.sh sso-login   # re-authenticate (once per day)\n"
        "~/fre-aws/user.sh start       # start your instance if it's stopped\n"
        "~/fre-aws/user.sh connect     # connect to your instance\n"
        "~/fre-aws/user.sh stop        # stop your instance when done"
    )
    step = step_offset
    html = f"""\
    <p><strong>{step}. Activate your AWS account:</strong></p>
    <ol type="a" style="margin-left:20px;">
      <li>Go to: <a href="{sso_start_url}">{sso_start_url}</a></li>
      <li>Enter your username: <strong><code>{username}</code></strong></li>
      <li>Click <strong>"Forgot password"</strong></li>
      <li>Complete the CAPTCHA</li>
      <li>Check your inbox for a password reset email and follow the link to set your password.</li>
    </ol>
    """
    step += 1

    _pre_install = _html_pre(cmd_install)
    html += f"""\
    <p><strong>{step}. Download and run the installer</strong> (link expires in 72 hours):</p>
    {_pre_install}
    """
    step += 1

    if has_private_key:
        _pre_github = _html_pre(cmd_github_key)
        html += f"""\
    <p>The installer will place your SSH key at <code>~/.ssh/fre-claude</code>. Then add the public key to GitHub so git push/pull works:</p>
    {_pre_github}
    """

    html += f"""\
    <p><strong>{step}. Log in to AWS</strong> (a browser window will open):</p>
    {_html_pre("~/fre-aws/user.sh sso-login")}
    """
    step += 1

    _pre_daily = _html_pre(cmd_daily)
    html += f"""\
    <p><strong>{step}. Connect to your development instance:</strong></p>
    {_html_pre("~/fre-aws/user.sh connect")}
    <h3 style="color:#333;">Daily use</h3>
    {_pre_daily}
    """

    if has_private_key:
        html += f"""\
    <p style="color:#666;font-size:13px;">Want to use your own SSH key instead of the generated one? Ask your admin to run: <code>./admin.sh update-user-key {username}</code></p>
    """

    html += """\
    <p>Questions? Contact your project admin.</p>"""

    return html


def build_html_installer_url(username, project, role, has_private_key,
                             sso_start_url, installer_url, logo_url):
    body_html = f"""\
    <p>Hi {username},</p>
    <p>You have been provisioned as a <strong>{role}</strong> in the <strong>{project}</strong> environment.</p>
    <h3 style="color:#333;">Setup instructions</h3>
    {_html_cli_steps(username, role, project, has_private_key, sso_start_url, installer_url)}"""
    return _html_card(project, logo_url, body_html)


def build_html_unified(username, project, role, has_private_key,
                       sso_start_url, installer_url, app_url, logo_url):
    """HTML unified email: browser link (top), CLI installer (below)."""
    body_html = f"""\
    <p>Hi {username},</p>
    <p>Your <strong>{project}</strong> development environment is ready.</p>
    <h3 style="color:#333;">Open in your browser</h3>
    <p>No install required — just click the link below:</p>
    <p style="text-align:center;margin:28px 0;">
      <a href="{app_url}" style="background:#0073bb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:4px;font-weight:bold;display:inline-block;">Open Development Environment</a>
    </p>
    <p style="color:#666;font-size:13px;">The link expires in 72 hours. If it has expired, contact your project admin for a new one.</p>
    <hr style="border:none;border-top:1px solid #e0e0e0;margin:24px 0;">
    <h3 style="color:#333;">Prefer the native terminal experience?</h3>
    <p>Follow these steps to install the CLI:</p>
    {_html_cli_steps(username, role, project, has_private_key, sso_start_url, installer_url)}"""
    return _html_card(project, logo_url, body_html)


# ---------------------------------------------------------------------------
# Admin onboarding builders
# ---------------------------------------------------------------------------

def build_body_admin(username, project, sso_start_url, aws_region,
                     sso_region, repo_url, app_url=None):
    """Plain-text admin onboarding: activation + config values + repo pointer."""
    lines = [
        f"Hi {username},",
        "",
        f"You have been provisioned as an admin in the {project} environment.",
        "",
        "Setup instructions:",
        "",
        "  1. Activate your AWS account:",
        f"     a. Go to: {sso_start_url}",
        f"     b. Enter your username: {username}",
        "     c. Click \"Forgot password\"",
        "     d. Complete the CAPTCHA",
        "     e. Check your inbox for a password reset email and follow the",
        "        link to set your password.",
        "",
    ]

    step = 2

    if repo_url:
        lines += [
            f"  {step}. Clone the repo:",
            f"     git clone {repo_url}",
            "",
        ]
    else:
        lines += [
            f"  {step}. Clone the {project} repo.",
            "",
        ]
    step += 1

    lines += [
        f"  {step}. Configure your admin environment:",
        "     cp config/admin.env.example config/admin.env",
        "",
        "     Fill in these deployment-specific values:",
        "",
        f"       PROJECT_NAME={project}",
        f"       AWS_REGION={aws_region}",
        f"       SSO_REGION={sso_region}",
        f"       SSO_START_URL={sso_start_url}",
        "",
        "     See config/admin.env.example for all settings and descriptions.",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Configure AWS credentials:",
        f"     Your AWS profile config is at: config/onboarding/{username}/aws-config",
        "     Copy it to ~/.aws/config (or append to existing):",
        f"       cat config/onboarding/{username}/aws-config >> ~/.aws/config",
        "",
        "     Then authenticate:",
        "       ./admin.sh sso-login",
        "",
    ]
    step += 1

    lines += [
        f"  {step}. Verify your setup:",
        "     ./admin.sh verify",
        "",
    ]

    if app_url:
        lines += [
            "Browser access (no install required):",
            "",
            f"  {app_url}",
            "",
            "  The link expires in 72 hours. If it has expired, contact the project owner.",
            "",
        ]

    lines += [
        "Questions? Contact the project owner.",
        "",
        "—",
        f"{project} automated onboarding",
    ]
    return "\n".join(lines)


def build_html_admin(username, project, sso_start_url, aws_region,
                     sso_region, repo_url, logo_url, app_url=None):
    """HTML admin onboarding email."""
    # Pre-compute strings that would put \n inside an f-string expression.
    config_values = (
        "PROJECT_NAME=" + project + "\n"
        "AWS_REGION=" + aws_region + "\n"
        "SSO_REGION=" + sso_region + "\n"
        "SSO_START_URL=" + sso_start_url
    )
    aws_config_cmd = (
        "cat config/onboarding/" + username + "/aws-config >> ~/.aws/config"
    )

    activation = f"""\
    <p><strong>1. Activate your AWS account:</strong></p>
    <ol type="a" style="margin-left:20px;">
      <li>Go to: <a href="{sso_start_url}">{sso_start_url}</a></li>
      <li>Enter your username: <strong><code>{username}</code></strong></li>
      <li>Click <strong>"Forgot password"</strong></li>
      <li>Complete the CAPTCHA</li>
      <li>Check your inbox for a password reset email and follow the link to set your password.</li>
    </ol>"""

    if repo_url:
        _pre_clone = _html_pre("git clone " + repo_url)
        clone = f"""\
    <p><strong>2. Clone the repo:</strong></p>
    {_pre_clone}"""
    else:
        clone = f"<p><strong>2.</strong> Clone the <strong>{project}</strong> repo.</p>"

    _pre_cfg_cp = _html_pre("cp config/admin.env.example config/admin.env")
    _pre_cfg_vals = _html_pre(config_values)
    config = f"""\
    <p><strong>3. Configure your admin environment:</strong></p>
    {_pre_cfg_cp}
    <p>Fill in these deployment-specific values:</p>
    {_pre_cfg_vals}
    <p style="color:#666;font-size:13px;">See <code>config/admin.env.example</code> in the repo for all settings and descriptions.</p>"""

    _pre_aws_copy = _html_pre(aws_config_cmd)
    _pre_sso_login = _html_pre("./admin.sh sso-login")
    aws_creds = f"""\
    <p><strong>4. Configure AWS credentials:</strong></p>
    <p>Your AWS profile config is at <code>config/onboarding/{username}/aws-config</code>.
    Copy it to <code>~/.aws/config</code> (or append to existing):</p>
    {_pre_aws_copy}
    <p>Then authenticate:</p>
    {_pre_sso_login}"""

    _pre_verify = _html_pre("./admin.sh verify")
    verify = f"""\
    <p><strong>5. Verify your setup:</strong></p>
    {_pre_verify}"""

    app_section = ""
    if app_url:
        app_section = f"""\
    <hr style="border:none;border-top:1px solid #e0e0e0;margin:24px 0;">
    <h3 style="color:#333;">Browser access</h3>
    <p>No install required — you can also access your environment in the browser:</p>
    <p style="text-align:center;margin:28px 0;">
      <a href="{app_url}" style="background:#0073bb;color:#ffffff;text-decoration:none;padding:12px 24px;border-radius:4px;font-weight:bold;display:inline-block;">Open Development Environment</a>
    </p>
    <p style="color:#666;font-size:13px;">The link expires in 72 hours. If it has expired, contact the project owner for a new one.</p>"""

    body_html = f"""\
    <p>Hi {username},</p>
    <p>You have been provisioned as an <strong>admin</strong> in the <strong>{project}</strong> environment.</p>
    <h3 style="color:#333;">Setup instructions</h3>
    {activation}
    {clone}
    {config}
    {aws_creds}
    {verify}
    {app_section}
    <p>Questions? Contact the project owner.</p>"""
    return _html_card(project, logo_url, body_html)


# ---------------------------------------------------------------------------
# Message assembly and sending
# ---------------------------------------------------------------------------

def build_message(to_addr, from_addr, subject, plain_body, html_body, attachments):
    """Build a MIME email message.

    When html_body is provided and there are no attachments, produces
    multipart/alternative (plain + HTML). When attachments are present,
    wraps the alternative part in multipart/mixed. html_body=None sends
    plain text only (used by the attachment fallback flow).
    """
    if attachments:
        outer = MIMEMultipart("mixed")
        outer["From"] = from_addr
        outer["To"] = to_addr
        outer["Subject"] = subject
        if html_body:
            alt = MIMEMultipart("alternative")
            alt.attach(MIMEText(plain_body, "plain"))
            alt.attach(MIMEText(html_body, "html"))
            outer.attach(alt)
        else:
            outer.attach(MIMEText(plain_body, "plain"))
        for path, filename in attachments:
            with open(path, "rb") as fh:
                part = MIMEApplication(fh.read(), Name=filename)
            part["Content-Disposition"] = f'attachment; filename="{filename}"'
            outer.attach(part)
        return outer
    else:
        if html_body:
            msg = MIMEMultipart("alternative")
            msg["From"] = from_addr
            msg["To"] = to_addr
            msg["Subject"] = subject
            msg.attach(MIMEText(plain_body, "plain"))
            msg.attach(MIMEText(html_body, "html"))
        else:
            msg = MIMEMultipart()
            msg["From"] = from_addr
            msg["To"] = to_addr
            msg["Subject"] = subject
            msg.attach(MIMEText(plain_body, "plain"))
        return msg


def send_via_ses(msg, ses_region, aws_cli_profile):
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


def parse_attachment(value):
    """Parse 'path:filename' into (path, filename)."""
    if ":" in value:
        path, _, filename = value.partition(":")
    else:
        path = value
        filename = os.path.basename(value)
    return path, filename


def main():
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
    parser.add_argument("--installer-url", default=None,
                        help="Pre-signed S3 URL for the installer zip (72-hour expiry). "
                             "When provided, no file attachments are sent.")
    parser.add_argument("--attachment", action="append", default=[],
                        metavar="PATH:FILENAME",
                        help="File attachment as path:filename (repeatable). "
                             "Fallback when --installer-url is not available.")
    parser.add_argument("--app-url", default=None,
                        help="Browser app magic-link URL (72-hour expiry). "
                             "Combined with --installer-url for a unified email; "
                             "alone sends a minimal app-link email.")
    parser.add_argument("--logo-url", default=None,
                        help="HTTPS URL of a banner image shown at the top of the email card. "
                             "Omit for a clean text-only header.")
    parser.add_argument("--sso-region", default=None,
                        help="AWS region where IAM Identity Center is configured. "
                             "Required for admin onboarding email.")
    parser.add_argument("--repo-url", default=None,
                        help="Git clone URL for the project repo. "
                             "Included in the admin onboarding email.")

    args = parser.parse_args()

    attachments = [parse_attachment(a) for a in args.attachment]
    logo_url = args.logo_url

    if args.role == "admin" and args.sso_region:
        # Admin onboarding — config values + repo pointer, no installer bundle
        plain = build_body_admin(
            username=args.username,
            project=args.project,
            sso_start_url=args.sso_start_url,
            aws_region=args.aws_region,
            sso_region=args.sso_region,
            repo_url=args.repo_url or "",
            app_url=args.app_url,
        )
        html = build_html_admin(
            username=args.username,
            project=args.project,
            sso_start_url=args.sso_start_url,
            aws_region=args.aws_region,
            sso_region=args.sso_region,
            repo_url=args.repo_url or "",
            logo_url=logo_url,
            app_url=args.app_url,
        )
        subject = f"[{args.project}] Admin environment setup"
        msg = build_message(args.to, args.from_addr, subject, plain, html, [])
        send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
        print(f"  Admin onboarding email sent to {args.to}")
        return

    if args.app_url and args.installer_url:
        # Unified mode — browser link + CLI installer in one email (Issue 2)
        has_private_key = any(fname == "fre-claude" for _, fname in attachments)
        plain = build_body_unified(
            username=args.username,
            project=args.project,
            role=args.role,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            installer_url=args.installer_url,
            app_url=args.app_url,
        )
        html = build_html_unified(
            username=args.username,
            project=args.project,
            role=args.role,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            installer_url=args.installer_url,
            app_url=args.app_url,
            logo_url=logo_url,
        )
        subject = f"[{args.project}] Your development environment is ready"
        msg = build_message(args.to, args.from_addr, subject, plain, html, [])
        send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
        print(f"  Onboarding email sent to {args.to}")
        return

    if args.app_url:
        # App link only — simple email with the magic link
        plain = build_body_app_link(
            username=args.username,
            project=args.project,
            app_url=args.app_url,
        )
        html = build_html_app_link(
            username=args.username,
            project=args.project,
            app_url=args.app_url,
            logo_url=logo_url,
        )
        subject = f"[{args.project}] Your development environment is ready"
        msg = build_message(args.to, args.from_addr, subject, plain, html, [])
        send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
        print(f"  App link email sent to {args.to}")
        return

    if args.installer_url:
        # Installer URL — no attachments
        has_private_key = any(fname == "fre-claude" for _, fname in attachments)
        plain = build_body_installer_url(
            username=args.username,
            project=args.project,
            role=args.role,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            installer_url=args.installer_url,
        )
        html = build_html_installer_url(
            username=args.username,
            project=args.project,
            role=args.role,
            has_private_key=has_private_key,
            sso_start_url=args.sso_start_url,
            installer_url=args.installer_url,
            logo_url=logo_url,
        )
        subject = f"[{args.project}] Your development environment credentials"
        msg = build_message(args.to, args.from_addr, subject, plain, html, [])
        send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
        print(f"  Onboarding email sent to {args.to}")
        return

    # Attachment fallback — plain text only
    has_private_key = any(fname == "fre-claude" for _, fname in attachments)
    for path, filename in attachments:
        if not os.path.exists(path):
            print(f"ERROR: Attachment not found: {path}", file=sys.stderr)
            sys.exit(1)
    plain = build_body_attachments(
        username=args.username,
        project=args.project,
        role=args.role,
        aws_profile=args.aws_profile,
        aws_region=args.aws_region,
        has_private_key=has_private_key,
        sso_start_url=args.sso_start_url,
    )
    subject = f"[{args.project}] Your development environment credentials"
    msg = build_message(args.to, args.from_addr, subject, plain, None, attachments)
    send_via_ses(msg, ses_region=args.ses_region, aws_cli_profile=args.aws_cli_profile)
    print(f"  Onboarding email sent to {args.to}")


if __name__ == "__main__":
    main()
