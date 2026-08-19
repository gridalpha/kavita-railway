#!/bin/bash
# Kavita on Railway — boot-time setup.
#
# Everything here exists because Kavita reads its configuration from
# config/appsettings.json only (Program.cs clears every other configuration
# source) and creates its first administrator through the API, not from the
# environment. Each step is idempotent: an operator's own settings, libraries and
# accounts are never rewritten on a later deploy.
set -uo pipefail

log() { printf 'railway-entrypoint: %s\n' "$*"; }

DATA_DIR="${KAVITA_DATA_DIR:-/data}"
MEDIA_DIR="${KAVITA_MEDIA_DIR:-${DATA_DIR}/media}"
CONFIG_DIR="${DATA_DIR}/config"
SETTINGS_FILE="${CONFIG_DIR}/appsettings.json"
APP_DIR=/kavita
API="http://127.0.0.1:5000/api"

# The admin password is consumed here and must not reach the application
# environment, where a future Kavita release could echo it into the deploy log.
ADMIN_USERNAME="${KAVITA_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${KAVITA_ADMIN_PASSWORD:-}"
ADMIN_EMAIL="${KAVITA_ADMIN_EMAIL:-}"
unset KAVITA_ADMIN_PASSWORD

# ---------------------------------------------------------------------------
# Volume layout
#
# Kavita resolves its config store as <cwd>/config and offers no override, while
# a Railway service may mount exactly one volume. So the volume holds both the
# config store and the libraries, and <cwd>/config becomes a link into it.
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$MEDIA_DIR/books" "$MEDIA_DIR/comics" "$MEDIA_DIR/manga"

if [ ! -L "$APP_DIR/config" ]; then
    rm -rf "$APP_DIR/config"
    ln -s "$CONFIG_DIR" "$APP_DIR/config"
    log "linked $APP_DIR/config -> $CONFIG_DIR"
fi

# ---------------------------------------------------------------------------
# appsettings.json
#
# TokenKey is deliberately left alone: Kavita generates a 256-byte key on first
# boot and persists it here, so it stays stable across deploys and never has to
# exist as a Railway variable. Port and IpAddresses are ignored inside Docker
# (Configuration.GetPort returns 5000 unconditionally), so they are written only
# to keep the file honest.
# ---------------------------------------------------------------------------
if [ ! -f "$SETTINGS_FILE" ]; then
    cp /tmp/config/appsettings.json "$SETTINGS_FILE"
    log "seeded appsettings.json from the image template"
fi

if tmp_settings=$(mktemp) && jq \
        --argjson cache "${KAVITA_CACHE_MB:-75}" \
        '.Port = 5000 | .Cache = $cache' \
        "$SETTINGS_FILE" > "$tmp_settings" 2>/dev/null && [ -s "$tmp_settings" ]; then
    mv "$tmp_settings" "$SETTINGS_FILE"
else
    log "WARNING: could not rewrite appsettings.json; leaving it as found"
    rm -f "$tmp_settings"
fi

# KnownProxies is intentionally never set. Kavita feeds each entry to
# IPAddress.Parse, which rejects a CIDR and would take the whole app down at
# startup — and Railway's edge has no fixed address to list. Nothing is lost:
# the single place Kavita reads Request.Scheme is overridden by the HostName
# server setting, which the bootstrap below sets to the public https URL.

