// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IBidBoard} from "src/interfaces/IBidBoard.sol";
import {JobManager} from "src/JobManager.sol";
import {MarketplaceRegistry} from "src/MarketplaceRegistry.sol";
import {ReputationOracle} from "src/ReputationOracle.sol";

/// @title BidBoard
/// @notice Competitive job bidding marketplace — reputation-weighted agent selection.

 contract BidBoard is IBidBoard {

    JobManager public immutable jobManager;
    MarketplaceRegistry public immutable registry;
    ReputationOracle public immutable reputation;

    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(uint256 => address[]) public bidders;
    mapping(uint256 => bool) public jobHasAcceptedBid;
    error NotRegistered();
    error AgentSlashed();
    error AlreadyBid();
    error JobNotOpen();
    error NoBidFound();
    error BidAlreadyAccepted();
    error NotClientOrEvaluator();
    error BelowMinimumReputation();
    error CannotBidOwnJob();
    error JobNotBiddable();

    constructor(
        address jobManagerAddress,
        address registryAddress,
        address reputationAddress
    ) {
        jobManager = JobManager(jobManagerAddress);
        registry = MarketplaceRegistry(registryAddress);
        reputation = ReputationOracle(reputationAddress);
    }

    function postBid(
        uint256 jobId,
        uint256 price,
        uint64 estimatedDelivery,
        bytes32 proofOfCapability
    ) external {
        if (!registry.isRegistered(msg.sender)) revert NotRegistered();
        if (reputation.isSlashed(msg.sender)) revert AgentSlashed();
        if (!reputation.meetsMinimumScore(msg.sender))
            revert BelowMinimumReputation();

        JobManager.Job memory job = jobManager.getJob(jobId);
        if (job.status != JobManager.JobStatus.Open) revert JobNotOpen();
        if (!jobManager.isBiddable(jobId)) revert JobNotBiddable();
        if (msg.sender == job.client) revert CannotBidOwnJob();
        if (bids[jobId][msg.sender].timestamp != 0) revert AlreadyBid();
        uint256 score = reputation.getScore(msg.sender);
        Bid memory newBid = Bid({
            bidder: msg.sender,
            price: price,
            estimatedDelivery: estimatedDelivery,
            reputationScore: score,
            proofOfCapability: proofOfCapability,
            timestamp: uint64(block.timestamp),
            accepted: false
        });
        bids[jobId][msg.sender] = newBid;
        bidders[jobId].push(msg.sender);
        emit BidPosted(jobId, msg.sender, price, estimatedDelivery, score);
    }

    function acceptBid(uint256 jobId, address bidder) external {
        JobManager.Job memory job = jobManager.getJob(jobId);
        if (msg.sender != job.client && msg.sender != job.evaluator)
            revert NotClientOrEvaluator();
        if (jobHasAcceptedBid[jobId]) revert BidAlreadyAccepted();
        if (job.status != JobManager.JobStatus.Open) revert JobNotOpen();
        if (!jobManager.isBiddable(jobId)) revert JobNotBiddable();
        Bid storage bid = bids[jobId][bidder];
        if (bid.timestamp == 0) revert NoBidFound();
        bid.accepted = true;
        jobHasAcceptedBid[jobId] = true;
        jobManager.claimAcceptedBid(jobId, bidder);
        emit BidAccepted(jobId, bidder, bid.price);
    }

    function getBids(uint256 jobId) external view returns (Bid[] memory) {
        address[] storage jobBidders = bidders[jobId];
        Bid[] memory result = new Bid[](jobBidders.length);
        for (uint256 i = 0; i < jobBidders.length; i++) {
            result[i] = bids[jobId][jobBidders[i]];
        }
        return result;
    }

    function getBid(
        uint256 jobId,
        address bidder
    ) external view returns (Bid memory) {
        return bids[jobId][bidder];
    }

    function getBidCount(uint256 jobId) external view returns (uint256) {
        return bidders[jobId].length;
    }

    function getAcceptedBid(uint256 jobId) external view returns (Bid memory) {
        address[] storage jobBidders = bidders[jobId];
        for (uint256 i = 0; i < jobBidders.length; i++) {
            if (bids[jobId][jobBidders[i]].accepted) {
                return bids[jobId][jobBidders[i]];
            }
        }
        revert NoBidFound();
    }
}
