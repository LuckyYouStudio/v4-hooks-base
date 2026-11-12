#!/usr/bin/env bash
# Runs both deployment scripts end to end against a LOCAL anvil that forks Base mainnet, then reads the
# result back with cast. Nothing leaves this machine except read-only RPC calls to the fork source.
#
# NOT AUDITED. Local verification only. The broadcast target is http://127.0.0.1:<port>, and before
# anything is sent the script checks that (1) ANVIL_PORT is a plain number in 1..65535, so the URL cannot
# be turned into another host, (2) nothing is listening on that port yet, (3) the anvil process it started
# is alive, and (4) the node answering on that port answers `anvil_nodeInfo` and reports chain id 8453.
# The transactions are sent by an anvil dev account through --unlocked (eth_sendTransaction; no key is
# read, typed or stored). Testnet / mainnet deployment needs the project owner's approval and is done by
# the project owner in person, with a keystore or a hardware wallet.
#
#   script/verify-deploy-local.sh
# Env:
#   BASE_RPC_URL   fork source, read-only (default https://mainnet.base.org; do not use a keyed URL here
#                  unless you accept it being visible in your process list)
#   FORK_BLOCK     block to fork at (default: latest)
#   ANVIL_PORT     local port, digits only (default 8547)
#
# The local fork has chain id 8453, so forge files its run records under broadcast/Deploy<Hook>.s.sol/8453/,
# the same place a dry run or a real run against Base mainnet uses (a dry run without --broadcast leaves
# .../8453/dry-run/). If that directory exists this script refuses to run, so that it can neither mix
# its records with yours nor delete yours: move or delete broadcast/Deploy<Hook>.s.sol/8453 first.
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
PORT="${ANVIL_PORT:-8547}"
# Digits only. Anything else (for example a value with an '@' in it, which a URL parser reads as
# user info followed by another host)
# is refused here, before any process is started and before any request is made.
case "$PORT" in
  '' | *[!0-9]*) echo "ANVIL_PORT must be a number (got '$PORT'); refusing" >&2; exit 1 ;;
esac
if [ "${#PORT}" -gt 5 ] || [ "$((10#$PORT))" -lt 1 ] || [ "$((10#$PORT))" -gt 65535 ]; then
  echo "ANVIL_PORT must be in 1..65535 (got '$PORT'); refusing" >&2; exit 1
fi
PORT="$((10#$PORT))"
LOCAL="http://127.0.0.1:${PORT}"
# anvil's first dev account (public, well known). Used unlocked on the local node only.
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b

BLOCK_ARGS=()
if [ -n "${FORK_BLOCK:-}" ]; then BLOCK_ARGS=(--fork-block-number "$FORK_BLOCK"); fi

# Refuse before starting anything if a previous forge run left records where ours would go.
for name in VolatilityFeeHook PriorityFeeHook; do
  rec="broadcast/Deploy${name}.s.sol/8453"
  [ ! -e "$rec" ] || { echo "refusing to run: $rec already exists (move it away first)" >&2; exit 1; }
done

# Refuse if anything already listens on the port: this script must only ever talk to the anvil it starts
# itself. First a bare TCP connect to 127.0.0.1 (no request is sent), then a JSON-RPC probe.
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "something already listens on 127.0.0.1:${PORT}; refusing (set ANVIL_PORT to a free port)" >&2; exit 1
fi
if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then
  echo "something already answers on $LOCAL; refusing (set ANVIL_PORT to a free port)" >&2; exit 1
fi

anvil --fork-url "$FORK_URL" ${BLOCK_ARGS[@]+"${BLOCK_ARGS[@]}"} --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true; wait "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  kill -0 "$ANVIL_PID" 2>/dev/null || break
  if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
# The node on the port must be the anvil started above: our process is alive, and the peer speaks anvil.
kill -0 "$ANVIL_PID" 2>/dev/null || { echo "anvil did not start (or exited); refusing" >&2; exit 1; }
cast rpc anvil_nodeInfo --rpc-url "$LOCAL" >/dev/null 2>&1 || { echo "$LOCAL is not an anvil node; refusing" >&2; exit 1; }
kill -0 "$ANVIL_PID" 2>/dev/null || { echo "anvil exited; refusing" >&2; exit 1; }
CHAIN_ID=$(cast chain-id --rpc-url "$LOCAL")
[ "$CHAIN_ID" = "8453" ] || { echo "local fork reports chain id $CHAIN_ID, expected 8453" >&2; exit 1; }
echo "local anvil fork of Base at block $(cast block-number --rpc-url "$LOCAL") ($LOCAL)"

check() { # name, expected address
  local name="$1" addr="$2"
  # forge records every broadcast under broadcast/<script>/<chain id>/. The local fork has chain id 8453,
  # so its records would look like Base mainnet records. Refuse to mix with existing ones, and remove
  # ours afterwards.
  local rec="broadcast/Deploy${name}.s.sol/8453"
  [ ! -e "$rec" ] || { echo "refusing to run: $rec already exists (move it away first)" >&2; exit 1; }
  forge script "script/Deploy${name}.s.sol" --rpc-url "$LOCAL" --broadcast --unlocked --sender "$SENDER" \
    >"cache/verify-deploy-${name}.log" 2>&1 || { cat "cache/verify-deploy-${name}.log"; exit 1; }
  grep -A6 "^  ${name}\$" "cache/verify-deploy-${name}.log" || true
  local code pm low
  code=$(cast code "$addr" --rpc-url "$LOCAL")
  [ "${#code}" -gt 2 ] || { echo "FAIL: no code at $addr" >&2; exit 1; }
  pm=$(cast call "$addr" 'poolManager()(address)' --rpc-url "$LOCAL")
  [ "$pm" = "$POOL_MANAGER" ] || { echo "FAIL: poolManager() = $pm" >&2; exit 1; }
  low=$(( 0x${addr: -4} & 0x3fff ))
  [ "$low" -eq $((0x1080)) ] || { echo "FAIL: low 14 bits = $low" >&2; exit 1; }
  echo "OK ${name}: code $(( (${#code} - 2) / 2 )) bytes at ${addr}, poolManager() = ${pm}, low 14 bits = 0x1080"
  # a second run must refuse (AlreadyDeployed) instead of deploying a copy at the next salt
  if forge script "script/Deploy${name}.s.sol" --rpc-url "$LOCAL" --broadcast --unlocked --sender "$SENDER" \
    >"cache/verify-deploy-${name}-2.log" 2>&1; then
    echo "FAIL: second run of Deploy${name} did not revert" >&2; exit 1
  fi
  grep -q "AlreadyDeployed" "cache/verify-deploy-${name}-2.log" || { cat "cache/verify-deploy-${name}-2.log"; exit 1; }
  echo "OK ${name}: second run refused with AlreadyDeployed"
  rm -rf "$rec"
  rmdir "broadcast/Deploy${name}.s.sol" broadcast 2>/dev/null || true
}
mkdir -p cache
check VolatilityFeeHook 0x4B7651999822ba687E96bbaE929A41f7E0AB9080
check PriorityFeeHook   0xBeb0026Aa9eF43478b921106D56Ebc7b1eD75080
echo "done: both hooks deployed on the LOCAL fork only; nothing was sent to a public network"
