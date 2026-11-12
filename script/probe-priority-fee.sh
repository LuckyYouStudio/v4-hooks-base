#!/usr/bin/env bash
# Read-only check against a real node: what do GASPRICE and BASEFEE report to a contract, and what LP
# fee would PriorityFeeHook charge? Sends eth_call requests only (no transaction, no key).
#
#   BASE_RPC_URL=https://mainnet.base.org script/probe-priority-fee.sh
#
# Each line prints: case, tx.gasprice, block.basefee, lpFee (pips).
set -euo pipefail
cd "$(dirname "$0")/.."
FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
CAST="${CAST:-$(command -v cast || echo "$HOME/.foundry/bin/cast")}"
RPC="${BASE_RPC_URL:?set BASE_RPC_URL}"
# an address with a large ETH balance, so that the node accepts any fee fields (WETH predeploy on Base)
FROM="${PROBE_FROM:-0x4200000000000000000000000000000000000006}"
CODE="$("$FORGE" inspect script/PriorityFeeProbe.sol:PriorityFeeProbe bytecode)"

probe() { # name, extra JSON fields
  local res
  res="$(curl -s "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"from\":\"$FROM\",\"data\":\"$CODE\"$2},\"latest\"]}")"
  local hex
  hex="$(printf '%s' "$res" | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  if [ -z "$hex" ]; then echo "$1: ERROR $res"; return; fi
  echo "$1: $("$CAST" abi-decode 'f()(uint256,uint256,uint24)' "$hex" | tr '\n' ' ')"
}

echo "block: $("$CAST" block-number --rpc-url "$RPC"), client: $("$CAST" client --rpc-url "$RPC")"
# the researcher's raw probe (docs/research/base-priority-ordering-for-hooks.md 2.3): returns GASPRICE, BASEFEE
raw() {
  curl -s "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"from\":\"$FROM\",\"data\":\"0x3a5f524860205260405ff3\"$1},\"latest\"]}"
  echo
}
echo "raw GASPRICE/BASEFEE, no fee fields: $(raw "")"
probe "no fee fields (plain eth_call, as Quoter calls are made)" ""
probe "type-2, maxPriorityFee 1,000,000 (node suggestion)      " ",\"maxFeePerGas\":\"0x3b9aca00\",\"maxPriorityFeePerGas\":\"0xf4240\""
probe "type-2, maxPriorityFee 20,000,000 (the allowance)       " ",\"maxFeePerGas\":\"0x3b9aca00\",\"maxPriorityFeePerGas\":\"0x1312d00\""
probe "type-2, maxPriorityFee 20,400,000 (first pip)           " ",\"maxFeePerGas\":\"0x3b9aca00\",\"maxPriorityFeePerGas\":\"0x1374780\""
probe "type-2, maxPriorityFee 100,000,000 (0.1 gwei)           " ",\"maxFeePerGas\":\"0x3b9aca00\",\"maxPriorityFeePerGas\":\"0x5f5e100\""
probe "type-2, maxPriorityFee 1,020,000,000, maxFee 10 gwei    " ",\"maxFeePerGas\":\"0x2540be400\",\"maxPriorityFeePerGas\":\"0x3ccbf700\""
probe "type-2, maxPriorityFee 26,000,000 = maxFee (maxFee binds)" ",\"maxFeePerGas\":\"0x18cba80\",\"maxPriorityFeePerGas\":\"0x18cba80\""
probe "legacy, gasPrice 60,000,000                             " ",\"gasPrice\":\"0x3938700\""
probe "legacy, gasPrice 1 (BELOW the base fee)                 " ",\"gasPrice\":\"0x1\""
