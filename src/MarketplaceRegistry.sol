// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title MarketplaceRegistry
/// @notice Marketplace specific metadata, capability indexing, and type classification.
contract MarketplaceRegistry {
    enum AgentType {
        General,      
        Specialist,   
        Evaluator,    
        Orchestrator  
    }

    struct AgentProfile {
        bool isRegistered;
        string endpoint;
        string metadataURI;
        uint256 stake;
        uint64 registeredAt;
        AgentType agentType;
    }

    mapping(address => AgentProfile) private profiles;
    mapping(address => mapping(bytes32 => bool)) private capabilities;
    mapping(bytes32 => address[]) private capabilityIndex;
    mapping(bytes32 => mapping(address => uint256)) private capabilityIndexPosition;
    address public owner;
    address public pendingOwner;


    event AgentRegistered(
        address indexed agent,
        string endpoint,
        string metadataURI,
        uint64 timestamp,
        AgentType agentType
    );
    event EndpointUpdated(address indexed agent, string newEndpoint);
    event CapabilityUpdated(
        address indexed agent,
        bytes32 indexed capability,
        bool enabled
    );
    event StakeUpdated(address indexed agent, uint256 newStake);
    event AgentTypeUpdated(address indexed agent, AgentType newType);


    error Unauthorized();
    error AgentNotRegistered();
    error InvalidInput();
    error AlreadyRegistered();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyRegistered() {
        if (!profiles[msg.sender].isRegistered) revert AgentNotRegistered();
        _;
    }

    constructor() {
        owner = msg.sender;
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


    function registerAgent(
        string calldata endpoint,
        string calldata metadataURI
    ) external {
        if (bytes(endpoint).length == 0) revert InvalidInput();
        if (profiles[msg.sender].isRegistered) revert AlreadyRegistered();

        profiles[msg.sender] = AgentProfile({
            isRegistered: true,
            endpoint: endpoint,
            metadataURI: metadataURI,
            stake: 0,
            registeredAt: uint64(block.timestamp),
            agentType: AgentType.General
        });

        emit AgentRegistered(
            msg.sender,
            endpoint,
            metadataURI,
            uint64(block.timestamp),
            AgentType.General
        );
    }


    function registerAgentWithType(
        string calldata endpoint,
        string calldata metadataURI,
        AgentType agentType
    ) external {
        if (bytes(endpoint).length == 0) revert InvalidInput();
        if (profiles[msg.sender].isRegistered) revert AlreadyRegistered();

        profiles[msg.sender] = AgentProfile({
            isRegistered: true,
            endpoint: endpoint,
            metadataURI: metadataURI,
            stake: 0,
            registeredAt: uint64(block.timestamp),
            agentType: agentType
        });

        emit AgentRegistered(
            msg.sender,
            endpoint,
            metadataURI,
            uint64(block.timestamp),
            agentType
        );
    }


    function updateEndpoint(
        string calldata newEndpoint
    ) external onlyRegistered {
        if (bytes(newEndpoint).length == 0) revert InvalidInput();
        profiles[msg.sender].endpoint = newEndpoint;
        emit EndpointUpdated(msg.sender, newEndpoint);
    }


    function setAgentType(AgentType newType) external onlyRegistered {
        profiles[msg.sender].agentType = newType;
        emit AgentTypeUpdated(msg.sender, newType);
    }


    function setCapability(
        bytes32 capability,
        bool enabled
    ) external onlyRegistered {
        if (capability == bytes32(0)) revert InvalidInput();

        bool current = capabilities[msg.sender][capability];
        capabilities[msg.sender][capability] = enabled;

        if (enabled && !current) {
            capabilityIndexPosition[capability][msg.sender] = capabilityIndex[capability].length;
            capabilityIndex[capability].push(msg.sender);
        } else if (!enabled && current) {
            uint256 idx = capabilityIndexPosition[capability][msg.sender];
            uint256 lastIdx = capabilityIndex[capability].length - 1;
            if (idx != lastIdx) {
                address lastAgent = capabilityIndex[capability][lastIdx];
                capabilityIndex[capability][idx] = lastAgent;
                capabilityIndexPosition[capability][lastAgent] = idx;
            }
            capabilityIndex[capability].pop();
            delete capabilityIndexPosition[capability][msg.sender];
        }

        emit CapabilityUpdated(msg.sender, capability, enabled);
    }


    function setStakeRequirement(
        address agent,
        uint256 amount
    ) external onlyOwner {
        if (agent == address(0)) revert InvalidInput();
        if (!profiles[agent].isRegistered) revert AgentNotRegistered();

        profiles[agent].stake = amount;
        emit StakeUpdated(agent, amount);
    }

    function isRegistered(address agent) external view returns (bool) {
        return profiles[agent].isRegistered;
    }

    function hasCapability(
        address agent,
        bytes32 capability
    ) external view returns (bool) {
        return capabilities[agent][capability];
    }

    function getProfile(
        address agent
    ) external view returns (AgentProfile memory) {
        return profiles[agent];
    }

    function getAgentType(address agent) external view returns (AgentType) {
        return profiles[agent].agentType;
    }

    function getStakeRequirement(
        address agent
    ) external view returns (uint256) {
        return profiles[agent].stake;
    }

    function getAgentsByCapability(
        bytes32 capability
    ) external view returns (address[] memory) {
        return capabilityIndex[capability];
    }
}
