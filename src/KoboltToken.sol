// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KoboltToken
/// @notice Configurable ERC-20 created through the Kobolt factory.
///
///         Every setting is fixed at creation and can never change:
///           name, symbol, decimals    metadata
///           initialSupply             base units minted to the owner
///           maxSupply                 cap for minting in base units, 0 = no cap
///           mintable, burnable, pausable  feature switches
///
///         The creator (not the factory) becomes the owner. The contract is not
///         upgradeable and has no fees, taxes or blacklist.
contract KoboltToken is ERC20, Ownable {
    uint8 private immutable _decimals;
    uint256 public immutable maxSupply;
    bool public immutable mintable;
    bool public immutable burnable;
    bool public immutable pausable;

    bool public paused;

    event Paused(bool paused);

    error InvalidSymbol();
    error InvalidName();
    error InvalidDecimals();
    error MaxSupplyBelowInitialSupply();
    error FixedTokenNeedsInitialSupply();
    error MintingDisabled();
    error MintExceedsMaxSupply();
    error BurningDisabled();
    error PausingDisabled();
    error TransfersPaused();
    error ZeroAmount();

    struct Config {
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
        uint256 maxSupply;
        bool mintable;
        bool burnable;
        bool pausable;
    }

    constructor(Config memory c, address owner_) ERC20(c.name, c.symbol) Ownable(owner_) {
        uint256 nameLength = bytes(c.name).length;
        if (nameLength == 0 || nameLength > 64) revert InvalidName();
        if (!_isValidSymbol(bytes(c.symbol))) revert InvalidSymbol();
        if (c.decimals > 18) revert InvalidDecimals();
        if (c.maxSupply != 0 && c.maxSupply < c.initialSupply) revert MaxSupplyBelowInitialSupply();
        if (!c.mintable && c.initialSupply == 0) revert FixedTokenNeedsInitialSupply();

        _decimals = c.decimals;
        maxSupply = c.maxSupply;
        mintable = c.mintable;
        burnable = c.burnable;
        pausable = c.pausable;

        if (c.initialSupply > 0) _mint(owner_, c.initialSupply);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ---------------------------------------------------------------- owner

    function mint(address to, uint256 amount) external onlyOwner {
        if (!mintable) revert MintingDisabled();
        if (amount == 0) revert ZeroAmount();
        if (maxSupply != 0 && totalSupply() + amount > maxSupply) revert MintExceedsMaxSupply();
        _mint(to, amount);
    }

    function pause() external onlyOwner {
        if (!pausable) revert PausingDisabled();
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        if (!pausable) revert PausingDisabled();
        paused = false;
        emit Paused(false);
    }

    // --------------------------------------------------------------- holders

    /// @notice Burns tokens from the caller's own balance.
    function burn(uint256 amount) external {
        if (!burnable) revert BurningDisabled();
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
    }

    // -------------------------------------------------------------- internal

    /// @dev Every mint, burn and transfer passes here, so pausing covers all of them.
    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TransfersPaused();
        super._update(from, to, value);
    }

    function _isValidSymbol(bytes memory s) private pure returns (bool) {
        if (s.length == 0 || s.length > 12) return false;
        for (uint256 i = 0; i < s.length; i++) {
            bytes1 ch = s[i];
            bool upper = ch >= 0x41 && ch <= 0x5A;
            bool digit = ch >= 0x30 && ch <= 0x39;
            if (!upper && !digit) return false;
        }
        return true;
    }
}
