// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MilestoneCrowdfunding} from "../src/MilestoneCrowdfunding.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
}

contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq(uint256) failed");
    }

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue failed");
    }
}

contract MockERC20 {
    string public constant name = "Mock Token";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MilestoneCrowdfundingTest is TestBase {
    MilestoneCrowdfunding internal crowdfunding;
    MockERC20 internal token;

    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);

    uint256 internal constant TARGET = 100 ether;
    uint256 internal constant FIRST = 40 ether;
    uint256 internal constant SECOND = 60 ether;
    uint256 internal constant USER_FUNDS = 1_000 ether;

    function setUp() public {
        crowdfunding = new MilestoneCrowdfunding();
        token = new MockERC20();

        token.mint(ALICE, USER_FUNDS);
        token.mint(BOB, USER_FUNDS);

        vm.prank(ALICE);
        token.approve(address(crowdfunding), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(crowdfunding), type(uint256).max);
    }

    function testTargetSuccessAndPartialRelease() public {
        (uint256 campaignId,) = _createCampaign();
        _fullyFund(campaignId);

        assertTrue(crowdfunding.isTargetReached(campaignId));

        crowdfunding.approveMilestone(campaignId, 0);
        vm.prank(CREATOR);
        crowdfunding.releaseMilestone(campaignId, 0);

        MilestoneCrowdfunding.Campaign memory campaign = crowdfunding.getCampaign(campaignId);
        assertEq(campaign.totalContributed, TARGET);
        assertEq(campaign.totalReleased, FIRST);
        assertEq(campaign.nextMilestone, 1);
        assertEq(token.balanceOf(CREATOR), FIRST);
        assertEq(crowdfunding.escrowedAmount(campaignId), SECOND);

        MilestoneCrowdfunding.Milestone memory second = crowdfunding.getMilestone(campaignId, 1);
        assertTrue(!second.released);
    }

    function testTargetFailureAllowsRefundAfterDeadline() public {
        (uint256 campaignId, uint64 deadline) = _createCampaign();

        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, FIRST);

        vm.warp(uint256(deadline) + 1);
        vm.prank(ALICE);
        crowdfunding.claimRefund(campaignId);

        MilestoneCrowdfunding.Campaign memory campaign = crowdfunding.getCampaign(campaignId);
        assertEq(campaign.totalContributed, FIRST);
        assertEq(campaign.totalRefunded, FIRST);
        assertEq(crowdfunding.escrowedAmount(campaignId), 0);
        assertEq(token.balanceOf(ALICE), USER_FUNDS);
    }

    function testDuplicateRefundReverts() public {
        (uint256 campaignId, uint64 deadline) = _createCampaign();

        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, FIRST);
        vm.warp(uint256(deadline) + 1);

        vm.prank(ALICE);
        crowdfunding.claimRefund(campaignId);

        vm.expectRevert(MilestoneCrowdfunding.AlreadyRefunded.selector);
        vm.prank(ALICE);
        crowdfunding.claimRefund(campaignId);
    }

    function testMilestonesMustBeApprovedAndReleasedInOrder() public {
        (uint256 campaignId,) = _createCampaign();
        _fullyFund(campaignId);

        vm.expectRevert(MilestoneCrowdfunding.MilestoneOutOfOrder.selector);
        crowdfunding.approveMilestone(campaignId, 1);

        vm.expectRevert(MilestoneCrowdfunding.MilestoneNotApproved.selector);
        vm.prank(CREATOR);
        crowdfunding.releaseMilestone(campaignId, 0);

        crowdfunding.approveMilestone(campaignId, 0);
        vm.prank(CREATOR);
        crowdfunding.releaseMilestone(campaignId, 0);

        crowdfunding.approveMilestone(campaignId, 1);
        vm.prank(CREATOR);
        crowdfunding.releaseMilestone(campaignId, 1);

        assertEq(token.balanceOf(CREATOR), TARGET);
        assertEq(crowdfunding.escrowedAmount(campaignId), 0);
    }

    function testUnauthorizedApprovalReverts() public {
        (uint256 campaignId,) = _createCampaign();
        _fullyFund(campaignId);

        vm.expectRevert(MilestoneCrowdfunding.NotOwner.selector);
        vm.prank(ATTACKER);
        crowdfunding.approveMilestone(campaignId, 0);
    }

    function testCreatorCannotWithdrawBeforeTarget() public {
        (uint256 campaignId,) = _createCampaign();

        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, FIRST);

        vm.expectRevert(MilestoneCrowdfunding.TargetNotReached.selector);
        crowdfunding.approveMilestone(campaignId, 0);
    }

    function testContributionAfterDeadlineReverts() public {
        (uint256 campaignId, uint64 deadline) = _createCampaign();
        vm.warp(uint256(deadline));

        vm.expectRevert(MilestoneCrowdfunding.CampaignEnded.selector);
        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, 1 ether);
    }

    function testCancelledCampaignRefundsContributors() public {
        (uint256 campaignId,) = _createCampaign();

        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, 30 ether);
        vm.prank(BOB);
        crowdfunding.contribute(campaignId, 20 ether);

        vm.prank(CREATOR);
        crowdfunding.cancelCampaign(campaignId);

        vm.prank(ALICE);
        crowdfunding.claimRefund(campaignId);
        vm.prank(BOB);
        crowdfunding.claimRefund(campaignId);

        MilestoneCrowdfunding.Campaign memory campaign = crowdfunding.getCampaign(campaignId);
        assertEq(campaign.totalContributed, 50 ether);
        assertEq(campaign.totalRefunded, 50 ether);
        assertEq(crowdfunding.escrowedAmount(campaignId), 0);
    }

    function testExplicitRefundCondition() public {
        (uint256 campaignId,) = _createCampaign();
        _fullyFund(campaignId);

        crowdfunding.enableRefunds(campaignId);

        vm.prank(ALICE);
        crowdfunding.claimRefund(campaignId);
        vm.prank(BOB);
        crowdfunding.claimRefund(campaignId);

        assertEq(crowdfunding.escrowedAmount(campaignId), 0);
        assertEq(token.balanceOf(ALICE), USER_FUNDS);
        assertEq(token.balanceOf(BOB), USER_FUNDS);
    }

    function testConservationAfterPartialRelease() public {
        (uint256 campaignId,) = _createCampaign();
        _fullyFund(campaignId);

        crowdfunding.approveMilestone(campaignId, 0);
        vm.prank(CREATOR);
        crowdfunding.releaseMilestone(campaignId, 0);

        MilestoneCrowdfunding.Campaign memory campaign = crowdfunding.getCampaign(campaignId);
        uint256 accounted = campaign.totalReleased + campaign.totalRefunded + crowdfunding.escrowedAmount(campaignId);
        assertEq(accounted, campaign.totalContributed);
        assertEq(token.balanceOf(address(crowdfunding)), crowdfunding.escrowedAmount(campaignId));
    }

    function _createCampaign() internal returns (uint256 campaignId, uint64 deadline) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = FIRST;
        amounts[1] = SECOND;
        deadline = uint64(block.timestamp + 7 days);

        vm.prank(CREATOR);
        campaignId = crowdfunding.createCampaign(address(token), TARGET, deadline, amounts);
    }

    function _fullyFund(uint256 campaignId) internal {
        vm.prank(ALICE);
        crowdfunding.contribute(campaignId, FIRST);
        vm.prank(BOB);
        crowdfunding.contribute(campaignId, SECOND);
    }
}
