// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {JobManager} from "src/JobManager.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract SubcontractRouterTest is Test {
    MarketplaceRegistry internal registry;
    JobEscrow internal escrow;
    JobManager internal manager;
    ReputationOracle internal reputation;
    MockUSDC internal usdc;

    address internal user = makeAddr("user");
    address internal agentA = makeAddr("agentA_PM");
    address internal agentB = makeAddr("agentB_Designer");
    address internal agentC = makeAddr("agentC_Writer");
    address internal eval = makeAddr("evaluator");

    uint256 internal constant TOTAL_BUDGET = 500e6;
    uint256 internal constant LOGO_BUDGET = 100e6;
    uint256 internal constant COPY_BUDGET = 50e6;

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

        usdc.mint(user, 10_000e6);

        vm.prank(user);
        registry.registerAgent("https://user.example", "ipfs://user-meta");

        vm.prank(agentA);
        registry.registerAgentWithType(
            "https://agentA.example",
            "ipfs://agentA-meta",
            MarketplaceRegistry.AgentType.Orchestrator
        );

        vm.prank(agentB);
        registry.registerAgentWithType(
            "https://agentB.example",
            "ipfs://agentB-meta",
            MarketplaceRegistry.AgentType.Specialist
        );

        vm.prank(agentC);
        registry.registerAgentWithType(
            "https://agentC.example",
            "ipfs://agentC-meta",
            MarketplaceRegistry.AgentType.Specialist
        );

        vm.prank(eval);
        registry.registerAgentWithType(
            "https://eval.example",
            "ipfs://eval-meta",
            MarketplaceRegistry.AgentType.Evaluator
        );

        vm.prank(agentB);
        registry.setCapability(keccak256("logo_generation"), true);

        vm.prank(agentC);
        registry.setCapability(keccak256("copywriting"), true);

        vm.prank(user);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testE2eEcommerceSiteFullSupplyChain() public {
        vm.prank(user);
        uint256 parentJobId = manager.createJob(
            keccak256("ecommerce_site"),
            keccak256("spec:shopwave;features:cart,checkout,inventory"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 14 days),
            eval,
            2
        );

        assertEq(usdc.balanceOf(address(escrow)), TOTAL_BUDGET);
        assertEq(escrow.getJobBalance(parentJobId), TOTAL_BUDGET);

        vm.prank(agentA);
        manager.claimJob(parentJobId);

        vm.prank(agentA);
        uint256 logoJobId = manager.createSubJob(
            parentJobId,
            keccak256("logo_generation"),
            keccak256("brand=ShopWave;style=modern;color=teal"),
            LOGO_BUDGET,
            uint64(block.timestamp + 7 days),
            eval,
            1
        );

        assertEq(escrow.getJobBalance(parentJobId), TOTAL_BUDGET - LOGO_BUDGET);
        assertEq(escrow.getJobBalance(logoJobId), LOGO_BUDGET);

        vm.prank(agentA);
        uint256 copyJobId = manager.createSubJob(
            parentJobId,
            keccak256("copywriting"),
            keccak256("product_descriptions;tone=professional"),
            COPY_BUDGET,
            uint64(block.timestamp + 7 days),
            eval,
            1
        );

        assertEq(
            escrow.getJobBalance(parentJobId),
            TOTAL_BUDGET - LOGO_BUDGET - COPY_BUDGET
        );
        assertEq(escrow.getJobBalance(copyJobId), COPY_BUDGET);

        uint256[] memory children = manager.getChildJobs(parentJobId);
        assertEq(children.length, 2);
        assertEq(children[0], logoJobId);
        assertEq(children[1], copyJobId);

        assertEq(manager.getJobDepth(parentJobId), 0);
        assertEq(manager.getJobDepth(logoJobId), 1);
        assertEq(manager.getJobDepth(copyJobId), 1);

        vm.prank(agentB);
        manager.claimJob(logoJobId);

        vm.prank(agentB);
        manager.submitResult(
            logoJobId,
            keccak256("ipfs://QmLogoFinal"),
            "ipfs://QmLogoFinal"
        );

        vm.prank(eval);
        manager.approveJob(logoJobId);

        uint256 logoFee = (LOGO_BUDGET * 50) / 10_000;
        assertEq(usdc.balanceOf(agentB), LOGO_BUDGET - logoFee);

        vm.prank(agentC);
        manager.claimJob(copyJobId);

        vm.prank(agentC);
        manager.submitResult(
            copyJobId,
            keccak256("ipfs://QmCopyFinal"),
            "ipfs://QmCopyFinal"
        );

        vm.prank(eval);
        manager.approveJob(copyJobId);

        uint256 copyFee = (COPY_BUDGET * 50) / 10_000;
        assertEq(usdc.balanceOf(agentC), COPY_BUDGET - copyFee);

        assertTrue(manager.allChildrenComplete(parentJobId));

        vm.prank(agentA);
        manager.submitResult(
            parentJobId,
            keccak256("ipfs://QmEcommerceSiteFinal"),
            "ipfs://QmEcommerceSiteFinal"
        );

        vm.prank(eval);
        manager.approveJob(parentJobId);

        uint256 agentABudget = TOTAL_BUDGET - LOGO_BUDGET - COPY_BUDGET;
        uint256 agentAFee = (agentABudget * 50) / 10_000;
        assertEq(usdc.balanceOf(agentA), agentABudget - agentAFee);

        JobManager.Job memory parentJob = manager.getJob(parentJobId);
        assertEq(
            uint256(parentJob.status),
            uint256(JobManager.JobStatus.Approved)
        );
        assertEq(parentJob.subcontractSpent, LOGO_BUDGET + COPY_BUDGET);

        assertEq(escrow.getJobBalance(parentJobId), 0);
        assertEq(escrow.getJobBalance(logoJobId), 0);
        assertEq(escrow.getJobBalance(copyJobId), 0);

        assertGt(reputation.getScore(agentA), 0);
        assertGt(reputation.getScore(agentB), 0);
        assertGt(reputation.getScore(agentC), 0);

        ReputationOracle.AgentMetrics memory agentAMetrics = reputation
            .getMetrics(agentA);
        assertEq(agentAMetrics.subJobsCreated, 2);
        assertEq(agentAMetrics.subJobsCompleted, 2);
        assertGt(agentAMetrics.totalEarned, 0);

        console2.log("=== E2E Supply Chain Complete ===");
        console2.log("Agent A (PM) earned:      ", usdc.balanceOf(agentA));
        console2.log("Agent B (Designer) earned: ", usdc.balanceOf(agentB));
        console2.log("Agent C (Writer) earned:  ", usdc.balanceOf(agentC));
        console2.log(
            "Platform fees collected:  ",
            usdc.balanceOf(manager.owner())
        );
    }

    function testSubJobOnlyWorkerCanCreate() public {
        vm.prank(user);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 7 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(jobId);

        vm.prank(user);
        vm.expectRevert(JobManager.NotAuthorized.selector);
        manager.createSubJob(
            jobId,
            keccak256("sub"),
            keccak256("spec"),
            50e6,
            uint64(block.timestamp + 3 days),
            eval,
            1
        );
    }

    function testSubJobBudgetOverflowReverts() public {
        vm.prank(user);
        uint256 jobId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 7 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(jobId);

        vm.prank(agentA);
        vm.expectRevert(JobManager.InsufficientSubcontractBudget.selector);
        manager.createSubJob(
            jobId,
            keccak256("sub"),
            keccak256("spec"),
            TOTAL_BUDGET + 1,
            uint64(block.timestamp + 3 days),
            eval,
            1
        );
    }

    function testSubJobMaxDepthEnforced() public {
        vm.prank(user);
        uint256 job0 = manager.createJob(
            keccak256("level0"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 30 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(job0);

        vm.prank(agentA);
        uint256 job1 = manager.createSubJob(
            job0,
            keccak256("level1"),
            keccak256("spec"),
            400e6,
            uint64(block.timestamp + 20 days),
            eval,
            1
        );

        vm.prank(agentB);
        manager.claimJob(job1);

        vm.prank(agentB);
        uint256 job2 = manager.createSubJob(
            job1,
            keccak256("level2"),
            keccak256("spec"),
            300e6,
            uint64(block.timestamp + 15 days),
            eval,
            1
        );

        vm.prank(agentC);
        manager.claimJob(job2);

        vm.prank(agentC);
        uint256 job3 = manager.createSubJob(
            job2,
            keccak256("level3"),
            keccak256("spec"),
            200e6,
            uint64(block.timestamp + 10 days),
            eval,
            1
        );

        address agentD = makeAddr("agentD");
        vm.prank(agentD);
        registry.registerAgent("https://d.example", "ipfs://d");

        vm.prank(agentD);
        manager.claimJob(job3);

        vm.prank(agentD);
        vm.expectRevert(JobManager.MaxDepthExceeded.selector);
        manager.createSubJob(
            job3,
            keccak256("level4"),
            keccak256("spec"),
            100e6,
            uint64(block.timestamp + 5 days),
            eval,
            1
        );
    }

    function testSubJobParentCannotSubmitUntilChildrenComplete() public {
        vm.prank(user);
        uint256 parentId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 14 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(parentId);

        vm.prank(agentA);
        manager.createSubJob(
            parentId,
            keccak256("sub"),
            keccak256("spec"),
            100e6,
            uint64(block.timestamp + 7 days),
            eval,
            1
        );

        vm.prank(agentA);
        vm.expectRevert(JobManager.ChildJobsIncomplete.selector);
        manager.submitResult(
            parentId,
            keccak256("ipfs://result"),
            "ipfs://result"
        );
    }

    function testSubJobDeadlineCannotExceedParent() public {
        vm.prank(user);
        uint256 parentId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 7 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(parentId);

        vm.prank(agentA);
        vm.expectRevert(JobManager.InvalidInput.selector);
        manager.createSubJob(
            parentId,
            keccak256("sub"),
            keccak256("spec"),
            100e6,
            uint64(block.timestamp + 14 days),
            eval,
            1
        );
    }

    function testSubJobCancelledChildAllowsParentSubmit() public {
        vm.prank(user);
        uint256 parentId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            TOTAL_BUDGET,
            uint64(block.timestamp + 14 days),
            eval,
            2
        );

        vm.prank(agentA);
        manager.claimJob(parentId);

        vm.prank(agentA);
        uint256 childId = manager.createSubJob(
            parentId,
            keccak256("sub"),
            keccak256("spec"),
            100e6,
            uint64(block.timestamp + 7 days),
            eval,
            1
        );

        vm.prank(agentA);
        manager.cancelJob(childId, "Changed requirements");

        assertTrue(manager.allChildrenComplete(parentId));

        vm.prank(agentA);
        manager.submitResult(
            parentId,
            keccak256("ipfs://result"),
            "ipfs://result"
        );
    }

    function testJobIdsStartAtOne() public {
        vm.prank(user);
        uint256 firstId = manager.createJob(
            keccak256("task"),
            keccak256("spec"),
            100e6,
            uint64(block.timestamp + 7 days),
            eval,
            2
        );

        assertEq(firstId, 1);
    }
}
