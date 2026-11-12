// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {DeployHookBase} from "./DeployHookBase.sol";

/// @notice Deploys VolatilityFeeHook with CREATE2 at the mined address. See DeployHookBase for every check.
///
/// NOT AUDITED. Run only against a local fork so far (script/verify-deploy-local.sh). Testnet / mainnet
/// deployment needs the project owner's approval and is done by the project owner in person.
/// VolatilityFeeHook has had internal AI-agent reviews only, NO external audit: do not use with mainnet funds.
///
///   # dry run (simulation only, nothing is sent, no signer needed):
///   forge script script/DeployVolatilityFeeHook.s.sol --rpc-url <rpc of Base or Base Sepolia>
///   # real run, by the project owner only - keystore or hardware wallet, never --private-key:
///   forge script script/DeployVolatilityFeeHook.s.sol --rpc-url <rpc> --account <keystore name> --broadcast
///   forge script script/DeployVolatilityFeeHook.s.sol --rpc-url <rpc> --ledger --broadcast
///
/// The PoolManager is chosen by chain id (8453, 84532); any other chain reverts with UnsupportedChain.
contract DeployVolatilityFeeHook is DeployHookBase {
    function _name() internal pure override returns (string memory) {
        return "VolatilityFeeHook";
    }

    function _creationCode() internal pure override returns (bytes memory) {
        return type(VolatilityFeeHook).creationCode;
    }

    function _create2(address poolManager, bytes32 salt) internal override returns (address) {
        return address(new VolatilityFeeHook{salt: salt}(IPoolManager(poolManager)));
    }
}
