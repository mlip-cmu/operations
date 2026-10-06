#!/usr/bin/env bash
# The blog system with monitoring: metrics, alerts, and logs during an outage of the
# spam filter. The output also goes to transcript.txt; the dashboard to dashboard.png.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
exec > >(tee transcript.txt) 2>&1

step() { printf '\n== %s\n' "$*"; }
show() {
  printf '$'
  for a in "$@"; do [[ $a =~ [[:space:]\;\{] ]] && printf " '%s'" "$a" || printf ' %s' "$a"; done
  echo
}
run() { show "$@"; "$@"; }
promql() {
  echo "PromQL> $1"
  curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" |
    jq -r '.data.result[] | "  \(.metric | del(.__name__, .instance) | to_entries | map("\(.key)=\(.value)") | join(" ")) \(.value[1] | tonumber * 1000 | round / 1000)"'
}
logql() {
  echo "LogQL> $1"
  curl -s -G localhost:3100/loki/api/v1/query_range --data-urlencode "query=$1" --data-urlencode "limit=$2" |
    jq -r '.data.result[].values[] | "  \(.[1])"' | tail -n "$2"
}
alerts() {
  echo "# alerts (Prometheus):"
  curl -s localhost:9090/api/v1/alerts |
    jq -r 'if (.data.alerts | length) == 0 then "  none" else .data.alerts[] | "  \(.state | ascii_upcase) \(.labels.alertname): \(.annotations.summary)" end'
}
wait_for() {  # wait_for <seconds> <command...>
  local limit=$1; shift
  for _ in $(seq "$limit"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
firing() { curl -s localhost:9090/api/v1/alerts | jq -e "any(.data.alerts[]; .labels.alertname == \"$1\" and .state == \"firing\")"; }
no_alerts() { curl -s localhost:9090/api/v1/alerts | jq -e '.data.alerts | length == 0'; }
trap 'docker compose down -v >/dev/null 2>&1' EXIT

step "1. Start the blog system with Prometheus, Loki, Alloy, and Grafana"
show docker compose up -d --build --wait
docker compose up -d --build --wait > out/up.log 2>&1 || { cat out/up.log; exit 1; }
run docker compose ps --format 'table {{.Service}}\t{{.Status}}'
echo "# Grafana: http://localhost:3000  Prometheus: http://localhost:9090"

step "2. Normal operation: readers post 8 comments per second (for 4 minutes)"
uv run --quiet ../traffic/send_traffic.py --target blog --url http://localhost:8080 \
  --duration 240 --rate 8 > out/traffic.txt &
traffic=$!
sleep 60
promql 'up'
promql 'sum(rate(blog_comments_posted_total[1m]))'
promql 'sum by (result) (rate(spamfilter_comments_total[1m]))'
promql 'histogram_quantile(0.95, sum by (le) (rate(spamfilter_inference_seconds_bucket[1m])))'
alerts

step "3. The spam filter stops"
stopped=$SECONDS
run docker compose stop spamfilter
for alert in SpamFilterDown CommentsWaiting; do
  wait_for 120 firing $alert && echo "# $alert fires $((SECONDS - stopped)) s after the stop"
done
promql 'up{job="spamfilter"}'
promql 'blog_comments_waiting'
alerts
echo "# logs (Loki): what does the worker report?"
logql '{service="worker"} |= "filter_unavailable"' 2

step "4. The spam filter is back"
started=$SECONDS
run docker compose start spamfilter
wait_for 120 no_alerts && echo "# all alerts resolved $((SECONDS - started)) s after the start"
promql 'blog_comments_waiting'
alerts
logql '{service="spamfilter"} |= "started"' 1

step "5. The dashboard (screenshot in dashboard.png)"
wait $traffic
cat out/traffic.txt
[ -n "${CHROMIUM_PATH:-}" ] || uv run playwright install chromium >/dev/null
run uv run python screenshot.py dashboard.png
