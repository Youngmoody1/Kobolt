// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KoboltToken} from "./KoboltToken.sol";

/// @title KoboltFactory
/// @notice Creates KoboltTokens for a small fee and keeps an on-chain count of every
///         token it has created, which the Kobolt website shows live.
///
///         The fee depends on what the token can do: a base price, plus a small add-on
///         for each owner power (minting, pausing) and for burning. `feeFor(config)`
///         returns the exact price. The creator pays it in the chain's native coin
///         (ETH on Base); it goes straight to `treasury` and the factory never holds
///         funds. The creator becomes the owner of the new token. Kobolt has no
///         control over tokens after they are created.
contract KoboltFactory is Ownable2Step, ReentrancyGuard {
    /// @notice Hard upper bound on each price, so fees can never be raised to a surprising amount.
    uint256 public constant MAX_PRICE = 0.005 ether;

    struct Prices {
        uint256 base;
        uint256 mintable;
        uint256 burnable;
        uint256 pausable;
    }

    Prices public prices;
    address payable public treasury;

    /// @notice Every token created here, in order. `allTokens.length == totalDeployed()`.
    address[] public allTokens;
    /// @notice True for addresses created by this factory, so anyone can verify a token.
    mapping(address => bool) public isKoboltToken;
    mapping(address => address[]) private _tokensByCreator;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        uint256 indexed index,
        string name,
        string symbol,
        uint256 feePaid
    );
    event PricesChanged(uint256 base, uint256 mintable, uint256 burnable, uint256 pausable);
    event TreasuryChanged(address oldTreasury, address newTreasury);

    error WrongFee(uint256 expected, uint256 sent);
    error FeeTooHigh();
    error ZeroAddress();
    error FeeTransferFailed();

    constructor(address initialOwner, address payable treasury_, Prices memory prices_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        _setPrices(prices_);
    }

    /// @notice The exact fee for creating a token with this config.
    function feeFor(KoboltToken.Config calldata config) public view returns (uint256 total) {
        Prices memory p = prices;
        total = p.base;
        if (config.mintable) total += p.mintable;
        if (config.burnable) total += p.burnable;
        if (config.pausable) total += p.pausable;
    }

    /// @notice Creates a token owned by the caller. `msg.value` must equal `feeFor(config)` exactly.
    function createToken(KoboltToken.Config calldata config) external payable nonReentrant returns (address token) {
        uint256 fee = feeFor(config);
        if (msg.value != fee) revert WrongFee(fee, msg.value);

        token = address(new KoboltToken(config, msg.sender));

        uint256 index = allTokens.length;
        allTokens.push(token);
        isKoboltToken[token] = true;
        _tokensByCreator[msg.sender].push(token);

        emit TokenCreated(token, msg.sender, index, config.name, config.symbol, msg.value);

        if (msg.value > 0) {
            (bool ok,) = treasury.call{value: msg.value}("");
            if (!ok) revert FeeTransferFailed();
        }
    }

    /// @notice Number of tokens created through this factory.
    function totalDeployed() external view returns (uint256) {
        return allTokens.length;
    }

    function tokensByCreator(address creator) external view returns (address[] memory) {
        return _tokensByCreator[creator];
    }

    // ---------------------------------------------------------------- owner

    function setPrices(Prices calldata newPrices) external onlyOwner {
        _setPrices(newPrices);
    }

    function _setPrices(Prices memory p) private {
        if (p.base > MAX_PRICE || p.mintable > MAX_PRICE || p.burnable > MAX_PRICE || p.pausable > MAX_PRICE) {
            revert FeeTooHigh();
        }
        prices = p;
        emit PricesChanged(p.base, p.mintable, p.burnable, p.pausable);
    }

    function setTreasury(address payable newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }
}
