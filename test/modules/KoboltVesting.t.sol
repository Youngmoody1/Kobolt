// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KoboltVesting} from "../../src/modules/KoboltVesting.sol";
import {MockToken, FeeToken} from "./Mocks.sol";

contract KoboltVestingTest is Test {
    MockToken token;
    KoboltVesting vault;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint64 t0;

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = uint64(block.timestamp);
        token = new MockToken();
        token.transfer(owner, 100_000_000 ether);
        vault = new KoboltVesting(IERC20(address(token)), owner);
        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);
    }

    function create(address who, uint256 amount, uint64 cliff, uint64 duration) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createSchedule(who, amount, t0, cliff, duration);
    }

    function test_LinearAfterCliff() public {
        uint256 id = create(alice, 1200 ether, 90 days, 360 days);
        assertEq(vault.totalLocked(), 1200 ether);
        vm.warp(t0 + 89 days);
        assertEq(vault.claimable(id), 0);
        vm.warp(t0 + 90 days);
        assertEq(vault.claimable(id), 300 ether);
        vm.warp(t0 + 180 days);
        vm.prank(alice);
        assertEq(vault.claim(id), 600 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        vm.warp(t0 + 400 days);
        vm.prank(alice);
        assertEq(vault.claim(id), 600 ether);
        assertEq(vault.totalLocked(), 0);
        vm.prank(alice);
        vm.expectRevert(KoboltVesting.NothingToClaim.selector);
        vault.claim(id);
    }

    function test_OnlyOwnerCreates() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.createSchedule(alice, 1, t0, 0, 1 days);
    }

    function test_OnlyBeneficiaryClaims() public {
        uint256 id = create(alice, 100 ether, 0, 10 days);
        vm.warp(t0 + 5 days);
        vm.prank(bob);
        vm.expectRevert(KoboltVesting.NotBeneficiary.selector);
        vault.claim(id);
        vm.prank(owner);
        vm.expectRevert(KoboltVesting.NotBeneficiary.selector);
        vault.claim(id);
    }

    function test_OwnerCannotTakeTokensOut() public {
        create(alice, 100 ether, 0, 10 days);
        // The vault has no withdraw, sweep or revoke; the only way out is claim().
        assertEq(token.balanceOf(address(vault)), 100 ether);
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function test_Batch() public {
        address[] memory who = new address[](2);
        who[0] = alice;
        who[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 300 ether;
        vm.prank(owner);
        uint256 first = vault.createSchedules(who, amounts, t0, 0, 100 days);
        assertEq(first, 0);
        assertEq(vault.scheduleCount(), 2);
        assertEq(vault.totalLocked(), 400 ether);
        assertEq(vault.schedulesOf(bob)[0], 1);
        vm.warp(t0 + 50 days);
        assertEq(vault.claimable(1), 150 ether);
    }

    function test_FutureStart() public {
        vm.prank(owner);
        uint256 id = vault.createSchedule(alice, 100 ether, t0 + 30 days, 0, 10 days);
        vm.warp(t0 + 29 days);
        assertEq(vault.claimable(id), 0);
        vm.warp(t0 + 35 days);
        assertEq(vault.claimable(id), 50 ether);
    }

    function test_RejectsBadInput() public {
        vm.startPrank(owner);
        vm.expectRevert(KoboltVesting.InvalidBeneficiary.selector);
        vault.createSchedule(address(0), 1, t0, 0, 1 days);
        vm.expectRevert(KoboltVesting.InvalidAmount.selector);
        vault.createSchedule(alice, 0, t0, 0, 1 days);
        vm.expectRevert(KoboltVesting.InvalidDuration.selector);
        vault.createSchedule(alice, 1, t0, 0, 0);
        vm.expectRevert(KoboltVesting.CliffAfterEnd.selector);
        vault.createSchedule(alice, 1, t0, 2 days, 1 days);
        vm.expectRevert(KoboltVesting.UnknownSchedule.selector);
        vault.claim(5);
        vm.stopPrank();
    }

    function test_RefusesFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        KoboltVesting v = new KoboltVesting(IERC20(address(fee)), address(this));
        fee.approve(address(v), type(uint256).max);
        vm.expectRevert(KoboltVesting.UnsupportedToken.selector);
        v.createSchedule(alice, 100 ether, t0, 0, 1 days);
    }

    function testFuzz_NeverMoreThanTotal(uint256 amount, uint64 cliff, uint64 duration, uint64 at) public {
        amount = bound(amount, 1, 100_000_000 ether);
        duration = uint64(bound(duration, 1, 20 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));
        at = uint64(bound(at, 0, 30 * 365 days));
        uint256 id = create(alice, amount, cliff, duration);
        vm.warp(t0 + at);
        uint256 c = vault.claimable(id);
        assertLe(c, amount);
        if (at >= duration) assertEq(c, amount);
        if (at < cliff) assertEq(c, 0);
    }
}
