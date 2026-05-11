// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

contract PredeployCheckScript is Script {
    uint256 internal constant MAX_PLATFORM_FEE_BPS = 500;
    uint256 internal constant MAX_DISPUTE_DELAY = 7 days;

    function run() external view {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address ownerAddress = vm.envOr("OWNER_ADDRESS", deployer);
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        uint256 platformFeeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(50));
        uint256 disputeDelay = vm.envOr(
            "DISPUTE_RESOLUTION_DELAY",
            uint256(1 hours)
        );
        uint256 minimumBidScore = vm.envOr("MIN_BID_SCORE", uint256(0));
        bool transferOwnershipToOwnerAddress = vm.envOr(
            "TRANSFER_OWNERSHIP",
            false
        );

        require(deployerKey != 0, "PRIVATE_KEY missing");
        require(expectedChainId != 0, "EXPECTED_CHAIN_ID missing/zero");

        require(usdc != address(0), "USDC_ADDRESS is zero");

        require(ownerAddress != address(0), "OWNER_ADDRESS is zero");
        if (transferOwnershipToOwnerAddress) {
            require(
                ownerAddress != deployer,
                "OWNER_ADDRESS must differ when transfer enabled"
            );
        }

        require(
            platformFeeBps <= MAX_PLATFORM_FEE_BPS,
            "PLATFORM_FEE_BPS too high"
        );
        require(
            disputeDelay <= MAX_DISPUTE_DELAY,
            "DISPUTE_RESOLUTION_DELAY too high"
        );

        console2.log("========================================");
        console2.log(" ArcHive predeploy checks: PASS");
        console2.log("========================================");
        console2.log("chainId:          ", block.chainid);
        console2.log("deployer:         ", deployer);
        console2.log(
            string.concat(
                "deployer USDC:    ",
                _formatNativeAmount(deployer.balance),
                " USDC"
            )
        );
        console2.log("owner:            ", ownerAddress);
        console2.log("transferOwnership:", transferOwnershipToOwnerAddress);
        console2.log("usdc:             ", usdc);
        console2.log(
            "note: Forge may label native gas unit as ETH in summaries; Arc uses USDC native gas accounting."
        );
        console2.log("platformFeeBps:   ", platformFeeBps);
        console2.log("disputeDelay(s):  ", disputeDelay);
        console2.log("minBidScore:      ", minimumBidScore);
        console2.log("========================================");
    }

    function _formatNativeAmount(
        uint256 amountWei
    ) internal view returns (string memory) {
        uint256 whole = amountWei / 1e18;
        uint256 frac6 = (amountWei % 1e18) / 1e12;

        return string.concat(vm.toString(whole), ".", _pad6(frac6));
    }

    function _pad6(uint256 value) internal view returns (string memory) {
        if (value < 10) return string.concat("00000", vm.toString(value));
        if (value < 100) return string.concat("0000", vm.toString(value));
        if (value < 1000) return string.concat("000", vm.toString(value));
        if (value < 10000) return string.concat("00", vm.toString(value));
        if (value < 100000) return string.concat("0", vm.toString(value));
        return vm.toString(value);
    }
}
