#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in single quotes are Markdown code spans, not expansions
# Local test of the deploy verifier (see README.md), without Railway, GitHub, Docker or the network.
# verify.sh runs against a stub `railway` and a stub `gh` in PATH (both record their calls) and a stub
# web origin (a small Python HTTP server with answers scripted per case), as in szczur-radar's
# tools/deploy-gate/test.sh:
#   1. web-url.sh: production, szczur-radar-pr-<N>, an unknown name (exit 2);
#   2. the verdict: a readiness service SUCCESS / SLEEPING with every probe passing (GREEN); FAILED while
#      the old version still serves (RED); a web deploy while a cron is CRASHED (GREEN, the cron never
#      read); a cron CRASHED or SUCCESS (no probe); DEPLOYING → SUCCESS or → FAILED; a transient state
#      until SETTLE_TIMEOUT (RED, unverifiable); a newer deploy WAITING / QUEUED / NEEDS_APPROVAL that
#      is not the webhook's skipped (the serving one judged); SKIPPED and REMOVED rows with a newer createdAt
#      ignored, the list sorted by createdAt; no deployment; an unknown state; /api/ready 503 for the
#      whole window (RED) or until it wakes (GREEN); GET / without text/html or without /assets/ (RED);
#      an environment without a known web address (RED);
#   3. the issue of the environment and service: RED opens one (title, label, assignee) or comments
#      on the open one; szczur-radar-pr-8 / szczur-radar-api never matches szczur-radar-pr-81 /
#      szczur-radar-api (nor a pull request); GREEN comments on and closes that service's issue, leaves
#      another service's open, and without one only reads the list;
#   4. the operator's alert: a red run of production checks in /fail with its summary, then a success, to
#      HEALTHCHECK_PING_URL; a PR env or a green run does not; healthchecks.io failing changes nothing;
#   5. errors: railway failing (RED, exit 1), Railway refusing the token (RED at once, no retry), gh
#      failing (exit 1), a hung railway or gh call stopped after CLI_TIMEOUT, a missing or bad variable
#      (exit 2).
# Needs bash, jq, curl and python3. Short limits (1–3 s) keep it under a minute or so.
# Run from anywhere: verifier/test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
readonly verify=$here/verify.sh
tmp=$(mktemp -d)

