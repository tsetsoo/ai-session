#!/usr/bin/env bash
# Install the AI Session Remote Ed25519 pubkey on Tailscale hosts and verify key auth.
set -euo pipefail

KEY="${HOME}/.ssh/id_ed25519_aisession"
PUB="${KEY}.pub"
LOGIN_KEY="${HOME}/.ssh/id_ed25519"

if [[ ! -f "$KEY" || ! -f "$PUB" ]]; then
  echo "Missing key pair: $KEY / $PUB" >&2
  echo "Generate with: ssh-keygen -t ed25519 -f $KEY -N \"\"" >&2
  exit 1
fi

HOSTS=(
  "tsetso@100.107.204.56"            # codbexs-macbook-pro
  "tsvetelinpantev@100.94.164.63"    # spreads-macbook-pro
  "pi@100.118.255.23"                # raspberrypi
)

PUBKEY="$(tr -d '\n\r' < "$PUB")"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/known_hosts"
chmod 600 "${HOME}/.ssh/known_hosts"

echo "Priming known_hosts for Tailscale IPs…"
for h in "${HOSTS[@]}"; do
  host_only="${h##*@}"
  echo "—— ssh-keyscan → $host_only"
  ssh-keyscan -T 5 "$host_only" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || {
    echo "WARN: could not scan $host_only (host offline?)" >&2
  }
done

install_pubkey() {
  local h="$1"
  local auth_key="$2"
  ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -i "$auth_key" \
    "$h" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$PUBKEY' ~/.ssh/authorized_keys || echo '$PUBKEY' >> ~/.ssh/authorized_keys"
}

echo
echo "Installing phone public key on hosts…"
need_password=()
installed=()
for h in "${HOSTS[@]}"; do
  echo "—— install → $h"
  if [[ -f "$LOGIN_KEY" ]] && install_pubkey "$h" "$LOGIN_KEY"; then
    echo "   installed via $LOGIN_KEY"
    installed+=("$h")
  elif install_pubkey "$h" "$KEY"; then
    echo "   already authorized with phone key"
    installed+=("$h")
  else
    echo "   no non-interactive key auth — will need a password in your terminal"
    need_password+=("$h")
  fi
done

if ((${#need_password[@]})); then
  echo
  echo "Hosts that need a one-time password (run these yourself in Terminal):"
  for h in "${need_password[@]}"; do
    cat <<EOF
  ssh-copy-id -o IdentitiesOnly=yes -i "$PUB" "$h"
EOF
  done
fi

echo
echo "Verifying phone key auth…"
failed=0
for h in "${HOSTS[@]}"; do
  echo "—— ssh -i aisession → $h"
  if ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "$KEY" "$h" \
      'echo ok && (command -v tmux || echo "tmux: not in PATH")'; then
    :
  else
    echo "FAILED: $h" >&2
    failed=1
  fi
done

echo
pbcopy < "$KEY"
echo "Private key copied to clipboard — paste into each new host in the app."

if [[ "$failed" -ne 0 ]]; then
  echo
  echo "Not all hosts verify yet. Finish the password installs above, then re-run:" >&2
  echo "  $0" >&2
  exit 1
fi

echo "Done — all hosts accept the phone key."
