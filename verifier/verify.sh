#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in single quotes are Markdown code spans, not expansions
# The check after one deploy of one Railway service of szczur-radar (see README.md), run by
# .github/workflows/verify.yml, which the Worker (worker/) dispatches for every final deployment event
# of a service. It judges the service that deployed, never the whole environment, from the current
# state in Railway (not from the webhook) and, for the services that serve users, from the web origin:
#
#   verify.sh >> "$GITHUB_STEP_SUMMARY"
#
# Input (variables; the workflow passes the dispatch inputs only through env:):
#   EVENT_TYPE          the Railway event: Deployment.deployed, .redeployed, .failed, .crashed, .oom_killed
#   ENVIRONMENT_ID      the Railway environment's ID (a UUID)
#   ENVIRONMENT_NAME    its name ([a-z0-9-]{1,64}), e.g. production or szczur-radar-pr-<N>
#   SERVICE_NAME        the service that deployed ([a-z0-9-]{1,64})
#   DEPLOYMENT_ID       the deployment the webhook named (a UUID; reported, the state comes from Railway)
#   RAILWAY_API_TOKEN   a Railway workspace token (read by the railway CLI; never `railway link`)
#   RAILWAY_PROJECT_ID  the szczur-radar project's ID (a UUID)
#   READINESS_SERVICES  comma-separated services whose deploy is judged by the environment's readiness
#                       (default szczur-radar-api,szczur-radar-web); every other service (a cron,
#                       the database) is judged by its deployment state alone
#   MONITOR_ASSIGNEE    the GitHub login a new issue is assigned to (the push in GitHub Mobile)
#   GH_TOKEN, GITHUB_REPOSITORY  gh against this monitor repo (issues: write); GITHUB_SERVER_URL and
#                       GITHUB_RUN_ID give the run link in the report
#   SETTLE_TIMEOUT      how long a transient state is polled for (default 5m; durations: 30s, 3m, 2h)
#   SETTLE_INTERVAL     between the questions to Railway (default 10s)
#   WAKE_TIMEOUT        how long the probes are retried once the state is OK (default 3m)
#   WEB_URL             optional, for tests and manual use only (the workflow never sets it): the web
#                       origin to probe instead of web-url.sh's
#
# The verdict, from `railway deployment list --json -s <SERVICE_NAME>` in the environment only (the
# state of another service is never read): the latest deployment is the newest by createdAt, skipping
# SKIPPED, REMOVED and REMOVING, and skipping WAITING, QUEUED and NEEDS_APPROVAL unless it is the
# webhook's DEPLOYMENT_ID: a later push's deploy that has not started (e.g. waiting for CI) does not
# replace the one serving, and its own final webhook gives its own run.
#   FAILED, CRASHED                       RED
#   BUILDING, DEPLOYING, INITIALIZING,    polled every SETTLE_INTERVAL; still transient (or Railway not
#   QUEUED, WAITING, NEEDS_APPROVAL       answering) after SETTLE_TIMEOUT: RED, "nieweryfikowalne"
#   SUCCESS, SLEEPING                     OK
#   no deployment, an unknown state       RED
#   Railway refusing the token            RED at once, "nieweryfikowalne: token Railway odrzucony"
#   (Unauthorized)                        (no retry: a refused token does not heal within the window)
# A readiness service with an OK state is then probed through the web origin, every probe retried
# within one WAKE_TIMEOUT window: GET /api/ready and GET /healthz must answer 200, GET / 200 with
# text/html that references /assets/ (the SPA, not only Caddy). Any other service is judged by its state
# alone, without probes. GREEN = an OK state and, for a readiness service, every probe passed.
#
# Issues (label deploy-health, one per environment and service, titled
# "Niezdrowe wdrożenie: <environment> / <service>", found as whole words, the oldest open one):
#   RED:   a comment on that issue, or a new one assigned to MONITOR_ASSIGNEE;
#   GREEN: a comment on that issue and closing it; an issue of another service stays open. Without
#          one only the list of open issues is read.
# The log goes to stderr (GitHub `::error::` / `::notice::` lines), the markdown report to stdout.
# No secret is printed.
# Exit codes: 0 GREEN, 1 RED (unverifiable, Railway failing and a failed gh call included), 2 a bad
# invocation or variable.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

log() { printf '%s\n' "$*" >&2; }
usage_error() { log "::error::verify: $*"; exit 2; }
# shellcheck source=lib.sh
. "$here/lib.sh"

readonly label=deploy-health
readonly title_prefix="Niezdrowe wdrożenie: "
readonly default_readiness_services=szczur-radar-api,szczur-radar-web
readonly uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
readonly name_pattern='^[a-z0-9-]{1,64}$'
# How many of the service's newest deployments are read: enough to see past a run of SKIPPED rows.
readonly deployment_limit=50

