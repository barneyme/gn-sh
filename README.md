# gn

**GET NOTES**

A simple CLI note-taking tool for people who prefer plain text over platforms.

`gn` uses Markdown files, your existing `$EDITOR`, and a private GitHub repository to create a portable note system that works in any Bash environment—even if Git is not installed.

Open a note, write, save, and quit.

`gn` handles the rest.

It automatically pulls the latest version before you edit and pushes your changes when you're done using the GitHub API and `curl`.

No databases. No subscriptions. No vendor lock-in.

Just text files and your terminal.

---

# Features

- Plain Markdown notes
- Uses your existing `$EDITOR`
- Automatic GitHub synchronization
- No Git installation required
- Works anywhere Bash and `curl` are available
- Nested note directories supported
- Full-text note searching
- Daily journal notes
- Note renaming
- Note deletion
- Private GitHub repository storage

---

# Prerequisites

Before installing `gn`, you'll need a GitHub account and a private repository.

## 1. Create a GitHub Account

If you don't already have one, create a GitHub account.

You will also need a GitHub Personal Access Token with repository permissions.

### Required Permission

```
repo
```

This grants access to your private repository.

Save the token somewhere safe—you'll need it during setup.

---

## 2. Create a Private Repository

Create a new repository named:

```text
gn
```

Recommended settings:

- Repository name: `gn`
- Visibility: **Private**
- Do not initialize with:
  - README
  - License
  - .gitignore

---

# Installation

## Option A: Automated Installer

Generate and download the installer from the project website.

Then run:

```bash
chmod +x install.sh
./install.sh
```

The installer will:

1. Create the notes directory
2. Generate `gn.conf`
3. Install `gn`
4. Register it globally

---

## Option B: Manual Installation

### Step 1 — Create the Notes Directory

```bash
mkdir -p ~/gn
```

---

### Step 2 — Create the Configuration File

```bash
nano ~/gn/gn.conf
```

Add:

```bash
GH_TOKEN=ghp_yourpersonalaccesstoken
GH_OWNER=GITHUB-USERNAME
GH_REPO=gn
```

### Configuration Variables

| Variable | Description |
|-----------|-------------|
| `GH_TOKEN` | GitHub Personal Access Token with `repo` permission |
| `GH_OWNER` | Your GitHub username |
| `GH_REPO` | Repository name (usually `gn`) |

---

### Step 3 — Install the Script

Make the script executable:

```bash
chmod +x gn.sh
```

Install globally:

```bash
sudo cp gn.sh /usr/local/bin/gn
```

You can now run:

```bash
gn
```

from anywhere.

---

# Usage

## Open Your Main Note

```bash
gn
```

Opens:

```text
index.md
```

---

## Create or Open a Note

```bash
gn daily-log
```

Creates or opens:

```text
daily-log.md
```

---

## Create Notes in Directories

```bash
gn work/reminders
```

Creates:

```text
work/reminders.md
```

and any missing directories automatically.

---

# Command Reference

## Help

```bash
gn -h
```

Displays help information.

---

## List Notes

```bash
gn -l
```

Lists all notes.

---

## Search Notes

```bash
gn -g "todo"
```

Searches every note for:

```text
todo
```

---

## Open Today's Journal

```bash
gn -t
```

Creates or opens:

```text
YYYY-MM-DD.md
```

Example:

```text
2026-06-07.md
```

---

## Delete a Note

```bash
gn -d daily-log
```

Deletes:

```text
daily-log.md
```

Locally and from GitHub.

You will be prompted for confirmation.

---

## Rename a Note

```bash
gn -r old new
```

Renames:

```text
old.md
```

to:

```text
new.md
```

Locally and on GitHub.

---

# Example Workflow

Create a note:

```bash
gn ideas
```

Edit:

```markdown
# Project Ideas

- Build a CLI dashboard
- Create a static site generator
```

Save and quit.

`gn` automatically:

1. Pulls the latest version
2. Opens your editor
3. Detects changes
4. Pushes updates to GitHub

No additional commands required.

---

# Setting Up a Second Computer

Since notes are stored in GitHub, there is nothing to clone.

Create the directory:

```bash
mkdir -p ~/gn
```

Create:

```bash
nano ~/gn/gn.conf
```

Add:

```bash
GH_TOKEN=ghp_yourpersonalaccesstoken
GH_OWNER=GITHUB-USERNAME
GH_REPO=gn
```

Install:

```bash
chmod +x gn.sh
sudo cp gn.sh /usr/local/bin/gn
```

Run:

```bash
gn
```

Your notes will automatically sync from GitHub.

---

# Browser Editing

You can edit notes without a terminal using GitHub's browser-based editor.

## Open github.dev

Visit:

```text
https://github.dev/YOUR-USERNAME/gn
```

or open your repository on GitHub and press:

```text
.
```

(period)

This launches a browser-based VS Code environment.

---

## Commit Changes

After editing:

1. Open Source Control
2. Enter a commit message
3. Commit the change

Your note is immediately saved to GitHub.

---

## Synchronization

The next time you run:

```bash
gn
```

the latest version of the note is pulled automatically.

### Important

`gn` syncs per file.

If the same note is edited simultaneously in two places, the most recent change wins.

---

# Notes Directory Structure

Example:

```text
~/gn
├── gn.conf
├── index.md
├── daily-log.md
├── ideas.md
└── work
    ├── todo.md
    └── meetings.md
```

---

# Philosophy

`gn` is built around a simple idea:

> Notes should be plain text files that belong to you.

No proprietary formats.

No databases.

No cloud subscriptions.

No lock-in.

Just Markdown, GitHub, and the terminal.

---

# License

MIT License

Copyright © 2026 Barney Matthews
