# Browser Access Guide

Your AWS development environment is already set up — your admin has provisioned a dedicated EC2 instance just for you. This guide covers the browser-based path: no install, no Docker, no AWS credentials required.

> **CLI path available too.** If you prefer the command-line path (or need file upload support), see the [User Guide](README-user.md).

---

## What You Need

| Requirement | Notes |
|-------------|-------|
| **A modern browser** | Chrome, Firefox, Safari, or Edge |
| **Your onboarding email** | Contains a personal access link — expires in 72 hours |
| **Claude Code account** | Create yours at [claude.ai/code](https://claude.ai/code) before your first session — your admin cannot do this for you |

---

## Step 1 — Open your access link

Your onboarding email contains a personal access link. Click it (or paste it into your browser). The link logs you in automatically — no username or password needed.

> **Link expired?** Contact your admin and ask them to run `./admin.sh publish-app-link <your-username>` to send a fresh one. Links expire after 72 hours.

After clicking the link, you'll be redirected to your personal dashboard. Bookmark that URL — it works without the original link from then on.

---

## Step 2 — Start your instance

Your dashboard shows the current state of your EC2 instance:

| Status | What it means |
|--------|--------------|
| **Instance stopped** (grey) | Instance is off — click **Start** |
| **Starting...** (yellow, pulsing) | Instance is booting — wait about 60 seconds |
| **Running — agent connecting...** (yellow) | Instance is up; the terminal agent is initialising — wait a few more seconds |
| **Ready** (green) | You can open a terminal |

Click **Start** and wait for the status to reach **Ready**.

---

## Step 3 — Open a terminal

Once the status shows **Ready**, click **Open Terminal**.

A new browser tab opens with an interactive terminal connected directly to your instance. You're logged in as `developer` and dropped into the session launcher automatically.

---

## Using the session launcher

Each time you open a terminal, you'll see a menu:

```
╔═══════════════════════════════════════╗
║     Claude Code Development Env       ║
╚═══════════════════════════════════════╝

   c) Clone a GitHub repo
   n) New project
   s) Shell

Choose [c]:
```

- **Number** — select a repo you've cloned before to reopen it in Claude Code
- **`c`** — clone a GitHub repo (authenticates with GitHub via browser code flow on first use)
- **`n`** — create a new empty project directory
- **`s`** — open a plain shell without launching Claude Code

### Session persistence

Each project opens in a named **tmux** session. If you close the terminal tab or your connection drops, the session keeps running on your instance. Reopen a terminal and select the same project to resume exactly where you left off — Claude Code and your conversation history intact.

---

## Stopping your instance

Your instance stops itself automatically when idle (after about 10 minutes with no active sessions). You can also stop it manually from your dashboard by clicking **Stop**.

A stopped instance doesn't incur compute charges, but your files are preserved on disk. Start it again any time from your dashboard.

---

## Daily use

1. Open your dashboard (bookmark the URL from your first login)
2. Click **Start** if the instance is stopped
3. Wait for **Ready**, then click **Open Terminal**
4. Select your project from the menu

AWS credentials are not required — everything is handled by the dashboard.

---

## Troubleshooting

**"Your invitation link is invalid or has expired"**
The link in your email expired (72-hour limit) or was already used. Contact your admin and ask for a new one: `./admin.sh publish-app-link <your-username>`.

**"Open Terminal" is greyed out**
The instance isn't ready yet. Wait for the status to turn green and show **Ready**. If it stays yellow for more than 2 minutes after the instance shows running, try refreshing the page.

**"Failed to open terminal"**
The terminal session couldn't be established. Try clicking **Open Terminal** again — transient errors resolve on retry. If it keeps failing, contact your admin.

**Terminal opened but shows `session_start.sh` isn't running**
This can happen on older instances. Ask your admin to run `./admin.sh refresh <your-username>` to push the latest configuration.

**Session launcher doesn't appear after the terminal opens**
The terminal may be running as the wrong user. Contact your admin.

**Lost your work**
Your files live on an EBS volume that persists even when the instance is stopped. They're only deleted if your admin explicitly destroys the environment. Check `~/repos` from a shell.

---

> **First time only:** Claude Code will prompt you to log in with your Claude account the first time you run it. Make sure you've created your [Claude Code account](https://claude.ai/code) before opening a terminal.
