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

# Build API URL if not explicitly set
if [ -z "$GIT_API" ]; then
    case "$GIT_PROVIDER" in
        github)    GIT_API="https://api.github.com/repos/$GIT_OWNER/$GIT_REPO/contents" ;;
        codeberg)  GIT_API="https://codeberg.org/api/v1/repos/$GIT_OWNER/$GIT_REPO/contents" ;;
        bitbucket) GIT_API="https://api.bitbucket.org/2.0/repositories/$GIT_OWNER/$GIT_REPO" ;;
        gitlab)
            URL_ENC_PATH=$(echo "${GIT_OWNER}/${GIT_REPO}" | sed 's/\//%2F/g')
            GIT_API="https://gitlab.com/api/v4/projects/${URL_ENC_PATH}/repository/files"
            ;;
        *) echo "Error: Unsupported provider '$GIT_PROVIDER'. Use github, gitlab, codeberg, or bitbucket."; exit 1 ;;
    esac
fi

mkdir -p "$NOTES_DIR"
cd "$NOTES_DIR" || { echo "Error: Could not access $NOTES_DIR"; exit 1; }

# --- Secure curl wrapper: token written to tempfile, never exposed in ps ---
git_curl() {
    local hdr rc
    hdr=$(mktemp)
    chmod 600 "$hdr"
    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        echo "PRIVATE-TOKEN: $GIT_TOKEN" > "$hdr"
        curl -s -H "@$hdr" "$@"
    elif [ "$GIT_PROVIDER" = "bitbucket" ]; then
        # Bitbucket uses HTTP Basic auth: GIT_OWNER:GIT_TOKEN (app password)
        rm -f "$hdr"
        curl -s -u "$GIT_OWNER:$GIT_TOKEN" "$@"
    else
        echo "Authorization: token $GIT_TOKEN" > "$hdr"
        curl -s -H "@$hdr" "$@"
    fi
    rc=$?
    rm -f "$hdr"
    return $rc
}

# --- Pull from cloud ---
pull_from_cloud() {
    local file="$1"
    local response content http_code url_target

    if [ "$GIT_PROVIDER" = "bitbucket" ]; then
        # Bitbucket /src endpoint returns raw file content directly
        url_target="${GIT_API}/src/main/$file"
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
        # Response is raw file content — write directly
        printf '%s' "$response" > "$file"
        return 0
    elif [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file=$(echo "$file" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}?ref=main"
    else
        url_target="$GIT_API/$file"
    fi

    # Capture response and HTTP status code safely
    response=$(git_curl -w "\n%{http_code}" "$url_target")
    http_code=$(echo "$response" | tail -n 1)
    response=$(echo "$response" | sed '$d')

    # If the file doesn't exist on the server yet, exit the function cleanly
    if [ "$http_code" = "404" ]; then
        return 0
    fi

    if [ "$http_code" != "200" ]; then
        echo "Error: Pull operation failed (HTTP $http_code). Check permissions/tokens." >&2
        exit 1
    fi

    # Strict content parsing extraction sequence
    content=$(echo "$response" | grep '"content"' | head -n 1 | sed 's/.*"content": *"\(.*\)".*/\1/' | tr -d '\\n[:space:]"')

    # Clear out escaped literal newlines (\n) string characters sometimes returned by the API
    content=$(echo "$content" | sed 's/\\n//g')

    # Ensure $content is absolutely not null or empty before running base64 decoders
    if [ -n "$content" ] && [ "$content" != "null" ]; then
        # Try cross-platform base64 flags natively without breaking standard streams
        if ! echo "$content" | base64 -d > "$file" 2>/dev/null; then
            echo "$content" | base64 -D > "$file" 2>/dev/null
        fi
    fi
}

# --- Push to cloud ---
push_to_cloud() {
    local file="$1"
    local sha content msg url_target sha_response push_response http_code req_method payload
    content=$(base64 -w0 < "$file" 2>/dev/null || base64 < "$file" | tr -d '\n')
    msg="Note update: $file on $(date '+%Y-%m-%d %H:%M:%S')"

    if [ "$GIT_PROVIDER" = "bitbucket" ]; then
        # Bitbucket uses multipart form POST to /src — no SHA needed for create/update
        url_target="${GIT_API}/src"
        push_response=$(git_curl -w "\n%{http_code}" -X POST \
            -F "message=$msg" \
            -F "branch=main" \
            -F "$file=@$file" \
            "$url_target")
        http_code=$(echo "$push_response" | tail -n 1)
    elif [ "$GIT_PROVIDER" = "gitlab" ]; then
        local url_enc_file
        url_enc_file=$(echo "$file" | sed 's/\//%2F/g')
        url_target="${GIT_API}/${url_enc_file}"
        local check_status
        check_status=$(git_curl -o /dev/null -w "%{http_code}" "${url_target}?ref=main")
        if [ "$check_status" = "200" ]; then
            req_method="PUT"
        else
            req_method="POST"
        fi
        payload="{\"branch\":\"main\",\"commit_message\":\"$msg\",\"content\":\"$content\",\"encoding\":\"base64\"}"
        push_response=$(git_curl -w "\n%{http_code}" -H "Content-Type: application/json" -X "$req_method" -d "$payload" "$url_target")
        http_code=$(echo "$push_response" | tail -n 1)
    else
        url_target="$GIT_API/$file"
        sha_response=$(git_curl "$url_target")
        sha=""
        if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
            sha="${BASH_REMATCH[1]}"
        fi
        local sha_field=""
        [ -n "$sha" ] && sha_field=",\"sha\":\"$sha\""
        payload="{\"message\":\"$msg\",\"content\":\"$content\"$sha_field,\"branch\":\"main\"}"
        push_response=$(git_curl -w "\n%{http_code}" -X PUT -d "$payload" "$url_target")
        http_code=$(echo "$push_response" | tail -n 1)
    fi

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        echo "Error: push failed (HTTP $http_code). Changes saved locally, but not synced." >&2
        exit 1
    fi
}

# --- Help ---
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
    echo "  gn log              Creates or opens log.md"
    echo "  gn work/todo        Opens work/todo.md"
    echo "  gn -g 'api key'     Searches notes for the term 'api key'"
    echo "  gn -t               Opens today's date as a note"
    exit 0
}

