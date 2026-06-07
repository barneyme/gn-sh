#!/usr/bin/env bash

# --- Configuration ---
NOTES_DIR="$HOME/gn"

# --- Load Config ---
CONFIG_FILE="$NOTES_DIR/gn.conf"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "Error: No config found at $CONFIG_FILE"
    echo "Create it with:"
    echo "  GH_TOKEN=yourtoken"
    echo "  GH_OWNER=yourusername"
    echo "  GH_REPO=yourrepo"
    exit 1
fi

GH_API="https://api.github.com/repos/$GH_OWNER/$GH_REPO/contents"

mkdir -p "$NOTES_DIR"
cd "$NOTES_DIR" || { echo "Error: Could not access $NOTES_DIR"; exit 1; }

# --- GitHub API Sync Functions (used when git is not available) ---
pull_from_github() {
    local file="$1"
    local response content
    response=$(curl -s -H "Authorization: token $GH_TOKEN" "$GH_API/$file")
    content=$(echo "$response" | grep '"content"' | sed 's/.*"content": *"\(.*\)".*/\1/' | tr -d '\\n')
    if [ -n "$content" ]; then
        echo "$content" | base64 -d > "$file" 2>/dev/null || echo "$content" | base64 -D > "$file"
    fi
}

push_to_github() {
    local file="$1"
    local sha content msg api_url
    api_url="$GH_API/$file"
    sha=$(curl -s -H "Authorization: token $GH_TOKEN" "$api_url" | grep '"sha"' | head -1 | sed 's/.*"sha": *"\([^"]*\)".*/\1/')
    content=$(base64 -w0 < "$file" 2>/dev/null || base64 < "$file")
    msg="Note update: $file on $(date '+%Y-%m-%d %H:%M:%S')"
    local sha_field=""
    [ -n "$sha" ] && sha_field=",\"sha\":\"$sha\""
    curl -s -X PUT -H "Authorization: token $GH_TOKEN" "$api_url" \
        -d "{\"message\":\"$msg\",\"content\":\"$content\"$sha_field}" > /dev/null
}

# --- Help Text Function ---
show_help() {
    echo "Usage: gn [options] [note_name]"
    echo ""
    echo "Options:"
    echo "  -h        Show this help message"
    echo "  -l        List all notes in your notes directory"
    echo "  -g QUERY  Search for text across all notes (grep)"
    echo "  -t        Quickly open today's journal note (YYYY-MM-DD.md)"
    echo "  -d NOTE   Delete a note locally and from GitHub"
    echo "  -r OLD NEW  Rename a note locally and on GitHub"
    echo ""
    echo "Examples:"
    echo "  gn                  Opens index.md"
    echo "  gn daily-log        Opens daily-log.md"
    echo "  gn work/todo        Opens work/todo.md"
    echo "  gn -g 'api key'     Searches notes for the term 'api key'"
    echo "  gn -t               Opens a scratchpad for today's date"
    exit 0
}

# --- List Files Function ---
list_notes() {
    echo "Current Notes in $NOTES_DIR:"
    if [ -d "$NOTES_DIR" ]; then
        find . -type f -not -name "gn.conf" -not -path '*/.*' | sed 's|^./||' | sort
    fi
    exit 0
}

# --- Search Inside Notes Function ---
search_notes() {
    echo "Searching for '$1' inside notes..."
    grep -Rin "$1" . --exclude-dir=".git" --exclude="gn.conf"
    exit 0
}