step() { printf '\n== %s\n' "$*"; }
pass() { printf 'PASS %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

for tool in jq curl python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done

step "1. web-url.sh: the web address of an environment"
[[ $("$here/web-url.sh" production) == https://szczur-radar-web-production.up.railway.app ]] \
    || die "web-url.sh production: wrong address"
[[ $("$here/web-url.sh" szczur-radar-pr-81) == https://szczur-radar-web-szczur-radar-pr-81.up.railway.app ]] \
    || die "web-url.sh szczur-radar-pr-81: wrong address"
pass "production and szczur-radar-pr-<N>"
for name in staging szczur-radar-pr-0 szczur-radar-pr-7x ""; do
    status=0
    "$here/web-url.sh" "$name" >"$tmp/web-url.out" 2>"$tmp/web-url.log" || status=$?
    [[ $status == 2 && ! -s $tmp/web-url.out ]] || die "web-url.sh '$name': exit $status, expected 2 and no output"
done
status=0
"$here/web-url.sh" >/dev/null 2>&1 || status=$?
[[ $status == 2 ]] || die "web-url.sh without an argument: exit $status, expected 2"
pass "an unknown name (staging, pr-0, pr-7x, empty) or no argument: exit 2, nothing printed"

# The stub web origin. STUB_CASE (JSON) scripts it: {"paths": {"<path>": [answer, …]}}: GET <path> gives
# the answers in turn, the last one repeating; an answer is {"status": <code>, "body": <JSON, or a
# string sent as text>, "type": <Content-Type, optional>}; any other path: 404. POST answers the same way
# (a healthchecks.io check-in). One line per request on stdout: "GET <path> <status>", or "POST <path>
# <status> <body with | for each newline>".
read -r -d '' stub_code <<'PY' || true
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

case = json.loads(os.environ["STUB_CASE"])
paths = {path: list(answers) for path, answers in case.get("paths", {}).items()}


class Web(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.answer("POST", self.rfile.read(length).decode().replace("\n", "|"))

    def do_GET(self):
        self.answer("GET", None)

    def answer(self, method, posted):
        answers = paths.get(self.path)
        if answers is None:
            entry = {"status": 404, "body": {"detail": "not_found"}}
        else:
            entry = answers.pop(0) if len(answers) > 1 else answers[0]
        body = entry.get("body")
        text = isinstance(body, str)
        data = b"" if body is None else (body if text else json.dumps(body)).encode()
        self.send_response(entry["status"])
        content_type = entry.get("type", "text/plain" if text else "application/json")
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        line = f"{method} {self.path} {entry['status']}"
        print(line if posted is None else f"{line} {posted}", flush=True)


server = ThreadingHTTPServer(("127.0.0.1", int(os.environ["STUB_PORT"])), Web)
print("listening", flush=True)
server.serve_forever()
PY

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Starts the stub web of case $1 answering $2 (STUB_CASE) and sets STUB_URL. Its requests go to
# $tmp/$1.requests.
stub_pid=""
start_stub() {
    local name=$1 case=$2 port
    port=$(free_port)
    STUB_URL=http://127.0.0.1:$port
    STUB_CASE=$case STUB_PORT=$port python3 -u -c "$stub_code" >"$tmp/$name.requests" 2>"$tmp/$name.stub-errors" &
    stub_pid=$!
    for _ in $(seq 1 50); do
        grep -qx listening "$tmp/$name.requests" && return 0
        sleep 0.1
    done
    cat "$tmp/$name.stub-errors" >&2
    die "$name: the stub web did not start"
}

stop_stub() {
    if [[ -n $stub_pid ]]; then
        kill "$stub_pid" 2>/dev/null || true
        wait "$stub_pid" 2>/dev/null || true
    fi
    stub_pid=""
}
trap 'stop_stub; rm -rf "$tmp"' EXIT

readonly project_id=decf00e4-f5a4-43df-b338-6698be87c5a1
readonly environment_id=00000000-0000-4000-8000-000000000001
readonly deployment_id=00000000-0000-4000-8000-0000000000d1
mkdir -p "$tmp/bin"

# The stub `railway`: answers `railway deployment list --json --limit <n> -s <service> -p <project> -e
# <environment>` of the project and environment above, with RAILWAY_API_TOKEN set, from
# $RAILWAY_STUB/<service>, one line per call, the last one repeating: a JSON list of deployments, or
# "fail" (the CLI fails), "unauthorized" / "invalid-token" (Railway refuses the token, two wordings) or "hang" (no
# answer within the test's CLI_TIMEOUT). A service
# without a file is unknown (the CLI's error). Every call goes to
# $RAILWAY_STUB/calls; any other command or option fails with exit 3.
cat >"$tmp/bin/railway" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RAILWAY_STUB/calls"
[[ ${1:-} == deployment && ${2:-} == list ]] || { echo "stub railway: unexpected command: $*" >&2; exit 3; }
shift 2
json="" limit="" service="" project="" environment=""
while (( $# > 0 )); do
    case $1 in
        --json) json=1; shift ;;
        --limit) limit=$2; shift 2 ;;
        -s) service=$2; shift 2 ;;
        -p) project=$2; shift 2 ;;
        -e) environment=$2; shift 2 ;;
        *) echo "stub railway: unexpected option $1" >&2; exit 3 ;;
    esac
done
[[ $json == 1 && $limit =~ ^[0-9]+$ && $project == "$STUB_PROJECT_ID" && $environment == "$STUB_ENVIRONMENT_ID" ]] \
    || { echo "stub railway: unexpected arguments" >&2; exit 3; }
[[ -n ${RAILWAY_API_TOKEN:-} ]] || { echo "Unauthorized. Please login with \`railway login\`" >&2; exit 1; }
answers=$RAILWAY_STUB/$service
[[ -f $answers ]] || { echo "Service '$service' not found" >&2; exit 1; }
answer=$(head -n 1 "$answers")
if (( $(wc -l <"$answers") > 1 )); then
    tail -n +2 "$answers" >"$answers.next"
    mv "$answers.next" "$answers"
fi
case $answer in
    fail) echo "Failed to fetch: error sending request" >&2; exit 1 ;;
    hang) sleep 30 ;;
    invalid-token) echo "Error: Invalid project token" >&2; exit 1 ;;
    unauthorized) echo "Unauthorized. Please check that your RAILWAY_API_TOKEN is valid and has access to the resource you're trying to use." >&2; exit 1 ;;
    *) printf '%s\n' "$answer" ;;
esac
SH
chmod +x "$tmp/bin/railway"

# The stub `gh`: every call goes to $GH_STUB/calls (one line of arguments) and the file of --body-file
# to $GH_STUB/body; $GH_STUB/fail makes every call fail (as gh does without a valid token), $GH_STUB/hang
# makes every call hang.
# `api repos/<repo>/issues?…` prints $GH_STUB/issues ([] without it); `issue create` and `issue
# comment` print a URL, as gh does. Any other command, or a call without GH_TOKEN, fails with exit 3.
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_STUB/calls"
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ ${args[i]} != --body-file ]] || cp "${args[i + 1]}" "$GH_STUB/body"
done
[[ -n ${GH_TOKEN:-} ]] || { echo "stub gh: no GH_TOKEN" >&2; exit 3; }
[[ ! -f $GH_STUB/hang ]] || sleep 30
[[ ! -f $GH_STUB/fail ]] || { echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1; }
case "${1:-} ${2:-}" in
    "label create" | "issue close") ;;
    "api repos/"*"/issues?"*) cat "$GH_STUB/issues" 2>/dev/null || echo "[]" ;;
    "issue create") echo "https://github.com/example/szczur-radar-monitor/issues/101" ;;
    "issue comment") echo "https://github.com/example/szczur-radar-monitor/issues/$3#issuecomment-1" ;;
    *) echo "stub gh: unexpected command: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$tmp/bin/gh"

