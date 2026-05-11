// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {JobManager} from "src/JobManager.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract JobManagerTest is Test {
    MarketplaceRegistry internal registry;
    JobEscrow internal escrow;
    JobManager internal manager;
    ReputationOracle internal reputation;
    MockUSDC internal usdc;
    address internal client = makeAddr("client");
    address internal worker = makeAddr("worker");
    address internal evaluator = makeAddr("evaluator");
    uint256 internal constant PAYMENT = 100e6;
    
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
        escrow.setManager(address(manager));
        reputation.setManager(address(manager));

        usdc.mint(client, 10_000e6);

        vm.prank(client);
        registry.registerAgent("https://client.example", "ipfs://client-meta");

        vm.prank(worker);
        registry.registerAgent("https://worker.example", "ipfs://worker-meta");

        vm.prank(evaluator);
        registry.registerAgent(
            "https://evaluator.example",
            "ipfs://evaluator-meta"
            );

        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testSubJobRefundExploitIsBlocked() public {
        address attacker = address(0x222);

        vm.deal(client, 1 ether);
        vm.deal(attacker, 1 ether);

        vm.startPrank(client);
        uint256 parentJobId = manager.createJob(
            bytes32("Web3 Frontend"),
            bytes32("SpecHash123"),
            1000e6,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );
        vm.stopPrank();

        vm.startPrank(attacker);
        registry.registerAgent("attacker.endpoint", "ipfs://metadata");
        manager.claimJob(parentJobId);

        uint256 attackerBalanceBefore = usdc.balanceOf(attacker);
        uint256 parentEscrowBefore = escrow.getJobBalance(parentJobId);

        uint256 childJobId = manager.createSubJob(
            parentJobId,
            bytes32("Sub-task"),
            bytes32("SpecHash456"),
            1000e6,
            uint64(block.timestamp + 6 days),
            evaluator,
            0
        );

        manager.cancelJob(childJobId, "Exploit refund");
        vm.stopPrank();

        uint256 attackerBalanceAfter = usdc.balanceOf(attacker);
        assertEq(
            attackerBalanceAfter,
            attackerBalanceBefore,
            "Attacker should not receive refunded funds"
        );
        assertEq(
            escrow.getJobBalance(parentJobId),
            parentEscrowBefore,
            "Parent job escrow should be restored"
        );
    }

    function testCreateClaimSubmitApproveReleasesPayment() public {
        bytes32 taskType = keccak256("logo_generation");
        bytes32 specHash = keccak256("brand=ShopWave;color=teal");
        uint64 deadline = uint64(block.timestamp + 7 days);

        address originalOwner = manager.owner();

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        assertEq(usdc.balanceOf(address(escrow)), PAYMENT);

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(
            jobId,
            keccak256("ipfs://logo-v1"),
            "ipfs://logo-result-v1"
        );

        vm.prank(evaluator);
        manager.approveJob(jobId);

        uint256 expectedFee = (PAYMENT * 50) / 10_000;
        uint256 expectedWorkerPayment = PAYMENT - expectedFee;

        assertEq(usdc.balanceOf(worker), expectedWorkerPayment);
        assertEq(usdc.balanceOf(originalOwner), expectedFee);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Approved));
    }

    function testCancelSubmittedJobReverts() public {
        bytes32 taskType = keccak256("logo_generation");
        bytes32 specHash = keccak256("brand=ShopWave;color=teal");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("ipfs://logo"), "ipfs://logo");

        vm.prank(client);
        vm.expectRevert(JobManager.JobNotInValidState.selector);
        manager.cancelJob(jobId, "too late");
    }

    function testRequestRevisionAllowsResubmission() public {
        bytes32 taskType = keccak256("logo_generation");
        bytes32 specHash = keccak256("brand=ShopWave");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(
            jobId,
            keccak256("ipfs://logo-v1"),
            "ipfs://logo-v1"
        );

        vm.prank(evaluator);
        manager.requestRevision(jobId, "Color palette needs to be warmer");

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Claimed));
        assertEq(job.revisionCount, 1);

        vm.prank(worker);
        manager.submitResult(
            jobId,
            keccak256("ipfs://logo-v2"),
            "ipfs://logo-v2"
        );

        job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Submitted));

        vm.prank(evaluator);
        manager.approveJob(jobId);

        job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Approved));
    }

    function testMaxRevisionsEnforced() public {
        bytes32 taskType = keccak256("content_writing");
        bytes32 specHash = keccak256("article topic");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            1
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(
            jobId,
            keccak256("ipfs://content-v1"),
            "ipfs://content-v1"
        );

        vm.prank(evaluator);
        manager.requestRevision(jobId, "Needs more depth");

        vm.prank(worker);
        manager.submitResult(
            jobId,
            keccak256("ipfs://content-v2"),
            "ipfs://content-v2"
        );

        vm.prank(evaluator);
        vm.expectRevert(JobManager.MaxRevisionsExceeded.selector);
        manager.requestRevision(jobId, "Still not good enough");
    }

    function testCancelExpiredJobRefundsClient() public {
        bytes32 taskType = keccak256("design_work");
        bytes32 specHash = keccak256("website mockup");
        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        assertEq(usdc.balanceOf(address(escrow)), PAYMENT);

        vm.warp(block.timestamp + 2 days);

        manager.cancelExpiredJob(jobId);

        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(client), 10_000e6);
    }

    function testReputationUpdatedOnApproval() public {
        bytes32 taskType = keccak256("logo_generation");
        bytes32 specHash = keccak256("brand=test");
        uint64 deadline = uint64(block.timestamp + 7 days);

        assertEq(reputation.getScore(worker), 0);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("ipfs://logo"), "ipfs://logo");

        vm.prank(evaluator);
        manager.approveJob(jobId);

        uint256 newScore = reputation.getScore(worker);
        assertGt(newScore, 0);
    }

    function testSlashedAgentCannotClaimJob() public {
        bytes32 taskType = keccak256("logo_generation");
        bytes32 specHash = keccak256("brand=test");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(reputation.owner());
        reputation.slash(worker, 10e6, "spam");

        vm.prank(worker);
        vm.expectRevert(JobManager.Unauthorized.selector);
        manager.claimJob(jobId);
    }

    function testPlatformFeeCalculatedCorrectly() public {
        bytes32 taskType = keccak256("logo");
        bytes32 specHash = keccak256("spec");
        uint64 deadline = uint64(block.timestamp + 7 days);

        address originalOwner = manager.owner();

        manager.setPlatformFee(100);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("ipfs://logo"), "ipfs://logo");

        vm.prank(evaluator);
        manager.approveJob(jobId);

        uint256 expectedFee = (PAYMENT * 100) / 10_000;
        uint256 expectedWorker = PAYMENT - expectedFee;
        assertEq(usdc.balanceOf(worker), expectedWorker);
        assertEq(usdc.balanceOf(originalOwner), expectedFee);
    }

    function testRaiseDisputeChangesStatus() public {
        bytes32 taskType = keccak256("logo");
        bytes32 specHash = keccak256("spec");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("ipfs://logo"), "ipfs://logo");

        vm.prank(client);
        manager.raiseDispute(jobId, "Work does not match spec");

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Disputed));
    }

    function testRaiseDisputeOnApprovedReverts() public {
        bytes32 taskType = keccak256("logo");
        bytes32 specHash = keccak256("spec");
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            taskType,
            specHash,
            PAYMENT,
            deadline,
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("ipfs://logo"), "ipfs://logo");

        vm.prank(evaluator);
        manager.approveJob(jobId);

        vm.prank(client);
        vm.expectRevert(JobManager.JobNotInValidState.selector);
        manager.raiseDispute(jobId, "too late");
    }

    function testZeroPaymentRejected() public {
        bytes32 taskType = keccak256("logo");
        bytes32 specHash = keccak256("spec");
        uint64 deadline = uint64(block.timestamp + 7 days);
        vm.prank(client);
        vm.expectRevert(JobManager.ZeroPayment.selector);
        manager.createJob(taskType, specHash, 0, deadline, evaluator, 2);
    }

    function testBidHijackDirectClaimBlockedOnBiddableJob() public {
        address fakeBidBoard = makeAddr("fakeBidBoard");
        manager.setBidBoard(fakeBidBoard);

        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        assertTrue(manager.isBiddable(jobId));

        vm.prank(worker);
        vm.expectRevert(JobManager.BidOnly.selector);
        manager.claimJob(jobId);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Open));
    }

    function testCreateBiddableJobRequiresBidBoard() public {
        vm.prank(client);
        vm.expectRevert(JobManager.InvalidBidBoard.selector);
        manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );
    }

    function testMarkBiddableOnlyClient() public {
        address fakeBidBoard = makeAddr("fakeBidBoard");
        manager.setBidBoard(fakeBidBoard);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        vm.expectRevert(JobManager.NotAuthorized.selector);
        manager.markBiddable(jobId);
        vm.prank(client);
        manager.markBiddable(jobId);
        assertTrue(manager.isBiddable(jobId));
    }

    function testMarkBiddableRequiresBidBoardSet() public {
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
        vm.expectRevert(JobManager.InvalidBidBoard.selector);
        manager.markBiddable(jobId);
    }

    function testNonBiddableJobStillClaimable() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Claimed));
        assertEq(job.worker, worker);
    }

    function testClaimAcceptedBidNonBiddableRevertsBidOnly() public {
        address fakeBidBoard = makeAddr("fakeBidBoard2");
        manager.setBidBoard(fakeBidBoard);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(fakeBidBoard);
        vm.expectRevert(JobManager.BidOnly.selector);
        manager.claimAcceptedBid(jobId, worker);
    }

    function testClaimAcceptedBidBiddableClaimsWorker() public {
        address fakeBidBoard = makeAddr("fakeBidBoard3");
        manager.setBidBoard(fakeBidBoard);

        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("logo"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(fakeBidBoard);
        manager.claimAcceptedBid(jobId, worker);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Claimed));
        assertEq(job.worker, worker);
    }
}
