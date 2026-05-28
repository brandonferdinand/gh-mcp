#!/usr/bin/env bash
# gh-mcp.sh — A minimal MCP server that wraps the GitHub CLI (`gh`).
#
# Auth model: reuses whatever account `gh` is already logged into on this
# machine (see `gh auth status`). No PAT is read or stored.
#
# Protocol: JSON-RPC 2.0 over stdio, newline-delimited (one JSON message
# per line). Implements MCP methods: initialize, tools/list, tools/call, ping.
#
# Dependencies: bash 3.2+ (macOS stock bash works), jq, gh.
#
# Optional env vars:
#   GH_MCP_ALLOWLIST           Comma-separated allowlist of top-level gh
#                              subcommands (e.g. "repo,pr,issue,api"). When set,
#                              any other subcommand is refused at the MCP layer
#                              before `gh` is invoked. Unset = no restriction.
#   GH_MCP_LOG_LEVEL           "info" (default) or "debug".
#   GH_MCP_CACHE_TTL_SECONDS   How long to cache `gh auth status` output on
#                              disk (default 3600). Set to 0 to disable.
#   GH_MCP_CACHE_DIR           Override cache directory (default:
#                              $XDG_CACHE_HOME/gh-mcp or ~/.cache/gh-mcp).
#
# CLI modes (when run directly, not as an MCP server):
#   --help          Print this help text.
#   --version       Print version.
#   --selftest      Run an internal JSON-RPC smoke test against a stub gh.
#   --clear-cache   Delete the cached whoami file and exit.

set -u

VERSION="0.3.1"
PROTOCOL_VERSION="2024-11-05"

# Where we cache `gh auth status` so we don't re-run it every server startup.
CACHE_DIR="${GH_MCP_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gh-mcp}"
CACHE_FILE="$CACHE_DIR/whoami"
CACHE_TTL="${GH_MCP_CACHE_TTL_SECONDS:-3600}"  # 0 disables the cache.

log() { printf '[gh-mcp] %s\n' "$*" >&2; }
debug() { [[ "${GH_MCP_LOG_LEVEL:-info}" == "debug" ]] && log "DEBUG $*"; }

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Version: $VERSION"
}

# --- CLI mode handling ------------------------------------------------------
case "${1:-}" in
  --help|-h)    usage; exit 0 ;;
  --version|-V) echo "gh-mcp $VERSION"; exit 0 ;;
  --clear-cache)
    if [[ -e "${GH_MCP_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gh-mcp}/whoami" ]]; then
      rm -f "${GH_MCP_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gh-mcp}/whoami"
      echo "Cleared whoami cache."
    else
      echo "No whoami cache to clear."
    fi
    exit 0
    ;;
  --selftest)
    # Re-exec self with a fake gh on PATH so we can verify protocol wiring
    # without touching the real GitHub. Isolate the cache to a tempdir.
    if [[ "${_GH_MCP_IN_SELFTEST:-0}" != "1" ]]; then
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      cat >"$tmp/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")
    cat <<'AUTH'
github.com
  ✓ Logged in to github.com account selftest-user (keyring)
  - Active account: true
  - Token scopes: 'repo'
AUTH
    exit 0
    ;;
esac
case "$1" in
  --version) echo "gh selftest 0.0.0"; exit 0;;
esac
echo "stub gh: $*"
STUB
      chmod +x "$tmp/gh"
      export _GH_MCP_IN_SELFTEST=1
      export GH_MCP_CACHE_DIR="$tmp/cache"
      PATH="$tmp:$PATH" "$0" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gh_whoami","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"gh_whoami","arguments":{"refresh":true}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gh_run","arguments":{"args":["repo","list","--limit","2"]}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"gh_api","arguments":{"endpoint":"/user","method":"GET"}}}
{"jsonrpc":"2.0","id":7,"method":"ping"}
EOF
      exit $?
    fi
    ;;
esac

