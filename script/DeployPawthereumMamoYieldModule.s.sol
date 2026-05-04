// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PawthereumMamoYieldModule} from "../src/PawthereumMamoYieldModule.sol";

contract DeployPawthereumMamoYieldModule is Script {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant BASE_META_MORPHO_USDC_VAULT = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;

    function run() external returns (PawthereumMamoYieldModule module) {
        // SAFE must be a Safe contract version >= 1.3.0 (the version that introduced
        // execTransactionFromModuleReturnData, which the module depends on).
        address safe = vm.envAddress("SAFE");
        address mamoStrategy = vm.envAddress("MAMO_STRATEGY");
        uint256 protectedPrincipal = vm.envUint("PROTECTED_PRINCIPAL");
        uint256 executionInterval = vm.envUint("EXECUTION_INTERVAL");
        uint256 minimumClaimAmount = vm.envUint("MIN_CLAIM_AMOUNT");

        address usdc = vm.envOr("USDC", BASE_USDC);
        address mToken = vm.envOr("M_TOKEN", BASE_M_USDC);
        address metaMorphoVault = vm.envOr("META_MORPHO_VAULT", BASE_META_MORPHO_USDC_VAULT);

        // Parallel comma-separated lists. RECIPIENT_BPS values must each be > 0 and the
        // sum must be <= 10_000; the remainder of 10_000 is auto-compounded into principal.
        // Lengths must match. Pass empty strings for both to start with no recipients
        // (100% compound).
        address[] memory addrs = vm.envOr("RECIPIENT_ADDRESSES", ",", new address[](0));
        uint256[] memory bps = vm.envOr("RECIPIENT_BPS", ",", new uint256[](0));
        require(addrs.length == bps.length, "RECIPIENT_ADDRESSES / RECIPIENT_BPS length mismatch");

        PawthereumMamoYieldModule.Recipient[] memory recipients =
            new PawthereumMamoYieldModule.Recipient[](addrs.length);
        for (uint256 i; i < addrs.length; ++i) {
            require(bps[i] <= type(uint16).max, "bps too large for uint16");
            recipients[i] = PawthereumMamoYieldModule.Recipient({addr: addrs[i], bps: uint16(bps[i])});
        }

        vm.startBroadcast();
        module = new PawthereumMamoYieldModule(
            safe,
            mamoStrategy,
            usdc,
            mToken,
            metaMorphoVault,
            recipients,
            protectedPrincipal,
            executionInterval,
            minimumClaimAmount
        );
        vm.stopBroadcast();

        console.log("PawthereumMamoYieldModule deployed at:", address(module));
        console.log("Next step: Safe must call enableModule(", address(module), ") via a Safe transaction");
    }
}
