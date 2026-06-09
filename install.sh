#!/usr/bin/env bash
set -e

echo "========================================="
echo "       Starting Setup: gn script         "
echo "========================================="

NOTES_DIR="$HOME/gn"
INSTALL_DIR="/usr/local/bin"

echo "Select your Git platform provider:"
echo "1) GitHub (github.com)"
echo "2) GitLab (gitlab.com)"
echo "3) Codeberg (codeberg.org)"
echo "4) Bitbucket (bitbucket.org)"
read -rp "Enter choice [1-4, default 1]: " PROV_IDX
PROV_IDX="${PROV_IDX:-1}"

case "$PROV_IDX" in
    2) GIT_PROVIDER="gitlab" ;;
    3) GIT_PROVIDER="codeberg" ;;
    4) GIT_PROVIDER="bitbucket" ;;
    *) GIT_PROVIDER="github" ;;
esac

echo ""
echo "--- Configuring credentials for $GIT_PROVIDER ---"
if [ "$GIT_PROVIDER" = "bitbucket" ]; then
    echo "(Bitbucket uses an App Password, not a personal access token.)"
    echo "Generate one at: Bitbucket > Settings > App passwords"
    echo "Required permissions: Repositories (Read, Write)"
fi
read -rp "Personal Access Token / App Password: " GIT_TOKEN
read -rp "Account Username:           " GIT_OWNER
read -rp "Repository Name [gn]:       " GIT_REPO
GIT_REPO="${GIT_REPO:-gn}"
echo ""

echo "-> Creating directory structure at $NOTES_DIR..."
mkdir -p "$NOTES_DIR"

echo "-> Writing configuration profile layout..."
cat << CONF > "$NOTES_DIR/gn.conf"
# Configuration rules for gn command line tool
GIT_PROVIDER="$GIT_PROVIDER"
GIT_TOKEN="$GIT_TOKEN"
GIT_OWNER="$GIT_OWNER"
GIT_REPO="$GIT_REPO"
CONF
chmod 600 "$NOTES_DIR/gn.conf"
echo "   Saved profile properties successfully: $NOTES_DIR/gn.conf"
