// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KoboltToken} from "./KoboltToken.sol";

/// @title KoboltFactory
/// @notice Creates KoboltTokens for a small fixed fee and keeps an on-chain count
///         of every token it has created, which the Kobolt website shows live.
///
///         The creator pays `fee` in the chain's native coin (ETH on Base). The fee
///         goes straight to `treasury`; the factory never holds funds. The creator
///         becomes the owner of the new token. Kobolt has no control over tokens
///         after they are created.
contract KoboltFactory is Ownable2Step, ReentrancyGuard {
    /// @notice Hard upper bound on the fee, so it can never be raised to a surprising amount.
    uint256 public constant MAX_FEE = 0.05 ether;

    uint256 public fee;
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
    event FeeChanged(uint256 oldFee, uint256 newFee);
    event TreasuryChanged(address oldTreasury, address newTreasury);

    error WrongFee(uint256 expected, uint256 sent);
    error FeeTooHigh();
    error ZeroAddress();
    error FeeTransferFailed();

    constructor(address initialOwner, address payable treasury_, uint256 fee_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (fee_ > MAX_FEE) revert FeeTooHigh();
        treasury = treasury_;
        fee = fee_;
    }

    /// @notice Creates a token owned by the caller. `msg.value` must equal `fee` exactly.
    function createToken(KoboltToken.Config calldata config) external payable nonReentrant returns (address token) {
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

    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        emit FeeChanged(fee, newFee);
        fee = newFee;
    }

    function setTreasury(address payable newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }
}
