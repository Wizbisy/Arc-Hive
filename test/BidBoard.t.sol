// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {JobManager} from "src/JobManager.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";
import {BidBoard} from "src/BidBoard.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract BidBoardTest is Test {
    MarketplaceRegistry internal registry;
    JobEscrow internal escrow;
    JobManager internal manager;
    ReputationOracle internal reputation;
    BidBoard internal bidBoard;
    MockUSDC internal usdc;

    address internal client = makeAddr("client");
    address internal worker1 = makeAddr("worker1");
    address internal worker2 = makeAddr("worker2");
    address internal worker3 = makeAddr("worker3");
    address internal evaluator = makeAddr("evaluator");

    uint256 internal constant PAYMENT = 200e6;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MarketplaceRegistry();
        escrow = new JobEscrow(address(usdc));
        reputation = new ReputationOracle();
        manager = new JobManager(
            address(registry),
            address(escrow),
            address(reputation),
            address(0)
        );
        bidBoard = new BidBoard(
            address(manager),
            address(registry),
            address(reputation)
        );

        manager.setBidBoard(address(bidBoard));

        escrow.setManager(address(manager));
        reputation.setManager(address(manager));

        usdc.mint(client, 10_000e6);

        vm.prank(client);
        registry.registerAgent("https://client.example", "ipfs://client");

        vm.prank(worker1);
        registry.registerAgent("https://worker1.example", "ipfs://worker1");

        vm.prank(worker2);
        registry.registerAgent("https://worker2.example", "ipfs://worker2");

        vm.prank(worker3);
        registry.registerAgent("https://worker3.example", "ipfs://worker3");

        vm.prank(evaluator);
        registry.registerAgent("https://eval.example", "ipfs://eval");

        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testPostBidStoresBidCorrectly() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("portfolio://worker1-logos")
        );

        BidBoard.Bid memory bid = bidBoard.getBid(jobId, worker1);
        assertEq(bid.bidder, worker1);
        assertEq(bid.price, 180e6);
        assertFalse(bid.accepted);
        assertEq(bidBoard.getBidCount(jobId), 1);
    }

    function testMultipleBidsClientSelectsBest() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("proof1")
        );

        vm.prank(worker2);
        bidBoard.postBid(
            jobId,
            150e6,
            uint64(block.timestamp + 2 days),
            keccak256("proof2")
        );

        vm.prank(worker3);
        bidBoard.postBid(
            jobId,
            190e6,
            uint64(block.timestamp + 1 days),
            keccak256("proof3")
        );

        assertEq(bidBoard.getBidCount(jobId), 3);

        vm.prank(client);
        bidBoard.acceptBid(jobId, worker2);

        BidBoard.Bid memory accepted = bidBoard.getBid(jobId, worker2);
        assertTrue(accepted.accepted);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(job.worker, worker2);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Claimed));

        BidBoard.Bid memory notAccepted = bidBoard.getBid(jobId, worker1);
        assertFalse(notAccepted.accepted);
    }

    function testSlashedAgentCannotBid() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(reputation.owner());
        reputation.slash(worker1, 10e6, "spam behavior");

        vm.prank(worker1);
        vm.expectRevert(BidBoard.AgentSlashed.selector);
        bidBoard.postBid(
            jobId,
            150e6,
            uint64(block.timestamp + 3 days),
            keccak256("proof")
        );
    }

    function testCannotBidOwnJob() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(client);
        vm.expectRevert(BidBoard.CannotBidOwnJob.selector);
        bidBoard.postBid(
            jobId,
            150e6,
            uint64(block.timestamp + 3 days),
            keccak256("proof")
        );
    }

    function testCannotBidTwice() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("proof")
        );

        vm.prank(worker1);
        vm.expectRevert(BidBoard.AlreadyBid.selector);
        bidBoard.postBid(
            jobId,
            170e6,
            uint64(block.timestamp + 2 days),
            keccak256("proof2")
        );
    }

    function testOnlyClientOrEvaluatorCanAcceptBid() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("proof")
        );

        vm.prank(worker2);
        vm.expectRevert(BidBoard.NotClientOrEvaluator.selector);
        bidBoard.acceptBid(jobId, worker1);

        vm.prank(evaluator);
        bidBoard.acceptBid(jobId, worker1);
    }

    function testCannotAcceptBidTwice() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("p1")
        );

        vm.prank(worker2);
        bidBoard.postBid(
            jobId,
            170e6,
            uint64(block.timestamp + 2 days),
            keccak256("p2")
        );

        vm.prank(client);
        bidBoard.acceptBid(jobId, worker1);

        vm.prank(client);
        vm.expectRevert(BidBoard.BidAlreadyAccepted.selector);
        bidBoard.acceptBid(jobId, worker2);
    }

    function testGetBidsReturnsAllBids() public {
        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("p1")
        );

        vm.prank(worker2);
        bidBoard.postBid(
            jobId,
            170e6,
            uint64(block.timestamp + 2 days),
            keccak256("p2")
        );

        BidBoard.Bid[] memory allBids = bidBoard.getBids(jobId);
        assertEq(allBids.length, 2);
        assertEq(allBids[0].bidder, worker1);
        assertEq(allBids[1].bidder, worker2);
    }

    function testMinimumReputationEnforced() public {
        vm.prank(reputation.owner());
        reputation.setMinimumScoreForBidding(1000);

        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        vm.expectRevert(BidBoard.BelowMinimumReputation.selector);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("p")
        );
    }

    function testPostBidNonBiddableReverts() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker1);
        vm.expectRevert(BidBoard.JobNotBiddable.selector);
        bidBoard.postBid(
            jobId,
            180e6,
            uint64(block.timestamp + 3 days),
            keccak256("p")
        );
    }

    function testAcceptBidNonBiddableReverts() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(client);
        vm.expectRevert(BidBoard.JobNotBiddable.selector);
        bidBoard.acceptBid(jobId, worker1);
    }
}
