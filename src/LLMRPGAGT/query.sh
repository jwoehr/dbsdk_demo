#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# query.sh - Send a query to a running LLMRPGAGT agent via HTTP
#
# Usage:
#   ./query.sh [OPTIONS] "your query text"
#
# Options:
#   -H HOST        Agent host (default: localhost)
#   -p PORT        Agent port (default: 8080)
#   -s SESSION_ID  Resume an existing session (optional)
#   -S             Session mode: automatically echo session_id for follow-up
#                  prompts so a multi-turn conversation stays in one session
#   -h             Show this help and exit
#
# Examples:
#   # Single query (new session)
#   ./query.sh "What is the current date on the IBM i system?"
#
#   # Single query against a remote agent on port 9090
#   ./query.sh -H myibmi.example.com -p 9090 "List the libraries in my library list"
#
#   # Resume a paused session (agent returned status=clarify)
#   ./query.sh -s 20250731143012-1 "Db2 for i"
#
#   # Interactive multi-turn session (-S flag)
#   ./query.sh -S "Tell me about LLMRPGAGT"
# -----------------------------------------------------------------------------

set -euo pipefail

# ---- defaults ---------------------------------------------------------------
HOST="localhost"
PORT="8080"
SESSION_ID=""
SESSION_MODE=false

# ---- argument parsing -------------------------------------------------------
while getopts "H:p:s:Sh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    s) SESSION_ID="$OPTARG" ;;
    S) SESSION_MODE=true ;;
    h)
      sed -n '/^# Usage/,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -lt 1 ]]; then
  echo "Error: query text is required." >&2
  echo "Usage: $0 [OPTIONS] \"query text\"" >&2
  exit 1
fi

QUERY="$*"
BASE_URL="http://${HOST}:${PORT}"

# ---- helper: JSON-encode a string (minimal escaping for bash) ---------------
json_escape() {
  # Escape backslashes first, then double-quotes, then control characters
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed ':a;N;$!ba;s/\n/\\n/g' \
    | sed 's/\r/\\r/g' \
    | sed 's/\t/\\t/g'
}

# ---- health check -----------------------------------------------------------
echo "Checking agent at ${BASE_URL}/health ..."
HEALTH=$(curl --silent --fail --max-time 5 "${BASE_URL}/health" 2>&1) || {
  echo "Error: agent is not reachable at ${BASE_URL}" >&2
  exit 1
}
echo "Health: ${HEALTH}"
echo

# ---- POST /query ------------------------------------------------------------
send_query() {
  local query="$1"
  local session="$2"

  local escaped_query
  escaped_query=$(json_escape "$query")

  local body
  if [[ -n "$session" ]]; then
    body="{\"session_id\":\"${session}\",\"query\":\"${escaped_query}\"}"
  else
    body="{\"query\":\"${escaped_query}\"}"
  fi

  curl \
    --silent \
    --fail \
    --max-time 120 \
    --header "Content-Type: application/json" \
    --data "$body" \
    "${BASE_URL}/query"
}

# ---- single-shot or session-mode loop ---------------------------------------
if ! $SESSION_MODE; then
  echo "Query: ${QUERY}"
  echo
  RESPONSE=$(send_query "$QUERY" "$SESSION_ID")
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
  CURRENT_QUERY="$QUERY"
  CURRENT_SESSION="$SESSION_ID"

  while true; do
    echo "Query: ${CURRENT_QUERY}"
    echo

    RESPONSE=$(send_query "$CURRENT_QUERY" "$CURRENT_SESSION")
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    echo

    # Extract status and session_id from the JSON response using python3
    STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)
    CURRENT_SESSION=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)

    if [[ "$STATUS" == "answer" || "$STATUS" == "error" || -z "$STATUS" ]]; then
      break
    fi

    if [[ "$STATUS" == "clarify" ]]; then
      QUESTION=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('question',''))" 2>/dev/null || true)
      printf "Clarification needed: %s\nYour answer: " "$QUESTION"
      read -r CURRENT_QUERY
      echo
    fi
  done
fi
