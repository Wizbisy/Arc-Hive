// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/JobManager.sol";
import "src/JobEscrow.sol";
import "src/ReputationOracle.sol";
import "src/MarketplaceRegistry.sol";
import "src/mocks/MockUSDC.sol"; 

contract JobManagerFuzzTest is Test {
    JobManager manager;
    JobEscrow escrow;
    ReputationOracle reputation;
    MarketplaceRegistry registry;
    MockUSDC token;

    address client = address(0x111);
    address worker = address(0x222);
    address evaluator = address(0x333);

    function setUp() public {
        token = new MockUSDC();
        registry = new MarketplaceRegistry();
        escrow = new JobEscrow(address(token));
        reputation = new ReputationOracle();
        manager = new JobManager(address(registry), address(escrow), address(reputation), address(0));
        escrow.setManager(address(manager));
        reputation.setManager(address(manager));

        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(registry.isRegistered.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(reputation),
            abi.encodeWithSelector(reputation.isSlashed.selector),
            abi.encode(false)
        );
        token.mint(client, 1_000_000 * 10**6);
    }

    /// @notice Fuzz test to prove subcontracting math never breaks during creation and cancellation
    function testFuzzSubJobBudgetAlwaysBalances(uint256 parentPayment, uint256 childPayment) public {
        parentPayment = bound(parentPayment, 100, 1_000_000 * 10**6);
        childPayment = bound(childPayment, 1, parentPayment); // Child cost can never exceed Parent cost
        vm.startPrank(client);
        token.approve(address(escrow), parentPayment);
        uint256 parentId = manager.createJob(
            bytes32("MAIN_TASK"), 
            bytes32("SPEC"), 
            parentPayment, 
            uint64(block.timestamp + 1 days), 
            evaluator, 
            2
        );
        vm.stopPrank();
        vm.prank(worker);
        manager.claimJob(parentId);
        vm.prank(worker);
        uint256 childId = manager.createSubJob(
            parentId, 
            bytes32("SUB_TASK"), 
            bytes32("SPEC"), 
            childPayment, 
            uint64(block.timestamp + 12 hours), 
            evaluator, 
            1
        );
        JobManager.Job memory pJobPre = manager.getJob(parentId);
        assertEq(pJobPre.subcontractSpent, childPayment, "Parent subcontractSpent should equal child payment");
        assertEq(escrow.getJobBalance(parentId), parentPayment - childPayment, "Parent escrow should be reduced by child cost");
        assertEq(escrow.getJobBalance(childId), childPayment, "Child escrow should hold the exact child payment");
        vm.prank(worker);
        manager.cancelJob(childId, "Worker cancelling sub-job");
        JobManager.Job memory pJobPost = manager.getJob(parentId);
        assertEq(pJobPost.subcontractSpent, 0, "Parent subcontractSpent MUST reset to 0");
        assertEq(escrow.getJobBalance(parentId), parentPayment, "Parent escrow MUST be fully refunded");
        assertEq(escrow.getJobBalance(childId), 0, "Child escrow MUST be completely empty");
        assertEq(token.balanceOf(address(escrow)), parentPayment, "Escrow total balance must perfectly match the parent payment");
    }
}
