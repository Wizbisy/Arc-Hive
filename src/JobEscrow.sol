// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "src/interfaces/IERC20.sol";

/// @title JobEscrow
/// @notice USDC escrow vault with per job balance tracking, milestone releases,
///         and budget splitting for recursive agent subcontracting.
contract JobEscrow {
    IERC20 public immutable token;
    address public owner;
    address public pendingOwner;
    address public manager;
    uint256 private locked;
    mapping(uint256 => uint256) public jobBalances;
    event ManagerUpdated(
        address indexed previousManager,
        address indexed newManager
    );
    event Deposited(
        uint256 indexed jobId,
        address indexed payer,
        uint256 amount
    );
    event Released(
        uint256 indexed jobId,
        address indexed payee,
        uint256 amount
    );
    event Refunded(
        uint256 indexed jobId,
        address indexed payee,
        uint256 amount
    );
    event MilestoneReleased(
        uint256 indexed jobId,
        address indexed payee,
        uint256 amount,
        uint256 milestoneIndex
    );
    event BudgetSplit(
        uint256 indexed parentJobId,
        uint256 indexed childJobId,
        uint256 amount
    );
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    error Unauthorized();
    error InvalidInput();
    error TransferFailed();
    error Reentrancy();
    error InsufficientJobBalance();
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (locked != 0) revert Reentrancy();
        locked = 1;
        _;
        locked = 0;
    }
    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) revert InvalidInput();
        token = IERC20(tokenAddress);
        owner = msg.sender;
    }

    function setManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert InvalidInput();
        emit ManagerUpdated(manager, newManager);
        manager = newManager;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidInput();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function depositFor(
        uint256 jobId,
        address payer,
        uint256 amount
    ) external onlyManager nonReentrant {
        if (payer == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        bool success = token.transferFrom(payer, address(this), amount);
        if (!success) revert TransferFailed();
        jobBalances[jobId] += amount;
        emit Deposited(jobId, payer, amount);
    }

    function releaseFor(
        uint256 jobId,
        address payee,
        uint256 amount
    ) external onlyManager nonReentrant {
        if (payee == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        if (jobBalances[jobId] < amount) revert InsufficientJobBalance();
        jobBalances[jobId] -= amount;
        bool success = token.transfer(payee, amount);
        if (!success) revert TransferFailed();
        emit Released(jobId, payee, amount);
    }

    function refundFor(
        uint256 jobId,
        address payee,
        uint256 amount
    ) external onlyManager nonReentrant {
        if (payee == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        if (jobBalances[jobId] < amount) revert InsufficientJobBalance();
        jobBalances[jobId] -= amount;
        bool success = token.transfer(payee, amount);
        if (!success) revert TransferFailed();
        emit Refunded(jobId, payee, amount);
    }

    function releaseMilestone(
        uint256 jobId,
        address payee,
        uint256 amount,
        uint256 milestoneIndex
    ) external onlyManager nonReentrant {
        if (payee == address(0)) revert InvalidInput();
        if (amount == 0) revert InvalidInput();
        if (jobBalances[jobId] < amount) revert InsufficientJobBalance();
        jobBalances[jobId] -= amount;
        bool success = token.transfer(payee, amount);
        if (!success) revert TransferFailed();
        emit MilestoneReleased(jobId, payee, amount, milestoneIndex);
    }

    function splitBudget(
        uint256 parentJobId,
        uint256 childJobId,
        uint256 amount
    ) external onlyManager nonReentrant {
        if (amount == 0) revert InvalidInput();
        if (jobBalances[parentJobId] < amount) revert InsufficientJobBalance();
        jobBalances[parentJobId] -= amount;
        jobBalances[childJobId] += amount;
        emit BudgetSplit(parentJobId, childJobId, amount);
    }

    function returnBudget(
        uint256 childJobId,
        uint256 parentJobId,
        uint256 amount
    ) external onlyManager nonReentrant {
        if (amount == 0) revert InvalidInput();
        if (jobBalances[childJobId] < amount) revert InsufficientJobBalance();
        jobBalances[childJobId] -= amount;
        jobBalances[parentJobId] += amount;
        emit BudgetSplit(childJobId, parentJobId, amount);
    }

    function getBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getJobBalance(uint256 jobId) external view returns (uint256) {
        return jobBalances[jobId];
    }

}
