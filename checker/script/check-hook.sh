#!/usr/bin/env bash
# Hook checker, command line. Local fork simulation only: read-only towards the RPC, nothing is signed
# or broadcast, no key is needed or read.
#
#   checker/script/check-hook.sh <hook address> [report name]
#
# The report is printed; with a report name it is also written to checker/reports-local/<name>.md
# (git-ignored; the profile used here cannot write anywhere else).
#
# Env (all optional, see checker/test/CheckHook.t.sol):
#   CHECK_RPC_URL (default: $BASE_RPC_URL, then https://mainnet.base.org), CHECK_FORK_BLOCK,
#   POOL_MANAGER (REQUIRED on any chain other than Base / Base Sepolia), POOL_CURRENCY0, POOL_CURRENCY1,
#   POOL_FEE, POOL_TICK_SPACING, CHECK_NATIVE, CHECK_STRICT
#
# An RPC URL with an API key in it is a secret in the environment. When the hook is somebody else's code,
# use a keyless public endpoint and keep every other secret out of the environment.
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "usage: $0 <hook address> [report name]" >&2
  exit 2
fi
cd "$(dirname "$0")/../.."
FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
export FOUNDRY_PROFILE=checker-run
export HOOK="$1"
export CHECK_RPC_URL="${CHECK_RPC_URL:-${BASE_RPC_URL:-https://mainnet.base.org}}"
if [ $# -ge 2 ]; then
  export CHECK_REPORT="$2"
  mkdir -p checker/reports-local
fi
exec "$FORGE" test --match-contract '^CheckHook$' -vv
