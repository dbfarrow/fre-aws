# How it works — the mental model

Before you dive into setup, it helps to have a picture of what's happening and why. Nothing here is required reading — but if you ever wonder "why do I have to log in again?" or "where is this actually running?", this is the answer.

---

## Two places, three services

When you use this environment, things are running in **two different places**: your Mac and a cloud computer (EC2 instance) running in AWS. Different services live in different places, and that's why authentication works differently for each one.

```
┌───────────────────────────────────┐     ┌────────────────────────────────────┐
│           YOUR MAC                │     │         YOUR EC2 INSTANCE          │
│                                   │     │         (cloud computer)           │
│  user.sh runs here                │     │                                    │
│  AWS credentials live here        │ ──► │  Claude Code runs here             │
│                                   │ SSH │  GitHub access lives here          │
│                                   │ SSM │  Your repos live here              │
│                                   │     │                                    │
└───────────────────────────────────┘     └────────────────────────────────────┘
  needs AWS login — every day               needs Claude login — once, ever
                                            needs GitHub login — once, ever
```

**AWS** is what connects the two places. You log in to AWS from your Mac before you connect, because AWS is the door. You can't reach the EC2 until it's open.

**Claude Code and GitHub** live inside the EC2. Your Mac has nothing to do with them. You set them up the first time you connect, and they remember you from then on — stored on the EC2's persistent disk, which survives stop/start cycles.

---

## Why they expire differently

| Service | Where you log in | How often | Why |
|---------|-----------------|-----------|-----|
| **AWS** | Your Mac (browser) | Once a day | SSO tokens are short-lived by design — a security feature, not a bug |
| **Claude Code** | EC2 instance (first connect only) | Once ever | Stored on your persistent disk; survives stop/start |
| **GitHub** | EC2 instance (first clone only) | Once ever (≈1 year) | OAuth token stored on disk; survives stop/start |

---

## The hotel analogy

Think of it like a hotel:

**AWS is your key card.** It lets you into the building and up to your floor. It lives in your pocket (your Mac) — not in the room. The front desk resets it every day, so you do a quick re-authorization each morning before heading up.

**Your EC2 instance is your hotel room.** Everything in it — your work, your tools, your logged-in accounts — stays put whether you're there or not. When you disconnect and come back later, nothing moved.

**Claude Code is the computer in your room.** You created your Claude account before arriving. The first time you turn it on, it asks you to log in. After that, it remembers you — across disconnects, across stop/start cycles, indefinitely.

**GitHub is the filing cabinet in the hallway.** The first time you need to pull files from it, you show your ID (a browser code flow, just like AWS SSO). After that, it trusts your room's computer until the token expires — usually about a year.

---

## What this means day-to-day

**Every day:**
```bash
~/fre-aws/user.sh sso-login   # renew your AWS key card
~/fre-aws/user.sh connect     # head up to your room
```

**First time only (on the EC2, after connecting):**
- Claude Code will prompt you to log in with your Claude account
- The session launcher will prompt you to authenticate with GitHub the first time you clone a repo

After that, both stay logged in. You never need to do either again unless you explicitly log out or your instance is rebuilt from scratch.

---

## When things go wrong

**`ERROR: Could not export credentials`** — your AWS key card expired. Run `sso-login` on your Mac.

**Claude asks you to log in again** — rare; only happens if you explicitly logged out or the instance was reprovisioned. Log in once and it's done again.

**`gh auth status` shows not authenticated** — the GitHub token expired (≈1 year) or you're on a new instance. Run `gh auth login --git-protocol https` from a shell on the EC2.
