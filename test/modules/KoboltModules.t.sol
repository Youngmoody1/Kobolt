// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KoboltModules} from "../../src/modules/KoboltModules.sol";
import {KoboltVesting} from "../../src/modules/KoboltVesting.sol";
import {KoboltStakingPool} from "../../src/modules/KoboltStakingPool.sol";
import {MockToken, FeeToken, MockPosition, RejectingTreasury} from "./Mocks.sol";

contract KoboltModulesTest is Test {
    uint256 constant PRICE = 0.004 ether;
    KoboltModules modules;
    MockToken token;
    MockToken lp;
    MockPosition nft;
    address admin = makeAddr("admin");
    address payable treasury = payable(makeAddr("treasury"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function prices(uint256 p) internal pure returns (KoboltModules.Prices memory) {
        return KoboltModules.Prices({vesting: p, staking: p, airdrop: p, lock: p});
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        modules = new KoboltModules(admin, treasury, prices(PRICE));
        token = new MockToken();
        lp = new MockToken();
        nft = new MockPosition();
        token.transfer(alice, 1_000_000 ether);
        lp.transfer(alice, 1_000 ether);
        nft.mint(alice, 7);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(modules), type(uint256).max);
        lp.approve(address(modules), type(uint256).max);
        nft.approve(address(modules), 7);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ vesting + staking

    function test_CreatesVaultOwnedByCaller() public {
        vm.prank(alice);
        address v = modules.createVesting{value: PRICE}(IERC20(address(token)));
        KoboltVesting vault = KoboltVesting(v);
        assertEq(vault.owner(), alice);
        assertEq(address(vault.token()), address(token));
        assertTrue(modules.isKoboltModule(v));
        assertEq(modules.vaultsOf(address(token))[0], v);
        assertEq(modules.modulesByCreator(alice)[0], v);
        assertEq(modules.totalVaults(), 1);
        assertEq(treasury.balance, PRICE);
        assertEq(address(modules).balance, 0);
    }

    function test_CreatesPoolOwnedByCaller() public {
        vm.prank(alice);
        address p = modules.createStakingPool{value: PRICE}(IERC20(address(token)), 2000, 365 days, 7 days);
        KoboltStakingPool pool = KoboltStakingPool(p);
        assertEq(pool.owner(), alice);
        assertEq(pool.maxAprBps(), 2000);
        assertEq(modules.poolsOf(address(token))[0], p);
        assertEq(modules.totalPools(), 1);
        assertEq(treasury.balance, PRICE);
    }

    function test_AdminHasNoPowerOverModules() public {
        vm.startPrank(alice);
        KoboltVesting vault = KoboltVesting(modules.createVesting{value: PRICE}(IERC20(address(token))));
        KoboltStakingPool pool =
            KoboltStakingPool(modules.createStakingPool{value: PRICE}(IERC20(address(token)), 0, 30 days, 0));
        vm.stopPrank();
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vault.createSchedule(admin, 1, 0, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        pool.fund(1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ fees

    function test_RejectsWrongFee() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KoboltModules.WrongFee.selector, PRICE, 0));
        modules.createVesting(IERC20(address(token)));
        vm.expectRevert(abi.encodeWithSelector(KoboltModules.WrongFee.selector, PRICE, PRICE + 1));
        modules.createStakingPool{value: PRICE + 1}(IERC20(address(token)), 0, 30 days, 0);
        vm.stopPrank();
        assertEq(treasury.balance, 0);
    }

    function test_PricesAreCappedAndOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        modules.setPrices(prices(0));
        vm.startPrank(admin);
        vm.expectRevert(KoboltModules.FeeTooHigh.selector);
        modules.setPrices(KoboltModules.Prices({vesting: 0, staking: 0, airdrop: 0, lock: 0.02 ether + 1}));
        modules.setPrices(prices(0));
        vm.stopPrank();
        vm.prank(alice);
        modules.createVesting(IERC20(address(token)));
        assertEq(treasury.balance, 0);
        vm.expectRevert(KoboltModules.FeeTooHigh.selector);
        new KoboltModules(admin, treasury, prices(1 ether));
    }

    function test_RevertsWhenTreasuryRejects() public {
        RejectingTreasury bad = new RejectingTreasury();
        vm.prank(admin);
        modules.setTreasury(payable(address(bad)));
        vm.prank(alice);
        vm.expectRevert(KoboltModules.FeeTransferFailed.selector);
        modules.createVesting{value: PRICE}(IERC20(address(token)));
    }

    function test_RejectsZeroAddresses() public {
        vm.prank(admin);
        vm.expectRevert(KoboltModules.ZeroAddress.selector);
        modules.setTreasury(payable(address(0)));
        vm.expectRevert(KoboltModules.ZeroAddress.selector);
        new KoboltModules(admin, payable(address(0)), prices(0));
        vm.prank(alice);
        vm.expectRevert(KoboltModules.ZeroAddress.selector);
        modules.createVesting{value: PRICE}(IERC20(address(0)));
    }

    // ------------------------------------------------------------ airdrop

    function test_Airdrop() public {
        address[] memory to = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            to[i] = address(uint160(1000 + i));
            amounts[i] = (i + 1) * 10 ether;
        }
        vm.prank(alice);
        uint256 total = modules.airdrop{value: PRICE}(IERC20(address(token)), to, amounts);
        assertEq(total, 60 ether);
        assertEq(token.balanceOf(to[2]), 30 ether);
        assertEq(token.balanceOf(alice), 1_000_000 ether - 60 ether);
        assertEq(token.balanceOf(address(modules)), 0);
        assertEq(modules.totalAirdrops(), 1);
        assertEq(treasury.balance, PRICE);
    }

    function test_AirdropValidation() public {
        address[] memory to = new address[](2);
        uint256[] memory one = new uint256[](1);
        vm.startPrank(alice);
        vm.expectRevert(KoboltModules.LengthMismatch.selector);
        modules.airdrop{value: PRICE}(IERC20(address(token)), to, one);
        vm.expectRevert(KoboltModules.NoRecipients.selector);
        modules.airdrop{value: PRICE}(IERC20(address(token)), new address[](0), new uint256[](0));
        vm.expectRevert(KoboltModules.TooManyRecipients.selector);
        modules.airdrop{value: PRICE}(IERC20(address(token)), new address[](501), new uint256[](501));
        uint256[] memory two = new uint256[](2);
        two[0] = 1;
        two[1] = 1;
        vm.expectRevert(KoboltModules.ZeroAddress.selector);
        modules.airdrop{value: PRICE}(IERC20(address(token)), to, two);
        vm.stopPrank();
    }

    function test_AirdropCanOnlySpendCallersTokens() public {
        address[] memory to = new address[](1);
        to[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.deal(bob, 1 ether);
        // Alice approved the contract, but bob cannot use that approval.
        vm.prank(bob);
        vm.expectRevert();
        modules.airdrop{value: PRICE}(IERC20(address(token)), to, amounts);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
    }

    // ------------------------------------------------------------ liquidity lock

    function test_LockAndWithdrawErc20() public {
        uint64 unlockAt = uint64(block.timestamp + 180 days);
        vm.prank(alice);
        uint256 id = modules.lockTokens{value: PRICE}(IERC20(address(lp)), 400 ether, unlockAt);
        KoboltModules.Lock memory l = modules.getLock(id);
        assertEq(l.owner, alice);
        assertEq(l.amount, 400 ether);
        assertEq(l.unlockAt, unlockAt);
        assertEq(lp.balanceOf(address(modules)), 400 ether);
        assertEq(modules.locksOf(alice)[0], id);
        assertEq(modules.locksByAsset(address(lp))[0], id);

        vm.prank(alice);
        vm.expectRevert(KoboltModules.StillLocked.selector);
        modules.withdraw(id);

        vm.warp(unlockAt);
        vm.prank(bob);
        vm.expectRevert(KoboltModules.NotLockOwner.selector);
        modules.withdraw(id);
        vm.prank(alice);
        modules.withdraw(id);
        assertEq(lp.balanceOf(alice), 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(KoboltModules.AlreadyWithdrawn.selector);
        modules.withdraw(id);
    }

    function test_LockNft() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        vm.prank(alice);
        uint256 id = modules.lockNft{value: PRICE}(IERC721(address(nft)), 7, unlockAt);
        assertEq(nft.ownerOf(7), address(modules));
        vm.warp(unlockAt);
        vm.prank(alice);
        modules.withdraw(id);
        assertEq(nft.ownerOf(7), alice);
    }

    function test_ExtendOnlyLater() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        vm.startPrank(alice);
        uint256 id = modules.lockTokens{value: PRICE}(IERC20(address(lp)), 1 ether, unlockAt);
        vm.expectRevert(KoboltModules.InvalidUnlockTime.selector);
        modules.extendLock(id, unlockAt - 1);
        modules.extendLock(id, unlockAt + 60 days);
        vm.stopPrank();
        assertEq(modules.getLock(id).unlockAt, unlockAt + 60 days);
        vm.warp(unlockAt + 1);
        vm.prank(alice);
        vm.expectRevert(KoboltModules.StillLocked.selector);
        modules.withdraw(id);
    }

    function test_TransferLock() public {
        vm.prank(alice);
        uint256 id = modules.lockTokens{value: PRICE}(IERC20(address(lp)), 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(alice);
        modules.transferLock(id, bob);
        assertEq(modules.getLock(id).owner, bob);
        assertEq(modules.locksOf(bob)[0], id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(KoboltModules.NotLockOwner.selector);
        modules.withdraw(id);
        vm.prank(bob);
        modules.withdraw(id);
        assertEq(lp.balanceOf(bob), 1 ether);
    }

    function test_LockValidation() public {
        vm.startPrank(alice);
        vm.expectRevert(KoboltModules.InvalidUnlockTime.selector);
        modules.lockTokens{value: PRICE}(IERC20(address(lp)), 1, uint64(block.timestamp));
        vm.expectRevert(KoboltModules.InvalidUnlockTime.selector);
        modules.lockTokens{value: PRICE}(IERC20(address(lp)), 1, uint64(block.timestamp + 51 * 365 days));
        vm.expectRevert(KoboltModules.InvalidAmount.selector);
        modules.lockTokens{value: PRICE}(IERC20(address(lp)), 0, uint64(block.timestamp + 1 days));
        vm.expectRevert(KoboltModules.UnknownLock.selector);
        modules.withdraw(99);
        vm.stopPrank();
    }

    function test_LockRefusesFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        fee.approve(address(modules), type(uint256).max);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(KoboltModules.UnsupportedToken.selector);
        modules.lockTokens{value: PRICE}(IERC20(address(fee)), 100 ether, uint64(block.timestamp + 1 days));
    }

    function test_AdminCannotTouchLocks() public {
        vm.prank(alice);
        uint256 id = modules.lockTokens{value: PRICE}(IERC20(address(lp)), 1 ether, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.startPrank(admin);
        vm.expectRevert(KoboltModules.NotLockOwner.selector);
        modules.withdraw(id);
        vm.expectRevert(KoboltModules.NotLockOwner.selector);
        modules.transferLock(id, admin);
        vm.stopPrank();
    }

    function testFuzz_LocksHoldExactBalances(uint96 a, uint96 b, uint32 d) public {
        a = uint96(bound(a, 1, 500 ether));
        b = uint96(bound(b, 1, 500 ether));
        uint64 unlockAt = uint64(block.timestamp + bound(d, 1, 50 * 365 days));
        vm.startPrank(alice);
        uint256 i1 = modules.lockTokens{value: PRICE}(IERC20(address(lp)), a, unlockAt);
        uint256 i2 = modules.lockTokens{value: PRICE}(IERC20(address(lp)), b, unlockAt);
        assertEq(lp.balanceOf(address(modules)), uint256(a) + b);
        vm.warp(unlockAt);
        modules.withdraw(i1);
        modules.withdraw(i2);
        vm.stopPrank();
        assertEq(lp.balanceOf(alice), 1_000 ether);
        assertEq(lp.balanceOf(address(modules)), 0);
    }
}
