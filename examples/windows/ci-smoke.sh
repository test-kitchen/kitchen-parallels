#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $(uname -sm) != 'Darwin arm64' ]]; then
  echo 'The Windows ARM64 smoke test requires an Apple silicon Mac.' >&2
  exit 1
fi

: "${KITCHEN_WINDOWS_BOX_URL:?Set the verified Windows box URL}"
: "${KITCHEN_WINDOWS_BOX_SHA256:?Set the independently verified box SHA-256}"
if [[ $KITCHEN_WINDOWS_BOX_URL != https://* ||
      ! $KITCHEN_WINDOWS_BOX_SHA256 =~ ^[[:xdigit:]]{64}$ ]]; then
  echo 'An HTTPS URL and a pinned SHA-256 are required.' >&2
  exit 1
fi

prlctl --version
config_dir=$(cd -- "$(dirname -- "$0")" && pwd)
export BUNDLE_GEMFILE="$config_dir/../../Gemfile"
scratch=$(mktemp -d)
tunnel_pid=
cleanup() {
  result=$?
  trap - EXIT
  cleanup_failed=0
  if [[ -d .kitchen ]] && ! bundle exec kitchen destroy; then
    echo "Guest cleanup failed. Kitchen state remains in $scratch." >&2
    cleanup_failed=1
  fi
  if [[ -n $tunnel_pid ]]; then
    kill "$tunnel_pid" 2>/dev/null || true
  fi
  if ((cleanup_failed)); then
    exit 1
  fi
  cd "$config_dir"
  rm -rf -- "$scratch"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$scratch"
cp "$config_dir/kitchen.yml" .
export KITCHEN_SMOKE_EXPECT_ARM64=1
curl --fail --silent --show-error --location --max-redirs 5 --retry 2 \
  --proto '=https' --proto-redir '=https' --output guest.box "$KITCHEN_WINDOWS_BOX_URL"
printf '%s  guest.box\n' "$KITCHEN_WINDOWS_BOX_SHA256" | shasum --algorithm 256 --check
# BSD tar accepts the archive member with or without the leading ./.
tar -xOf guest.box metadata.json | ruby -rjson -e \
  'abort "Unexpected box provider" unless JSON.parse(STDIN.read).fetch("provider") == ARGV.fetch(0)' parallels

: "${KITCHEN_WINRM_CLIENT_CERT_PEM:?Set the guest WinRM client certificate}"
: "${KITCHEN_WINRM_CLIENT_KEY_PEM:?Set the guest WinRM client key}"
: "${KITCHEN_WINRM_CA_PEM:?Set the WinRM server CA}"
: "${KITCHEN_SSH_KEY_PEM:?Set the SSH forwarding key}"
: "${KITCHEN_SSH_HOST_PUBLIC_KEY:?Set the verified SSH server public key}"
: "${KITCHEN_SSH_USERNAME:?Set the SSH forwarding account}"
export KITCHEN_PARALLELS_WINDOWS_BOX="$scratch/guest.box"
export KITCHEN_WINRM_CLIENT_CERT="$scratch/client.pem"
export KITCHEN_WINRM_CLIENT_KEY="$scratch/client-key.pem"
export SSL_CERT_FILE="$scratch/ca.pem"
printf '%s\n' "$KITCHEN_WINRM_CLIENT_CERT_PEM" > "$KITCHEN_WINRM_CLIENT_CERT"
printf '%s\n' "$KITCHEN_WINRM_CLIENT_KEY_PEM" > "$KITCHEN_WINRM_CLIENT_KEY"
printf '%s\n' "$KITCHEN_WINRM_CA_PEM" > "$SSL_CERT_FILE"
printf '%s\n' "$KITCHEN_SSH_KEY_PEM" > ssh-key
printf 'kitchen-winrm-guest %s\n' "$KITCHEN_SSH_HOST_PUBLIC_KEY" > known-hosts
unset KITCHEN_WINRM_CLIENT_KEY_PEM KITCHEN_SSH_KEY_PEM

if KITCHEN_WINRM_PROBE=1 bundle exec kitchen create > rejection.log 2>&1; then
  echo 'WinRM unexpectedly worked without the SSH tunnel.' >&2
  exit 1
fi
guest_ip=$(sed -En 's/.*WinRM expects a loopback tunnel at 127\.0\.0\.1:15986 for Parallels guest ([0-9.]+).*/\1/p' rejection.log)
if [[ ! $guest_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
   ! grep -Eqi 'connection refused|ECONNREFUSED' rejection.log; then
  echo 'The closed-tunnel probe failed before the expected WinRM connection refusal.' >&2
  cat rejection.log >&2
  exit 1
fi
echo 'WinRM could not connect without the loopback tunnel.'
ssh -N -F /dev/null -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=yes -o HostKeyAlias=kitchen-winrm-guest \
  -o "UserKnownHostsFile=$scratch/known-hosts" -o IdentitiesOnly=yes -i "$scratch/ssh-key" \
  -L 127.0.0.1:15986:127.0.0.1:5986 -l "$KITCHEN_SSH_USERNAME" "$guest_ip" &
tunnel_pid=$!
bundle exec kitchen create

bundle exec kitchen converge
bundle exec kitchen verify
# The EXIT trap always destroys the Kitchen instance and propagates cleanup failures.