# --- dependency check -------------------------------------------------------------
# Note: this script targets bash 3.2+ so it runs on stock macOS bash without
# `brew install bash`. Anything bash 4+ here (associative arrays, namerefs,
# mapfile) would break that contract — see allowlist + json_array_to_bash.
command -v gh >/dev/null 2>&1 || { log "ERROR: 'gh' not found on PATH ($PATH)"; exit 1; }
command -v jq >/dev/null 2>&1 || { log "ERROR: 'jq' not found on PATH ($PATH)"; exit 1; }

# Parse allowlist (if any) into an indexed bash array. Small list, linear
# lookup is fine — we shell out to `gh` anyway, which dwarfs the comparison.
ALLOWLIST=()
if [[ -n "${GH_MCP_ALLOWLIST:-}" ]]; then
  IFS=',' read -ra _allow <<<"$GH_MCP_ALLOWLIST"
  for cmd in "${_allow[@]}"; do
    cmd="${cmd// /}"
    [[ -n "$cmd" ]] && ALLOWLIST+=("$cmd")
  done
fi

# --- tool definitions ----------------------------------------------------------
TOOLS_JSON='[
  {
    "name": "gh_run",
    "description": "Run any GitHub CLI (gh) subcommand against the locally-authenticated account. Pass arguments as an array of strings. Examples: {\"args\":[\"repo\",\"list\",\"--limit\",\"5\"]}, {\"args\":[\"pr\",\"view\",\"123\",\"--json\",\"title,body,state\"]}, {\"args\":[\"issue\",\"create\",\"--title\",\"X\",\"--body\",\"Y\"]}. Use the cwd field for repo-scoped commands like `gh pr create`. Output captures both stdout and stderr; non-zero exit codes are reported as tool errors.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "args": {
          "type": "array",
          "items": {"type": "string"},
          "description": "Arguments passed to `gh` (e.g. [\"pr\",\"list\",\"--limit\",\"5\"])."
        },
        "cwd": {
          "type": "string",
          "description": "Optional working directory. Useful for repo-scoped commands."
        }
      },
      "required": ["args"]
    }
  },
  {
    "name": "gh_api",
    "description": "Call the GitHub REST or GraphQL API via `gh api`. Prefer this over `gh_run` whenever you want structured JSON output. For REST, set endpoint to a path like \"/repos/{owner}/{repo}/issues\". For GraphQL, set endpoint to \"graphql\" and pass the query/variables via fields. Use `fields` for strings/booleans/numbers (auto-typed by gh) and `raw_fields` for forced-string values. Use `query_params` for ?key=value pairs on GET requests.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "endpoint": {
          "type": "string",
          "description": "API endpoint, e.g. \"/user\", \"/repos/{owner}/{repo}\", or \"graphql\"."
        },
        "method": {
          "type": "string",
          "enum": ["GET", "POST", "PATCH", "PUT", "DELETE"],
          "description": "HTTP method. Defaults to GET (or POST for graphql)."
        },
        "fields": {
          "type": "object",
          "description": "Body/query fields passed via `-F key=value` (gh infers types: true/false/null/numbers). Strings starting with @ or numbers will be coerced; use raw_fields if you need a literal string.",
          "additionalProperties": true
        },
        "raw_fields": {
          "type": "object",
          "description": "Body/query fields passed via `-f key=value` (always a literal string).",
          "additionalProperties": {"type": "string"}
        },
        "query_params": {
          "type": "object",
          "description": "Query string params for GET. Each pair is sent via `-F key=value` on a GET (gh maps these to ?key=value).",
          "additionalProperties": true
        },
        "paginate": {
          "type": "boolean",
          "description": "If true, pass --paginate so gh follows Link headers and concatenates pages."
        },
        "hostname": {
          "type": "string",
          "description": "Override GitHub hostname (e.g. for GitHub Enterprise). Defaults to github.com."
        }
      },
      "required": ["endpoint"]
    }
  },
  {
    "name": "gh_whoami",
    "description": "Show which GitHub account `gh` is currently authenticated as on this machine. The active identity is already included in the server'\''s initialize instructions, so you usually do not need to call this tool. Result is cached to disk (GH_MCP_CACHE_TTL_SECONDS, default 1h). Pass {\"refresh\":true} to force a fresh `gh auth status`.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "refresh": {
          "type": "boolean",
          "description": "If true, bypass the cache and re-run `gh auth status`."
        }
      }
    }
  }
]'