[[ $# == 0 ]] || usage_error "usage: verify.sh (input in variables, see the header)"

# The Worker's list of forwarded events (worker/src/index.ts, FORWARDED_EVENT_TYPES).
case ${EVENT_TYPE:-} in
    Deployment.deployed | Deployment.redeployed | Deployment.failed | Deployment.crashed | Deployment.oom_killed) ;;
    *) usage_error "EVENT_TYPE must be a final deployment event such as Deployment.deployed (it is '${EVENT_TYPE:-}')" ;;
esac
for name in ENVIRONMENT_ID DEPLOYMENT_ID RAILWAY_PROJECT_ID; do
    [[ ${!name:-} =~ $uuid_pattern ]] || usage_error "$name must be a lower-case UUID (it is '${!name:-}')"
done
for name in ENVIRONMENT_NAME SERVICE_NAME; do
    [[ ${!name:-} =~ $name_pattern ]] || usage_error "$name must match [a-z0-9-]{1,64} (it is '${!name:-}')"
done
[[ -n ${RAILWAY_API_TOKEN:-} ]] || usage_error "RAILWAY_API_TOKEN is not set (a Railway workspace token)"
[[ -n ${GH_TOKEN:-} ]] || usage_error "GH_TOKEN is not set (gh reports in issues with it)"
[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || usage_error "GITHUB_REPOSITORY must be <owner>/<repository> (it is '${GITHUB_REPOSITORY:-}')"
[[ ${MONITOR_ASSIGNEE:-} =~ ^[A-Za-z0-9-]{1,39}$ ]] \
    || usage_error "MONITOR_ASSIGNEE must be a GitHub login (it is '${MONITOR_ASSIGNEE:-}')"

readiness_services=()
IFS=, read -r -a readiness_list <<<"${READINESS_SERVICES:-$default_readiness_services}"
for service in "${readiness_list[@]}"; do
    service=${service//[[:space:]]/}
    [[ -n $service ]] || continue
    [[ $service =~ $name_pattern ]] || usage_error "READINESS_SERVICES must list service names [a-z0-9-]{1,64} (it has '$service')"
    readiness_services+=("$service")
done
(( ${#readiness_services[@]} > 0 )) || usage_error "READINESS_SERVICES names no service"

: "${SETTLE_TIMEOUT:=5m}" "${SETTLE_INTERVAL:=10s}" "${WAKE_TIMEOUT:=3m}"
duration_seconds SETTLE_TIMEOUT; readonly settle_timeout=$REPLY
duration_seconds SETTLE_INTERVAL; readonly settle_interval=$REPLY
duration_seconds WAKE_TIMEOUT; readonly wake_timeout=$REPLY
for tool in railway gh jq curl; do
    command -v "$tool" >/dev/null || usage_error "$tool is not installed"
done

readonly environment=$ENVIRONMENT_NAME service=$SERVICE_NAME
# The service's class: a readiness service (api, web) or a state service (a cron, the database).
kind=state
for readiness_service in "${readiness_services[@]}"; do
    [[ $service != "$readiness_service" ]] || kind=readiness
done
readonly kind

web_url=""
if [[ $kind == readiness ]]; then
    if [[ -n ${WEB_URL:-} ]]; then
        web_origin "$WEB_URL"
        web_url=$REPLY
        log "verify: probing WEB_URL=$web_url instead of the address of $environment"
    else
        web_url=$("$here/web-url.sh" "$environment" 2>/dev/null) || web_url=""
    fi
fi
readonly web_url

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
HTTP_BODY=$work/body HTTP_ERROR=$work/error

if [[ -n ${GITHUB_RUN_ID:-} ]]; then
    run_link="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
else
    run_link="(brak: uruchomione poza GitHub Actions)"
fi
readonly run_link

# --- The state of the service that deployed -------------------------------------------------------

# The service's latest deployment: sets LATEST_ID and LATEST_STATUS (LATEST_ID "none": no deployment
# but SKIPPED, REMOVED or REMOVING ones). Returns 1, with the reason in the log, when the CLI fails or
# prints no list of deployments, and 2 when Railway refuses the token (Unauthorized).
latest() {
    local out
    if ! out=$(railway deployment list --json --limit "$deployment_limit" -s "$service" \
            -p "$RAILWAY_PROJECT_ID" -e "$ENVIRONMENT_ID" 2>"$work/railway-error"); then
        log "verify: railway deployment list -s $service failed: $(head -n 3 "$work/railway-error" | tr '\n' ' ')"
        ! grep -q Unauthorized "$work/railway-error" || return 2
        return 1
    fi
    # createdAt is ISO 8601 in UTC; fractions of a second are dropped before it is compared.
    if ! out=$(jq -r --arg webhook "$DEPLOYMENT_ID" '
            def created: .createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601;
            if type != "array" then error("not a list") else
                map(if type == "object" and (.id | type) == "string" and (.status | type) == "string"
                        and (.createdAt | type) == "string"
                    then . else error("not a deployment") end)
                | map(select(.status as $status | ["SKIPPED", "REMOVED", "REMOVING"] | index($status) | not))
                | map(select(.id == $webhook
                    or (.status as $status | ["WAITING", "QUEUED", "NEEDS_APPROVAL"] | index($status) | not)))
                | map(. + {created: created})
                | if length == 0 then "none -" else (max_by(.created) | "\(.id) \(.status)") end
            end' <<<"$out" 2>/dev/null); then
        log "verify: railway deployment list -s $service printed no list of deployments"
        return 1
    fi
    read -r LATEST_ID LATEST_STATUS <<<"$out"
}

state=""        # OK, RED or UNVERIFIABLE
state_text=""   # for the report
deployment_text="—"
last_seen=""
readonly settle_deadline=$(( SECONDS + settle_timeout ))
log "verify: $EVENT_TYPE of $service in $environment (deployment $DEPLOYMENT_ID, a $kind service); reading its state in Railway"
while true; do
    railway_status=0
    latest || railway_status=$?
    if (( railway_status == 0 )); then
        last_seen=$LATEST_STATUS
        if [[ $LATEST_ID == none ]]; then
            state=RED state_text="brak deployu"
            break
        fi
        deployment_text="\`$LATEST_ID\`"
        case $LATEST_STATUS in
            SUCCESS | SLEEPING)
                state=OK state_text=$LATEST_STATUS
                break
                ;;
            FAILED | CRASHED)
                state=RED state_text=$LATEST_STATUS
                break
                ;;
            BUILDING | DEPLOYING | INITIALIZING | QUEUED | WAITING | NEEDS_APPROVAL)
                log "verify: $service deployment $LATEST_ID: $LATEST_STATUS; asking again every $SETTLE_INTERVAL for up to $SETTLE_TIMEOUT"
                ;;
            *)
                state=RED state_text="nieznany stan: $LATEST_STATUS"
                break
                ;;
        esac
    elif (( railway_status == 2 )); then
        state=UNVERIFIABLE state_text="nieweryfikowalne: token Railway odrzucony"
        break
    else
        last_seen="Railway nie odpowiada"
    fi
    if (( SECONDS >= settle_deadline )); then
        state=UNVERIFIABLE state_text="nieweryfikowalne: $last_seen"
        break
    fi
    pause=$(( settle_deadline - SECONDS ))
    (( pause < settle_interval )) || pause=$settle_interval
    sleep "$pause"
done
log "verify: $service in $environment: $state_text"

# --- The probes of a readiness service ------------------------------------------------------------

# GET <web>$1 until it passes or the window closes (at least once): returns 0 when it passed, sets
# RESULT to its last outcome. GET / passes only on 200 with text/html referencing /assets/.
probe() {
    local path=$1
    while true; do
        http_get "$web_url$path"
        if [[ $REPLY == 200 ]]; then
            if [[ $path != / ]]; then
                RESULT="HTTP 200"
                log "verify: $path: $RESULT"
                return 0
            elif [[ $HTTP_TYPE != text/html* ]]; then
                RESULT="HTTP 200, ale nie text/html (${HTTP_TYPE:-brak Content-Type})"
            elif ! grep -qF '/assets/' "$HTTP_BODY"; then
                RESULT="HTTP 200, ale bez odwołania do /assets/"
            else
                RESULT="HTTP 200, text/html z /assets/"
                log "verify: $path: $RESULT"
                return 0
            fi
        else
            RESULT=$(http_outcome)
        fi
        if (( SECONDS >= probe_deadline )); then
            log "verify: $path: $RESULT"
            return 1
        fi
        log "verify: $path: $RESULT; retrying (the service may be waking up)"
        sleep "$WAKE_INTERVAL"
    done
}

probe_rows=()
probes_passed=1
if [[ $kind == readiness ]]; then
    if [[ $state != OK ]]; then
        probes_passed=""
        probe_rows+=("| — | pominięte: stan deployu nie jest OK |")
    elif [[ -z $web_url ]]; then
        probes_passed=""
        state=UNVERIFIABLE state_text="nieweryfikowalne: nieznany adres weba środowiska $environment"
        probe_rows+=("| — | pominięte: brak adresu weba (web-url.sh) |")
    else
        probe_deadline=$(( SECONDS + wake_timeout ))
        log "verify: probing $web_url (retried for up to $WAKE_TIMEOUT)"
        for path in /api/ready /healthz /; do
            probe "$path" || probes_passed=""
            probe_rows+=("| \`$path\` | $RESULT |")
        done
    fi
fi

if [[ $state == OK && -n $probes_passed ]]; then
    verdict=GREEN
else
    verdict=RED
fi
readonly verdict

# --- The report (step summary, issue body and comments) -------------------------------------------

{
    if [[ $verdict == GREEN ]]; then
        printf '### Zdrowe wdrożenie: `%s` / `%s`\n\n' "$environment" "$service"
    else
        printf '### Niezdrowe wdrożenie: `%s` / `%s`\n\n' "$environment" "$service"
    fi
    printf '| | |\n| --- | --- |\n'
    printf '| Środowisko | `%s` (`%s`) |\n' "$environment" "$ENVIRONMENT_ID"
    printf '| Usługa | `%s` (%s) |\n' "$service" "$([[ $kind == readiness ]] && echo 'gotowość środowiska' || echo 'tylko stan deployu, bez sond')"
    printf '| Zdarzenie | `%s`, deploy `%s` |\n' "$EVENT_TYPE" "$DEPLOYMENT_ID"
    printf '| Najnowszy deploy (Railway) | %s |\n' "$deployment_text"
    printf '| Stan deployu | **%s** |\n' "$state_text"
    [[ $kind != readiness ]] || printf '| Web | %s |\n' "${web_url:-—}"
    printf '| Run | %s |\n' "$run_link"
    if [[ $kind == readiness ]]; then
        printf '\n| Sonda | Wynik |\n| --- | --- |\n'
        printf '%s\n' "${probe_rows[@]}"
    fi
} >"$work/report.md"

# --- The issue of this environment and service ----------------------------------------------------

gh_failed() {
    log "::error::verify: $1 failed, the issue of $environment / $service is not up to date: $(head -n 3 "$work/gh-error" | tr '\n' ' ')"
    cat "$work/report.md"
    exit 1
}

# The number of the oldest open issue of this environment and service (empty: none). The REST list,
# not `gh issue list --label`, which goes through the search index and lags further behind; the list
# also returns pull requests.
open_issue() {
    local issues
    issues=$(gh api "repos/$GITHUB_REPOSITORY/issues?labels=$label&state=open&per_page=100" \
        2>"$work/gh-error") || gh_failed "gh api repos/$GITHUB_REPOSITORY/issues"
    # "<environment> / <service>" as whole words: szczur-radar-pr-8 must not match szczur-radar-pr-81
    # (both names are [a-z0-9-], so they need no regex escaping).
    ISSUE=$(jq -r --arg name "$environment / $service" '
            if type != "array" then error("not a list") else
                [.[] | select(type == "object" and (has("pull_request") | not))
                    | select((.title | type) == "string"
                    and (.title | test("(^|[^A-Za-z0-9-])" + $name + "($|[^A-Za-z0-9-])")))
                    | .number] | sort | (.[0] // "") | tostring
            end' <<<"$issues" 2>"$work/gh-error") || gh_failed "reading the list of open issues"
}

if [[ $verdict == GREEN ]]; then
    log "::notice::verify: $environment / $service is healthy ($state_text$([[ $kind == state ]] || echo ', every probe passed'))"
    open_issue
    if [[ -n $ISSUE ]]; then
        {
            printf 'Zielone po deployu `%s`: zamykam.\n\n' "$DEPLOYMENT_ID"
            cat "$work/report.md"
        } >"$work/comment.md"
        gh issue comment "$ISSUE" --repo "$GITHUB_REPOSITORY" --body-file "$work/comment.md" >/dev/null \
            2>"$work/gh-error" || gh_failed "gh issue comment $ISSUE"
        gh issue close "$ISSUE" --repo "$GITHUB_REPOSITORY" >/dev/null 2>"$work/gh-error" \
            || gh_failed "gh issue close $ISSUE"
        log "::notice::verify: closed the issue #$ISSUE of $environment / $service"
    fi
    cat "$work/report.md"
    exit 0
fi

log "::error::verify: $environment / $service is unhealthy after $EVENT_TYPE (deployment $DEPLOYMENT_ID): $state_text"
gh label create "$label" --repo "$GITHUB_REPOSITORY" --force --color B60205 \
    --description "Unhealthy deployment reported by szczur-radar-monitor" >/dev/null 2>"$work/gh-error" \
    || gh_failed "gh label create $label"
open_issue
if [[ -n $ISSUE ]]; then
    url=$(gh issue comment "$ISSUE" --repo "$GITHUB_REPOSITORY" --body-file "$work/report.md" 2>"$work/gh-error") \
        || gh_failed "gh issue comment $ISSUE"
    log "::notice::verify: commented on the open issue #$ISSUE: $url"
else
    url=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title_prefix$environment / $service" \
        --label "$label" --assignee "$MONITOR_ASSIGNEE" --body-file "$work/report.md" 2>"$work/gh-error") \
        || gh_failed "gh issue create"
    log "::notice::verify: opened $url"
fi
cat "$work/report.md"
exit 1
