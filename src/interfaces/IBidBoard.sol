// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IBidBoard
/// @notice Competitive job bidding interface for ArcHive.
interface IBidBoard {
    struct Bid {
        address bidder;
        uint256 price;
        uint64 estimatedDelivery;
        uint256 reputationScore;
        bytes32 proofOfCapability;
        uint64 timestamp;
        bool accepted;
    }


    function postBid(
        uint256 jobId,
        uint256 price,
        uint64 estimatedDelivery,
        bytes32 proofOfCapability
    ) external;


    function acceptBid(uint256 jobId, address bidder) external;

    function getBids(uint256 jobId) external view returns (Bid[] memory);

    function getBid(uint256 jobId, address bidder) external view returns (Bid memory);

    function getBidCount(uint256 jobId) external view returns (uint256);

    event BidPosted(
        uint256 indexed jobId,
        address indexed bidder,
        uint256 price,
        uint64 estimatedDelivery,
        uint256 reputationScore
    );

    event BidAccepted(
        uint256 indexed jobId,
        address indexed bidder,
        uint256 price
    );
}