# A JSON list of deployments, newest first as the CLI prints it, from "<id> <STATUS> <createdAt>"
# arguments (createdAt in the CLI's format, with fractions of a second).
deployments() {
    local row id status created
    for row in "$@"; do
        read -r id status created <<<"$row"
        jq -cn --arg id "$id" --arg status "$status" --arg created "$created" \
            '{id: $id, status: $status, createdAt: $created, meta: {commitHash: "0123456789abcdef0123456789abcdef01234567"}}'
    done | jq -cs .
}

# The stub railway of case $1 answers `deployment list -s $2` with the answers after it, in turn.
railway_answers() {
    mkdir -p "$tmp/$1.railway"
    printf '%s\n' "${@:3}" >"$tmp/$1.railway/$2"
}

# A list with one deployment: ID $1, state $2.
only() {
    deployments "$1 $2 2026-10-20T10:00:00.000Z"
}

# The stub gh of case $1 lists the open issues $2 (JSON).
open_issues() {
    mkdir -p "$tmp/$1.gh"
    printf '%s\n' "$2" >"$tmp/$1.gh/issues"
}

show_run() {
    printf -- '--- log (%s)\n' "$1"
    cat "$tmp/$1.log"
    if [[ -s $tmp/$1.out ]]; then
        printf -- '--- stdout\n'
        cat "$tmp/$1.out"
    fi
    if [[ -f $tmp/$1.requests ]]; then
        printf -- '--- requests to the stub web\n'
        grep -vx listening "$tmp/$1.requests" || true
    fi
    if [[ -f $tmp/$1.railway/calls ]]; then
        printf -- '--- railway calls\n'
        cat "$tmp/$1.railway/calls"
    fi
    if [[ -f $tmp/$1.gh/calls ]]; then
        printf -- '--- gh calls\n'
        cat "$tmp/$1.gh/calls"
    fi
}

run_says() {
    grep -qF -- "$2" "$tmp/$1.log" || { show_run "$1"; die "$1: the log does not say '$2'"; }
}

out_says() {
    grep -qF -- "$2" "$tmp/$1.out" || { show_run "$1"; die "$1: stdout does not say '$2'"; }
}

# Case $1's stub web got $2 requests.
web_requests_were() {
    local count
    count=$(grep -c '^GET ' "$tmp/$1.requests" || true)
    [[ $count == "$2" ]] || { show_run "$1"; die "$1: $count requests to the stub web, expected $2"; }
}

# Case $1's stub railway was asked only about the service $2.
railway_asked_only() {
    local calls
    calls=$(grep -c . "$tmp/$1.railway/calls" || true)
    (( calls > 0 )) || { show_run "$1"; die "$1: railway was not called"; }
    [[ $(grep -c -- "-s $2 -p $project_id -e $environment_id\$" "$tmp/$1.railway/calls" || true) == "$calls" ]] \
        || { show_run "$1"; die "$1: railway was asked about another service than $2"; }
}

