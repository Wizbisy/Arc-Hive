// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ReputationOracle
/// @notice Tracks agent reputation, success rates, subcontracting reliability, and slashing.
contract ReputationOracle {
    struct AgentMetrics {
        uint256 totalJobsCompleted;
        uint256 totalJobsFailed;
        uint256 reputationScore;       
        uint256 totalStakeSlashed;
        bool isSlashed;
        uint256 subJobsCreated;        
        uint256 subJobsCompleted;      
        uint256 totalEarned;           
    }

    address public owner;
    address public pendingOwner;
    address public manager;
    uint256 public minimumScoreForBidding;  
    mapping(address => AgentMetrics) public metrics;
    event ScoreUpdated(
        address indexed agent,
        uint256 newScore,
        bool successful
    );
    event AgentSlashed(
        address indexed agent,
        uint256 slashAmount,
        string reason
    );
    event MetricsReset(address indexed agent);
    event SubJobTracked(
        address indexed orchestrator,
        bool completed
    );
    event MinimumScoreUpdated(uint256 newMinimum);
    event AgentUnslashed(address indexed agent);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    error Unauthorized();
    error InvalidAgent();
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        minimumScoreForBidding = 0; 
    }

    function setManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert InvalidAgent();
        manager = newManager;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAgent();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setMinimumScoreForBidding(uint256 score) external onlyOwner {
        minimumScoreForBidding = score;
        emit MinimumScoreUpdated(score);
    }

    function recordSuccess(address agent) external onlyManager {
        if (agent == address(0)) revert InvalidAgent();

        AgentMetrics storage m = metrics[agent];
        m.totalJobsCompleted++;


        if (m.reputationScore < 9900) {
            m.reputationScore += 100;
        } else {
            m.reputationScore = 10000;
        }

        emit ScoreUpdated(agent, m.reputationScore, true);
    }

    function recordFailure(address agent) external onlyManager {
        if (agent == address(0)) revert InvalidAgent();

        AgentMetrics storage m = metrics[agent];
        m.totalJobsFailed++;

        if (m.reputationScore > 200) {
            m.reputationScore -= 200;
        } else {
            m.reputationScore = 0;
        }

        emit ScoreUpdated(agent, m.reputationScore, false);
    }

    function recordEarnings(address agent, uint256 amount) external onlyManager {
        if (agent == address(0)) revert InvalidAgent();
        metrics[agent].totalEarned += amount;
    }

    function recordSubJobCreated(address orchestrator) external onlyManager {
        if (orchestrator == address(0)) revert InvalidAgent();
        metrics[orchestrator].subJobsCreated++;
        emit SubJobTracked(orchestrator, false);
    }

    function recordSubJobCompleted(address orchestrator) external onlyManager {
        if (orchestrator == address(0)) revert InvalidAgent();
        metrics[orchestrator].subJobsCompleted++;
        emit SubJobTracked(orchestrator, true);
    }

    function slash(
        address agent,
        uint256 amount,
        string calldata reason
    ) external onlyOwner {
        if (agent == address(0)) revert InvalidAgent();

        AgentMetrics storage m = metrics[agent];
        m.totalStakeSlashed += amount;
        m.isSlashed = true;

        m.reputationScore = m.reputationScore > 500
            ? m.reputationScore - 500
            : 0;

        emit AgentSlashed(agent, amount, reason);
    }

    function unslash(address agent) external onlyOwner {
        if (agent == address(0)) revert InvalidAgent();
        metrics[agent].isSlashed = false;
        emit AgentUnslashed(agent);
    }

    function getScore(address agent) external view returns (uint256) {
        return metrics[agent].reputationScore;
    }

    function getMetrics(
        address agent
    ) external view returns (AgentMetrics memory) {
        return metrics[agent];
    }

    function isSlashed(address agent) external view returns (bool) {
        return metrics[agent].isSlashed;
    }

    function meetsMinimumScore(address agent) external view returns (bool) {
        return metrics[agent].reputationScore >= minimumScoreForBidding;
    }

    function getReliabilityScore(address agent) external view returns (uint256) {
        AgentMetrics storage m = metrics[agent];

        uint256 totalJobs = m.totalJobsCompleted + m.totalJobsFailed;
        if (totalJobs == 0) return 5000; 

        uint256 completionRate = (m.totalJobsCompleted * 10000) / totalJobs;

        if (m.subJobsCreated > 0) {
            uint256 subRate = (m.subJobsCompleted * 10000) / m.subJobsCreated;
            return (completionRate * 7000 + subRate * 3000) / 10000;
        }

        return completionRate;
    }

    function resetMetrics(address agent) external onlyOwner {
        if (agent == address(0)) revert InvalidAgent();

        metrics[agent] = AgentMetrics({
            totalJobsCompleted: 0,
            totalJobsFailed: 0,
            reputationScore: 5000,
            totalStakeSlashed: 0,
            isSlashed: false,
            subJobsCreated: 0,
            subJobsCompleted: 0,
            totalEarned: 0
        });

        emit MetricsReset(agent);
    }
}
