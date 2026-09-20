#!/usr/bin/env python3
"""Email when CI fails. Called from an `if: failure()` step.

Why a script and not three lines of curl in the workflow: this has to fail
SOFTLY. A notifier that errors turns one red run into two red runs, the second
of which is about the notifier, and the actual failure is now one click further
away. Every path here exits 0.

Credentials come from the environment, which Forgejo fills from repository
secrets. Nothing is read from the repo and nothing is written back to it:

    SMTP_USER   the Gmail address sending the mail
    SMTP_PASS   a Google APP PASSWORD, not the account password -- Google
                disabled basic auth for SMTP, so the account password is
                rejected outright. App passwords are per-app and revocable
                without touching the account.
    NOTIFY_TO   where to send it (defaults to SMTP_USER)

With any of those unset this prints a line saying so and exits 0, so a fork or
a machine without the secrets still runs CI normally -- it just does not mail.
"""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
PORT = int(os.environ.get("SMTP_PORT", "587"))
USER = os.environ.get("SMTP_USER", "")
PASS = os.environ.get("SMTP_PASS", "")
TO = os.environ.get("NOTIFY_TO") or USER

# Forgejo sets these for every step; they are what makes the mail actionable
# rather than "something failed".
REPO = os.environ.get("GITHUB_REPOSITORY", "ergonOS")
WORKFLOW = os.environ.get("GITHUB_WORKFLOW", "?")
JOB = os.environ.get("GITHUB_JOB", "?")
SHA = os.environ.get("GITHUB_SHA", "")[:8]
REF = os.environ.get("GITHUB_REF_NAME", "?")
RUN = os.environ.get("GITHUB_RUN_NUMBER", "?")
SERVER = os.environ.get("GITHUB_SERVER_URL", "").rstrip("/")
RUN_ID = os.environ.get("GITHUB_RUN_ID", "")

if not (USER and PASS):
    print("notify: SMTP_USER/SMTP_PASS not set — no mail sent (this is not an error)")
    sys.exit(0)

url = f"{SERVER}/{REPO}/actions/runs/{RUN_ID}" if SERVER and RUN_ID else "(no run URL)"

msg = EmailMessage()
# The subject carries everything needed to triage from a phone lock screen:
# which suite, which branch, which commit. Opening the mail is for the link.
msg["Subject"] = f"[{REPO}] {WORKFLOW} failed on {REF} ({SHA})"
msg["From"] = USER
msg["To"] = TO
msg.set_content(
    f"""{WORKFLOW} / {JOB} failed.

repo      {REPO}
branch    {REF}
commit    {SHA}
run       #{RUN}
log       {url}

The VM suites keep their full output on the runner at
  ~/.cache/fleet-artifacts/arch-vm/session.log
which is where the actual assertion failures are. The job log shows the summary
counts; session.log shows which check failed and what it printed.
"""
)

try:
    ctx = ssl.create_default_context()
    with smtplib.SMTP(HOST, PORT, timeout=30) as s:
        s.starttls(context=ctx)
        s.login(USER, PASS)
        s.send_message(msg)
    print(f"notify: mailed {TO}")
except Exception as exc:  # noqa: BLE001 - a notifier must never fail the run
    # Deliberately broad. Every failure mode here -- DNS, auth, TLS, a revoked
    # app password -- has the same correct response: say so on the job log and
    # leave the run's own result alone.
    print(f"notify: could not send mail ({type(exc).__name__}: {exc})")
sys.exit(0)