# ---------------------------------------------------------------------------
# Demo library
#
# Kavita has no web upload for library files — books arrive over the filesystem
# — so a fresh deployment would otherwise present an empty reader with no
# obvious next step. These are public-domain texts from Project Gutenberg.
# ---------------------------------------------------------------------------
# Kavita's scanner enumerates sub-directories of a library folder and never the
# folder itself, so a loose file at the library root is silently never indexed:
# the scan completes clean, reporting "0 directories to process". Every book
# therefore gets its own series folder, which is also Kavita's documented layout.
DEMO_SEEDED=0
seed_demo_media() {
    local marker="${DATA_DIR}/.demo-media-seeded-v2"
    [ "${KAVITA_DEMO_MEDIA:-true}" = "true" ] || return 0
    [ -f "$marker" ] && return 0

    local ok=0 id name
    while read -r id name; do
        [ -n "$id" ] || continue
        # A flat copy from the pre-series-folder layout would never be scanned.
        rm -f "${MEDIA_DIR}/books/${name}.epub"
        mkdir -p "${MEDIA_DIR}/books/${name}"
        if curl -fsSL --max-time 60 -o "${MEDIA_DIR}/books/${name}/${name}.epub" \
                "https://www.gutenberg.org/cache/epub/${id}/pg${id}-images-3.epub"; then
            ok=$((ok + 1))
        else
            rm -rf "${MEDIA_DIR}/books/${name}"
            log "demo media: could not fetch Gutenberg #${id}"
        fi
    done <<'BOOKS'
11 Alice's Adventures in Wonderland
84 Frankenstein
1661 The Adventures of Sherlock Holmes
1342 Pride and Prejudice
BOOKS

    if [ "$ok" -gt 0 ]; then
        touch "$marker"
        DEMO_SEEDED=1
        log "demo media: seeded $ok public-domain books into ${MEDIA_DIR}/books"
    else
        log "demo media: nothing fetched; will retry on the next deploy"
    fi
}

# ---------------------------------------------------------------------------
# First administrator and server settings
#
# The first account registered through /api/Account/register becomes the
# administrator and the endpoint refuses once one exists, so an unbootstrapped
# Kavita is claimable by whoever reaches the URL first. This closes that window
# as soon as the server answers.
# ---------------------------------------------------------------------------
bootstrap() {
    [ "${KAVITA_BOOTSTRAP:-true}" = "true" ] || { log "bootstrap: disabled"; return 0; }

    if [ -z "$ADMIN_PASSWORD" ]; then
        log "bootstrap: KAVITA_ADMIN_PASSWORD is unset — the first visitor will be able to claim this server"
        return 0
    fi

    # /api/health answers only after EF migrations and seeding have completed,
    # so a 200 here is a real readiness signal rather than a liveness one.
    local i ready=0
    for i in $(seq 1 150); do
        if curl -fsS --max-time 5 "$API/health" >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    if [ "$ready" -ne 1 ]; then
        log "bootstrap: Kavita did not answer /api/health in time; skipping"
        return 0
    fi

    local code
    code=$(curl -sS -o /tmp/register.json -w '%{http_code}' --max-time 30 \
        -X POST "$API/Account/register" -H 'Content-Type: application/json' \
        --data-binary "$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" --arg e "$ADMIN_EMAIL" \
            '{username:$u, password:$p} + (if $e == "" then {} else {email:$e} end)')" 2>/dev/null) || code=000
    case "$code" in
        200) log "bootstrap: created administrator '$ADMIN_USERNAME'" ;;
        400) log "bootstrap: an administrator already exists — leaving accounts untouched" ;;
        *)   log "bootstrap: register returned HTTP $code" ;;
    esac

    local token
    token=$(curl -sS --max-time 30 -X POST "$API/Account/login" -H 'Content-Type: application/json' \
        --data-binary "$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" '{username:$u, password:$p}')" \
        2>/dev/null | jq -r '.token // empty')
    if [ -z "$token" ]; then
        log "bootstrap: could not sign in as '$ADMIN_USERNAME'; server settings left untouched"
        return 0
    fi

    seed_server_settings "$token"
    seed_libraries "$token"
}

