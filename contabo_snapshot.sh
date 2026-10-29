#!/bin/bash
# contabo_snapshot.sh - keep a rolling set of Contabo VPS snapshots for chosen instances.
#
# Usage: contabo_snapshot.sh [--dry-run] [--check] [--list]
#   (no option)  create a new snapshot per instance, deleting the oldest managed one first when the limit is reached.
#   --dry-run    do every read-only call and print what would be deleted and created, change nothing.
#   --check      test the login and that each instance and its snapshots can be read, change nothing.
#   --list       print the snapshots of each instance, change nothing.
#
# Settings in config.conf (next to this script, or CONFIG_FILE): CLIENT_ID CLIENT_SECRET API_USER API_PASSWORD (required)
#   INSTANCE_IDS            required, space separated instance ids to snapshot. Other instances on the account are never touched.
#   SNAPSHOT_LIMIT          snapshots allowed per instance by your plan, default 1.
#   ROTATE_PREFIX           only snapshots whose name starts with this are rotated, default auto-. New snapshots get this prefix.
#   ALLOW_DELETE_UNMANAGED  1 lets the script delete snapshots without the prefix to make room, default 0.
#   SNAPSHOT_DESCRIPTION    description of new snapshots.
#   LOCK_FILE               default /var/lock/contabo_snapshot.lock
#
# Exit status: 0 done, 1 an error occurred, 2 configuration or login problem, 3 skipped because the only snapshots in the
# way are not managed by this script (nothing was deleted).
#
# Rules this script follows: it never deletes anything it cannot identify, never creates before the limit is respected,
# never prints the password, client secret or token, and sends DELETE without a Content-Type header (Contabo answers 400 to it).

set -u
set -o pipefail

readonly AUTH_URL='https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token'
readonly API_URL='https://api.contabo.com/v1/compute'
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONFIG_FILE=${CONFIG_FILE:-$SCRIPT_DIR/config.conf}

DRY_RUN=0
MODE=run

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
log()  { printf '%s %s\n' "$(date '+%F %T %z')" "$*"; }
warn() { log "WARNING: $*"; }
fail() {
  log "ERROR: $*" >&2
  if command -v logger >/dev/null 2>&1; then logger -t contabo-snapshot -p user.err -- "$*" 2>/dev/null; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check)   MODE=check ;;
    --list)    MODE=list ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- configuration -----------------------------------------------------------------------------------------------
[ -r "$CONFIG_FILE" ] || { fail "cannot read $CONFIG_FILE"; exit 2; }
cfg_mode=$(stat -c '%a' "$CONFIG_FILE")
cfg_owner=$(stat -c '%u' "$CONFIG_FILE")
if [ "$cfg_owner" != 0 ] && [ "$cfg_owner" != "$(id -u)" ]; then
  fail "$CONFIG_FILE belongs to another user"; exit 2