# Case $1's stub gh got exactly the calls after it (each a prefix of its line, in order).
gh_calls_are() {
    local name=$1 calls=() i line
    shift
    if [[ -f $tmp/$name.gh/calls ]]; then
        while IFS= read -r line; do calls+=("$line"); done <"$tmp/$name.gh/calls"
    fi
    (( ${#calls[@]} == $# )) || { show_run "$name"; die "$name: ${#calls[@]} gh calls, expected $#"; }
    for (( i = 1; i <= $#; i++ )); do
        [[ ${calls[i - 1]} == "${!i}"* ]] || { show_run "$name"; die "$name: gh call $i is not '${!i}…'"; }
    done
}

body_says() {
    grep -qF -- "$2" "$tmp/$1.gh/body" || { show_run "$1"; cat "$tmp/$1.gh/body" 2>/dev/null; die "$1: the issue body does not say '$2'"; }
}

readonly repo=example/szczur-radar-monitor
readonly list_call="api repos/$repo/issues?labels=deploy-health&state=open&per_page=100"

# Case $1: verify.sh with the variables after it (NAME=value; by default Deployment.deployed of
# szczur-radar-api in szczur-radar-pr-8, run 4242, short limits) must exit with $2. Every input of the
# caller is dropped first. Its stdout goes to $tmp/$1.out, its log to $tmp/$1.log, the stubs' calls
# to $tmp/$1.railway/ and $tmp/$1.gh/.
run_verify() {
    local name=$1 expected=$2 status=0
    shift 2
    mkdir -p "$tmp/$name.railway" "$tmp/$name.gh"
    env -u EVENT_TYPE -u ENVIRONMENT_ID -u ENVIRONMENT_NAME -u SERVICE_NAME -u DEPLOYMENT_ID \
        -u RAILWAY_API_TOKEN -u RAILWAY_PROJECT_ID -u READINESS_SERVICES -u MONITOR_ASSIGNEE -u GH_TOKEN \
        -u GITHUB_REPOSITORY -u GITHUB_RUN_ID -u WAKE_TIMEOUT -u SETTLE_TIMEOUT -u SETTLE_INTERVAL -u WEB_URL \
        -u CLI_TIMEOUT -u HEALTHCHECK_PING_URL \
        PATH="$tmp/bin:$PATH" RAILWAY_STUB="$tmp/$name.railway" GH_STUB="$tmp/$name.gh" \
        STUB_PROJECT_ID=$project_id STUB_ENVIRONMENT_ID=$environment_id \
        EVENT_TYPE=Deployment.deployed ENVIRONMENT_ID=$environment_id ENVIRONMENT_NAME=szczur-radar-pr-8 \
        SERVICE_NAME=szczur-radar-api DEPLOYMENT_ID=$deployment_id RAILWAY_API_TOKEN=stub-railway-token \
        RAILWAY_PROJECT_ID=$project_id MONITOR_ASSIGNEE=operator GH_TOKEN=stub-gh-token \
        GITHUB_REPOSITORY=$repo GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242 \
        SETTLE_INTERVAL=1s SETTLE_TIMEOUT=3s WAKE_TIMEOUT=3s \
        "$@" "$verify" >"$tmp/$name.out" 2>"$tmp/$name.log" || status=$?
    [[ $status == "$expected" ]] || { show_run "$name"; die "$name: exit code $status, expected $expected"; }
    # No secret in the log, the report or an issue.
    ! grep -qF -e stub-railway-token -e stub-gh-token -e ping-secret "$tmp/$name.out" "$tmp/$name.log" \
        || { show_run "$name"; die "$name: a token was printed"; }
    [[ ! -f $tmp/$name.gh/body ]] || ! grep -qF -e stub-railway-token -e stub-gh-token -e ping-secret "$tmp/$name.gh/body" \
        || die "$name: a token went into an issue"
}

readonly ready='{"status": 200, "body": {"status": "ok"}}'
readonly unavailable='{"status": 503, "body": {"status": "unavailable"}}'
readonly healthz='{"status": 200, "body": "ok"}'
readonly spa='{"status": 200, "type": "text/html; charset=utf-8", "body": "<!doctype html><script type=\"module\" src=\"/assets/index-B1x2.js\"></script>"}'
readonly healthy_web="{\"paths\": {\"/api/ready\": [$ready], \"/healthz\": [$healthz], \"/\": [$spa]}}"

# Case $1: verify.sh against the stub web answering $3 (STUB_CASE; "" for a healthy web) with the
# variables after it must exit with $2. The stub railway's answers are set before (railway_answers).
verify_case() {
    local name=$1 expected=$2 web=${3:-$healthy_web}
    shift 3
    start_stub "$name" "$web"
    # @STUB@ in a variable stands for the stub's origin (known only once it runs).
    run_verify "$name" "$expected" WEB_URL="$STUB_URL" "${@//@STUB@/$STUB_URL}"
    stop_stub
}

step "2. the verdict: the state of the service that deployed, and the probes of a readiness service"
for status in SUCCESS SLEEPING; do
    railway_answers "api-$status" szczur-radar-api "$(only a1 "$status")"
    verify_case "api-$status" 0 ""
    out_says "api-$status" '### Zdrowe wdrożenie: `szczur-radar-pr-8` / `szczur-radar-api`'
    out_says "api-$status" "| Stan deployu | **$status** |"
    out_says "api-$status" '| `/api/ready` | HTTP 200 |'
    out_says "api-$status" '| `/healthz` | HTTP 200 |'
    out_says "api-$status" '| `/` | HTTP 200, text/html z /assets/ |'
    out_says "api-$status" '| Run | https://github.com/example/szczur-radar-monitor/actions/runs/4242 |'
    run_says "api-$status" '::notice::verify: szczur-radar-pr-8 / szczur-radar-api is healthy'
    web_requests_were "api-$status" 3
    railway_asked_only "api-$status" szczur-radar-api
    grep -qF -- "deployment list --json --limit 50 -s szczur-radar-api -p $project_id -e $environment_id" \
        "$tmp/api-$status.railway/calls" || { show_run "api-$status"; die "api-$status: railway not asked by project and environment ID"; }
done
pass "api SUCCESS or SLEEPING, /api/ready, /healthz and / pass: GREEN, exit 0 (railway asked by project and environment ID)"

railway_answers api-failed szczur-radar-api "$(deployments "a2 FAILED 2026-10-20T10:05:00.000Z" "a1 SUCCESS 2026-10-20T10:00:00.000Z")"
verify_case api-failed 1 ""
out_says api-failed '### Niezdrowe wdrożenie: `szczur-radar-pr-8` / `szczur-radar-api`'
out_says api-failed '| Stan deployu | **FAILED** |'
out_says api-failed '| Najnowszy deploy (Railway) | `a2` |'
run_says api-failed '::error::verify: szczur-radar-pr-8 / szczur-radar-api is unhealthy after Deployment.deployed'
web_requests_were api-failed 0
pass "api FAILED while the old deployment still serves (probes would answer 200): RED, exit 1, no probe"

railway_answers web-cron-crashed szczur-radar-web "$(only w1 SUCCESS)"
railway_answers web-cron-crashed pipeline-trigger "$(only t1 CRASHED)"
railway_answers web-cron-crashed db-backup "$(only b1 CRASHED)"
verify_case web-cron-crashed 0 "" SERVICE_NAME=szczur-radar-web
railway_asked_only web-cron-crashed szczur-radar-web
out_says web-cron-crashed '### Zdrowe wdrożenie: `szczur-radar-pr-8` / `szczur-radar-web`'
pass "a web deploy while the crons are CRASHED: GREEN, the crons' state never read"

railway_answers cron-crashed pipeline-trigger "$(only t1 CRASHED)"
railway_answers cron-crashed szczur-radar-api "$(only a1 FAILED)"
verify_case cron-crashed 1 "" SERVICE_NAME=pipeline-trigger EVENT_TYPE=Deployment.crashed
web_requests_were cron-crashed 0
railway_asked_only cron-crashed pipeline-trigger
out_says cron-crashed '| Usługa | `pipeline-trigger` (tylko stan deployu, bez sond) |'
out_says cron-crashed '| Stan deployu | **CRASHED** |'
! grep -qF '| Sonda |' "$tmp/cron-crashed.out" || { show_run cron-crashed; die "cron-crashed: the report has probes"; }
railway_answers cron-success db-backup "$(only b1 SUCCESS)"
verify_case cron-success 0 "" SERVICE_NAME=db-backup
web_requests_were cron-success 0
railway_asked_only cron-success db-backup
pass "a cron CRASHED: RED; a cron SUCCESS: GREEN; neither probed, no other service read"

railway_answers settles-green szczur-radar-api "$(only a2 DEPLOYING)" "$(only a2 DEPLOYING)" "$(only a2 SUCCESS)"
verify_case settles-green 0 ""
run_says settles-green 'verify: szczur-radar-api deployment a2: DEPLOYING; asking again every 1s'
railway_answers settles-red szczur-radar-api "$(only a2 BUILDING)" "$(only a2 DEPLOYING)" "$(only a2 FAILED)"
verify_case settles-red 1 ""
out_says settles-red '| Stan deployu | **FAILED** |'
pass "DEPLOYING, then SUCCESS: GREEN; BUILDING, DEPLOYING, then FAILED: RED"

# The webhook's own deployment (a redeploy may still be queued); INITIALIZING counts whoever's it is.
for status in QUEUED WAITING NEEDS_APPROVAL INITIALIZING; do
    railway_answers "transient-$status" szczur-radar-api "$(only "$deployment_id" "$status")"
    verify_case "transient-$status" 1 "" SETTLE_TIMEOUT=2s
    out_says "transient-$status" "| Stan deployu | **nieweryfikowalne: $status** |"
    web_requests_were "transient-$status" 0
done
pass "a transient state (QUEUED, WAITING, NEEDS_APPROVAL, INITIALIZING) until SETTLE_TIMEOUT: RED, unverifiable"

# A later push's deploy waiting for CI (or queued) is not the webhook's: the one serving is judged.
for status in WAITING QUEUED NEEDS_APPROVAL; do
    railway_answers "newer-$status" szczur-radar-api "$(deployments \
        "a9 $status 2026-10-20T11:00:00.000Z" "$deployment_id SUCCESS 2026-10-20T10:00:00.000Z")"
    verify_case "newer-$status" 0 ""
    out_says "newer-$status" '| Stan deployu | **SUCCESS** |'
done
railway_answers newer-waiting-failed szczur-radar-api "$(deployments \
    "a9 WAITING 2026-10-20T11:00:00.000Z" "$deployment_id FAILED 2026-10-20T10:00:00.000Z")"
verify_case newer-waiting-failed 1 ""
out_says newer-waiting-failed '| Stan deployu | **FAILED** |'
pass "a newer deploy WAITING / QUEUED / NEEDS_APPROVAL (not the webhook's) skipped: the serving one judged"

# Not sorted on purpose: the newest by createdAt, whatever the order, and SKIPPED / REMOVED / REMOVING
# rows (which carry a newer commit) do not count.
railway_answers skipped szczur-radar-api "$(deployments \
    "a1 FAILED 2026-10-20T09:00:00.000Z" "a4 SKIPPED 2026-10-20T11:00:00.000Z" \
    "a3 REMOVING 2026-10-20T10:30:00.000Z" "a2 SUCCESS 2026-10-20T10:00:00.500Z" \
    "a0 REMOVED 2026-10-20T10:20:00Z")"
verify_case skipped 0 ""
out_says skipped '| Najnowszy deploy (Railway) | `a2` |'
railway_answers skipped-red szczur-radar-api "$(deployments \
    "a4 SKIPPED 2026-10-20T11:00:00.000Z" "a2 CRASHED 2026-10-20T10:00:00.000Z" "a1 SUCCESS 2026-10-20T09:00:00.000Z")"
verify_case skipped-red 1 ""
out_says skipped-red '| Stan deployu | **CRASHED** |'
pass "SKIPPED, REMOVED and REMOVING rows ignored, the newest by createdAt counts (SUCCESS: GREEN, CRASHED: RED)"

railway_answers none szczur-radar-api "[]"
verify_case none 1 ""
out_says none '| Stan deployu | **brak deployu** |'
railway_answers only-skipped szczur-radar-api "$(only a1 SKIPPED)"
verify_case only-skipped 1 ""
out_says only-skipped '| Stan deployu | **brak deployu** |'
railway_answers unknown-state szczur-radar-api "$(only a1 HIBERNATING)"
verify_case unknown-state 1 ""
out_says unknown-state '| Stan deployu | **nieznany stan: HIBERNATING** |'
pass "no deployment (or only SKIPPED): RED; an unknown state: RED"

railway_answers ready-down szczur-radar-api "$(only a1 SUCCESS)"
verify_case ready-down 1 "{\"paths\": {\"/api/ready\": [$unavailable], \"/healthz\": [$healthz], \"/\": [$spa]}}" WAKE_TIMEOUT=2s
out_says ready-down '| `/api/ready` | HTTP 503 |'
out_says ready-down '| Stan deployu | **SUCCESS** |'
railway_answers ready-wakes szczur-radar-api "$(only a1 SLEEPING)"
verify_case ready-wakes 0 "{\"paths\": {\"/api/ready\": [$unavailable, $ready], \"/healthz\": [$healthz], \"/\": [$spa]}}"
run_says ready-wakes 'verify: /api/ready: HTTP 503; retrying (the service may be waking up)'
pass "/api/ready 503 for the whole WAKE_TIMEOUT: RED; 503, then 200: GREEN"

railway_answers root-not-html szczur-radar-web "$(only w1 SUCCESS)"
verify_case root-not-html 1 "{\"paths\": {\"/api/ready\": [$ready], \"/healthz\": [$healthz], \"/\": [{\"status\": 200, \"body\": \"<script src=/assets/x.js>\"}]}}" \
    SERVICE_NAME=szczur-radar-web WAKE_TIMEOUT=1s
out_says root-not-html '| `/` | HTTP 200, ale nie text/html (text/plain) |'
railway_answers root-no-assets szczur-radar-web "$(only w1 SUCCESS)"
verify_case root-no-assets 1 "{\"paths\": {\"/api/ready\": [$ready], \"/healthz\": [$healthz], \"/\": [{\"status\": 200, \"type\": \"text/html\", \"body\": \"<p>Caddy</p>\"}]}}" \
    SERVICE_NAME=szczur-radar-web WAKE_TIMEOUT=1s
out_says root-no-assets '| `/` | HTTP 200, ale bez odwołania do /assets/ |'
pass "GET / 200 without text/html or without /assets/: RED"

railway_answers no-address szczur-radar-api "$(only a1 SUCCESS)"
run_verify no-address 1 ENVIRONMENT_NAME=staging
out_says no-address '| Stan deployu | **nieweryfikowalne: nieznany adres weba środowiska staging** |'
railway_answers custom-readiness worker "$(only k1 SUCCESS)"
verify_case custom-readiness 0 "" SERVICE_NAME=worker READINESS_SERVICES="szczur-radar-web, worker"
web_requests_were custom-readiness 3
pass "a readiness service in an environment without a web address: RED; READINESS_SERVICES chooses the probed services"

step "3. the issue of the environment and service"
railway_answers red-new szczur-radar-api "$(only a2 FAILED)"
open_issues red-new '[{"number": 7, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-web"}]'
verify_case red-new 1 ""
gh_calls_are red-new "label create deploy-health --repo $repo --force" "$list_call" \
    "issue create --repo $repo --title Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api --label deploy-health --assignee operator --body-file "
body_says red-new '| Stan deployu | **FAILED** |'
body_says red-new '| Zdarzenie | `Deployment.deployed`, deploy `00000000-0000-4000-8000-0000000000d1` |'
run_says red-new '::notice::verify: opened https://github.com/example/szczur-radar-monitor/issues/101'
pass "RED without an issue of the service (another service's open): a new one, labelled and assigned"

railway_answers red-comment szczur-radar-api "$(only a2 CRASHED)"
open_issues red-comment '[
    {"number": 12, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api"},
    {"number": 9, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api"},
    {"number": 5, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api", "pull_request": {}}]'
verify_case red-comment 1 ""
gh_calls_are red-comment "label create deploy-health" "$list_call" "issue comment 9 --repo $repo --body-file "
body_says red-comment '| Stan deployu | **CRASHED** |'
pass "RED with open issues of the service: a comment on the oldest (a pull request ignored), no new one"

railway_answers whole-word szczur-radar-api "$(only a2 FAILED)"
open_issues whole-word '[
    {"number": 3, "title": "Niezdrowe wdrożenie: szczur-radar-pr-81 / szczur-radar-api"},
    {"number": 4, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api-x"}]'
verify_case whole-word 1 ""
gh_calls_are whole-word "label create deploy-health" "$list_call" "issue create --repo $repo --title Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api "
pass "szczur-radar-pr-8 / szczur-radar-api matches neither szczur-radar-pr-81 / szczur-radar-api nor … / szczur-radar-api-x"

railway_answers green-close szczur-radar-api "$(only a3 SUCCESS)"
open_issues green-close '[{"number": 3, "title": "Niezdrowe wdrożenie: szczur-radar-pr-81 / szczur-radar-api"},
    {"number": 11, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api"}]'
verify_case green-close 0 ""
gh_calls_are green-close "$list_call" "issue comment 11 --repo $repo --body-file " "issue close 11 --repo $repo"
body_says green-close 'Zielone po deployu `00000000-0000-4000-8000-0000000000d1`'
run_says green-close '::notice::verify: closed the issue #11 of szczur-radar-pr-8 / szczur-radar-api'
pass "GREEN with an open issue of the service: a comment and closing it"

railway_answers green-web szczur-radar-web "$(only w2 SUCCESS)"
open_issues green-web '[{"number": 11, "title": "Niezdrowe wdrożenie: szczur-radar-pr-8 / szczur-radar-api"}]'
verify_case green-web 0 "" SERVICE_NAME=szczur-radar-web
gh_calls_are green-web "$list_call"
pass "GREEN of the web with an open issue of the API: the API's issue stays open, no comment"

railway_answers green-none szczur-radar-api "$(only a1 SUCCESS)"
verify_case green-none 0 ""
gh_calls_are green-none "$list_call"
pass "GREEN without an issue: only the list of open issues read, nothing written"

step "4. the operator's alert (healthchecks.io, production only)"
readonly ping=/ping/ping-secret-0000
readonly pinged="{\"paths\": {\"$ping/fail\": [{\"status\": 200, \"body\": \"OK\"}], \"$ping\": [{\"status\": 200, \"body\": \"OK\"}]}}"
# Case $1's stub web got exactly the check-ins (POST lines) after it, in order, each a prefix of its line.
posts_are() {
    local name=$1 i=0 line
    shift
    local expected=("$@")
    while IFS= read -r line; do
        (( i < ${#expected[@]} )) || { show_run "$name"; die "$name: an unexpected check-in: $line"; }
        [[ $line == "${expected[i]}"* ]] || { show_run "$name"; die "$name: check-in $(( i + 1 )) is not '${expected[i]}'"; }
        i=$(( i + 1 ))
    done < <(grep '^POST ' "$tmp/$name.requests" || true)
    (( i == ${#expected[@]} )) || { show_run "$name"; die "$name: $i check-ins, expected ${#expected[@]}"; }
}
railway_answers alert-red db-backup "$(only b1 CRASHED)"
verify_case alert-red 1 "$pinged" SERVICE_NAME=db-backup ENVIRONMENT_NAME=production HEALTHCHECK_PING_URL=@STUB@$ping
posts_are alert-red "POST $ping/fail 200 DEPLOY_UNHEALTHY (production / db-backup): CRASHED; run https://github.com/$repo/actions/runs/4242" \
    "POST $ping 200 ok"
run_says alert-red '::notice::verify: alerted the operator through healthchecks.io'
gh_calls_are alert-red "label create deploy-health" "$list_call" "issue create "
railway_answers alert-pr-env db-backup "$(only b1 CRASHED)"
verify_case alert-pr-env 1 "$pinged" SERVICE_NAME=db-backup HEALTHCHECK_PING_URL=@STUB@$ping
posts_are alert-pr-env
railway_answers alert-green db-backup "$(only b1 SUCCESS)"
verify_case alert-green 0 "$pinged" SERVICE_NAME=db-backup ENVIRONMENT_NAME=production HEALTHCHECK_PING_URL=@STUB@$ping
posts_are alert-green
pass "a red run of production: /fail with the summary, then a success; a PR env or a green run: no check-in"
railway_answers alert-down db-backup "$(only b1 CRASHED)"
verify_case alert-down 1 "{\"paths\": {\"$ping/fail\": [{\"status\": 500, \"body\": \"no\"}]}}" \
    SERVICE_NAME=db-backup ENVIRONMENT_NAME=production HEALTHCHECK_PING_URL=@STUB@$ping
run_says alert-down '::warning::verify: the healthchecks.io alert was not delivered (HTTP 500 to the failure ping'
posts_are alert-down "POST $ping/fail 500"
railway_answers alert-stuck db-backup "$(only b1 CRASHED)"
verify_case alert-stuck 1 "{\"paths\": {\"$ping/fail\": [{\"status\": 200, \"body\": \"OK\"}], \"$ping\": [{\"status\": 500, \"body\": \"no\"}]}}" \
    SERVICE_NAME=db-backup ENVIRONMENT_NAME=production HEALTHCHECK_PING_URL=@STUB@$ping
run_says alert-stuck 'the healthchecks.io alert went out, but HTTP 500 to the success ping'

gh_calls_are alert-down "label create deploy-health" "$list_call" "issue create "
railway_answers alert-unset db-backup "$(only b1 CRASHED)"
verify_case alert-unset 1 "" SERVICE_NAME=db-backup ENVIRONMENT_NAME=production
run_says alert-unset '::notice::verify: no HEALTHCHECK_PING_URL, no healthchecks.io alert'
posts_are alert-unset
pass "healthchecks.io failing: a warning, the verdict and the issue stand; no HEALTHCHECK_PING_URL: no alert"

step "5. errors"
railway_answers railway-fails szczur-radar-api fail
verify_case railway-fails 1 "" SETTLE_TIMEOUT=2s
run_says railway-fails 'verify: railway deployment list -s szczur-radar-api failed: Failed to fetch'
out_says railway-fails '| Stan deployu | **nieweryfikowalne: Railway nie odpowiada** |'
gh_calls_are railway-fails "label create deploy-health" "$list_call" "issue create "
web_requests_were railway-fails 0
railway_answers railway-garbage szczur-radar-api 'Not JSON at all'
verify_case railway-garbage 1 "" SETTLE_TIMEOUT=1s
run_says railway-garbage 'printed no list of deployments'
railway_answers railway-recovers szczur-radar-api fail "$(only a1 SUCCESS)"
verify_case railway-recovers 0 ""
pass "railway failing or printing no list until SETTLE_TIMEOUT: RED, unverifiable, exit 1; failing once: retried"

# A refused token never heals within the window: one question, RED at once, no "Railway nie odpowiada".
railway_answers railway-unauthorized szczur-radar-api unauthorized "$(only a1 SUCCESS)"
verify_case railway-unauthorized 1 "" SETTLE_TIMEOUT=30s
(( $(wc -l <"$tmp/railway-unauthorized.railway/calls") == 1 )) \
    || { show_run railway-unauthorized; die "railway-unauthorized: railway asked more than once"; }
out_says railway-unauthorized '| Stan deployu | **nieweryfikowalne: token Railway odrzucony** |'
gh_calls_are railway-unauthorized "label create deploy-health" "$list_call" "issue create "
web_requests_were railway-unauthorized 0
railway_answers railway-invalid-token szczur-radar-api invalid-token "$(only a1 SUCCESS)"
verify_case railway-invalid-token 1 "" SETTLE_TIMEOUT=30s
out_says railway-invalid-token '| Stan deployu | **nieweryfikowalne: token Railway odrzucony** |'
pass "Railway refusing the token (either wording): RED at once (one question, no retry), the issue says so"

railway_answers gh-fails-red szczur-radar-api "$(only a2 FAILED)"
mkdir -p "$tmp/gh-fails-red.gh"
touch "$tmp/gh-fails-red.gh/fail"
verify_case gh-fails-red 1 ""
run_says gh-fails-red '::error::verify: gh label create deploy-health failed, the issue of szczur-radar-pr-8 / szczur-radar-api is not up to date: HTTP 401'
out_says gh-fails-red '### Niezdrowe wdrożenie'
railway_answers gh-fails-green szczur-radar-api "$(only a1 SUCCESS)"
mkdir -p "$tmp/gh-fails-green.gh"
touch "$tmp/gh-fails-green.gh/fail"
verify_case gh-fails-green 1 ""
run_says gh-fails-green "::error::verify: gh api repos/$repo/issues failed"
pass "gh failing (RED, or GREEN reading the issues): exit 1"

# A hung CLI call is stopped after CLI_TIMEOUT: railway as "Railway nie odpowiada", gh as a failed call.
railway_answers railway-hangs szczur-radar-api hang
verify_case railway-hangs 1 "" CLI_TIMEOUT=1s SETTLE_TIMEOUT=2s
out_says railway-hangs '| Stan deployu | **nieweryfikowalne: Railway nie odpowiada** |'
railway_answers gh-hangs szczur-radar-api "$(only a2 FAILED)"
mkdir -p "$tmp/gh-hangs.gh"
touch "$tmp/gh-hangs.gh/hang"
verify_case gh-hangs 1 "" CLI_TIMEOUT=1s
run_says gh-hangs '::error::verify: gh label create deploy-health failed'
pass "a hung railway or gh call stopped after CLI_TIMEOUT: RED (Railway nie odpowiada) or exit 1"

for case in \
    "no-event EVENT_TYPE=" \
    "bad-event EVENT_TYPE=Deployment.building" \
    "bad-environment-id ENVIRONMENT_ID=production" \
    "upper-deployment-id DEPLOYMENT_ID=00000000-0000-4000-8000-0000000000D1" \
    "no-project RAILWAY_PROJECT_ID=" \
    "bad-environment-name ENVIRONMENT_NAME=Production" \
    "injected-service SERVICE_NAME=api;rm" \
    "long-service SERVICE_NAME=$(printf 'a%.0s' {1..65})" \
    "no-railway-token RAILWAY_API_TOKEN=" \
    "no-gh-token GH_TOKEN=" \
    "bad-ping-url HEALTHCHECK_PING_URL=ftp://hc-ping.com/x" \
    "quoted-ping-url HEALTHCHECK_PING_URL=https://hc-ping.com/x\"y" \
    "bad-repository GITHUB_REPOSITORY=szczur-radar-monitor" \
    "no-assignee MONITOR_ASSIGNEE=" \
    "bad-readiness READINESS_SERVICES=Api" \
    "empty-readiness READINESS_SERVICES=," \
    "bad-settle SETTLE_TIMEOUT=5min" \
    "bad-interval SETTLE_INTERVAL=0s" \
    "bad-wake WAKE_TIMEOUT=-1m" \
    "bad-web-url WEB_URL=https://example.test/api"; do
    read -r name assignment <<<"$case"
    run_verify "$name" 2 "$assignment"
    run_says "$name" '::error::verify: '
    [[ ! -f $tmp/$name.railway/calls && ! -f $tmp/$name.gh/calls ]] || { show_run "$name"; die "$name: a stub was called"; }
done
status=0
PATH="$tmp/bin:$PATH" "$verify" extra-argument >/dev/null 2>&1 || status=$?
[[ $status == 2 ]] || die "verify.sh with an argument: exit $status, expected 2"
pass "a missing or bad variable (event, IDs, names, tokens, repository, assignee, READINESS_SERVICES, durations, WEB_URL) or an argument: exit 2, no railway or gh call"

printf '\nAll verifier tests passed.\n'
