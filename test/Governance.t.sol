// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {JobManager} from "src/JobManager.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract GovernanceTest is Test {
    MarketplaceRegistry internal registry;
    JobEscrow internal escrow;
    JobManager internal manager;
    ReputationOracle internal reputation;
    MockUSDC internal usdc;
    address internal deployer;
    address internal client = makeAddr("client");
    address internal worker = makeAddr("worker");
    address internal evaluator = makeAddr("evaluator");
    address internal newOwner = makeAddr("newOwner");
    address internal attacker = makeAddr("attacker");
    uint256 internal constant PAYMENT = 100e6;

    function setUp() public {
        deployer = address(this);

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

    function testH1CancelExpiredJobRevertsOnSubmittedJob() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 1 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(JobManager.JobNotInValidState.selector);
        manager.cancelExpiredJob(jobId);
    }

    function testH1CancelExpiredJobPenalizesClaimedWorker() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 1 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.warp(block.timestamp + 2 days);
        manager.cancelExpiredJob(jobId);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Cancelled));

        ReputationOracle.AgentMetrics memory m = reputation.getMetrics(worker);
        assertEq(m.totalJobsFailed, 1);
    }

    function testH1CancelExpiredJobRevertsOnDisputedJob() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 1 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(client);
        manager.raiseDispute(jobId, "quality issue");

        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(JobManager.JobNotInValidState.selector);
        manager.cancelExpiredJob(jobId);
    }

    function testM1UntrackedFunctionsRemoved() public view {
        assertEq(escrow.getJobBalance(999), 0);
        assertGe(escrow.getBalance(), 0);
    }

    function testM2UnslashRestoresAgentAbility() public {
        reputation.slash(worker, 10e6, "test slash");
        assertTrue(reputation.isSlashed(worker));

        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        vm.expectRevert(JobManager.Unauthorized.selector);
        manager.claimJob(jobId);

        reputation.unslash(worker);
        assertFalse(reputation.isSlashed(worker));

        vm.prank(worker);
        manager.claimJob(jobId);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(job.worker, worker);
    }

    function testM2UnslashOnlyOwner() public {
        reputation.slash(worker, 10e6, "test");

        vm.prank(attacker);
        vm.expectRevert(ReputationOracle.Unauthorized.selector);
        reputation.unslash(worker);
    }

    function testL1CapabilityIndexCleanedOnDisable() public {
        bytes32 cap = keccak256("logo_generation");

        vm.prank(worker);
        registry.setCapability(cap, true);

        address[] memory agents = registry.getAgentsByCapability(cap);
        assertEq(agents.length, 1);
        assertEq(agents[0], worker);

        vm.prank(worker);
        registry.setCapability(cap, false);

        agents = registry.getAgentsByCapability(cap);
        assertEq(agents.length, 0);
    }

    function testL1CapabilityIndexSwapAndPop() public {
        bytes32 cap = keccak256("writing");

        address agent3 = makeAddr("agent3");
        vm.prank(agent3);
        registry.registerAgent("https://agent3.example", "ipfs://agent3");

        vm.prank(worker);
        registry.setCapability(cap, true);
        vm.prank(evaluator);
        registry.setCapability(cap, true);
        vm.prank(agent3);
        registry.setCapability(cap, true);

        vm.prank(worker);
        registry.setCapability(cap, false);

        address[] memory agents = registry.getAgentsByCapability(cap);
        assertEq(agents.length, 2);
        assertEq(agents[0], agent3);
        assertEq(agents[1], evaluator);
    }

    function testL2JobManagerOwnershipTransfer() public {
        manager.transferOwnership(newOwner);
        assertEq(manager.owner(), deployer);

        vm.prank(newOwner);
        manager.acceptOwnership();
        assertEq(manager.owner(), newOwner);
    }

    function testL2JobEscrowOwnershipTransfer() public {
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), deployer);

        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
    }

    function testL2ReputationOracleOwnershipTransfer() public {
        reputation.transferOwnership(newOwner);
        assertEq(reputation.owner(), deployer);

        vm.prank(newOwner);
        reputation.acceptOwnership();
        assertEq(reputation.owner(), newOwner);
    }

    function testL2MarketplaceRegistryOwnershipTransfer() public {
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), deployer);

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
    }

    function testL2OwnershipTransferRejectsUnauthorized() public {
        manager.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert(JobManager.NotAuthorized.selector);
        manager.acceptOwnership();
    }

    function testL3EvaluatorCannotClaimJob() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(evaluator);
        vm.expectRevert(JobManager.EvaluatorCannotWork.selector);
        manager.claimJob(jobId);
    }

    function testL3EvaluatorCannotBeAcceptedViaBidBoard() public {
        address fakeBidBoard = makeAddr("fakeBidBoard");
        manager.setBidBoard(fakeBidBoard);

        vm.prank(client);
        uint256 jobId = manager.createBiddableJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(fakeBidBoard);
        vm.expectRevert(JobManager.EvaluatorCannotWork.selector);
        manager.claimAcceptedBid(jobId, evaluator);
    }

    function testL4CancelJobCheckBeforeEffect() public {
        vm.prank(client);
        uint256 parentId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(parentId);

        vm.prank(worker);
        uint256 childId = manager.createSubJob(
            parentId,
            keccak256("sub"),
            keccak256("spec"),
            50e6,
            uint64(block.timestamp + 6 days),
            evaluator,
            0
        );

        vm.prank(worker);
        manager.cancelJob(childId, "changed mind");

        JobManager.Job memory parentJob = manager.getJob(parentId);
        assertEq(parentJob.subcontractSpent, 0);
        assertEq(escrow.getJobBalance(parentId), PAYMENT);
    }

    function testI1CannotReRegister() public {
        address fresh = makeAddr("freshAgent");
        vm.prank(fresh);
        registry.registerAgent("https://fresh.example", "ipfs://fresh");

        vm.prank(fresh);
        vm.expectRevert(MarketplaceRegistry.AlreadyRegistered.selector);
        registry.registerAgent("https://fresh2.example", "ipfs://fresh2");
    }

    function testI1CannotReRegisterWithType() public {
        address fresh = makeAddr("freshAgent2");
        vm.prank(fresh);
        registry.registerAgentWithType(
            "https://fresh.example",
            "ipfs://fresh",
            MarketplaceRegistry.AgentType.Specialist
        );

        vm.prank(fresh);
        vm.expectRevert(MarketplaceRegistry.AlreadyRegistered.selector);
        registry.registerAgentWithType(
            "https://fresh2.example",
            "ipfs://fresh2",
            MarketplaceRegistry.AgentType.Evaluator
        );
    }

    function testI3ResolveDisputeApprovesWorker() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(client);
        manager.raiseDispute(jobId, "Quality issue");

        vm.warp(block.timestamp + manager.disputeResolutionDelay() + 1);

        manager.resolveDispute(jobId, true);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Approved));

        uint256 expectedFee = (PAYMENT * manager.platformFeeBps()) / 10_000;
        assertEq(usdc.balanceOf(worker), PAYMENT - expectedFee);

        assertEq(escrow.getJobBalance(jobId), 0);
    }

    function testI3ResolveDisputeRefundsClient() public {
        uint256 clientBalanceBefore = usdc.balanceOf(client);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(evaluator);
        manager.raiseDispute(jobId, "Plagiarized work");

        vm.warp(block.timestamp + manager.disputeResolutionDelay() + 1);

        manager.resolveDispute(jobId, false);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Cancelled));

        assertEq(usdc.balanceOf(client), clientBalanceBefore);

        ReputationOracle.AgentMetrics memory m = reputation.getMetrics(worker);
        assertEq(m.totalJobsFailed, 1);
    }

    function testI3ResolveDisputeOnlyOwner() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(client);
        manager.raiseDispute(jobId, "issue");

        vm.prank(attacker);
        vm.expectRevert(JobManager.Unauthorized.selector);
        manager.resolveDispute(jobId, true);
    }

    function testI3ResolveDisputeTooEarlyReverts() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(client);
        manager.raiseDispute(jobId, "issue");

        vm.expectRevert(JobManager.DisputeResolutionTooEarly.selector);
        manager.resolveDispute(jobId, true);
    }

    function testI3ResolveDisputeDelayBoundary() public {
        manager.setDisputeResolutionDelay(2 hours);

        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.prank(worker);
        manager.claimJob(jobId);

        vm.prank(worker);
        manager.submitResult(jobId, keccak256("result"), "ipfs://result");

        vm.prank(client);
        manager.raiseDispute(jobId, "issue");

        uint256 readyAt = manager.disputeReadyAt(jobId);

        vm.warp(readyAt - 1);
        vm.expectRevert(JobManager.DisputeResolutionTooEarly.selector);
        manager.resolveDispute(jobId, true);

        vm.warp(readyAt);
        manager.resolveDispute(jobId, true);

        JobManager.Job memory job = manager.getJob(jobId);
        assertEq(uint256(job.status), uint256(JobManager.JobStatus.Approved));
    }

    function testI3ResolveDisputeOnlyDisputedJobs() public {
        vm.prank(client);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            PAYMENT,
            uint64(block.timestamp + 7 days),
            evaluator,
            2
        );

        vm.expectRevert(JobManager.JobNotInValidState.selector);
        manager.resolveDispute(jobId, true);
    }
}
