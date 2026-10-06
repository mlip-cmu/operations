#!/usr/bin/env bash
# Configure four servers with Ansible: first run, second run, drift, and a new API key.
# The output also goes to transcript.txt.
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
recap() { show "$@"; "$@" | sed -n '/PLAY RECAP/,$p'; }
check() {
  printf "\$ curl -X POST localhost:%s/check -d '{\"text\": \"%s\"}'\n" "$1" "$2"
  curl -s -X POST "localhost:$1/check" -H 'content-type: application/json' -d "{\"text\": \"$2\"}"
  echo
}
fleet() { docker compose -f servers/compose.yaml "$@"; }
trap 'fleet down >/dev/null 2>&1' EXIT

step "0. Start four fresh servers (containers): web1, web2, spam1, spam2"
docker build -q -t spamfilter:1.0 ../01-container >/dev/null
fleet down >/dev/null 2>&1
fleet up -d --build --wait > out/up.log 2>&1 || { cat out/up.log; exit 1; }
run docker ps --filter name=web --filter name=spam --format '{{.Names}}\t{{.Image}}'

step "1. Inventory: which servers exist and which role each has"
run uv run ansible-inventory --graph
show uv run ansible all -m ping
uv run ansible all -m ping | grep '|'

step "2. The API key is in the repository, but encrypted (Ansible Vault)"
run head -3 group_vars/all/vault.yml

step "3. First run: configure all servers"
run uv run ansible-playbook site.yml

step "4. The web servers forward comments to both spam filter servers, with the API key"
check 8081 "Earn \$500 a day from home!!! Click here www.easy-money.biz"
check 8082 "Thanks for sharing, very helpful."
echo "# without the API key, a spam filter server rejects the request:"
show docker exec web1 curl -s -X POST spam1:8000/check -d '{"text": "hi"}'
docker exec web1 curl -s -X POST spam1:8000/check -H 'content-type: application/json' -d '{"text": "hi"}'
echo

step "5. Second run: nothing to change (idempotent)"
recap uv run ansible-playbook site.yml

step "6. Drift: someone changes the threshold on spam2 by hand"
run docker exec spam2 sed -i 's/SPAM_THRESHOLD=0.5/SPAM_THRESHOLD=0.99/' /etc/spamfilter/spamfilter.env
echo "# dry run: show what Ansible would change"
show uv run ansible-playbook site.yml --check --diff --limit spam2
uv run ansible-playbook site.yml --check --diff --limit spam2 | sed -n '/PLAY \[Configure the spam/,/PLAY \[Configure the web/p' | head -n -1
recap uv run ansible-playbook site.yml

step "7. A new API key: one run updates all four servers consistently"
recap uv run ansible-playbook site.yml -e vault_spamfilter_api_key=k-2b9d41c07e66
check 8081 "Free crypto signals, 1000% profit guaranteed, join t.me/moonpump now"
