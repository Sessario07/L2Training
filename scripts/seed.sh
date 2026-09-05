#!/usr/bin/env bash
# Create a handful of users who follow each other and post, so the timeline
# and the fan-out worker have something real to do.
set -euo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "usage: $0 https://app.example.com" >&2
  exit 1
fi

PASSWORD="password123"
USERS=(alice bob carol dave)

echo "seeding $BASE"

for u in "${USERS[@]}"; do
  jar="$(mktemp)"
  # Signup is idempotent enough for our purposes: a 409 just means the user
  # already exists, so fall through to login.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -c "$jar" \
    -X POST "$BASE/api/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}")

  if [[ "$code" == "409" ]]; then
    curl -sS -o /dev/null -c "$jar" \
      -X POST "$BASE/api/login" \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}"
    echo "  $u: logged in (already existed)"
  else
    echo "  $u: created"
  fi

  # Everyone follows everyone else, which makes the fan-out worker actually
  # do work on each post rather than invalidating a single cache entry.
  for other in "${USERS[@]}"; do
    [[ "$other" == "$u" ]] && continue
    curl -sS -o /dev/null -b "$jar" -X POST "$BASE/api/follow/$other" || true
  done

  # A display name and bio, so profile pages are not empty.
  curl -sS -o /dev/null -b "$jar" -X PATCH "$BASE/api/me" \
    -H 'Content-Type: application/json' \
    -d "{\"display_name\":\"${u^}\",\"bio\":\"Training for L2. Breaks things on purpose.\"}"

  for i in 1 2 3; do
    curl -sS -o /dev/null -b "$jar" \
      -X POST "$BASE/api/posts" \
      -H 'Content-Type: application/json' \
      -d "{\"body\":\"post $i from $u at $(date -u +%H:%M:%S)\"}"
  done

  cp "$jar" "/tmp/l2lab-$u.jar"
  rm -f "$jar"
done

# --- replies and likes ----------------------------------------------------
# Done in a second pass, because everyone has to exist and have posted before
# anyone can reply to or like them.
echo "  adding replies and likes"
jar="/tmp/l2lab-alice.jar"
POST_IDS=$(curl -sS -b "$jar" "$BASE/api/timeline" \
  | tr ',' '\n' | grep -o '"id":[0-9]*' | head -6 | cut -d: -f2)

for u in "${USERS[@]}"; do
  ujar="/tmp/l2lab-$u.jar"
  n=0
  for pid in $POST_IDS; do
    n=$((n + 1))
    # Like most posts, reply to a couple, so counts are not uniform.
    curl -sS -o /dev/null -b "$ujar" -X PUT "$BASE/api/posts/$pid/like" || true
    if [ $((n % 3)) -eq 0 ]; then
      curl -sS -o /dev/null -b "$ujar" -X POST "$BASE/api/posts" \
        -H 'Content-Type: application/json' \
        -d "{\"body\":\"good point — $u\",\"parent_id\":$pid}" || true
    fi
  done
done

rm -f /tmp/l2lab-*.jar

echo ""
echo "done. ${#USERS[@]} users following each other, 3 posts each, plus replies and likes."
echo "log in at $BASE as alice / $PASSWORD"
