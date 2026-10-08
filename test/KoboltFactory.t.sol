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

    uint256 constant BASE = 0.0005 ether;
    uint256 constant MINT = 0.0003 ether;
    uint256 constant BURN = 0.0001 ether;
    uint256 constant PAUSE = 0.0003 ether;
    /// Fee for the default config below (burnable only).
    uint256 constant FEE = BASE + BURN;

    function prices(uint256 b, uint256 m, uint256 bu, uint256 p) internal pure returns (KoboltFactory.Prices memory) {
        return KoboltFactory.Prices({base: b, mintable: m, burnable: bu, pausable: p});
    }

    function setUp() public {
        factory = new KoboltFactory(admin, treasury, prices(BASE, MINT, BURN, PAUSE));
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

    // -------------------------------------------------------------- pricing

    function test_FeeDependsOnFeatures() public view {
        KoboltToken.Config memory c = cfg("X", "X");
        c.burnable = false;
        assertEq(factory.feeFor(c), BASE);
        c.burnable = true;
        assertEq(factory.feeFor(c), BASE + BURN);
        c.mintable = true;
        assertEq(factory.feeFor(c), BASE + BURN + MINT);
        c.pausable = true;
        assertEq(factory.feeFor(c), BASE + BURN + MINT + PAUSE);
    }

    function test_PaysFeeForChosenFeatures() public {
        KoboltToken.Config memory c = cfg("Full", "FULL");
        c.mintable = true;
        c.pausable = true;
        uint256 fee = BASE + MINT + BURN + PAUSE;
        vm.prank(alice);
        factory.createToken{value: fee}(c);
        assertEq(treasury.balance, fee);
    }

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
        // Paying the base price for a mintable token is not enough.
        KoboltToken.Config memory c = cfg("Harbor", "HRB");
        c.mintable = true;
        vm.expectRevert(abi.encodeWithSelector(KoboltFactory.WrongFee.selector, FEE + MINT, FEE));
        factory.createToken{value: FEE}(c);
        vm.stopPrank();
        assertEq(factory.totalDeployed(), 0);
    }

    function test_ZeroPricesWork() public {
        vm.prank(admin);
        factory.setPrices(prices(0, 0, 0, 0));
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

    function test_OnlyOwnerChangesPricesAndTreasury() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setPrices(prices(0, 0, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setTreasury(payable(alice));
        vm.stopPrank();

        vm.startPrank(admin);
        factory.setPrices(prices(0.001 ether, 0, 0, 0));
        factory.setTreasury(payable(bob));
        vm.stopPrank();
        (uint256 base,,,) = factory.prices();
        assertEq(base, 0.001 ether);
        assertEq(factory.treasury(), bob);
    }

    function test_EachPriceIsCapped() public {
        uint256 tooHigh = 0.005 ether + 1;
        vm.startPrank(admin);
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        factory.setPrices(prices(tooHigh, 0, 0, 0));
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        factory.setPrices(prices(0, tooHigh, 0, 0));
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        factory.setPrices(prices(0, 0, tooHigh, 0));
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        factory.setPrices(prices(0, 0, 0, tooHigh));
        vm.stopPrank();
        vm.expectRevert(KoboltFactory.FeeTooHigh.selector);
        new KoboltFactory(admin, treasury, prices(1 ether, 0, 0, 0));
    }

    function test_RejectsZeroTreasury() public {
        vm.prank(admin);
        vm.expectRevert(KoboltFactory.ZeroAddress.selector);
        factory.setTreasury(payable(address(0)));
        vm.expectRevert(KoboltFactory.ZeroAddress.selector);
        new KoboltFactory(admin, payable(address(0)), prices(BASE, MINT, BURN, PAUSE));
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
        uint256 fee = factory.feeFor(c);
        vm.prank(alice);
        KoboltToken token = KoboltToken(factory.createToken{value: fee}(c));

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

    function testFuzz_CountAndFeesMatchDeploys(uint8 n, bool mint, bool burn, bool pause) public {
        n = uint8(bound(n, 0, 20));
        KoboltToken.Config memory c = cfg("Token", "TKN");
        c.mintable = mint;
        c.burnable = burn;
        c.pausable = pause;
        uint256 fee = factory.feeFor(c);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(alice);
            factory.createToken{value: fee}(c);
        }
        assertEq(factory.totalDeployed(), n);
        assertEq(treasury.balance, fee * n);
    }
}
