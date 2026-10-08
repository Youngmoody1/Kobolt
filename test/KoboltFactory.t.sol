// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KoboltFactory} from "../src/KoboltFactory.sol";
import {KoboltToken} from "../src/KoboltToken.sol";

contract RejectingTreasury {
    receive() external payable {
        revert("no");
    }
}

contract KoboltFactoryTest is Test {
    KoboltFactory factory;
    address admin = makeAddr("admin");
    address payable treasury = payable(makeAddr("treasury"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant FEE = 0.002 ether;

    function setUp() public {
        factory = new KoboltFactory(admin, treasury, FEE);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function cfg(string memory name, string memory symbol) internal pure returns (KoboltToken.Config memory c) {
        c = KoboltToken.Config({
            name: name,
            symbol: symbol,
            decimals: 18,
            initialSupply: 1_000_000 ether,
            maxSupply: 0,
            mintable: false,
            burnable: true,
            pausable: false
        });
    }

    // ------------------------------------------------------------- creating

    function test_CreatesTokenOwnedByCaller() public {
        vm.prank(alice);
        address t = factory.createToken{value: FEE}(cfg("Harbor", "HRB"));
        KoboltToken token = KoboltToken(t);

        assertEq(token.name(), "Harbor");
        assertEq(token.symbol(), "HRB");
        assertEq(token.owner(), alice);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertTrue(factory.isKoboltToken(t));
    }

    function test_CountsEveryDeploy() public {
        assertEq(factory.totalDeployed(), 0);
        vm.prank(alice);
        address a = factory.createToken{value: FEE}(cfg("A", "A"));
        vm.prank(bob);
        address b = factory.createToken{value: FEE}(cfg("B", "B"));
        vm.prank(alice);
        address c = factory.createToken{value: FEE}(cfg("C", "C"));

        assertEq(factory.totalDeployed(), 3);
        assertEq(factory.allTokens(0), a);
        assertEq(factory.allTokens(2), c);
        address[] memory mine = factory.tokensByCreator(alice);
        assertEq(mine.length, 2);
        assertEq(mine[0], a);
        assertEq(mine[1], c);
        assertEq(factory.tokensByCreator(bob)[0], b);
    }

    function test_EmitsTokenCreated() public {
        vm.expectEmit(false, true, true, true);
        emit KoboltFactory.TokenCreated(address(0), alice, 0, "Harbor", "HRB", FEE);
        vm.prank(alice);
        factory.createToken{value: FEE}(cfg("Harbor", "HRB"));
    }

    // ------------------------------------------------------------------ fee

    function test_FeeGoesToTreasury() public {
        vm.prank(alice);
        factory.createToken{value: FEE}(cfg("Harbor", "HRB"));
        assertEq(treasury.balance, FEE);
        assertEq(address(factory).balance, 0);
        assertEq(alice.balance, 10 ether - FEE);
    }

    function test_RejectsWrongFee() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KoboltFactory.WrongFee.selector, FEE, 0));
        factory.createToken(cfg("Harbor", "HRB"));
        vm.expectRevert(abi.encodeWithSelector(KoboltFactory.WrongFee.selector, FEE, FEE + 1));
        factory.createToken{value: FEE + 1}(cfg("Harbor", "HRB"));
        vm.stopPrank();
        assertEq(factory.totalDeployed(), 0);
    }

    function test_ZeroFeeWorks() public {
        vm.prank(admin);
        factory.setFee(0);
        vm.prank(alice);
        factory.createToken(cfg("Free", "FREE"));
        assertEq(factory.totalDeployed(), 1);
        assertEq(treasury.balance, 0);
    }

    function test_RevertsWhenTreasuryRejects() public {
        RejectingTreasury bad = new RejectingTreasury();
        vm.prank(admin);
        factory.setTreasury(payable(address(bad)));
        vm.prank(alice);
        vm.expectRevert(KoboltFactory.FeeTransferFailed.selector);
        factory.createToken{value: FEE}(cfg("Harbor", "HRB"));
        assertEq(factory.totalDeployed(), 0);
    }

    // ---------------------------------------------------------------- admin

    function test_OnlyOwnerChangesFeeAndTreasury() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setTreasury(payable(alice));
        vm.stopPrank();

        vm.startPrank(admin);
        factory.setFee(0.001 ether);
        factory.setTreasury(payable(bob));
        vm.stopPrank();
        assertEq(factory.fee(), 0.001 ether);
        assertEq(factory.treasury(), bob);
    }

    function test_FeeIsCapped() public {
        vm.prank(admin);
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        factory.setFee(0.05 ether + 1);
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        new KoboltFactory(admin, treasury, 1 ether);
    }

    function test_RejectsZeroTreasury() public {
        vm.prank(admin);
        vm.expectRevert(KoboltFactory.ZeroAddress.selector);
        factory.setTreasury(payable(address(0)));
        vm.expectRevert(KoboltFactory.ZeroAddress.selector);
        new KoboltFactory(admin, payable(address(0)), FEE);
    }

    function test_OwnershipTransferNeedsAcceptance() public {
        vm.prank(admin);
        factory.transferOwnership(bob);
        assertEq(factory.owner(), admin);
        vm.prank(bob);
        factory.acceptOwnership();
        assertEq(factory.owner(), bob);
    }

    function test_FactoryOwnerHasNoPowerOverTokens() public {
        KoboltToken.Config memory c = cfg("Harbor", "HRB");
        c.mintable = true;
        c.pausable = true;
        vm.prank(alice);
        KoboltToken token = KoboltToken(factory.createToken{value: FEE}(c));

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        token.mint(admin, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        token.pause();
        vm.stopPrank();
    }

    // ------------------------------------------------------------ validation

    function test_InvalidConfigRevertsAndIsNotCounted() public {
        vm.startPrank(alice);
        vm.expectRevert(KoboltToken.InvalidSymbol.selector);
        factory.createToken{value: FEE}(cfg("Harbor", "hrb"));
        vm.expectRevert(KoboltToken.InvalidName.selector);
        factory.createToken{value: FEE}(cfg("", "HRB"));
        vm.stopPrank();
        assertEq(factory.totalDeployed(), 0);
        assertEq(treasury.balance, 0);
    }

    function testFuzz_CountMatchesDeploys(uint8 n) public {
        n = uint8(bound(n, 0, 20));
        for (uint256 i = 0; i < n; i++) {
            vm.prank(alice);
            factory.createToken{value: FEE}(cfg("Token", "TKN"));
        }
        assertEq(factory.totalDeployed(), n);
        assertEq(treasury.balance, FEE * n);
    }
}