fi
if [ $(( 8#$cfg_mode & 8#022 )) -ne 0 ]; then
  fail "$CONFIG_FILE can be written by other users (mode $cfg_mode): run chmod 600"; exit 2
fi
[ $(( 8#$cfg_mode & 8#044 )) -eq 0 ] || warn "$CONFIG_FILE can be read by other users (mode $cfg_mode): run chmod 600"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

CLIENT_ID=${CLIENT_ID:-}; CLIENT_SECRET=${CLIENT_SECRET:-}; API_USER=${API_USER:-}; API_PASSWORD=${API_PASSWORD:-}
INSTANCE_IDS=${INSTANCE_IDS:-}
SNAPSHOT_LIMIT=${SNAPSHOT_LIMIT:-1}
ROTATE_PREFIX=${ROTATE_PREFIX:-auto-}
ALLOW_DELETE_UNMANAGED=${ALLOW_DELETE_UNMANAGED:-0}
SNAPSHOT_DESCRIPTION=${SNAPSHOT_DESCRIPTION:-Automatic snapshot by contabo_snapshot.sh}
LOCK_FILE=${LOCK_FILE:-/var/lock/contabo_snapshot.lock}
RETRY_SLEEP=${RETRY_SLEEP:-5}

for v in CLIENT_ID CLIENT_SECRET API_USER API_PASSWORD; do
  [ -n "${!v}" ] || { fail "$v is not set in $CONFIG_FILE"; exit 2; }
done
[ -n "$INSTANCE_IDS" ] || { fail "INSTANCE_IDS is not set in $CONFIG_FILE (example: INSTANCE_IDS=\"202386857\"); refusing to touch every instance of the account"; exit 2; }
for id in $INSTANCE_IDS; do
  [[ "$id" =~ ^[0-9]+$ ]] || { fail "INSTANCE_IDS must contain only numbers, got: $id"; exit 2; }
done
[[ "$SNAPSHOT_LIMIT" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_LIMIT" -ge 1 ] && [ "$SNAPSHOT_LIMIT" -le 10 ] || { fail "SNAPSHOT_LIMIT must be a number from 1 to 10"; exit 2; }
[[ "$ROTATE_PREFIX" =~ ^[A-Za-z0-9_-]+$ ]] || { fail "ROTATE_PREFIX must not be empty and may contain only letters, digits, _ and -"; exit 2; }
[[ "$ALLOW_DELETE_UNMANAGED" =~ ^[01]$ ]] || { fail "ALLOW_DELETE_UNMANAGED must be 0 or 1"; exit 2; }

# ---- lock and temporary files ----------------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || { fail "cannot open the lock file $LOCK_FILE"; exit 2; }
  flock -n 9 || { fail "another run is in progress (lock $LOCK_FILE)"; exit 1; }
else
  warn "flock not found: running without a lock"
fi
TMP=$(mktemp -d) || { fail "cannot create a temporary directory"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
BODY=$TMP/body.json
TOKEN=""
HTTP_CODE=000

uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || printf '%s-%s' "$(date +%s%N)" "$RANDOM"; }
TRACE_ID=$(uuid)
# value for a curl config file line: escape backslash and double quote
esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

get_token() {
  local code
  code=$(printf 'data-urlencode = "client_id=%s"\ndata-urlencode = "client_secret=%s"\ndata-urlencode = "username=%s"\ndata-urlencode = "password=%s"\ndata-urlencode = "grant_type=password"\n' \
           "$(esc "$CLIENT_ID")" "$(esc "$CLIENT_SECRET")" "$(esc "$API_USER")" "$(esc "$API_PASSWORD")" |
         curl -sS --max-time 60 --connect-timeout 15 -X POST -o "$TMP/token.json" -w '%{http_code}' \
              -H "x-request-id: $(uuid)" -K - "$AUTH_URL" 2>"$TMP/curl.err") || code=000
  if [ "$code" != 200 ]; then
    fail "login to Contabo failed (HTTP $code, error=$(jq -r '.error // "none"' "$TMP/token.json" 2>/dev/null), description=$(jq -r '.error_description // "none"' "$TMP/token.json" 2>/dev/null)) $(head -c 200 "$TMP/curl.err" 2>/dev/null)"
    rm -f "$TMP/token.json"
    return 1
  fi
  TOKEN=$(jq -r '.access_token // empty' "$TMP/token.json" 2>/dev/null)
  rm -f "$TMP/token.json"
  [ -n "$TOKEN" ] || { fail "login answered HTTP 200 but returned no access token"; return 1; }
  return 0
}

# api METHOD URL [JSON]: sets HTTP_CODE and writes the answer to $BODY. GET is retried on 429, 5xx and network errors.
# One new login is attempted when the token is refused. The token travels in a curl config on stdin, never in arguments.
api() {
  local method=$1 url=$2 data=${3:-} attempt=1 max=1 reauth=0
  local -a args
  [ "$method" = GET ] && max=3
  while :; do
    : > "$BODY"
    args=(-sS --max-time 60 --connect-timeout 15 -X "$method" -o "$BODY" -w '%{http_code}'
          -H "x-request-id: $(uuid)" -H "x-trace-id: $TRACE_ID")
    [ -z "$data" ] || args+=(-H 'Content-Type: application/json' -d "$data")
    HTTP_CODE=$(printf 'header = "Authorization: Bearer %s"\n' "$(esc "$TOKEN")" |
                curl "${args[@]}" -K - "$url" 2>"$TMP/curl.err") || HTTP_CODE=000
    if [ "$HTTP_CODE" = 401 ] && [ "$reauth" -eq 0 ]; then
      reauth=1; warn "token refused, logging in again"; get_token || return 1; continue
    fi
    case "$HTTP_CODE" in
      000|429|5??) if [ "$attempt" -lt "$max" ]; then attempt=$((attempt + 1)); sleep "$RETRY_SLEEP"; continue; fi ;;
    esac
    return 0
  done
}

api_message() { jq -r '.message // .error_description // .error // empty' "$BODY" 2>/dev/null | head -c 200; }

# fetch_snapshots INSTANCE: writes the snapshots, oldest first, to $TMP/snaps.json as [{id,name,created}]
fetch_snapshots() {
  api GET "$API_URL/instances/$1/snapshots?size=100"
  if [ "$HTTP_CODE" != 200 ]; then fail "instance $1: listing snapshots failed (HTTP $HTTP_CODE $(api_message))"; return 1; fi
  if ! jq -e '.data | type == "array"' "$BODY" >/dev/null 2>&1; then fail "instance $1: the snapshot list has no data array, refusing to continue"; return 1; fi
  if [ "$(jq -r '._pagination.totalPages // 1' "$BODY")" != 1 ]; then fail "instance $1: more than 100 snapshots, refusing to continue"; return 1; fi
  if ! jq -e 'all(.data[]; (.snapshotId | type == "string" and length > 0) and (.name | type == "string"))' "$BODY" >/dev/null 2>&1; then
    fail "instance $1: a snapshot entry has no id or name, refusing to continue"; return 1
  fi
  jq -c '[.data[] | {id: .snapshotId, name: .name, created: (.createdDate // "")}] | sort_by(.created)' "$BODY" > "$TMP/snaps.json"
}

print_snapshots() { jq -r '.[] | "  \(.id)  \(.name)  created \(.created)"' "$TMP/snaps.json"; }

# process_instance INSTANCE: returns 0 ok, 1 error, 3 skipped for safety
process_instance() {
  local id=$1 total need eligible_json eligible_count name body sid new_id attempt created=0 deleted=0 protected
  log "instance $id: reading"
  api GET "$API_URL/instances/$id"
  if [ "$HTTP_CODE" != 200 ]; then fail "instance $id: cannot be read (HTTP $HTTP_CODE $(api_message))"; return 1; fi
  fetch_snapshots "$id" || return 1
  total=$(jq 'length' "$TMP/snaps.json")
  log "instance $id: $total snapshot(s), limit $SNAPSHOT_LIMIT, rotating names that start with '$ROTATE_PREFIX'"
  print_snapshots
  [ "$MODE" = list ] && return 0
  [ "$MODE" = check ] && { log "instance $id: readable"; return 0; }

  need=0
  [ "$total" -ge "$SNAPSHOT_LIMIT" ] && need=$((total - SNAPSHOT_LIMIT + 1))
  if [ "$ALLOW_DELETE_UNMANAGED" = 1 ]; then
    eligible_json=$(jq -c '[.[] | .id]' "$TMP/snaps.json")
  else
    eligible_json=$(jq -c --arg p "$ROTATE_PREFIX" '[.[] | select(.name | startswith($p)) | .id]' "$TMP/snaps.json")
  fi
  eligible_count=$(jq 'length' <<< "$eligible_json")
  if [ "$need" -gt "$eligible_count" ]; then
    protected=$(jq -r --argjson e "$eligible_json" '[.[] | select(.id as $i | $e | index($i) | not) | .name] | join(", ")' "$TMP/snaps.json")
    warn "instance $id: the limit is reached and room for a new snapshot needs $need deletion(s) but only $eligible_count managed snapshot(s) exist. Not deleting protected snapshot(s): $protected. Nothing was changed. Delete one by hand or set ALLOW_DELETE_UNMANAGED=1."
    return 3
  fi

  name="${ROTATE_PREFIX}$(date +%Y%m%d-%H%M%S)"
  if [ "$DRY_RUN" = 1 ]; then
    if [ "$need" -gt 0 ]; then
      log "DRY RUN instance $id: would delete $need snapshot(s), oldest first: $(jq -r --argjson n "$need" '.[:$n] | join(", ")' <<< "$eligible_json")"
    else
      log "DRY RUN instance $id: nothing to delete"
    fi
    log "DRY RUN instance $id: would create snapshot $name"
    return 0
  fi

  while [ "$deleted" -lt "$need" ]; do
    sid=$(jq -r --argjson d "$deleted" '.[$d] // empty' <<< "$eligible_json")
    [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || { fail "instance $id: refusing to delete an empty or odd snapshot id"; return 1; }
    log "instance $id: deleting $sid ($(jq -r --arg s "$sid" '.[] | select(.id == $s) | .name' "$TMP/snaps.json"))"
    api DELETE "$API_URL/instances/$id/snapshots/$sid"
    case "$HTTP_CODE" in
      200|202|204) deleted=$((deleted + 1)) ;;
      *) fail "instance $id: deleting $sid failed (HTTP $HTTP_CODE $(api_message)), nothing was created"; return 1 ;;
    esac
  done

  body=$(jq -nc --arg n "$name" --arg d "$SNAPSHOT_DESCRIPTION" '{name: $n, description: $d}')
  attempt=1
  while :; do
    api POST "$API_URL/instances/$id/snapshots" "$body"
    if [ "$HTTP_CODE" = 201 ]; then new_id=$(jq -r '.data[0].snapshotId // empty' "$BODY"); created=1; break; fi
    case "$HTTP_CODE" in
      000|429|5??)
        if [ "$attempt" -lt 3 ]; then
          attempt=$((attempt + 1)); sleep "$RETRY_SLEEP"
          # the request may have gone through although the answer was lost
          if fetch_snapshots "$id" && new_id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' "$TMP/snaps.json") && [ -n "$new_id" ]; then created=1; break; fi
          continue
        fi ;;
    esac
    break
  done
  if [ "$created" != 1 ]; then
    if [ "$deleted" -gt 0 ]; then
      fail "CRITICAL instance $id: deleted $deleted snapshot(s) but creating $name failed (HTTP $HTTP_CODE $(api_message)). The instance may have NO recent snapshot."
    else
      fail "instance $id: creating $name failed (HTTP $HTTP_CODE $(api_message)); nothing was deleted"
    fi
    return 1
  fi

  fetch_snapshots "$id" || return 1
  if ! jq -e --arg n "$name" 'any(.[]; .name == $n)' "$TMP/snaps.json" >/dev/null; then
    fail "instance $id: snapshot $name was reported as created but is not in the list"; return 1
  fi
  log "instance $id: created $name (${new_id:-no id returned}); snapshots now:"
  print_snapshots
  return 0
}

# ---- main ------------------------------------------------------------------------------------------------------
log "contabo_snapshot start: mode=$MODE dry_run=$DRY_RUN instances='$INSTANCE_IDS' limit=$SNAPSHOT_LIMIT prefix=$ROTATE_PREFIX"
get_token || exit 2
any_error=0; any_skip=0
for id in $INSTANCE_IDS; do
  process_instance "$id"
  case $? in
    0) ;;
    3) any_skip=1 ;;
    *) any_error=1 ;;
  esac
done
if [ "$any_error" = 1 ]; then log "finished with errors"; exit 1; fi
if [ "$any_skip" = 1 ]; then log "finished, at least one instance was skipped for safety"; exit 3; fi
log "finished"
exit 0
