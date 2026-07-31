// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_mint_transfer_decimals() public {
        assertEq(usdc.decimals(), 6);
        usdc.mint(address(this), 1_000_000); // 1.000000 USDC
        assertEq(usdc.balanceOf(address(this)), 1_000_000);

        usdc.transfer(address(0xBEEF), 400_000);
        assertEq(usdc.balanceOf(address(0xBEEF)), 400_000);
        assertEq(usdc.balanceOf(address(this)), 600_000);
    }
}
