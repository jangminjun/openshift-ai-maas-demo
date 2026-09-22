HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HARNESS_DIR}/state"

log()  { printf '\033[1;34m[maas-harness]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[maas-harness:error]\033[0m %s\n' "$*" >&2; exit 1; }

ssh_bastion() {
  ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -i "$SSH_KEY_PATH" "ec2-user@${BASTION_IP}" "$@"
}

scp_to_bastion() {
  scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$1" "ec2-user@${BASTION_IP}:$2"
}

# save_state <file-basename> <KEY> <VALUE> -- upserts into harness/state/<file-basename>,
# e.g. save_state keycloak-users.env KEYCLOAK_USER_BASIC_PASSWORD 'abc123'
save_state() {
  local file="${STATE_DIR}/$1" key="$2" value="$3"
  mkdir -p "$STATE_DIR"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    echo "${key}=${value}" >> "$file"
  fi
}