# --- JSON-RPC helpers ----------------------------------------------------------
send_response() {
  # $1 = id (JSON literal), $2 = result JSON
  jq -cn --argjson id "$1" --argjson result "$2" \
    '{jsonrpc:"2.0", id:$id, result:$result}'
}

send_error() {
  # $1 = id, $2 = code, $3 = message
  jq -cn --argjson id "$1" --argjson code "$2" --arg msg "$3" \
    '{jsonrpc:"2.0", id:$id, error:{code:$code, message:$msg}}'
}

text_result() {
  # $1 = text, $2 = isError ("true"/"false")
  jq -cn --arg text "$1" --argjson isError "$2" \
    '{content:[{type:"text", text:$text}], isError:$isError}'
}

# --- whoami cache ---------------------------------------------------------------
# Cross-platform `stat -c %Y` / `stat -f %m` for mtime.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Returns the cached `gh auth status` text on stdout; refreshes if missing,
# stale, or if "force" is passed as $1. Returns gh's exit code.
cached_whoami() {
  local force="${1:-}"
  local now mtime age
  if [[ "$force" != "force" && "$CACHE_TTL" != "0" && -f "$CACHE_FILE" ]]; then
    now=$(date +%s)
    mtime=$(file_mtime "$CACHE_FILE")
    age=$(( now - mtime ))
    if (( age < CACHE_TTL )); then
      debug "whoami cache hit (age=${age}s, ttl=${CACHE_TTL}s)"
      cat "$CACHE_FILE"
      return 0
    fi
    debug "whoami cache stale (age=${age}s, ttl=${CACHE_TTL}s)"
  fi
  local output rc
  output=$(gh auth status 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "$CACHE_TTL" != "0" ]]; then
    mkdir -p "$CACHE_DIR" 2>/dev/null
    printf '%s\n' "$output" >"$CACHE_FILE" 2>/dev/null || true
  fi
  printf '%s\n' "$output"
  return $rc
}

# Extract "<account> on <host>" from `gh auth status` output. Empty if not
# logged in or format unexpected.
parse_active_identity() {
  # Line we look for: "✓ Logged in to github.com account brandonferdinand (...)"
  awk '
    /Logged in to/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "to") host = $(i+1)
        if ($i == "account") { acct = $(i+1); gsub(/[(,)]/, "", acct) }
      }
      if (acct && host) { print acct " on " host; exit }
    }
  '
}