# --- Delete Note Function ---
delete_note() {
    local file="$1"
    if [[ "$file" != *.md ]]; then
        file="${file}.md"
    fi
    if [ ! -f "$NOTES_DIR/$file" ]; then
        echo "Error: '$file' not found locally."
        exit 1
    fi
    read -r -p "Delete '$file'? This cannot be undone. [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    local sha api_url
    api_url="$GH_API/$file"
    sha=$(curl -s -H "Authorization: token $GH_TOKEN" "$api_url" | grep '"sha"' | head -1 | sed 's/.*"sha": *"\([^"]*\)".*/\1/')
    if [ -n "$sha" ]; then
        curl -s -X DELETE -H "Authorization: token $GH_TOKEN" "$api_url" \
            -d "{\"message\":\"Delete $file\",\"sha\":\"$sha\"}" > /dev/null
        echo "Deleted from GitHub."
    else
        echo "Warning: File not found on GitHub. Removing locally only."
    fi
    rm "$NOTES_DIR/$file"
    echo "Deleted '$file'."
    exit 0
}

# --- Rename Note Function ---
rename_note() {
    local old_name="$1"
    local new_name="$2"
    if [[ "$old_name" != *.md ]]; then
        old_name="${old_name}.md"
    fi
    if [[ "$new_name" != *.md ]]; then
        new_name="${new_name}.md"
    fi
    if [ ! -f "$NOTES_DIR/$old_name" ]; then
        echo "Error: '$old_name' not found locally."
        exit 1
    fi
    if [ -f "$NOTES_DIR/$new_name" ]; then
        echo "Error: '$new_name' already exists."
        exit 1
    fi
    local sha old_api_url new_api_url content
    old_api_url="$GH_API/$old_name"
    new_api_url="$GH_API/$new_name"
    sha=$(curl -s -H "Authorization: token $GH_TOKEN" "$old_api_url" | grep '"sha"' | head -1 | sed 's/.*"sha": *"\([^"]*\)".*/\1/')
    content=$(base64 -w0 < "$NOTES_DIR/$old_name" 2>/dev/null || base64 < "$NOTES_DIR/$old_name")
    curl -s -X PUT -H "Authorization: token $GH_TOKEN" "$new_api_url" \
        -d "{\"message\":\"Rename $old_name to $new_name\",\"content\":\"$content\"}" > /dev/null
    if [ -n "$sha" ]; then
        curl -s -X DELETE -H "Authorization: token $GH_TOKEN" "$old_api_url" \
            -d "{\"message\":\"Rename $old_name to $new_name\",\"sha\":\"$sha\"}" > /dev/null
    fi
    mv "$NOTES_DIR/$old_name" "$NOTES_DIR/$new_name"
    echo "Renamed '$old_name' to '$new_name'."
    exit 0
}

# --- Parse Flags ---
while getopts "hlg:td:r:" opt; do
    case ${opt} in
        h ) show_help ;;
        l ) list_notes ;;
        g ) search_notes "$OPTARG" ;;
        t ) NOTE_NAME=$(date '+%Y-%m-%d') ;;
        d ) delete_note "$OPTARG" ;;
        r ) rename_note "$OPTARG" "${@:$OPTIND:1}" ;;
        \? ) show_help ;;
    esac
done
shift $((OPTIND -1))

# If -t wasn't passed, get note name from command line arguments
if [ -z "$NOTE_NAME" ]; then
    NOTE_NAME="${1:-index}"
fi

if [[ "$NOTE_NAME" == "gn.conf" ]]; then
    echo "Error: Protection rule triggered. Cannot edit configuration file via gn script loop."
    exit 1
fi

if [[ "$NOTE_NAME" != *.md ]]; then
    NOTE_NAME="${NOTE_NAME}.md"
fi

NOTE_DIR_PATH=$(dirname "$NOTE_NAME")
if [ "$NOTE_DIR_PATH" != "." ]; then
    mkdir -p "$NOTE_DIR_PATH"
fi

# --- Sync From Cloud ---
echo "Fetching latest cloud updates..."
pull_from_github "$NOTE_NAME"

# --- Open the Editor ---
${EDITOR:-nano} "$NOTE_NAME"

# --- Sync Back to GitHub ---
echo "Syncing changes to GitHub..."
push_to_github "$NOTE_NAME"
echo "Sync complete!"