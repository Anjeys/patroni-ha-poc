#!/usr/bin/env bash
# Lifecycle of the lab.
#   scripts/lab.sh up      keys + secrets if missing, compose up --build, playbook
#   scripts/lab.sh check   playbook again; fails if anything changed (idempotency)
#   scripts/lab.sh down    stop, keep volumes
#   scripts/lab.sh reset   DESTRUCTIVE: stop and drop volumes
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The lab subnet is 172.<LAB_NET>.0.0/16. A runner or a laptop may already use
# 172.18 (Docker hands bridge networks out from 172.17 upwards), so the octet
# is chosen once, written to .lab_net, and rendered into the inventory.
pick_net() {
  if [[ -f .lab_net ]]; then LAB_NET="$(cat .lab_net)"; return; fi
  local used n
  used="$(docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -oE '^172\.[0-9]+' | sort -u)"
  for n in 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    grep -qx "172.$n" <<<"$used" || { LAB_NET="$n"; break; }
  done
  [[ -n "${LAB_NET:-}" ]] || { echo "ERROR: no free 172.x/16 between 18 and 31" >&2; exit 1; }
  printf '%s\n' "$LAB_NET" > .lab_net
}
pick_net; export LAB_NET
sed "s/@NET@/$LAB_NET/g" inventory.ini.tpl > inventory.ini

SSH_PUBKEY="$(cat .ssh/lab_ed25519.pub 2>/dev/null || echo none)"
export SSH_PUBKEY

keys() {
  mkdir -p .ssh
  [[ -f .ssh/lab_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C lab-control -f .ssh/lab_ed25519
  [[ -f .ssh/pgbackrest_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C pgbackrest-mesh -f .ssh/pgbackrest_ed25519
  chmod 0600 .ssh/*_ed25519
}

# Secrets are generated once and stored vault-encrypted; the vault password is
# the only clear-text secret on the control node and is gitignored too.
SECRETS=group_vars/all/secrets.yml
SECRET_KEYS=(pg_superuser_password pg_replication_password patroni_restapi_password pgbouncer_auth_password)

# ansible.cfg names the vault password file, so vault commands need no flag
# (a flag on top of it creates two "default" vault ids and encrypt refuses).
secrets() {
  umask 077
  [[ -f .vault_pass ]] || openssl rand -hex 32 > .vault_pass
  [[ -f "$SECRETS" ]] || printf -- '---\n' > "$SECRETS"
  local plain key
  if head -c 14 "$SECRETS" | grep -q ANSIBLE_VAULT; then plain="$(ansible-vault view "$SECRETS")"; else plain="$(cat "$SECRETS")"; fi
  # Every key the roles need, generated once; a key added later is appended.
  for key in "${SECRET_KEYS[@]}"; do
    grep -q "^${key}:" <<<"$plain" || plain+=$'\n'"${key}: \"$(openssl rand -base64 24)\""
  done
  printf '%s\n' "$plain" > "$SECRETS"
  ansible-vault encrypt "$SECRETS" >/dev/null
  echo ">>> $SECRETS: ${#SECRET_KEYS[@]} keys, vault-encrypted (gitignored)"
}

case "${1:-}" in
  up)
    keys; secrets
    SSH_PUBKEY="$(cat .ssh/lab_ed25519.pub)"
    export SSH_PUBKEY
    docker compose up -d --build
    # systemd as PID 1 can fail to start (cgroup scope on a tired WSL); a node
    # that is not Up must stop the run here, not as "unreachable" from Ansible.
    sleep 3
    down="$(docker compose ps --format '{{.Name}} {{.State}}' | grep -v ' running$' || true)"
    [[ -z "$down" ]] || { printf 'ERROR: not running:\n%s\n' "$down" >&2; exit 1; }
    for _ in $(seq 1 30); do timeout 2 bash -c "echo >/dev/tcp/172.$LAB_NET.0.5/22" 2>/dev/null && break; sleep 2; done
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