# --- helpers ------------------------------------------------------------------
# Materialise a JSON array into a bash array (NUL-delimited so spaces/newlines
# in arg values survive intact). Usage:
#   local -a OUT
#   json_array_to_bash '["a","b c"]' OUT
json_array_to_bash() {
  local json="$1" varname="$2"
  local -a _tmp=()
  local a
  while IFS= read -r -d '' a; do
    _tmp+=("$a")
  done < <(jq -j '.[] | . + "\u0000"' <<<"$json")
  # eval-based assignment works on bash 3.2; nameref would need 4.3+.
  if [[ ${#_tmp[@]} -eq 0 ]]; then
    eval "$varname=()"
  else
    eval "$varname=(\"\${_tmp[@]}\")"
  fi
}

allowed_subcommand() {
  # Returns 0 if subcommand is allowed, 1 otherwise. Linear scan over the
  # indexed array — small list, and we shell out to `gh` after this anyway.
  local sub="$1" cmd
  [[ ${#ALLOWLIST[@]} -eq 0 ]] && return 0
  for cmd in "${ALLOWLIST[@]}"; do
    [[ "$cmd" == "$sub" ]] && return 0
  done
  return 1
}

run_gh() {
  # $1 = cwd (may be empty); $2.. = args to gh
  # Emits a text_result JSON to stdout.
  local cwd="$1"; shift
  local tmpdir out err rc
  tmpdir=$(mktemp -d)

  if [[ -n "$cwd" ]]; then
    ( cd "$cwd" 2>/dev/null && gh "$@" ) >"$tmpdir/out" 2>"$tmpdir/err"
  else
    gh "$@" >"$tmpdir/out" 2>"$tmpdir/err"
  fi
  rc=$?

  out=$(cat "$tmpdir/out")
  err=$(cat "$tmpdir/err")
  rm -rf "$tmpdir"

  local combined="$out"
  if [[ -n "$err" ]]; then
    if [[ -n "$combined" ]]; then
      combined="${combined}"$'\n\n[stderr]\n'"${err}"
    else
      combined="$err"
    fi
  fi
  if [[ $rc -ne 0 && -z "$combined" ]]; then
    combined="(gh exited with code $rc and produced no output)"
  fi

  local is_error="false"
  [[ $rc -ne 0 ]] && is_error="true"
  text_result "$combined" "$is_error"
}

# --- method handlers -----------------------------------------------------------
handle_initialize() {
  local id="$1"
  local result identity instructions
  # Resolve active identity from cache (or refresh if stale). Failures are
  # tolerated — we just omit the instructions field.
  identity=$(cached_whoami 2>/dev/null | parse_active_identity)
  if [[ -n "$identity" ]]; then
    instructions="GitHub identity: $identity. The locally-configured \`gh\` CLI is already authenticated as this account, so you usually do not need to call \`gh_whoami\` to confirm. All gh_run / gh_api calls act as this user."
  else
    instructions="The locally-configured \`gh\` CLI does not appear to be logged in. Run \`gh auth login\` on the host machine to authenticate."
  fi
  result=$(jq -cn \
    --arg pv "$PROTOCOL_VERSION" \
    --arg version "$VERSION" \
    --arg instructions "$instructions" \
    '{
      protocolVersion: $pv,
      capabilities: {tools: {}},
      serverInfo: {name: "gh-mcp", version: $version},
      instructions: $instructions
    }')
  send_response "$id" "$result"
}

handle_tools_list() {
  local id="$1"
  local result
  result=$(jq -cn --argjson tools "$TOOLS_JSON" '{tools:$tools}')
  send_response "$id" "$result"
}

handle_gh_run() {
  local id="$1" params="$2"
  local args_json cwd
  args_json=$(jq -c '.arguments.args // []' <<<"$params")
  cwd=$(jq -r '.arguments.cwd // empty' <<<"$params")

  local -a gh_args=()
  json_array_to_bash "$args_json" gh_args

  if [[ ${#gh_args[@]} -eq 0 ]]; then
    send_response "$id" "$(text_result 'No args provided. Try {"args":["--help"]}.' 'true')"
    return
  fi
  if ! allowed_subcommand "${gh_args[0]}"; then
    send_response "$id" "$(text_result "Subcommand '${gh_args[0]}' is not in GH_MCP_ALLOWLIST." 'true')"
    return
  fi

  debug "gh_run: gh ${gh_args[*]} (cwd=${cwd:-.})"
  send_response "$id" "$(run_gh "$cwd" "${gh_args[@]}")"
}

handle_gh_api() {
  local id="$1" params="$2"
  local endpoint method hostname paginate
  endpoint=$(jq -r '.arguments.endpoint // empty' <<<"$params")
  method=$(jq -r '.arguments.method // empty' <<<"$params")
  hostname=$(jq -r '.arguments.hostname // empty' <<<"$params")
  paginate=$(jq -r '.arguments.paginate // false' <<<"$params")

  if [[ -z "$endpoint" ]]; then
    send_error "$id" -32602 "gh_api: endpoint is required"
    return
  fi

  if ! allowed_subcommand "api"; then
    send_response "$id" "$(text_result "Subcommand 'api' is not in GH_MCP_ALLOWLIST." 'true')"
    return
  fi

  local -a args=(api "$endpoint")
  [[ -n "$method" ]] && args+=(--method "$method")
  [[ -n "$hostname" ]] && args+=(--hostname "$hostname")
  [[ "$paginate" == "true" ]] && args+=(--paginate)

  # Typed fields → -F key=value (gh infers true/false/null/number)
  while IFS= read -r -d '' kv; do
    [[ -n "$kv" ]] && args+=(-F "$kv")
  done < <(jq -j '(.arguments.fields // {}) | to_entries[] | (.key + "=" + (if .value|type=="string" then .value else (.value|tostring) end)) + "\u0000"' <<<"$params")

  # Raw fields → -f key=value (always string)
  while IFS= read -r -d '' kv; do
    [[ -n "$kv" ]] && args+=(-f "$kv")
  done < <(jq -j '(.arguments.raw_fields // {}) | to_entries[] | (.key + "=" + .value) + "\u0000"' <<<"$params")

  # Query params for GET requests use -F as well (same flag, gh handles routing)
  while IFS= read -r -d '' kv; do
    [[ -n "$kv" ]] && args+=(-F "$kv")
  done < <(jq -j '(.arguments.query_params // {}) | to_entries[] | (.key + "=" + (if .value|type=="string" then .value else (.value|tostring) end)) + "\u0000"' <<<"$params")

  debug "gh_api: gh ${args[*]}"
  send_response "$id" "$(run_gh "" "${args[@]}")"
}

handle_gh_whoami() {
  local id="$1" params="$2"
  local refresh text rc force=""
  refresh=$(jq -r '.arguments.refresh // false' <<<"$params")
  [[ "$refresh" == "true" ]] && force="force"
  text=$(cached_whoami "$force")
  rc=$?
  local is_error="false"
  [[ $rc -ne 0 ]] && is_error="true"
  send_response "$id" "$(text_result "$text" "$is_error")"
}

handle_tools_call() {
  local id="$1" params="$2"
  local name
  name=$(jq -r '.name // empty' <<<"$params")
  case "$name" in
    gh_run)    handle_gh_run    "$id" "$params" ;;
    gh_api)    handle_gh_api    "$id" "$params" ;;
    gh_whoami) handle_gh_whoami "$id" "$params" ;;
    '')        send_error "$id" -32602 "Missing tool name" ;;
    *)         send_error "$id" -32602 "Unknown tool: $name" ;;
  esac
}

# --- startup info --------------------------------------------------------------
gh_version=$(gh --version 2>/dev/null | head -1 || echo "unknown")
active_identity=$(cached_whoami 2>/dev/null | parse_active_identity)
log "starting v$VERSION (gh: $gh_version; identity: ${active_identity:-unknown}; cache: ${CACHE_FILE})"
if [[ ${#ALLOWLIST[@]} -gt 0 ]]; then
  log "allowlist active: ${ALLOWLIST[*]}"
fi

# --- main loop -----------------------------------------------------------------
trap 'log "exiting"' EXIT

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
    log "ignoring non-JSON line: $line"
    continue
  fi

  method=$(jq -r '.method // empty' <<<"$line")
  id=$(jq -c '.id // null' <<<"$line")
  params=$(jq -c '.params // {}' <<<"$line")

  debug "<-- method=$method id=$id"

  case "$method" in
    initialize)       handle_initialize "$id" ;;
    tools/list)       handle_tools_list "$id" ;;
    tools/call)       handle_tools_call "$id" "$params" ;;
    ping)             send_response "$id" '{}' ;;
    notifications/*)  : ;;
    '')               log "request with no method: $line" ;;
    *)
      if [[ "$id" != "null" ]]; then
        send_error "$id" -32601 "Method not found: $method"
      fi
      ;;
  esac
done
