#!/usr/bin/env bash
# gn - Get Notes
# A zero-dependency CLI note utility that syncs markdown files to cloud providers
# Author: Barney Matthews. License: MIT
# https://gn-notes.pages.dev | https://github.com/barneyme/gn-notes

# --- Configuration ---
NOTES_DIR="$HOME/gn"

# --- Hardened Config Loader ---
CONFIG_FILE="$NOTES_DIR/gn.conf"
if [ -f "$CONFIG_FILE" ]; then
    chmod 600 "$CONFIG_FILE"
    while IFS='=' read -r key value; do
        key=$(echo "$key" | tr -d '[:space:]')
        if [[ ! "$key" =~ ^# ]] && [[ -n "$key" ]]; then
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            # Strip inline comments
            value=$(echo "$value" | sed 's/[[:space:]]*#.*//')
            if [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; then
                value="${value:1:${#value}-2}"
            fi
            case "$key" in
                GIT_PROVIDER) GIT_PROVIDER="$value" ;;
                GIT_TOKEN)    GIT_TOKEN="$value" ;;
                GIT_OWNER)    GIT_OWNER="$value" ;;
                GIT_REPO)     GIT_REPO="$value" ;;
                GIT_API)      GIT_API="$value" ;;
                GH_TOKEN)     GH_TOKEN="$value" ;;
                GH_OWNER)     GH_OWNER="$value" ;;
                GH_REPO)      GH_REPO="$value" ;;
            esac
        fi
    done < "$CONFIG_FILE"
else
    echo "Error: No config found at $CONFIG_FILE"
    exit 1
fi

# Fallback compatibility for older GH_* variable names
[ -z "$GIT_PROVIDER" ] && [ -n "$GH_TOKEN" ] && GIT_PROVIDER="github"
[ -z "$GIT_TOKEN" ]   && GIT_TOKEN="$GH_TOKEN"
[ -z "$GIT_OWNER" ]   && GIT_OWNER="$GH_OWNER"
[ -z "$GIT_REPO" ]    && GIT_REPO="$GH_REPO"

if [ -z "$GIT_PROVIDER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$GIT_OWNER" ] || [ -z "$GIT_REPO" ]; then
    echo "Error: gn.conf is incomplete. Check GIT_PROVIDER, GIT_TOKEN, GIT_OWNER, and GIT_REPO."
    exit 1
fi

# Normalize provider to lowercase
GIT_PROVIDER=$(echo "$GIT_PROVIDER" | tr '[:upper:]' '[:lower:]')

# --- Dynamic API URL Constructor ---
if [ -z "$GIT_API" ]; then
    case "$GIT_PROVIDER" in
        gitlab)
            URL_ENC_PATH=$(echo "${GIT_OWNER}/${GIT_REPO}" | sed 's/\//%2F/g')
            GIT_API="https://gitlab.com/api/v4/projects/${URL_ENC_PATH}/repository/files"
            ;;
        codeberg)
            GIT_API="https://codeberg.org/api/v1/repos/${GIT_OWNER}/${GIT_REPO}/contents"
            ;;
        *)
            GIT_API="https://api.github.com/repos/${GIT_OWNER}/${GIT_REPO}/contents"
            ;;
    esac
fi

# Determine default terminal text editor
EDITOR="${EDITOR:-nano}"

# --- Check Dependencies ---
for cmd in curl grep sed base64 tr; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required dependency '$cmd' is missing." >&2
        exit 1
    fi
done

# --- Helper Functions ---
show_help() {
    echo "Usage: gn [options] [note_name]"
    echo ""
    echo "Options:"
    echo "  -h          Show this help summary"
    echo "  -l          List all local and remote tracking notes"
    echo "  -g PATTERN  Search content across notes for a regex pattern (grep)"
    echo "  -t          Open/create a note named after today's date (YYYY-MM-DD)"
    echo "  -d NOTE     Delete a note locally and push removal upstream"
    echo "  -r OLD NEW  Rename a note locally and swap its tracking upstream"
    echo ""
    echo "Defaults to opening 'index' if no note_name is specified."
    exit 0
}

# Secure network hook to protect credentials from OS process logs
git_curl() {
    local hdr rc
    hdr=$(mktemp)
    chmod 600 "$hdr"
    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        echo "PRIVATE-TOKEN: $GIT_TOKEN" > "$hdr"
    else
        echo "Authorization: token $GIT_TOKEN" > "$hdr"
    fi
    curl -s -H "@$hdr" "$@"
    rc=$?
    rm -f "$hdr"
    return $rc
}

