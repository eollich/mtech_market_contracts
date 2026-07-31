// SPDX-License-Identifier: MIT
pragma solidity ^0.5.1;

// this file exists ONLY to pull the 0.5.x Gnosis Conditional Tokens Framework
// into the compile graph, so its artifact is available to vm.deployCode() from
// our 0.8 tests. we never import the 0.5 source into 0.8 code -- 0.8 interacts
// with the deployed CTF through the IConditionalTokens interface instead.
import "conditional-tokens-contracts/ConditionalTokens.sol";
