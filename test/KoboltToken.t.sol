// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KoboltToken} from "../src/KoboltToken.sol";

contract KoboltTokenTest is Test {
    uint256 constant UNIT = 1e8;
    address owner = address(this);
    address alice = makeAddr("alice");

    function mk(string memory n, string memory s, uint8 d, uint256 i, uint256 m, bool mi, bool bu, bool pa)
        internal
        returns (KoboltToken)
    {
        return new KoboltToken(KoboltToken.Config(n, s, d, i, m, mi, bu, pa), address(this));
    }

    function deploy(string memory symbol, uint256 initial, uint256 max, bool mintable_, bool burnable_, bool pausable_)
        internal
        returns (KoboltToken)
    {
        return mk("Agent Token", symbol, 8, initial, max, mintable_, burnable_, pausable_);
    }

    function defaultToken() internal returns (KoboltToken) {
        return deploy("AGENT", 100_000_000 * UNIT, 0, false, true, false);
    }

    function test_DeploySetsMetadataAndMintsToOwner() public {
        KoboltToken t = defaultToken();
        assertEq(t.name(), "Agent Token");
        assertEq(t.symbol(), "AGENT");
        assertEq(t.decimals(), 8);
        assertEq(t.totalSupply(), 100_000_000 * UNIT);
        assertEq(t.balanceOf(owner), 100_000_000 * UNIT);
        assertEq(t.owner(), owner);
        assertFalse(t.mintable());
        assertTrue(t.burnable());
    }

    function test_DeployRejectsInvalidParameters() public {
        vm.expectRevert(KoboltToken.InvalidSymbol.selector);
        deploy("agent", 1, 0, false, true, false);

        vm.expectRevert(KoboltToken.InvalidSymbol.selector);
        deploy("WAYTOOLONGSYMBOL", 1, 0, false, true, false);

        vm.expectRevert(KoboltToken.InvalidDecimals.selector);
        mk("X", "X", 19, 1, 0, false, true, false);

        vm.expectRevert(KoboltToken.InvalidName.selector);
        mk("", "X", 8, 1, 0, false, true, false);

        vm.expectRevert(KoboltToken.FixedTokenNeedsInitialSupply.selector);
        deploy("ZERO", 0, 0, false, true, false);

        vm.expectRevert(KoboltToken.MaxSupplyBelowInitialSupply.selector);
        deploy("CAP", 10, 5, true, true, false);
    }

    function test_Transfer() public {
        KoboltToken t = defaultToken();
        assertTrue(t.transfer(alice, 5 * UNIT));
        assertEq(t.balanceOf(alice), 5 * UNIT);
    }

    function test_MintDisabledByDefault() public {
        KoboltToken t = defaultToken();
        vm.expectRevert(KoboltToken.MintingDisabled.selector);
        t.mint(owner, 1);
    }

    function test_MintRespectsOwnerAndCap() public {
        KoboltToken t = deploy("CAP", 100 * UNIT, 150 * UNIT, true, true, false);
        t.mint(alice, 50 * UNIT);
        assertEq(t.totalSupply(), 150 * UNIT);

        vm.expectRevert(KoboltToken.MintExceedsMaxSupply.selector);
        t.mint(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        t.mint(alice, 1);
    }

    function test_UncappedMint() public {
        KoboltToken t = deploy("FREE", 0, 0, true, true, false);
        t.mint(alice, 1e30);
        assertEq(t.balanceOf(alice), 1e30);
    }

    function test_PauseBlocksTransfersOnlyWhenEnabled() public {
        KoboltToken fixedToken = defaultToken();
        vm.expectRevert(KoboltToken.PausingDisabled.selector);
        fixedToken.pause();

        KoboltToken t = deploy("PAUSE", 100 * UNIT, 0, false, true, true);
        t.pause();
        assertTrue(t.paused());
        vm.expectRevert(KoboltToken.TransfersPaused.selector);
        t.transfer(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        t.unpause();

        t.unpause();
        assertTrue(t.transfer(alice, 1));
    }

    function test_BurnReducesSupply() public {
        KoboltToken t = defaultToken();
        t.burn(10 * UNIT);
        assertEq(t.totalSupply(), 100_000_000 * UNIT - 10 * UNIT);
    }

    function test_BurnDisabledWhenNotBurnable() public {
        KoboltToken t = deploy("NOBURN", 100, 0, false, false, false);
        vm.expectRevert(KoboltToken.BurningDisabled.selector);
        t.burn(1);
    }

    function test_TransferOwnershipMovesAdminPowers() public {
        KoboltToken t = deploy("OWN", 100 * UNIT, 0, true, true, false);
        t.transferOwnership(alice);
        assertEq(t.owner(), alice);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        t.mint(owner, 1);

        vm.prank(alice);
        t.mint(alice, 1);
        assertEq(t.balanceOf(alice), 1);
    }

    function testFuzz_TransferConservesSupply(uint256 amount) public {
        KoboltToken t = defaultToken();
        amount = bound(amount, 0, t.balanceOf(owner));
        uint256 supply = t.totalSupply();
        t.transfer(alice, amount);
        assertEq(t.totalSupply(), supply);
        assertEq(t.balanceOf(alice) + t.balanceOf(owner), supply);
    }
}
