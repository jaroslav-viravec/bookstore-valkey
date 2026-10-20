#!/usr/bin/env bash
# delete-data-from-valkey.sh — remove all books from Valkey via the Bookstore API
#
# The counterpart to add-data-to-valkey.sh. It lists every book currently stored
# and issues a DELETE for each ISBN, leaving the store empty. Data only — the
# Valkey instance itself (managed by the operator) is untouched.
#
# Usage:
#   # With port-forward running (kubectl port-forward -n bookstore svc/bookstore 8080:80):
#   ./scripts/delete-data-from-valkey.sh
#
#   # With a custom base URL:
#   BASE_URL=http://my-host:8080 ./scripts/delete-data-from-valkey.sh

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "Deleting data from Valkey via bookstore API at ${BASE_URL} ..."

# Fail early with a friendly message if the API isn't reachable.
if ! curl -sf -o /dev/null "${BASE_URL}/health"; then
  echo "ERROR: cannot reach ${BASE_URL}/health"
  echo "Is the port-forward running?  kubectl port-forward -n bookstore svc/bookstore 8080:80"
  exit 1
fi

# Collect all ISBNs currently in the store.
ISBNS=$(curl -s "${BASE_URL}/books" \
  | python3 -c "import sys,json; print('\n'.join(b['isbn'] for b in json.load(sys.stdin)))")

if [[ -z "$ISBNS" ]]; then
  echo "  Store is already empty — nothing to delete."
  exit 0
fi

delete_book() {
  local isbn="$1"
  echo -n "  → Deleting book ${isbn} ... "
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "${BASE_URL}/books/${isbn}")
  if [[ "$http_code" == "204" ]]; then
    echo "OK (204)"
  elif [[ "$http_code" == "404" ]]; then
    echo "not found (404), skipping"
  else
    echo "FAILED (HTTP ${http_code})"
  fi
}

# ── Delete every book ────────────────────────────────────────────────────────
while IFS= read -r isbn; do
  [[ -n "$isbn" ]] && delete_book "$isbn"
done <<< "$ISBNS"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Done. Verifying ..."
echo ""

TOTAL=$(curl -s "${BASE_URL}/books" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
echo "  Books in store: ${TOTAL}"