# HostName is what Kavita substitutes into every generated link — password
# resets, invitations, OPDS and Koreader sync — and it is also what overrides
# the one Request.Scheme read in the codebase. Setting it is what makes the
# deployment produce https URLs without any trusted-proxy configuration.
seed_server_settings() {
    local token="$1" host current desired
    host="${KAVITA_HOST_NAME:-}"
    if [ -z "$host" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        host="https://${RAILWAY_PUBLIC_DOMAIN}"
    fi
    [ -n "$host" ] || return 0

    current=$(curl -sS --max-time 30 "$API/Settings" -H "Authorization: Bearer $token" 2>/dev/null | jq -S . 2>/dev/null)
    [ -n "$current" ] || { log "bootstrap: could not read server settings"; return 0; }

    # Only ever move hostName off an empty value, so an operator who has pointed
    # this instance at a custom domain keeps their setting.
    desired=$(echo "$current" | jq -S --arg h "$host" \
        'if (.hostName // "") == "" then .hostName = $h else . end')

    # Stat collection keeps Kavita's own default unless the deployer asked for a
    # value; writing it every boot would silently revert the admin UI's toggle.
    if [ -n "${KAVITA_ALLOW_STAT_COLLECTION:-}" ]; then
        desired=$(echo "$desired" | jq -S --argjson s "${KAVITA_ALLOW_STAT_COLLECTION}" '.allowStatCollection = $s')
    fi

    if [ "$desired" = "$current" ]; then
        log "bootstrap: server settings already current"
        return 0
    fi
    if curl -fsS --max-time 30 -X POST "$API/Settings" \
            -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
            --data-binary "$desired" >/dev/null 2>&1; then
        log "bootstrap: set hostName to $host"
    else
        log "bootstrap: updating server settings failed"
    fi
}

# Newly seeded books land after the library was created on an earlier deploy, so
# ask for a scan rather than leaving them until the nightly task.
rescan_books() {
    local token="$1" id
    id=$(curl -sS --max-time 30 "$API/Library/libraries" -H "Authorization: Bearer $token" 2>/dev/null \
        | jq -r --arg f "${MEDIA_DIR}/books" 'map(select(.folders | index($f))) | .[0].id // empty')
    [ -n "$id" ] || return 0
    if curl -fsS --max-time 30 -X POST "$API/Library/scan?libraryId=${id}&force=true" \
            -H "Authorization: Bearer $token" -H 'Content-Length: 0' >/dev/null 2>&1; then
        log "bootstrap: requested a rescan of library $id for the new demo books"
    fi
}

# Libraries are created only when the server has none at all, so this never
# fights an operator who has renamed or repointed them.
seed_libraries() {
    local token="$1" existing name type folder
    existing=$(curl -sS --max-time 30 "$API/Library/libraries" -H "Authorization: Bearer $token" 2>/dev/null | jq 'length' 2>/dev/null)
    if [ -z "$existing" ]; then
        log "bootstrap: could not list libraries; skipping"
        return 0
    fi
    if [ "$existing" -gt 0 ]; then
        log "bootstrap: $existing librar(ies) already present — leaving them alone"
        [ "$DEMO_SEEDED" = "1" ] && rescan_books "$token"
        return 0
    fi

    # type: 2=Book, 1=Comic, 0=Manga. fileGroupTypes: 1=Archive, 2=EPub, 3=Pdf.
    while read -r type folder name; do
        [ -n "$type" ] || continue
        name=${name//_/ }
        if curl -fsS --max-time 60 -X POST "$API/Library/create" \
                -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
                --data-binary "$(jq -n --arg n "$name" --argjson t "$type" --arg f "${MEDIA_DIR}/${folder}" '{
                    id: 0, name: $n, type: $t, folders: [$f],
                    folderWatching: false, includeInDashboard: true, includeInSearch: true,
                    manageCollections: false, manageReadingLists: true,
                    allowScrobbling: false, allowMetadataMatching: false,
                    enableMetadata: true, removePrefixForSortName: false,
                    inheritWebLinksFromFirstChapter: false,
                    fileGroupTypes: [1, 2, 3], excludePatterns: []
                }')" >/dev/null 2>&1; then
            log "bootstrap: created library '$name' at ${MEDIA_DIR}/${folder}"
        else
            log "bootstrap: could not create library '$name'"
        fi
    done <<'LIBRARIES'
2 books Books
1 comics Comics
0 manga Manga
LIBRARIES
}

# Kavita has to be listening before the bootstrap can run, so this goes to the
# background and the server is exec'd into PID 1's child slot — which keeps
# Railway's restart and draining signals working normally. The downloads run
# first but in the same subshell, so they overlap Kavita's startup and are on
# disk before the library scan that creating a library kicks off.
( seed_demo_media; bootstrap ) &

log "starting Kavita"
cd "$APP_DIR" || exit 1
exec ./Kavita
