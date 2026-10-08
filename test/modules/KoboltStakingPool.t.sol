// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KoboltStakingPool} from "../../src/modules/KoboltStakingPool.sol";
import {MockToken, FeeToken} from "./Mocks.sol";

contract KoboltStakingPoolTest is Test {
    uint256 constant YEAR = 365 days;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    MockToken token;
    KoboltStakingPool pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockToken();
        pool = new KoboltStakingPool(IERC20(address(token)), owner, 1000, YEAR, 7 days);
        token.approve(address(pool), type(uint256).max);
        token.transfer(alice, 30_000_000 ether);
        token.transfer(bob, 30_000_000 ether);
        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        token.approve(address(pool), type(uint256).max);
    }

    function stake(address who, uint256 amount) internal {
        vm.prank(who);
        pool.stake(amount);
    }

    function test_OnlyOwnerFunds() public {
        pool.fund(1_000_000 ether);
        assertApproxEqAbs(pool.rewardsPerYear(), 1_000_000 ether, 1 ether);
        assertEq(pool.undistributed(), 1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.fund(1);
    }

    function test_CappedAtMaxApr() public {
        pool.fund(1_000_000 ether);
        stake(alice, 100_000 ether);
        vm.warp(block.timestamp + YEAR);
        assertApproxEqAbs(pool.earned(alice), 10_000 ether, 1 ether);
        assertApproxEqAbs(pool.undistributed(), 990_000 ether, 1 ether);
    }

    function test_FollowsFundedRateBelowCap() public {
        pool.fund(1_000_000 ether);
        stake(alice, 20_000_000 ether);
        vm.warp(block.timestamp + YEAR / 2);
        assertApproxEqAbs(pool.earned(alice), 500_000 ether, 1 ether);
    }

    function test_ProportionalShares() public {
        pool.fund(1_000_000 ether);
        stake(alice, 15_000_000 ether);
        stake(bob, 5_000_000 ether);
        vm.warp(block.timestamp + YEAR / 2);
        assertApproxEqAbs(pool.earned(alice), 375_000 ether, 1 ether);
        assertApproxEqAbs(pool.earned(bob), 125_000 ether, 1 ether);
    }

    function test_UnstakeAnytime() public {
        stake(alice, 1_000 ether);
        vm.prank(alice);
        pool.unstake(400 ether);
        assertEq(pool.stakeOf(alice), 600 ether);
        assertEq(pool.totalStaked(), 600 ether);
        assertEq(token.balanceOf(alice), 30_000_000 ether - 600 ether);
        vm.prank(alice);
        vm.expectRevert(KoboltStakingPool.MoreThanStaked.selector);
        pool.unstake(601 ether);
    }

    function test_ClaimKeepsStake() public {
        pool.fund(1_000_000 ether);
        stake(alice, 20_000_000 ether);
        vm.warp(block.timestamp + YEAR / 4);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.claim();
        assertApproxEqAbs(paid, 250_000 ether, 1 ether);
        assertEq(token.balanceOf(alice), before + paid);
        assertEq(pool.stakeOf(alice), 20_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(KoboltStakingPool.NothingToClaim.selector);
        pool.claim();
    }

    function test_LeftoverCanBeRespread() public {
        pool.fund(1_000_000 ether);
        vm.warp(block.timestamp + YEAR + 1); // nobody staked, nothing paid out
        assertEq(pool.rewardsPerYear(), 0);
        assertEq(pool.undistributed(), 1_000_000 ether);
        pool.fund(0);
        assertApproxEqAbs(pool.rewardsPerYear(), 1_000_000 ether, 1 ether);
        stake(alice, 20_000_000 ether);
        vm.warp(block.timestamp + YEAR / 2);
        assertApproxEqAbs(pool.earned(alice), 500_000 ether, 1 ether);
    }

    function test_FundZeroWithEmptyPoolReverts() public {
        vm.expectRevert(KoboltStakingPool.InvalidAmount.selector);
        pool.fund(0);
    }

    function test_QualifiedStakeNeedsMaturity() public {
        stake(alice, 50_000 ether);
        assertEq(pool.qualifiedStakeOf(alice), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(pool.qualifiedStakeOf(alice), 50_000 ether);
        stake(alice, 10_000 ether);
        assertEq(pool.qualifiedStakeOf(alice), 50_000 ether);
        vm.warp(block.timestamp + 7 days);
        assertEq(pool.qualifiedStakeOf(alice), 60_000 ether);
        stake(alice, 5_000 ether);
        vm.prank(alice);
        pool.unstake(5_000 ether);
        assertEq(pool.qualifiedStakeOf(alice), 60_000 ether);
    }

    function test_StakeIsSafeFromOwner() public {
        stake(alice, 1_000 ether);
        pool.transferOwnership(bob);
        vm.prank(bob);
        pool.acceptOwnership();
        // No owner function moves staked tokens; alice can always leave.
        vm.prank(alice);
        pool.unstake(1_000 ether);
        assertEq(token.balanceOf(alice), 30_000_000 ether);
    }

    function test_RejectsInvalidParameters() public {
        vm.expectRevert(KoboltStakingPool.InvalidParameter.selector);
        new KoboltStakingPool(IERC20(address(0)), owner, 1000, YEAR, 7 days);
        vm.expectRevert(KoboltStakingPool.InvalidParameter.selector);
        new KoboltStakingPool(IERC20(address(token)), owner, 1000, 0, 7 days);
        vm.expectRevert(KoboltStakingPool.InvalidParameter.selector);
        new KoboltStakingPool(IERC20(address(token)), owner, 100_001, YEAR, 7 days);
        vm.expectRevert(KoboltStakingPool.InvalidAmount.selector);
        pool.stake(0);
    }

    function test_RefusesFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        KoboltStakingPool p = new KoboltStakingPool(IERC20(address(fee)), owner, 0, YEAR, 0);
        fee.approve(address(p), type(uint256).max);
        vm.expectRevert(KoboltStakingPool.UnsupportedToken.selector);
        p.stake(100 ether);
    }

    function testFuzz_NeverPaysMoreThanFunded(uint96 funded, uint96 a, uint96 b, uint32 t1, uint32 t2) public {
        funded = uint96(bound(funded, 1, 1_000_000 ether));
        a = uint96(bound(a, 1, 10_000_000 ether));
        b = uint96(bound(b, 1, 10_000_000 ether));
        pool.fund(funded);
        stake(alice, a);
        vm.warp(block.timestamp + t1);
        stake(bob, b);
        vm.warp(block.timestamp + t2);
        uint256 paid;
        if (pool.earned(alice) > 0) {
            vm.prank(alice);
            paid += pool.claim();
        }
        if (pool.earned(bob) > 0) {
            vm.prank(bob);
            paid += pool.claim();
        }
        assertLe(paid, funded);
        assertEq(token.balanceOf(address(pool)), uint256(a) + b + funded - paid);
        // Everyone can always get their stake back.
        vm.prank(alice);
        pool.unstake(a);
        vm.prank(bob);
        pool.unstake(b);
    }
}
