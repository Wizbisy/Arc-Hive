// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {JobManager} from "src/JobManager.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";
import {BidBoard} from "src/BidBoard.sol";

/// @title ArcHive Deploy
/// @notice Deploys the ArcHive contracts
contract DeployScript is Script {
    uint256 internal constant MAX_PLATFORM_FEE_BPS = 500;
    uint256 internal constant MAX_DISPUTE_DELAY = 7 days;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address usdc = vm.envAddress("USDC_ADDRESS");
        address ownerAddress = vm.envOr("OWNER_ADDRESS", deployer);
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", block.chainid);
        uint256 platformFeeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(50));
        uint256 disputeDelay = vm.envOr(
            "DISPUTE_RESOLUTION_DELAY",
            uint256(1 hours)
        );
        uint256 minimumBidScore = vm.envOr("MIN_BID_SCORE", uint256(0));
        address arcIdentityRegistry = vm.envOr(
            "ARC_IDENTITY_REGISTRY",
            0x8004A818BFB912233c491871b3d84c89A494BD9e
        );
        bool transferOwnershipToOwnerAddress = vm.envOr(
            "TRANSFER_OWNERSHIP",
            false
        );

        require(deployerKey != 0, "PRIVATE_KEY missing");
        require(ownerAddress != address(0), "OWNER_ADDRESS is zero");
        require(usdc != address(0), "USDC_ADDRESS is zero");
        require(usdc.code.length > 0, "USDC_ADDRESS has no code");
        require(block.chainid == expectedChainId, "Unexpected chain id");
        require(
            platformFeeBps <= MAX_PLATFORM_FEE_BPS,
            "PLATFORM_FEE_BPS too high"
        );
        require(
            disputeDelay <= MAX_DISPUTE_DELAY,
            "DISPUTE_RESOLUTION_DELAY too high"
        );

        console2.log("========================================");
        console2.log(" ArcHive deployment starting");
        console2.log(" chainId:", block.chainid);
        console2.log(" deployer:", deployer);
        console2.log(
            string.concat(
                " deployer USDC: ",
                _formatNativeAmount(deployer.balance),
                " USDC"
            )
        );
        console2.log(" owner:", ownerAddress);
        console2.log(" usdc:", usdc);
        console2.log(" arcIdentityRegistry:", arcIdentityRegistry);
        console2.log("========================================");

        vm.startBroadcast(deployerKey);

        MarketplaceRegistry registry = new MarketplaceRegistry();
        ReputationOracle reputation = new ReputationOracle();
        JobEscrow escrow = new JobEscrow(usdc);
        JobManager manager = new JobManager(
            address(registry),
            address(escrow),
            address(reputation),
            arcIdentityRegistry
        );
        BidBoard bidBoard = new BidBoard(
            address(manager),
            address(registry),
            address(reputation)
        );

        manager.setPlatformFee(platformFeeBps);
        manager.setDisputeResolutionDelay(disputeDelay);
        manager.setBidBoard(address(bidBoard));

        escrow.setManager(address(manager));
        reputation.setManager(address(manager));
        reputation.setMinimumScoreForBidding(minimumBidScore);

        require(address(registry) != address(0), "registry deploy failed");
        require(address(reputation) != address(0), "reputation deploy failed");
        require(address(escrow) != address(0), "escrow deploy failed");
        require(address(manager) != address(0), "manager deploy failed");
        require(address(bidBoard) != address(0), "bidBoard deploy failed");

        require(
            manager.bidBoard() == address(bidBoard),
            "manager bidBoard mismatch"
        );
        require(
            address(escrow.manager()) == address(manager),
            "escrow manager mismatch"
        );
        require(
            address(reputation.manager()) == address(manager),
            "reputation manager mismatch"
        );
        require(
            manager.platformFeeBps() == platformFeeBps,
            "platform fee mismatch"
        );
        require(
            manager.disputeResolutionDelay() == disputeDelay,
            "dispute delay mismatch"
        );
        require(
            reputation.minimumScoreForBidding() == minimumBidScore,
            "minimum score mismatch"
        );

        if (transferOwnershipToOwnerAddress && ownerAddress != deployer) {
            registry.transferOwnership(ownerAddress);
            reputation.transferOwnership(ownerAddress);
            escrow.transferOwnership(ownerAddress);
            manager.transferOwnership(ownerAddress);

            require(
                registry.pendingOwner() == ownerAddress,
                "registry pendingOwner mismatch"
            );
            require(
                reputation.pendingOwner() == ownerAddress,
                "reputation pendingOwner mismatch"
            );
            require(
                escrow.pendingOwner() == ownerAddress,
                "escrow pendingOwner mismatch"
            );
            require(
                manager.pendingOwner() == ownerAddress,
                "manager pendingOwner mismatch"
            );
        }

        vm.stopBroadcast();

        console2.log("========================================");
        console2.log(" ArcHive deployment complete");
        console2.log("========================================");
        console2.log("MarketplaceRegistry:    ", address(registry));
        console2.log("ReputationOracle: ", address(reputation));
        console2.log("JobEscrow:        ", address(escrow));
        console2.log("JobManager:       ", address(manager));
        console2.log("BidBoard:         ", address(bidBoard));
        console2.log("USDC Token:       ", usdc);
        console2.log(
            "Note: Forge gas report shows native unit label as ETH; on Arc this is USDC-native gas accounting."
        );
        console2.log("Platform Fee BPS: ", manager.platformFeeBps());
        console2.log("Dispute Delay:    ", manager.disputeResolutionDelay());
        console2.log("Min Bid Score:    ", reputation.minimumScoreForBidding());
        console2.log("Owner (current):  ", manager.owner());
        console2.log("Owner (pending):  ", manager.pendingOwner());
        console2.log("========================================");

        if (transferOwnershipToOwnerAddress && ownerAddress != deployer) {
            console2.log("Ownership transfer initiated for core contracts.");
            console2.log(
                "New owner must call acceptOwnership() on each contract."
            );
        }
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
