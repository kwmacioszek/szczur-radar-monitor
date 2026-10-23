# shellcheck shell=bash
# Helpers of the deploy verifier (see README.md), copied from szczur-radar's tools/deploy-gate/lib.sh
# (S-14) and extended with the response's content type. Sourced, never run: `. "$here/lib.sh"`. The
# sourcing script defines usage_error (exit 2) before it calls them.

# Durations, as in szczur-radar's tools/pipeline-trigger/trigger.sh: a positive whole number with an
# optional unit s, m or h (a bare number is seconds). Sets REPLY to the seconds of the duration in the
# variable named $1.
duration_seconds() {
    [[ ${!1:-} =~ ^([1-9][0-9]*)([smh]?)$ ]] \
        || usage_error "$1 must be a duration such as 30s, 3m or 2h (it is '${!1:-}')"
    case ${BASH_REMATCH[2]} in
        h) REPLY=$(( BASH_REMATCH[1] * 3600 )) ;;
        m) REPLY=$(( BASH_REMATCH[1] * 60 )) ;;
        *) REPLY=${BASH_REMATCH[1]} ;;
    esac
}

# The web origin a script was given: an http(s) URL with a host and no path. Sets REPLY to it without a
# trailing slash.
web_origin() {
    [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] \
        || usage_error "the web address must be an http(s) origin such as https://szczur-radar-web-production.up.railway.app (it is '$1')"
    REPLY=${1%/}
}

# Runs "$@" for at most $1 seconds (macOS has no coreutils `timeout`, and the tests run there too):
# its exit code, or 124 when the limit ran out and it was stopped. It gets no stdin; its stdout and
# stderr are the caller's.
limited() {
    local limit=$1 pid watcher status=0
    shift
    "$@" </dev/null &
    pid=$!
    { sleep "$limit"; kill -TERM "$pid"; } >/dev/null 2>&1 &
    watcher=$!
    wait "$pid" || status=$?
    if kill -0 "$watcher" 2>/dev/null; then
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
    elif (( status != 0 )); then
        status=124
    fi
    return "$status"
}

# Between attempts while the API wakes or restarts (the same pause as szczur-radar's pipeline-trigger).
# shellcheck disable=SC2034 # used by the sourcing script
readonly WAKE_INTERVAL=2

# One GET of the URL $1: sets REPLY to the HTTP status (000: no answer) and HTTP_TYPE to the response's
# Content-Type (empty without one), leaves the body in $HTTP_BODY and curl's error in $HTTP_ERROR
# (files the caller names). `--disable` first: no .curlrc is read.
http_get() {
    local out
    : >"$HTTP_BODY"
    out=$(curl --disable --silent --show-error --output "$HTTP_BODY" --write-out '%{http_code} %{content_type}' \
        --connect-timeout 10 --max-time 30 "$1" 2>"$HTTP_ERROR") || true
    REPLY=${out%% *}
    HTTP_TYPE=""
    [[ $out != *" "* ]] || HTTP_TYPE=${out#* }
    # shellcheck disable=SC2034 # HTTP_TYPE is read by the sourcing script
    [[ $REPLY =~ ^[0-9]{3}$ && $REPLY != 000 ]] || { REPLY=000; HTTP_TYPE=""; }
    return 0
}

# The last request's outcome for the log: curl's error, or the HTTP status.
http_outcome() {
    local text
    if [[ $REPLY == 000 ]]; then
        text=$(head -n 1 "$HTTP_ERROR")
        printf '%s\n' "${text:-no answer}"
    else
        printf 'HTTP %s\n' "$REPLY"
    fi
}
