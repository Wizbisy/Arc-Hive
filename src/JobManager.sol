// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {JobEscrow} from "src/JobEscrow.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";

/// @title JobManager
/// @notice core: ERC-8183 job lifecycle with recursive subcontracting.
///         Handles posting, claiming, submission, revision, approval, disputes,
///         and parent-child job delegation with budget waterfall.
interface IArcIdentityRegistry {
    function isRegistered(address agent) external view returns (bool);
}

contract JobManager {
    enum JobStatus {
        Open,
        Claimed,
        Submitted,
        Approved,
        Cancelled,
        Disputed
    }
    


    struct Job {
        address client;
        address evaluator;
        address worker;
        uint256 payment;
        uint64 deadline;
        uint8 maxRevisions;
        uint8 revisionCount;
        bytes32 taskType;
        bytes32 specHash;
        bytes32 resultHash;
        JobStatus status;
        string resultURI;
        uint256 parentJobId;
        bool hasParent;
        uint256 subcontractBudget;
        uint256 subcontractSpent;
    }

    MarketplaceRegistry public immutable registry;
    JobEscrow public immutable escrow;
    ReputationOracle public immutable reputation;
    address public immutable arcIdentityRegistry;

    address public owner;
    address public pendingOwner;
    address public bidBoard;
    uint256 public nextJobId;
    uint256 public platformFeeBps;
    uint256 public disputeResolutionDelay;

    uint256 public constant MAX_DEPTH = 3;
    uint256 public constant MAX_DISPUTE_DELAY = 7 days;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => uint256[]) public childJobs;
    mapping(uint256 => uint256) public jobDepth;
    mapping(uint256 => bool) public isBiddable;
    mapping(uint256 => uint256) public disputeReadyAt;
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed evaluator,
        bytes32 taskType,
        uint256 payment,
        uint64 deadline,
        uint8 maxRevisions
    );
    event JobClaimed(uint256 indexed jobId, address indexed worker);
    event ResultSubmitted(
        uint256 indexed jobId,
        address indexed worker,
        bytes32 resultHash,
        string resultURI,
        uint8 revisionCount
    );
    event JobApproved(
        uint256 indexed jobId,
        address indexed evaluator,
        address indexed worker,
        uint256 payment,
        uint256 fee
    );
    event RevisionRequested(
        uint256 indexed jobId,
        address indexed evaluator,
        uint8 revisionCount,
        string reason
    );
    event JobCancelled(
        uint256 indexed jobId,
        address indexed client,
        string reason
    );
    event JobDisputed(
        uint256 indexed jobId,
        address indexed initiator,
        string reason
    );
    event SubJobCreated(
        uint256 indexed parentJobId,
        uint256 indexed childJobId,
        address indexed worker,
        bytes32 taskType,
        uint256 payment
    );
    event OwnershipTransferStarted(
        address indexed previousOwner,
        address indexed newOwner
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event DisputeResolved(
        uint256 indexed jobId,
        address indexed resolver,
        JobStatus resolution
    );
    event DisputeResolutionDelayUpdated(uint256 newDelay);

    error Unauthorized();
    error InvalidInput();
    error JobNotInValidState();
    error JobExpired();
    error MaxRevisionsExceeded();
    error NotAuthorized();
    error ZeroPayment();
    error MaxDepthExceeded();
    error InsufficientSubcontractBudget();
    error ChildJobsIncomplete();
    error InvalidBidBoard();
    error BidOnly();
    error EvaluatorCannotWork();
    error DisputeResolutionTooEarly();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyJobParticipant(uint256 jobId) {
        Job storage job = jobs[jobId];
        if (
            msg.sender != job.client &&
            msg.sender != job.evaluator &&
            msg.sender != job.worker
        ) {
            revert NotAuthorized();
        }
        _;
    }

    constructor(
        address registryAddress,
        address escrowAddress,
        address reputationAddress,
        address arcIdentityRegistryAddress
    ) {
        if (
            registryAddress == address(0) ||
            escrowAddress == address(0) ||
            reputationAddress == address(0)
        ) {
            revert InvalidInput();
        }

        registry = MarketplaceRegistry(registryAddress);
        escrow = JobEscrow(escrowAddress);
        reputation = ReputationOracle(reputationAddress);
        arcIdentityRegistry = arcIdentityRegistryAddress;
        owner = msg.sender;
        nextJobId = 1;
        platformFeeBps = 50;
        disputeResolutionDelay = 1 hours;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidInput();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAuthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 500) revert InvalidInput();
        platformFeeBps = newFeeBps;
    }

    function setDisputeResolutionDelay(uint256 newDelay) external onlyOwner {
        if (newDelay > MAX_DISPUTE_DELAY) revert InvalidInput();
        disputeResolutionDelay = newDelay;
        emit DisputeResolutionDelayUpdated(newDelay);
    }

    function setBidBoard(address newBidBoard) external onlyOwner {
        if (newBidBoard == address(0)) revert InvalidBidBoard();
        bidBoard = newBidBoard;
    }

    function markBiddable(uint256 jobId) external {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotAuthorized();
        if (job.status != JobStatus.Open) revert JobNotInValidState();
        if (bidBoard == address(0)) revert InvalidBidBoard();
        isBiddable[jobId] = true;
    }

    function createJob(
        bytes32 taskType,
        bytes32 specHash,
        uint256 payment,
        uint64 deadline,
        address evaluator,
        uint8 maxRevisions
    ) external returns (uint256 jobId) {
        return
            _createJob(
                taskType,
                specHash,
                payment,
                deadline,
                evaluator,
                maxRevisions,
                false
            );
    }

    function createBiddableJob(
        bytes32 taskType,
        bytes32 specHash,
        uint256 payment,
        uint64 deadline,
        address evaluator,
        uint8 maxRevisions
    ) external returns (uint256 jobId) {
        if (bidBoard == address(0)) revert InvalidBidBoard();
        return
            _createJob(
                taskType,
                specHash,
                payment,
                deadline,
                evaluator,
                maxRevisions,
                true
            );
    }

    function _createJob(
        bytes32 taskType,
        bytes32 specHash,
        uint256 payment,
        uint64 deadline,
        address evaluator,
        uint8 maxRevisions,
        bool biddable
    ) internal returns (uint256 jobId) {
        if (arcIdentityRegistry != address(0)) {
            if (!IArcIdentityRegistry(arcIdentityRegistry).isRegistered(msg.sender)) revert Unauthorized();
        }
        if (!registry.isRegistered(msg.sender)) revert Unauthorized();
        if (evaluator == address(0)) revert InvalidInput();
        if (payment == 0) revert ZeroPayment();
        if (deadline <= block.timestamp) revert InvalidInput();
        if (maxRevisions > 10) revert InvalidInput();

        jobId = nextJobId++;

        escrow.depositFor(jobId, msg.sender, payment);

        jobs[jobId] = Job({
            client: msg.sender,
            evaluator: evaluator,
            worker: address(0),
            payment: payment,
            deadline: deadline,
            maxRevisions: maxRevisions,
            revisionCount: 0,
            taskType: taskType,
            specHash: specHash,
            resultHash: bytes32(0),
            status: JobStatus.Open,
            resultURI: "",
            parentJobId: 0,
            hasParent: false,
            subcontractBudget: 0,
            subcontractSpent: 0
        });

        if (biddable) {
            isBiddable[jobId] = true;
        }

        emit JobCreated(
            jobId,
            msg.sender,
            evaluator,
            taskType,
            payment,
            deadline,
            maxRevisions
        );
    }

    function claimJob(uint256 jobId) external {
        Job storage job = jobs[jobId];

        if (isBiddable[jobId]) revert BidOnly();
        if (job.status != JobStatus.Open) revert JobNotInValidState();
        if (block.timestamp > job.deadline) revert JobExpired();
        if (arcIdentityRegistry != address(0)) {
            if (!IArcIdentityRegistry(arcIdentityRegistry).isRegistered(msg.sender)) revert Unauthorized();
        }
        if (!registry.isRegistered(msg.sender)) revert Unauthorized();
        if (msg.sender == job.client) revert InvalidInput();
        if (msg.sender == job.evaluator) revert EvaluatorCannotWork();
        if (reputation.isSlashed(msg.sender)) revert Unauthorized();

        job.worker = msg.sender;
        job.status = JobStatus.Claimed;

        emit JobClaimed(jobId, msg.sender);
    }

    function claimAcceptedBid(uint256 jobId, address worker) external {
        if (msg.sender != bidBoard) revert NotAuthorized();
        if (!isBiddable[jobId]) revert BidOnly();

        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Open) revert JobNotInValidState();
        if (block.timestamp > job.deadline) revert JobExpired();
        if (arcIdentityRegistry != address(0)) {
            if (!IArcIdentityRegistry(arcIdentityRegistry).isRegistered(worker)) revert Unauthorized();
        }
        if (!registry.isRegistered(worker)) revert Unauthorized();
        if (worker == job.client) revert InvalidInput();
        if (worker == job.evaluator) revert EvaluatorCannotWork();
        if (reputation.isSlashed(worker)) revert Unauthorized();

        job.worker = worker;
        job.status = JobStatus.Claimed;

        emit JobClaimed(jobId, worker);
    }

    function submitResult(
        uint256 jobId,
        bytes32 resultHash,
        string calldata resultURI
    ) external {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Claimed) revert JobNotInValidState();
        if (msg.sender != job.worker) revert NotAuthorized();
        if (resultHash == bytes32(0)) revert InvalidInput();
        if (block.timestamp > job.deadline) revert JobExpired();

        if (childJobs[jobId].length > 0) {
            if (!_allChildrenComplete(jobId)) revert ChildJobsIncomplete();
        }

        job.resultHash = resultHash;
        job.resultURI = resultURI;
        job.status = JobStatus.Submitted;

        emit ResultSubmitted(
            jobId,
            msg.sender,
            resultHash,
            resultURI,
            job.revisionCount
        );
    }

    function approveJob(uint256 jobId) external {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Submitted) revert JobNotInValidState();
        if (msg.sender != job.evaluator) revert NotAuthorized();

        job.status = JobStatus.Approved;

        uint256 remainingBalance = job.payment - job.subcontractSpent;

        uint256 fee = (remainingBalance * platformFeeBps) / 10_000;
        uint256 workerPayment = remainingBalance - fee;

        escrow.releaseFor(jobId, job.worker, workerPayment);

        if (fee > 0) {
            escrow.releaseFor(jobId, owner, fee);
        }

        reputation.recordSuccess(job.worker);
        reputation.recordEarnings(job.worker, workerPayment);

        if (job.hasParent) {
            address orchestrator = jobs[job.parentJobId].worker;
            if (orchestrator != address(0)) {
                reputation.recordSubJobCompleted(orchestrator);
            }
        }

        emit JobApproved(jobId, msg.sender, job.worker, workerPayment, fee);
    }

    function requestRevision(uint256 jobId, string calldata reason) external {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Submitted) revert JobNotInValidState();
        if (msg.sender != job.evaluator) revert NotAuthorized();
        if (job.revisionCount >= job.maxRevisions)
            revert MaxRevisionsExceeded();
        if (block.timestamp > job.deadline) revert JobExpired();

        job.revisionCount++;
        job.resultHash = bytes32(0);
        job.resultURI = "";
        job.status = JobStatus.Claimed;

        emit RevisionRequested(jobId, msg.sender, job.revisionCount, reason);
    }

    function cancelJob(uint256 jobId, string calldata reason) external {
        Job storage job = jobs[jobId];

        if (msg.sender != job.client && msg.sender != owner)
            revert NotAuthorized();
        if (
            job.status == JobStatus.Approved ||
            job.status == JobStatus.Cancelled ||
            job.status == JobStatus.Submitted ||
            job.status == JobStatus.Disputed
        ) revert JobNotInValidState();

        job.status = JobStatus.Cancelled;

        if (job.worker != address(0) && job.revisionCount >= job.maxRevisions) {
            reputation.recordFailure(job.worker);
        }

        uint256 remaining = job.payment - job.subcontractSpent;
        if (remaining > 0) {
            if (job.hasParent) {
                Job storage parentJob = jobs[job.parentJobId];
                if (parentJob.subcontractSpent < remaining) {
                    revert InsufficientSubcontractBudget();
                }
                escrow.returnBudget(jobId, job.parentJobId, remaining);
                parentJob.subcontractSpent -= remaining;
            } else {
                escrow.refundFor(jobId, job.client, remaining);
            }
        }

        emit JobCancelled(jobId, msg.sender, reason);
    }

    function cancelExpiredJob(uint256 jobId) external {
        Job storage job = jobs[jobId];

        if (block.timestamp <= job.deadline) revert InvalidInput();
        if (
            job.status == JobStatus.Approved ||
            job.status == JobStatus.Cancelled ||
            job.status == JobStatus.Submitted ||
            job.status == JobStatus.Disputed
        ) revert JobNotInValidState();

        bool wasInProgress = job.worker != address(0) &&
            job.status == JobStatus.Claimed;

        job.status = JobStatus.Cancelled;

        if (wasInProgress) {
            reputation.recordFailure(job.worker);
        }

        uint256 remaining = job.payment - job.subcontractSpent;
        if (remaining > 0) {
            if (job.hasParent) {
                Job storage parentJob = jobs[job.parentJobId];
                if (parentJob.subcontractSpent < remaining) {
                    revert InsufficientSubcontractBudget();
                }
                escrow.returnBudget(jobId, job.parentJobId, remaining);
                parentJob.subcontractSpent -= remaining;
            } else {
                escrow.refundFor(jobId, job.client, remaining);
            }
        }

        emit JobCancelled(jobId, msg.sender, "expired");
    }

    function raiseDispute(
        uint256 jobId,
        string calldata reason
    ) external onlyJobParticipant(jobId) {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Submitted) revert JobNotInValidState();

        job.status = JobStatus.Disputed;
        disputeReadyAt[jobId] = block.timestamp + disputeResolutionDelay;
        emit JobDisputed(jobId, msg.sender, reason);
    }

    function resolveDispute(
        uint256 jobId,
        bool approveWorker
    ) external onlyOwner {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.Disputed) revert JobNotInValidState();
        if (block.timestamp < disputeReadyAt[jobId]) {
            revert DisputeResolutionTooEarly();
        }

        if (approveWorker) {
            job.status = JobStatus.Approved;

            uint256 remainingBalance = job.payment - job.subcontractSpent;
            uint256 fee = (remainingBalance * platformFeeBps) / 10_000;
            uint256 workerPayment = remainingBalance - fee;

            escrow.releaseFor(jobId, job.worker, workerPayment);
            if (fee > 0) {
                escrow.releaseFor(jobId, owner, fee);
            }

            reputation.recordSuccess(job.worker);
            reputation.recordEarnings(job.worker, workerPayment);

            emit DisputeResolved(jobId, msg.sender, JobStatus.Approved);
        } else {
            job.status = JobStatus.Cancelled;

            reputation.recordFailure(job.worker);

            uint256 remaining = job.payment - job.subcontractSpent;
            if (remaining > 0) {
                if (job.hasParent) {
                    Job storage parentJob = jobs[job.parentJobId];
                    if (parentJob.subcontractSpent < remaining) {
                        revert InsufficientSubcontractBudget();
                    }
                    escrow.returnBudget(jobId, job.parentJobId, remaining);
                    parentJob.subcontractSpent -= remaining;
                } else {
                    escrow.refundFor(jobId, job.client, remaining);
                }
            }

            emit DisputeResolved(jobId, msg.sender, JobStatus.Cancelled);
        }

        disputeReadyAt[jobId] = 0;
    }

    function setSubcontractBudget(uint256 jobId, uint256 budget) external {
        Job storage job = jobs[jobId];

        if (msg.sender != job.worker) revert NotAuthorized();
        if (job.status != JobStatus.Claimed) revert JobNotInValidState();
        if (budget > job.payment) revert InvalidInput();
        if (budget < job.subcontractSpent) revert InvalidInput();

        job.subcontractBudget = budget;
    }

    function createSubJob(
        uint256 parentJobId,
        bytes32 taskType,
        bytes32 specHash,
        uint256 payment,
        uint64 deadline,
        address evaluator,
        uint8 maxRevisions
    ) external returns (uint256 childJobId) {
        Job storage parentJob = jobs[parentJobId];

        if (msg.sender != parentJob.worker) revert NotAuthorized();
        if (parentJob.status != JobStatus.Claimed) revert JobNotInValidState();
        if (payment == 0) revert ZeroPayment();
        if (evaluator == address(0)) revert InvalidInput();
        if (deadline <= block.timestamp) revert InvalidInput();
        if (deadline > parentJob.deadline) revert InvalidInput();

        uint256 parentDepth = jobDepth[parentJobId];
        if (parentDepth >= MAX_DEPTH) revert MaxDepthExceeded();

        uint256 available = parentJob.payment - parentJob.subcontractSpent;

        if (parentJob.subcontractBudget != 0) {
            if (parentJob.subcontractSpent > parentJob.subcontractBudget) {
                revert InsufficientSubcontractBudget();
            }

            available =
                parentJob.subcontractBudget -
                parentJob.subcontractSpent;
        }

        if (payment > available) revert InsufficientSubcontractBudget();

        parentJob.subcontractSpent += payment;

        childJobId = nextJobId++;

        escrow.splitBudget(parentJobId, childJobId, payment);

        jobs[childJobId] = Job({
            client: parentJob.worker,
            evaluator: evaluator,
            worker: address(0),
            payment: payment,
            deadline: deadline,
            maxRevisions: maxRevisions,
            revisionCount: 0,
            taskType: taskType,
            specHash: specHash,
            resultHash: bytes32(0),
            status: JobStatus.Open,
            resultURI: "",
            parentJobId: parentJobId,
            hasParent: true,
            subcontractBudget: 0,
            subcontractSpent: 0
        });

        childJobs[parentJobId].push(childJobId);
        jobDepth[childJobId] = parentDepth + 1;

        reputation.recordSubJobCreated(msg.sender);

        emit SubJobCreated(
            parentJobId,
            childJobId,
            msg.sender,
            taskType,
            payment
        );

        emit JobCreated(
            childJobId,
            parentJob.worker,
            evaluator,
            taskType,
            payment,
            deadline,
            maxRevisions
        );
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getChildJobs(
        uint256 parentJobId
    ) external view returns (uint256[] memory) {
        return childJobs[parentJobId];
    }

    function getJobDepth(uint256 jobId) external view returns (uint256) {
        return jobDepth[jobId];
    }

    function allChildrenComplete(
        uint256 parentJobId
    ) external view returns (bool) {
        return _allChildrenComplete(parentJobId);
    }

    function totalJobs() external view returns (uint256) {
        return nextJobId - 1;
    }

    function _allChildrenComplete(
        uint256 parentJobId
    ) internal view returns (bool) {
        uint256[] storage children = childJobs[parentJobId];
        for (uint256 i = 0; i < children.length; i++) {
            JobStatus childStatus = jobs[children[i]].status;
            if (
                childStatus != JobStatus.Approved &&
                childStatus != JobStatus.Cancelled
            ) {
                return false;
            }
        }
        return true;
    }
}