pull_from_cloud() {
    local file="$1"
    local response content http_code url_target

    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file=$(echo "$file" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}?ref=main"
    else
        url_target="$GIT_API/$file"
    fi

    response=$(git_curl -w "\n%{http_code}" "$url_target")
    http_code=$(echo "$response" | tail -n 1)
    response=$(echo "$response" | sed '$d')

    if [ "$http_code" = "404" ]; then
        return 0
    fi

    if [ "$http_code" != "200" ]; then
        echo "Error: Pull operation failed (HTTP $http_code). Check permissions/tokens." >&2
        exit 1
    fi

    content=$(echo "$response" | grep '"content"' | head -n 1 | sed 's/.*"content": *"\(.*\)".*/\1/' | tr -d '\\n[:space:]"')
    content=$(echo "$content" | sed 's/\\n//g')

    if [ -n "$content" ] && [ "$content" != "null" ]; then
        if ! echo "$content" | base64 -d > "$file" 2>/dev/null; then
            echo "$content" | base64 -D > "$file" 2>/dev/null
        fi
    fi
}

push_to_cloud() {
    local file="$1"
    local sha content msg url_target sha_response push_response http_code req_method payload
    content=$(base64 -w0 < "$file" 2>/dev/null || base64 < "$file" | tr -d '\n')
    msg="Note update: $file on $(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file=$(echo "$file" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}"
        sha_response=$(git_curl -w "\n%{http_code}" "${url_target}?ref=main")
        http_code=$(echo "$sha_response" | tail -n 1)

        if [ "$http_code" = "200" ]; then
            req_method="PUT"
        else
            req_method="POST"
        fi
        payload="{\"branch\": \"main\", \"commit_message\": \"$msg\", \"content\": \"$content\", \"encoding\": \"base64\"}"
    else
        url_target="$GIT_API/$file"
        sha_response=$(git_curl -s "$url_target")
        sha=""
        if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
            sha="${BASH_REMATCH[1]}"
        fi
        req_method="PUT"
        if [ -n "$sha" ]; then
            payload="{\"message\": \"$msg\", \"content\": \"$content\", \"sha\": \"$sha\", \"branch\": \"main\"}"
        else
            payload="{\"message\": \"$msg\", \"content\": \"$content\", \"branch\": \"main\"}"
        fi
    fi

    push_response=$(git_curl -w "\n%{http_code}" -X "$req_method" -H "Content-Type: application/json" -d "$payload" "$url_target")
    http_code=$(echo "$push_response" | tail -n 1)

    if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
        echo "Error: Push operation failed upstream (HTTP $http_code)." >&2
        exit 1
    fi
}

list_notes() {
    echo "=== Notes Workspace Tracking: $NOTES_DIR ==="
    if [ -d "$NOTES_DIR" ]; then
        find . -type f -not -name "gn.conf" -not -name "gn.sh" -not -path '*/.*' | sed 's|^./||' | sort
    fi
    exit 0
}

search_notes() {
    echo "=== Searching structural contents for: '$1' ==="
    grep -Rin "$1" . --exclude-dir=".git" --exclude="gn.conf" --exclude="gn.sh"
    exit 0
}

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

    local sha msg url_target delete_response http_code
    msg="Note deletion: $file on $(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file=$(echo "$file" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}"
        payload="{\"branch\": \"main\", \"commit_message\": \"$msg\"}"
        delete_response=$(git_curl -w "\n%{http_code}" -X DELETE -H "Content-Type: application/json" -d "$payload" "$url_target")
        http_code=$(echo "$delete_response" | tail -n 1)
        if [ "$http_code" != "200" ]; then
            echo "Warning: Remote file could not be dropped from GitLab repo lifecycle." >&2
        fi
    else
        url_target="$GIT_API/$file"
        local sha_response
        sha_response=$(git_curl -s "$url_target")
        sha=""
        if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
            sha="${BASH_REMATCH[1]}"
        fi
        if [ -n "$sha" ]; then
            payload="{\"message\": \"$msg\", \"sha\": \"$sha\", \"branch\": \"main\"}"
            delete_response=$(git_curl -w "\n%{http_code}" -X DELETE -H "Content-Type: application/json" -d "$payload" "$url_target")
            http_code=$(echo "$delete_response" | tail -n 1)
            if [ "$http_code" != "200" ]; then
                echo "Warning: Remote node reference asset drop rejected upstream." >&2
            fi
        fi
    fi

    rm "$NOTES_DIR/$file"
    echo "Deleted '$file'."
    exit 0
}

