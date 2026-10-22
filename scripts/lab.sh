#!/usr/bin/env bash
# Lifecycle of the lab.
#   scripts/lab.sh up      keys + secrets if missing, compose up --build, playbook
#   scripts/lab.sh check   playbook again; fails if anything changed (idempotency)
#   scripts/lab.sh down    stop, keep volumes
#   scripts/lab.sh reset   DESTRUCTIVE: stop and drop volumes
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# compose refuses to interpolate without it, even for down/ps
export SSH_PUBKEY="$(cat .ssh/lab_ed25519.pub 2>/dev/null || echo none)"

keys() {
  mkdir -p .ssh
  [[ -f .ssh/lab_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C lab-control -f .ssh/lab_ed25519
  [[ -f .ssh/pgbackrest_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C pgbackrest-mesh -f .ssh/pgbackrest_ed25519
  chmod 0600 .ssh/*_ed25519
}

secrets() {
  [[ -f group_vars/all/secrets.yml ]] && return 0
  local a b c
  a="$(openssl rand -base64 24)"; b="$(openssl rand -base64 24)"; c="$(openssl rand -base64 24)"
  umask 077
  printf -- '---\npg_superuser_password: "%s"\npg_replication_password: "%s"\npatroni_restapi_password: "%s"\n' "$a" "$b" "$c" > group_vars/all/secrets.yml
  echo ">>> generated group_vars/all/secrets.yml (gitignored)"
}

case "${1:-}" in
  up)
    keys; secrets
    export SSH_PUBKEY="$(cat .ssh/lab_ed25519.pub)"
    docker compose up -d --build
    # systemd as PID 1 can fail to start (cgroup scope on a tired WSL); a node
    # that is not Up must stop the run here, not as "unreachable" from Ansible.
    sleep 3
    down="$(docker compose ps --format '{{.Name}} {{.State}}' | grep -v ' running$' || true)"
    [[ -z "$down" ]] || { printf 'ERROR: not running:\n%s\n' "$down" >&2; exit 1; }
    for _ in $(seq 1 30); do timeout 2 bash -c 'echo >/dev/tcp/172.18.0.5/22' 2>/dev/null && break; sleep 2; done
    ansible-playbook playbook.yml
    echo ">>> lab is up"
    ;;
  check)
    out="$(ansible-playbook playbook.yml 2>&1)"; rc=$?
    printf '%s\n' "$out" | grep -A6 '^PLAY RECAP'
    (( rc == 0 )) || exit "$rc"
    if printf '%s\n' "$out" | grep -A6 '^PLAY RECAP' | grep -qE 'changed=[1-9]'; then
      echo "ERROR: a second run changed something; the playbook is not idempotent" >&2; exit 1
    fi
    echo ">>> second run changed nothing"
    ;;
  down)  docker compose down ;;
  reset) docker compose down -v ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
