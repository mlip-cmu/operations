#!/usr/bin/env bash
# Build the spam filter image and run it. The output also goes to transcript.txt.
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
check() {
  printf "\$ curl -X POST localhost:%s/check -d '{\"text\": \"%s\"}'\n" "$1" "$2"
  curl -s -X POST "localhost:$1/check" -H 'content-type: application/json' -d "{\"text\": \"$2\"}"
  echo
}
wait_healthy() {
  for _ in $(seq 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = healthy ] && break
    sleep 1
  done
  echo "$1: $(docker inspect -f '{{.State.Health.Status}}' "$1")"
}
size() { docker image inspect -f '{{.Size}}' "$1" | awk -v t="$1" '{printf "%-24s %4d MB\n", t, $1/1e6}'; }
cleanup() { docker rm -f spamfilter spamfilter-strict spamfilter-offline >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "1. Build: stage 1 converts the model (needs PyTorch), stage 2 is the service"
run docker build -q --target model -t spamfilter:build-stage .
run docker build -q --build-arg APP_VERSION=1.0 -t spamfilter:1.0 .
size spamfilter:build-stage
size spamfilter:1.0
run docker run --rm spamfilter:build-stage uv run --no-sync python -c "import torch; print(torch.__version__)"
show docker run --rm spamfilter:1.0 python -c "import torch"
docker run --rm spamfilter:1.0 python -c "import torch" 2>&1 | tail -1 || true

step "2. Run the container; Docker checks its health"
run docker run -d --name spamfilter -p 8000:8000 spamfilter:1.0
wait_healthy spamfilter
run docker exec spamfilter whoami
run curl -s localhost:8000/health
echo

step "3. Check comments"
check 8000 "Great post about the playoffs, I had the same experience last year."
check 8000 "Free crypto signals, 1000% profit guaranteed, join t.me/moonpump now"
run uv run --quiet ../traffic/send_traffic.py --url http://localhost:8000 -n 200
run docker logs spamfilter 2>&1 | tail -2

step "4. Same image, different configuration (environment variable)"
run docker run -d --name spamfilter-strict -p 8001:8000 -e SPAM_THRESHOLD=0.99 spamfilter:1.0
wait_healthy spamfilter-strict
check 8000 "Thanks for writing about your sourdough recipe. Could you share more details?"
check 8001 "Thanks for writing about your sourdough recipe. Could you share more details?"

step "5. No network needed at start: the model is inside the image"
run docker run -d --name spamfilter-offline --network none spamfilter:1.0
wait_healthy spamfilter-offline

step "6. Release 1.1, then roll back to 1.0: tags point to fixed images"
run docker build -q --build-arg APP_VERSION=1.1 -t spamfilter:1.1 .
run docker rm -f spamfilter
run docker run -d --name spamfilter -p 8000:8000 spamfilter:1.1
wait_healthy spamfilter
run curl -s localhost:8000/health
echo
echo "# 1.1 has a problem: roll back"
run docker rm -f spamfilter
run docker run -d --name spamfilter -p 8000:8000 spamfilter:1.0
wait_healthy spamfilter
run curl -s localhost:8000/health
echo
run docker image ls spamfilter --format '{{.Tag}}\t{{.ID}}'