rename_note() {
    local old_name="$1"
    local new_name="$2"
    if [[ "$old_name" != *.md ]]; then old_name="${old_name}.md"; fi
    if [[ "$new_name" != *.md ]]; then new_name="${new_name}.md"; fi

    if [ ! -f "$NOTES_DIR/$old_name" ]; then
        echo "Error: '$old_name' not found locally."
        exit 1
    fi
    if [ -f "$NOTES_DIR/$new_name" ]; then
        echo "Error: '$new_name' already exists."
        exit 1
    fi

    local sha msg url_target delete_response http_code payload
    msg="Note migration: Rename $old_name to $new_name"

    echo "Renaming tracking asset matches upstream..."
    cp "$old_name" "$new_name"
    push_to_cloud "$new_name"

    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file=$(echo "$old_name" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}"
        payload="{\"branch\": \"main\", \"commit_message\": \"$msg\"}"
        delete_response=$(git_curl -w "\n%{http_code}" -X DELETE -H "Content-Type: application/json" -d "$payload" "$url_target")
        http_code=$(echo "$delete_response" | tail -n 1)
        if [ "$http_code" != "200" ]; then
            echo "Warning: Remote legacy artifact cleanup failed upstream on GitLab." >&2
        fi
    else
        url_target="$GIT_API/$old_name"
        local sha_response
        sha_response=$(git_curl -s "$url_target")
        sha=""
        if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
            sha="${BASH_REMATCH[1]}"
        fi
        if [ -n "$sha" ]; then
            payload="{\"message\": \"$msg\", \"sha\": \"$sha\", \"branch\": \"main\"}"
            delete_response=$(git_curl -w "\n%{http_code}" -X DELETE -H "Content-Type: application/json" -d "$payload" "$url_target")
            http_code=$(echo "$delete_response" | tail -n 1)
            if [ "$http_code" != "200" ]; then
                echo "Warning: Old note could not be removed automatically from remote repo." >&2
            fi
        fi
    fi

    mv "$NOTES_DIR/$old_name" "$NOTES_DIR/$new_name"
    echo "Renamed '$old_name' to '$new_name'."
    exit 0
}

# --- Handle -r before getopts (needs two arguments) ---
if [ "$1" = "-r" ]; then
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "Error: -r requires two arguments: gn -r OLD NEW"
        exit 1
    fi
    rename_note "$2" "$3"
fi

# --- Parse flags ---
while getopts "hlg:td:" opt; do
    case ${opt} in
        h ) show_help ;;
        l ) list_notes ;;
        g ) search_notes "$OPTARG" ;;
        t ) NOTE_NAME=$(date '+%Y-%m-%d') ;;
        d ) delete_note "$OPTARG" ;;
        \? ) show_help ;;
    esac
done
shift $((OPTIND -1))

if [ -z "$NOTE_NAME" ]; then
    NOTE_NAME="${1:-index}"
fi

if [[ "$NOTE_NAME" == "gn.conf" || "$NOTE_NAME" == "gn.sh" ]]; then
    echo "Error: Protection rule triggered. Cannot touch runtime files via gn."
    exit 1
fi

if [[ "$NOTE_NAME" != *.md ]]; then
    NOTE_NAME="${NOTE_NAME}.md"
fi

# Ensure working folder space exists and drop into context
mkdir -p "$NOTES_DIR"
cd "$NOTES_DIR" || { echo "Error: Could not access $NOTES_DIR"; exit 1; }

# Handle nested directory creation if editing subfolders (e.g., gn work/todo)
NOTE_DIR_PATH=$(dirname "$NOTE_NAME")
if [ "$NOTE_DIR_PATH" != "." ] && [ -n "$NOTE_DIR_PATH" ]; then
    mkdir -p "$NOTE_DIR_PATH"
fi

# --- Sync, edit, sync ---
echo "Fetching latest version..."
pull_from_cloud "$NOTE_NAME"

# Track file characteristics before user modifications
PRE_SHA=""
if [ -f "$NOTE_NAME" ]; then
    PRE_SHA=$(md5sum "$NOTE_NAME" 2>/dev/null || shasum "$NOTE_NAME" 2>/dev/null)
fi

$EDITOR "$NOTE_NAME"

# Verify file still exists after editor exit
if [ ! -f "$NOTE_NAME" ]; then
    echo "No target note found to save. Operation cancelled."
    exit 0
fi

POST_SHA=$(md5sum "$NOTE_NAME" 2>/dev/null || shasum "$NOTE_NAME" 2>/dev/null)

if [ "$PRE_SHA" = "$POST_SHA" ]; then
    echo "No local changes detected. Cloud syncing skipped."
else
    echo "Pushing mutations upstream to cloud network..."
    push_to_cloud "$NOTE_NAME"
    echo "Sync complete!"
fi
