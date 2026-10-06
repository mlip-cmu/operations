#!/usr/bin/env bash
# Start the blog system with Docker Compose, stop the spam filter, and start it again.
# The output also goes to transcript.txt.
set -euo pipefail
cd "$(dirname "$0")"
exec > >(tee transcript.txt) 2>&1

step() { printf '\n== %s\n' "$*"; }
show() {
  printf '$'
  for a in "$@"; do [[ $a =~ [[:space:]\;\{] ]] && printf " '%s'" "$a" || printf ' %s' "$a"; done
  echo
}
run() { show "$@"; "$@"; }
stats() { run curl -s localhost:8080/stats; echo; }
wait_until_filtered() {
  local start=$SECONDS
  until curl -s localhost:8080/stats | grep -q '"waiting":0'; do sleep 1; done
  echo "# all comments checked after $((SECONDS - start)) s"
}
trap 'docker compose down -v >/dev/null 2>&1' EXIT

step "1. Start the whole system with one command"
run docker compose up -d --build --wait --quiet-pull 2>/dev/null
run docker compose ps --format 'table {{.Service}}\t{{.Status}}'

step "2. Readers post comments; the worker sends each one to the spam filter"
run uv run --quiet ../traffic/send_traffic.py --target blog --url http://localhost:8080 -n 30
wait_until_filtered
stats
run docker compose logs worker --no-log-prefix | tail -2

step "3. The spam filter stops; the blog still accepts comments"
run docker compose stop spamfilter
run uv run --quiet ../traffic/send_traffic.py --target blog --url http://localhost:8080 -n 30
sleep 3
stats
run docker compose logs worker --no-log-prefix | tail -2
echo "# a blog that called the spam filter directly would fail now:"
direct='import httpx; httpx.post("http://spamfilter:8000/check")'
show docker compose exec worker python -c "$direct"
docker compose exec worker python -c "$direct" 2>&1 | tail -1 || true

step "4. The spam filter is back; the worker checks the waiting comments"
run docker compose start spamfilter
wait_until_filtered
stats

step "5. Stop and remove everything"
show docker compose down -v
docker compose down -v 2>&1 | tail -1
