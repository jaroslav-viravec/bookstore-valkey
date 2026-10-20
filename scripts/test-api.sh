#!/usr/bin/env bash
# test-api.sh — exercise the Bookstore API end-to-end (demo walkthrough)
#
# Prerequisite: a port-forward to the bookstore service must be running:
#   kubectl port-forward -n bookstore svc/bookstore 8080:80
#
# Usage:
#   ./scripts/test-api.sh                       # against http://localhost:8080
#   BASE_URL=http://my-host:8080 ./scripts/test-api.sh
#
# What it does (each step pauses so it reads well in a live demo — set NO_PAUSE=1
# to run straight through):
#   1. /health  — confirms Valkey connectivity + Sentinel/TLS mode
#   2. seeds the 8 sample books (if the store is empty)
#   3. lists all books
#   4. gets one book by ISBN
#   5. gets books by author
#   6. creates -> updates -> deletes a throwaway book (full CRUD)

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ISBN="9780385490818"

# ── helpers ─────────────────────────────────────────────────────────────────
step() { echo; echo "───────────────────────────────────────────────────────"; echo "▶ $*"; echo "───────────────────────────────────────────────────────"; }
run()  { echo "\$ $*"; eval "$*"; echo; }
pause() { [[ "${NO_PAUSE:-0}" == "1" ]] && return 0; read -rp "  (press Enter to continue) " _; }
pp()   { python3 -m json.tool 2>/dev/null || cat; }

# Fail early with a friendly message if the API isn't reachable.
if ! curl -sf -o /dev/null "${BASE_URL}/health"; then
  echo "ERROR: cannot reach ${BASE_URL}/health"
  echo "Is the port-forward running?  kubectl port-forward -n bookstore svc/bookstore 8080:80"
  exit 1
fi

echo "Testing Bookstore API at ${BASE_URL}"

# 1. Health / connection mode ---------------------------------------------------
step "1) Health check — Valkey connectivity, Sentinel + TLS mode"
run "curl -s ${BASE_URL}/health | pp"
pause

# 2. Seed data (only if empty) --------------------------------------------------
COUNT=$(curl -s "${BASE_URL}/books" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [[ "$COUNT" == "0" ]]; then
  step "2) Store is empty — seeding 8 sample books"
  "${SCRIPTS_DIR}/add-data-to-valkey.sh"
else
  step "2) Store already has ${COUNT} books — skipping seed"
fi
pause

# 3. List all books -------------------------------------------------------------
step "3) List all books"
run "curl -s ${BASE_URL}/books | pp"
pause

# 4. Get one book by ISBN -------------------------------------------------------
step "4) Get one book by ISBN (The Great Gatsby)"
run "curl -s ${BASE_URL}/books/9780743273565 | pp"
pause

# 5. Books by author ------------------------------------------------------------
step "5) Books by author (case-insensitive) — J.R.R. Tolkien"
run "curl -s '${BASE_URL}/books/author/J.R.R.%20Tolkien' | pp"
pause

# 6. Full CRUD on a throwaway book ---------------------------------------------
step "6a) Create a book (POST)"
run "curl -s -X POST ${BASE_URL}/books \
  -H 'Content-Type: application/json' \
  -d '{\"isbn\":\"${DEMO_ISBN}\",\"title\":\"The Handmaid'\\''s Tale\",\"author\":\"Margaret Atwood\",\"year\":1985,\"price\":12.99,\"description\":\"A dystopian novel.\"}' | pp"
pause

step "6b) Partial update — change only the price (PUT)"
run "curl -s -X PUT ${BASE_URL}/books/${DEMO_ISBN} \
  -H 'Content-Type: application/json' \
  -d '{\"price\": 10.99}' | pp"
pause

step "6c) Delete the book (DELETE — expect HTTP 204)"
run "curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE ${BASE_URL}/books/${DEMO_ISBN}"

step "6d) Confirm it's gone (GET — expect HTTP 404)"
run "curl -s -o /dev/null -w 'HTTP %{http_code}\n' ${BASE_URL}/books/${DEMO_ISBN}"

echo
echo "✅ Done. Swagger UI: ${BASE_URL}/docs"
