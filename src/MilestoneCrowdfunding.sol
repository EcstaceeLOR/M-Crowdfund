// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MilestoneCrowdfunding
/// @notice Multi-campaign ERC-20 crowdfunding with ordered milestone approvals, releases, and refunds.
/// @dev The funding target is also the campaign cap, and milestone amounts must sum exactly to the target.
contract MilestoneCrowdfunding {
    error NotOwner();
    error NotCreator();
    error InvalidToken();
    error InvalidTarget();
    error InvalidDeadline();
    error InvalidMilestones();
    error InvalidAmount();
    error CampaignNotFound();
    error CampaignEnded();
    error CampaignCancelled();
    error TargetExceeded();
    error TargetNotReached();
    error MilestoneOutOfOrder();
    error MilestoneAlreadyApproved();
    error MilestoneNotApproved();
    error MilestoneAlreadyReleased();
    error RefundsActive();
    error RefundUnavailable();
    error AlreadyRefunded();
    error NoContribution();
    error FundsAlreadyReleased();
    error TransferFailed();
    error UnsupportedTokenBehavior();
    error Reentrancy();

    struct Campaign {
        address creator;
        address acceptedToken;
        uint256 target;
        uint64 deadline;
        uint256 totalContributed;
        uint256 totalReleased;
        uint256 totalRefunded;
        uint256 nextMilestone;
        bool cancelled;
        bool refundsEnabled;
    }

    struct Milestone {
        uint256 amount;
        bool approved;
        bool released;
    }

    address public immutable owner;
    uint256 public campaignCount;

    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => Milestone[]) private _milestones;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => uint256)) public refundedAmount;

    uint256 private _reentrancyStatus = 1;

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        address indexed acceptedToken,
        uint256 target,
        uint64 deadline
    );
    event ContributionReceived(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event MilestoneApproved(uint256 indexed campaignId, uint256 indexed milestoneIndex, uint256 amount);
    event MilestoneReleased(
        uint256 indexed campaignId,
        uint256 indexed milestoneIndex,
        address indexed creator,
        uint256 amount
    );
    event CampaignCancelledEvent(uint256 indexed campaignId);
    event RefundsEnabled(uint256 indexed campaignId);
    event RefundClaimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus != 1) revert Reentrancy();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Creates a campaign. Milestones must be non-zero and sum exactly to the target.
    function createCampaign(
        address acceptedToken,
        uint256 target,
        uint64 deadline,
        uint256[] calldata milestoneAmounts
    ) external returns (uint256 campaignId) {
        if (acceptedToken == address(0)) revert InvalidToken();
        if (target == 0) revert InvalidTarget();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (milestoneAmounts.length == 0) revert InvalidMilestones();

        uint256 sum;
        for (uint256 i; i < milestoneAmounts.length; ++i) {
            uint256 amount = milestoneAmounts[i];
            if (amount == 0) revert InvalidMilestones();
            sum += amount;
        }
        if (sum != target) revert InvalidMilestones();

        campaignId = ++campaignCount;
        Campaign storage campaign = _campaigns[campaignId];
        campaign.creator = msg.sender;
        campaign.acceptedToken = acceptedToken;
        campaign.target = target;
        campaign.deadline = deadline;

        for (uint256 i; i < milestoneAmounts.length; ++i) {
            _milestones[campaignId].push(Milestone({amount: milestoneAmounts[i], approved: false, released: false}));
        }

        emit CampaignCreated(campaignId, msg.sender, acceptedToken, target, deadline);
    }

    /// @notice Contributes the campaign's accepted ERC-20 token before the deadline.
    function contribute(uint256 campaignId, uint256 amount) external nonReentrant {
        Campaign storage campaign = _getCampaign(campaignId);
        if (campaign.cancelled) revert CampaignCancelled();
        if (campaign.refundsEnabled) revert RefundsActive();
        if (block.timestamp >= campaign.deadline) revert CampaignEnded();
        if (amount == 0) revert InvalidAmount();
        if (campaign.totalContributed + amount > campaign.target) revert TargetExceeded();

        IERC20 token = IERC20(campaign.acceptedToken);
        uint256 beforeBalance = token.balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTokenBehavior();

        contributions[campaignId][msg.sender] += amount;
        campaign.totalContributed += amount;

        emit ContributionReceived(campaignId, msg.sender, amount);
    }

    /// @notice Approves exactly the next milestone. Only the platform owner may approve.
    function approveMilestone(uint256 campaignId, uint256 milestoneIndex) external onlyOwner {
        Campaign storage campaign = _getCampaign(campaignId);
        if (campaign.cancelled) revert CampaignCancelled();
        if (campaign.refundsEnabled) revert RefundsActive();
        if (campaign.totalContributed < campaign.target) revert TargetNotReached();
        if (milestoneIndex != campaign.nextMilestone) revert MilestoneOutOfOrder();

        Milestone storage milestone = _milestoneAt(campaignId, milestoneIndex);
        if (milestone.released) revert MilestoneAlreadyReleased();
        if (milestone.approved) revert MilestoneAlreadyApproved();

        milestone.approved = true;
        emit MilestoneApproved(campaignId, milestoneIndex, milestone.amount);
    }

    /// @notice Releases exactly one approved milestone amount to the campaign creator.
    function releaseMilestone(uint256 campaignId, uint256 milestoneIndex) external nonReentrant {
        Campaign storage campaign = _getCampaign(campaignId);
        if (msg.sender != campaign.creator) revert NotCreator();
        if (campaign.cancelled) revert CampaignCancelled();
        if (campaign.refundsEnabled) revert RefundsActive();
        if (campaign.totalContributed < campaign.target) revert TargetNotReached();
        if (milestoneIndex != campaign.nextMilestone) revert MilestoneOutOfOrder();

        Milestone storage milestone = _milestoneAt(campaignId, milestoneIndex);
        if (milestone.released) revert MilestoneAlreadyReleased();
        if (!milestone.approved) revert MilestoneNotApproved();

        milestone.released = true;
        campaign.totalReleased += milestone.amount;
        campaign.nextMilestone = milestoneIndex + 1;

        _safeTransfer(IERC20(campaign.acceptedToken), campaign.creator, milestone.amount);
        emit MilestoneReleased(campaignId, milestoneIndex, campaign.creator, milestone.amount);
    }

    /// @notice Cancels a campaign before any milestone funds have been released.
    function cancelCampaign(uint256 campaignId) external {
        Campaign storage campaign = _getCampaign(campaignId);
        if (msg.sender != campaign.creator) revert NotCreator();
        if (campaign.cancelled) revert CampaignCancelled();
        if (campaign.totalReleased != 0) revert FundsAlreadyReleased();

        campaign.cancelled = true;
        emit CampaignCancelledEvent(campaignId);
    }

    /// @notice Activates the exceptional refund condition before any funds are released.
    /// @dev This is a one-way safety switch controlled by the platform owner.
    function enableRefunds(uint256 campaignId) external onlyOwner {
        Campaign storage campaign = _getCampaign(campaignId);
        if (campaign.totalReleased != 0) revert FundsAlreadyReleased();
        if (campaign.refundsEnabled) revert RefundsActive();

        campaign.refundsEnabled = true;
        emit RefundsEnabled(campaignId);
    }

    /// @notice Refunds a contributor if the campaign failed, was cancelled, or refunds were explicitly enabled.
    function claimRefund(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = _getCampaign(campaignId);
        uint256 contributed = contributions[campaignId][msg.sender];
        if (contributed == 0) revert NoContribution();
        if (refundedAmount[campaignId][msg.sender] != 0) revert AlreadyRefunded();

        bool targetFailed = block.timestamp >= campaign.deadline && campaign.totalContributed < campaign.target;
        if (!targetFailed && !campaign.cancelled && !campaign.refundsEnabled) revert RefundUnavailable();

        refundedAmount[campaignId][msg.sender] = contributed;
        campaign.totalRefunded += contributed;

        _safeTransfer(IERC20(campaign.acceptedToken), msg.sender, contributed);
        emit RefundClaimed(campaignId, msg.sender, contributed);
    }

    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        Campaign storage campaign = _getCampaign(campaignId);
        return campaign;
    }

    function milestoneCount(uint256 campaignId) external view returns (uint256) {
        _getCampaign(campaignId);
        return _milestones[campaignId].length;
    }

    function getMilestone(uint256 campaignId, uint256 milestoneIndex) external view returns (Milestone memory) {
        _getCampaign(campaignId);
        return _milestoneAt(campaignId, milestoneIndex);
    }

    /// @notice Internal campaign escrow according to contribution/release/refund accounting.
    function escrowedAmount(uint256 campaignId) public view returns (uint256) {
        Campaign storage campaign = _getCampaign(campaignId);
        return campaign.totalContributed - campaign.totalReleased - campaign.totalRefunded;
    }

    function isTargetReached(uint256 campaignId) external view returns (bool) {
        Campaign storage campaign = _getCampaign(campaignId);
        return campaign.totalContributed >= campaign.target;
    }

    function isRefundAvailable(uint256 campaignId) external view returns (bool) {
        Campaign storage campaign = _getCampaign(campaignId);
        bool targetFailed = block.timestamp >= campaign.deadline && campaign.totalContributed < campaign.target;
        return targetFailed || campaign.cancelled || campaign.refundsEnabled;
    }

    function _getCampaign(uint256 campaignId) internal view returns (Campaign storage campaign) {
        campaign = _campaigns[campaignId];
        if (campaign.creator == address(0)) revert CampaignNotFound();
    }

    function _milestoneAt(uint256 campaignId, uint256 milestoneIndex) internal view returns (Milestone storage milestone) {
        if (milestoneIndex >= _milestones[campaignId].length) revert MilestoneOutOfOrder();
        milestone = _milestones[campaignId][milestoneIndex];
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
