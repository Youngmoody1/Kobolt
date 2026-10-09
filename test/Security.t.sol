// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KoboltToken} from "../src/KoboltToken.sol";
import {KoboltModules} from "../src/modules/KoboltModules.sol";
import {KoboltVesting} from "../src/modules/KoboltVesting.sol";
import {KoboltStakingPool} from "../src/modules/KoboltStakingPool.sol";
import {MockToken, MockPosition} from "./modules/Mocks.sol";

/// NFT whose transferFrom silently does nothing when the sender isn't the owner.
contract LenientNft is ERC721 {
    constructor() ERC721("Lenient", "LEN") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (ownerOf(id) != from) return;
        super.transferFrom(from, to, id);
    }
}

contract SixDecimals is ERC20 {
    constructor() ERC20("Six", "SIX") {
        _mint(msg.sender, 1_000_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// Regression tests for the issues found in the pre-mainnet security review.
contract SecurityTest is Test {
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");

    function token(uint256 initial, uint256 max, bool mint, bool pause) internal returns (KoboltToken) {
        return new KoboltToken(KoboltToken.Config("Test", "TST", 18, initial, max, mint, true, pause), address(this));
    }

    // ------------------------------------------------------------ token

    function test_CannotRenounceWhilePaused() public {
        KoboltToken t = token(100, 0, false, true);
        t.pause();
        vm.expectRevert(KoboltToken.RenounceWhilePaused.selector);
        t.renounceOwnership();
        t.unpause();
        t.renounceOwnership();
        assertEq(t.owner(), address(0));
    }

    function test_OwnershipNeedsAcceptance() public {
        KoboltToken t = token(100, 1000, true, false);
        t.transferOwnership(alice);
        // A typo'd address that never accepts leaves control with the current owner.
        t.mint(address(this), 1);
        vm.prank(alice);
        t.acceptOwnership();
        assertEq(t.owner(), alice);
    }

    function test_FixedTokenMaxSupplyEqualsInitial() public {
        KoboltToken t = token(100, 0, false, false);
        assertEq(t.maxSupply(), 100);
        assertEq(token(100, 100, false, false).maxSupply(), 100);
        vm.expectRevert(KoboltToken.FixedTokenMaxSupply.selector);
        token(100, type(uint256).max, false, false);
    }

    function test_BurningDoesNotMakeRoomToMintMore() public {
        KoboltToken t = token(100, 100, true, false);
        t.burn(60);
        vm.expectRevert(KoboltToken.MintExceedsMaxSupply.selector);
        t.mint(address(this), 1);
        assertEq(t.totalMinted(), 100);
    }

    function test_NameMustBePrintableAscii() public {
        vm.expectRevert(KoboltToken.InvalidName.selector);
        new KoboltToken(KoboltToken.Config("Bad\nName", "TST", 18, 1, 0, false, true, false), address(this));
        vm.expectRevert(KoboltToken.InvalidName.selector);
        new KoboltToken(KoboltToken.Config(string(abi.encodePacked("Usdc", hex"e280ae")), "TST", 18, 1, 0, false, true, false), address(this));
        new KoboltToken(KoboltToken.Config("Harbor & Co. - 2", "TST", 18, 1, 0, false, true, false), address(this));
    }

    // ------------------------------------------------------------ vesting

    function test_VestingRejectsStuckBeneficiariesAndFarStarts() public {
        vm.warp(1_800_000_000);
        MockToken m = new MockToken();
        KoboltVesting v = new KoboltVesting(IERC20(address(m)), address(this));
        m.approve(address(v), type(uint256).max);
        vm.expectRevert(KoboltVesting.InvalidBeneficiary.selector);
        v.createSchedule(address(v), 1, uint64(block.timestamp), 0, 1 days);
        vm.expectRevert(KoboltVesting.InvalidBeneficiary.selector);
        v.createSchedule(address(m), 1, uint64(block.timestamp), 0, 1 days);
        vm.expectRevert(KoboltVesting.InvalidStart.selector);
        v.createSchedule(alice, 1, uint64(block.timestamp * 1000), 0, 1 days); // milliseconds by mistake
        v.createSchedule(alice, 1, uint64(block.timestamp + 365 days), 0, 1 days);
    }

    // ------------------------------------------------------------ staking

    function test_FrequentUpdatesDoNotSuppressCappedRewards() public {
        vm.warp(1_800_000_000);
        SixDecimals six = new SixDecimals();
        KoboltStakingPool quiet = new KoboltStakingPool(IERC20(address(six)), address(this), 1000, 365 days, 0);
        KoboltStakingPool busy = new KoboltStakingPool(IERC20(address(six)), address(this), 1000, 365 days, 0);
        six.approve(address(quiet), type(uint256).max);
        six.approve(address(busy), type(uint256).max);
        quiet.fund(1_000_000e6);
        busy.fund(1_000_000e6);
        quiet.stake(100e6);
        busy.stake(100e6);
        six.transfer(eve, 1e6);
        vm.prank(eve);
        six.approve(address(busy), type(uint256).max);
        // Eve pokes the busy pool every 2 seconds for 2 hours.
        for (uint256 i = 0; i < 3600; i++) {
            vm.warp(block.timestamp + 2);
            vm.prank(eve);
            busy.stake(1);
        }
        uint256 q = quiet.earned(address(this));
        uint256 b = busy.earned(address(this));
        assertGt(q, 0);
        assertApproxEqRel(b, q, 0.001e18);
    }

    function test_StakingOwnerCannotRenounce() public {
        MockToken m = new MockToken();
        KoboltStakingPool p = new KoboltStakingPool(IERC20(address(m)), address(this), 0, 30 days, 0);
        vm.expectRevert(KoboltStakingPool.RenounceDisabled.selector);
        p.renounceOwnership();
    }

    // ------------------------------------------------------------ modules / locks

    function modules() internal returns (KoboltModules) {
        return new KoboltModules(
            address(this), payable(makeAddr("treasury")), KoboltModules.Prices({vesting: 0, staking: 0, airdrop: 0, lock: 0})
        );
    }

    function test_SameNftCannotBackTwoLocks() public {
        KoboltModules mod = modules();
        LenientNft nft = new LenientNft();
        nft.mint(alice, 7);
        vm.startPrank(alice);
        nft.approve(address(mod), 7);
        mod.lockNft(IERC721(address(nft)), 7, uint64(block.timestamp + 365 days));
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(KoboltModules.NftAlreadyLocked.selector);
        mod.lockNft(IERC721(address(nft)), 7, uint64(block.timestamp + 1));
    }

    function test_CannotLockSomeoneElsesNft() public {
        KoboltModules mod = modules();
        MockPosition nft = new MockPosition();
        nft.mint(alice, 1);
        vm.prank(eve);
        vm.expectRevert(KoboltModules.NotNftOwner.selector);
        mod.lockNft(IERC721(address(nft)), 1, uint64(block.timestamp + 1 days));
    }

    function test_NftRelockAfterWithdraw() public {
        KoboltModules mod = modules();
        MockPosition nft = new MockPosition();
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.approve(address(mod), 1);
        uint256 id = mod.lockNft(IERC721(address(nft)), 1, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        mod.withdraw(id);
        nft.approve(address(mod), 1);
        mod.lockNft(IERC721(address(nft)), 1, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_LockTokensRejectsNfts() public {
        KoboltModules mod = modules();
        MockPosition nft = new MockPosition();
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.approve(address(mod), 1);
        vm.expectRevert(KoboltModules.UseLockNft.selector);
        mod.lockTokens(IERC20(address(nft)), 1, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_PagedLockViews() public {
        KoboltModules mod = modules();
        MockToken lp = new MockToken();
        lp.approve(address(mod), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            mod.lockTokens(IERC20(address(lp)), 1 ether, uint64(block.timestamp + 1 days));
        }
        assertEq(mod.locksOfCount(address(this)), 5);
        uint256[] memory page = mod.locksOfPaged(address(this), 3, 10);
        assertEq(page.length, 2);
        assertEq(page[0], 3);
        assertEq(mod.locksByAssetPaged(address(lp), 9, 2).length, 0);
        assertEq(mod.locksByAssetCount(address(lp)), 5);
    }
}