# --- List notes ---
list_notes() {
    echo "Current Notes in $NOTES_DIR:"
    if [ -d "$NOTES_DIR" ]; then
        find . -type f -not -name "gn.conf" -not -name "gn.sh" -not -path '*/.*' | sed 's|^./||' | sort
    fi
    exit 0
}

# --- Search notes ---
search_notes() {
    echo "Searching for '$1' inside notes..."
    grep -Rin "$1" . --exclude-dir=".git" --exclude="gn.conf" --exclude="gn.sh"
    exit 0
}

# --- Delete note ---
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

    local sha api_url sha_response delete_response http_code
    api_url="$GIT_API/$file"

    if [ "$GIT_PROVIDER" = "bitbucket" ]; then
        # Bitbucket Cloud REST API does not support deleting individual files.
        # Remove locally only and warn the user.
        echo "Warning: Bitbucket does not support remote file deletion via API."
        echo "Removing '$file' locally only. Delete it manually from your repo if needed."
        rm "$NOTES_DIR/$file"
        echo "Deleted '$file' locally."
        exit 0
    fi

    sha_response=$(git_curl "$api_url")
    sha=""
    if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
        sha="${BASH_REMATCH[1]}"
    fi

    if [ -n "$sha" ]; then
        delete_response=$(git_curl -w "\n%{http_code}" -X DELETE "$api_url" \
            -d "{\"message\":\"Delete $file\",\"sha\":\"$sha\"}")
        http_code=$(echo "$delete_response" | tail -n 1)
        if [ "$http_code" != "200" ]; then
            echo "Error: Failed to delete from remote (HTTP $http_code). Aborting local deletion." >&2
            exit 1
        fi
        echo "Deleted from remote."
    else
        echo "Warning: File not found on remote. Removing locally only."
    fi
    rm "$NOTES_DIR/$file"
    echo "Deleted '$file'."
    exit 0
}

# --- Rename note ---
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

    local sha old_api_url new_api_url sha_response content push_response delete_response http_code
    old_api_url="$GIT_API/$old_name"
    new_api_url="$GIT_API/$new_name"

    if [ "$GIT_PROVIDER" = "bitbucket" ]; then
        # Bitbucket: push new file via /src, then warn about manual cleanup of old
        local msg="Rename $old_name to $new_name"
        push_response=$(git_curl -w "\n%{http_code}" -X POST \
            -F "message=$msg" \
            -F "branch=main" \
            -F "$new_name=@$NOTES_DIR/$old_name" \
            "${GIT_API}/src")
        http_code=$(echo "$push_response" | tail -n 1)
        if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
            echo "Error: Failed to create '$new_name' on remote (HTTP $http_code). No changes made." >&2
            exit 1
        fi
        mv "$NOTES_DIR/$old_name" "$NOTES_DIR/$new_name"
        echo "Renamed '$old_name' to '$new_name'."
        echo "Warning: Bitbucket does not support remote file deletion via API."
        echo "Please delete '$old_name' manually from your Bitbucket repo."
        exit 0
    fi

    sha_response=$(git_curl "$old_api_url")
    sha=""
    if [[ "$sha_response" =~ \"sha\":\ *\"([^\"]+)\" ]]; then
        sha="${BASH_REMATCH[1]}"
    fi

    content=$(base64 -w0 < "$NOTES_DIR/$old_name" 2>/dev/null || base64 < "$NOTES_DIR/$old_name" | tr -d '\n')

    push_response=$(git_curl -w "\n%{http_code}" -X PUT "$new_api_url" \
        -d "{\"message\":\"Rename $old_name to $new_name\",\"content\":\"$content\",\"branch\":\"main\"}")
    http_code=$(echo "$push_response" | tail -n 1)
    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        echo "Error: Failed to create '$new_name' on remote (HTTP $http_code). No changes made." >&2
        exit 1
    fi

    if [ -n "$sha" ]; then
        delete_response=$(git_curl -w "\n%{http_code}" -X DELETE "$old_api_url" \
            -d "{\"message\":\"Rename $old_name to $new_name\",\"sha\":\"$sha\"}")
        http_code=$(echo "$delete_response" | tail -n 1)
        if [ "$http_code" != "200" ]; then
            echo "Warning: New note created on remote, but old note could not be removed automatically." >&2
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

NOTE_DIR_PATH=$(dirname "$NOTE_NAME")
if [ "$NOTE_DIR_PATH" != "." ]; then
    mkdir -p "$NOTE_DIR_PATH"
fi

# --- Sync, edit, sync ---
echo "Fetching latest version..."
pull_from_cloud "$NOTE_NAME"

${EDITOR:-nano} "$NOTE_NAME"

echo "Syncing to remote..."
push_to_cloud "$NOTE_NAME"
echo "Sync complete!"
