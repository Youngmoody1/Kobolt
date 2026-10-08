// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/// Takes 1% of every transfer.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockPosition is ERC721 {
    constructor() ERC721("Position", "POS") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract RejectingTreasury {
    receive() external payable {
        revert("no");
    }
}
