// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Exchange} from "../src/Exchange.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";

// deploys the full stack to whatever chain --rpc-url points at (Anvil locally).
// the deployer becomes the Exchange owner; OPERATOR (env, default = deployer)
// is the address allowed to submit fills.
contract Deploy is Script {
    function run() external {
        address operator = vm.envOr("OPERATOR", msg.sender);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(30)); // 0.30% default

        vm.startBroadcast();
        MockUSDC usdc = new MockUSDC();
        address ctf = deployCode("ConditionalTokens.sol:ConditionalTokens");
        Exchange exchange = new Exchange(IConditionalTokens(ctf), IERC20(address(usdc)), operator, feeBps);
        vm.stopBroadcast();

        console.log("USDC     ", address(usdc));
        console.log("CTF      ", ctf);
        console.log("Exchange ", address(exchange));
        console.log("operator ", operator);
        console.log("feeBps   ", feeBps);
    }
}
