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
            if [[ "$value" == \"*\" ]] || [[ "$value" == \'*\' ]]; then
                value="${value:1:${#value}-2}"
            fi
            eval "$key=\"\$value\""
        fi
    done < "$CONFIG_FILE"
else
    echo "Error: No config found at $CONFIG_FILE"
    exit 1
fi

# Fallback compatibility check for older legacy configuration files
[ -z "$GIT_PROVIDER" ] && [ -n "$GH_TOKEN" ] && GIT_PROVIDER="github"
[ -z "$GIT_TOKEN" ] && GIT_TOKEN="$GH_TOKEN"
[ -z "$GIT_OWNER" ] && GIT_OWNER="$GH_OWNER"
[ -z "$GIT_REPO" ] && GIT_REPO="$GH_REPO"

if [ -z "$GIT_PROVIDER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$GIT_OWNER" ] || [ -z "$GIT_REPO" ]; then
    echo "Error: gn.conf is incomplete. Check GIT_PROVIDER, GIT_TOKEN, GIT_OWNER, and GIT_REPO."
    exit 1
fi

# Normalize provider string to lowercase
GIT_PROVIDER=$(echo "$GIT_PROVIDER" | tr '[:upper:]' '[:lower:]')

# Auto-compute standard target APIs if not explicitly overridden by user
if [ -z "$GIT_API" ]; then
    case "$GIT_PROVIDER" in
        github)   GIT_API="https://api.github.com/repos/$GIT_OWNER/$GIT_REPO/contents" ;;
        codeberg) GIT_API="https://codeberg.org/api/v1/repos/$GIT_OWNER/$GIT_REPO/contents" ;;
        gitlab)
            # GitLab requires a URL-encoded project path (owner%2Frepo)
            URL_ENC_PATH=$(echo "${GIT_OWNER}/${GIT_REPO}" | sed 's/\//%2F/g')
            GIT_API="https://gitlab.com/api/v4/projects/${URL_ENC_PATH}/repository/files"
            ;;
        *) echo "Error: Unsupported provider '$GIT_PROVIDER'"; exit 1 ;;
    esac
fi

mkdir -p "$NOTES_DIR"
cd "$NOTES_DIR" || { echo "Error: Could not access $NOTES_DIR"; exit 1; }

# --- Secure Network Call Request Router Wrapper ---
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

# --- Cloud API Sync Core Layers ---
pull_from_cloud() {
    local file="$1"
    local response content http_code url_target

    if [ "$GIT_PROVIDER" = "gitlab" ]; then
        # GitLab targets specific branches via explicit query strings
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
        echo "Error: pull failed (HTTP $http_code). Check token and access rules." >&2
        exit 1
    fi

    # Native Bash extraction wrapper across JSON structures
    content=""
    while read -r line; do
        if [[ "$line" =~ \"content\":\ *\"([^\"]+)\" ]]; then
            content="${BASH_REMATCH[1]}"
            break
        fi
    done <<< "$response"

    content=$(echo "$content" | tr -d '\\n[:space:]')

    if [ -n "$content" ]; then
        echo "$content" | base64 -d > "$file" 2>/dev/null || echo "$content" | base64 -D > "$file"
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

        # GitLab requires checking existence first to determine if POST or PUT is used
        local check_status=$(git_curl -o /dev/null -w "%{http_code}" "${url_target}?ref=main")
        if [ "$check_status" = "200" ]; then
            req_method="PUT"
        else
            req_method="POST"
        fi
        payload="{\"branch\":\"main\",\"commit_message\":\"$msg\",\"content\":\"$content\",\"encoding\":\"base64\"}"

        push_response=$(git_curl -w "\n%{http_code}" -H "Content-Type: application/json" -X "$req_method" -d "$payload" "$url_target")
        http_code=$(echo "$push_response" | tail -n 1)

    else
        # GitHub & Codeberg target mechanics
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
