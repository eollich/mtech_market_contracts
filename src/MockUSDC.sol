// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// stand-in for USDC on local/testnets: 6 decimals + an open mint faucet
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6; // real usdc uses 6, not 18
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
