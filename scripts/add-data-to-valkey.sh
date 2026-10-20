#!/usr/bin/env bash
# add-data-to-valkey.sh — populate the Bookstore API with sample data
#
# Usage:
#   # With port-forward running (kubectl port-forward -n bookstore svc/bookstore 8080:80):
#   ./scripts/add-data-to-valkey.sh
#
#   # With a custom base URL:
#   BASE_URL=http://my-host:8080 ./scripts/add-data-to-valkey.sh

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "Adding data to Valkey via bookstore API at ${BASE_URL} ..."

post_book() {
  local payload="$1"
  local isbn
  isbn=$(echo "$payload" | grep -o '"isbn":"[^"]*"' | cut -d'"' -f4)
  echo -n "  → Creating book ${isbn} ... "
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${BASE_URL}/books" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if [[ "$http_code" == "201" ]]; then
    echo "OK (201)"
  elif [[ "$http_code" == "409" ]]; then
    echo "already exists (409), skipping"
  else
    echo "FAILED (HTTP ${http_code})"
  fi
}

# ── Sample books ───────────────────────────────────────────────────────────────

post_book '{"isbn":"9780743273565","title":"The Great Gatsby","author":"F. Scott Fitzgerald","year":1925,"price":9.99,"description":"A story of the fabulously wealthy Jay Gatsby and his love for Daisy Buchanan."}'

post_book '{"isbn":"9780061096525","title":"To Kill a Mockingbird","author":"Harper Lee","year":1960,"price":12.99,"description":"The unforgettable novel of a childhood in a sleepy Southern town and the crisis of conscience that rocked it."}'

post_book '{"isbn":"9780140449136","title":"Crime and Punishment","author":"Fyodor Dostoevsky","year":1866,"price":11.49,"description":"A murderer faces psychological anguish after committing an act he believes will benefit humanity."}'

post_book '{"isbn":"9780547928227","title":"The Hobbit","author":"J.R.R. Tolkien","year":1937,"price":14.99,"description":"A hobbit is swept into an epic quest to reclaim the lost Dwarf Kingdom of Erebor."}'

post_book '{"isbn":"9780062316097","title":"The Alchemist","author":"Paulo Coelho","year":1988,"price":13.49,"description":"A shepherd boy travels from Spain to the Egyptian desert in search of a treasure."}'

post_book '{"isbn":"9780316769174","title":"The Catcher in the Rye","author":"J.D. Salinger","year":1951,"price":10.99,"description":"The story of Holden Caulfield, a teenager navigating disillusionment and identity."}'

post_book '{"isbn":"9780679720201","title":"One Hundred Years of Solitude","author":"Gabriel García Márquez","year":1967,"price":15.99,"description":"The multi-generational story of the Buendía family in the mythical town of Macondo."}'

post_book '{"isbn":"9780743477567","title":"The Old Man and the Sea","author":"Ernest Hemingway","year":1952,"price":8.99,"description":"An aging Cuban fisherman struggles with a giant marlin far out in the Gulf Stream."}'

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "Done. Verifying ..."
echo ""

TOTAL=$(curl -s "${BASE_URL}/books" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
echo "  Books in store: ${TOTAL}"
echo ""
echo "  Explore the API:"
echo "    ${BASE_URL}/books             → list all books"
echo "    ${BASE_URL}/books/9780743273565  → get one book"
echo "    ${BASE_URL}/books/author/J.R.R.%20Tolkien  → books by author"
echo "    ${BASE_URL}/docs              → Swagger UI"
