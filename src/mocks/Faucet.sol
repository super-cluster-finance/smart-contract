// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MockUSDC} from "./tokens/MockUSDC.sol";

contract Faucet {
    MockUSDC public usdc;

    uint256 private amount = 100e18;

    constructor(address _usdc) {
        usdc = MockUSDC(_usdc);
    }

    function requestTokens() public {
        usdc.mint(msg.sender, amount);
    }
}
