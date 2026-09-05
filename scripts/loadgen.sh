#!/usr/bin/env bash
# Continuous, gentle traffic generator.
#
# Dashboards are meaningless without traffic - an idle system looks identical
# to a broken one. Leave this running in a second terminal while you explore
# Grafana.
#
# Ctrl-C to stop.
set -uo pipefail

BASE="${1:-}"
RPS="${2:-2}"
if [[ -z "$BASE" ]]; then
  echo "usage: $0 https://app.example.com [requests-per-second]" >&2
  exit 1
fi

PASSWORD="password123"
USERS=(alice bob carol dave)
declare -A JARS

cleanup() {
  echo ""
  echo "stopping; cleaning up cookie jars"
  for j in "${JARS[@]:-}"; do [[ -n "${j:-}" ]] && rm -f "$j"; done
  exit 0
}
trap cleanup INT TERM

echo "logging in as ${#USERS[@]} users..."
for u in "${USERS[@]}"; do
  jar="$(mktemp)"
  JARS[$u]="$jar"
  curl -sS -o /dev/null -c "$jar" -X POST "$BASE/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$u\",\"password\":\"$PASSWORD\"}" \
    || echo "  warning: could not log in as $u (run scripts/seed.sh first)"
done

echo "generating ~${RPS} req/s against $BASE - Ctrl-C to stop"
delay=$(awk "BEGIN{printf \"%.3f\", 1/$RPS}")
n=0

while true; do
  u="${USERS[$((RANDOM % ${#USERS[@]}))]}"
  jar="${JARS[$u]}"
  n=$((n + 1))

  # Weighted mix: reads dominate, as they would in a real social app.
  roll=$((RANDOM % 100))
  if   (( roll < 70 )); then
    curl -sS -o /dev/null -b "$jar" "$BASE/api/timeline"
  elif (( roll < 85 )); then
    curl -sS -o /dev/null -b "$jar" "$BASE/api/me"
  elif (( roll < 95 )); then
    curl -sS -o /dev/null -b "$jar" -X POST "$BASE/api/posts" \
      -H 'Content-Type: application/json' \
      -d "{\"body\":\"load test $n at $(date -u +%H:%M:%S)\"}"
  else
    # Deliberately fails: exercises the 401 path so the dashboards show a
    # realistic baseline of 4xx rather than a suspiciously perfect 100%.
    curl -sS -o /dev/null "$BASE/api/timeline"
  fi

  (( n % 50 == 0 )) && echo "  $n requests sent"
  sleep "$delay"
done
