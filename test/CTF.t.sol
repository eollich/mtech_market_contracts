// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";

// exercises the on-chain complete-set mechanics directly on the Gnosis CTF:
// split (mint) -> merge -> resolve -> redeem. these are the on-chain versions
// of our C++ engine's mint / merge / resolution+redeem.
contract CTFTest is Test {
    IConditionalTokens ctf;
    MockUSDC usdc;

    address oracle = makeAddr("oracle");
    address alice = makeAddr("alice");
    bytes32 questionId = keccak256("will it rain tomorrow?");

    // binary market: outcome slot 0 = YES (index set 0b01=1), slot 1 = NO (0b10=2)
    uint256[] partition; // [1, 2] -> a full split

    function setUp() public {
        usdc = new MockUSDC();
        ctf = IConditionalTokens(deployCode("ConditionalTokens.sol:ConditionalTokens"));
        partition = new uint256[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO
    }

    function _posId(bytes32 conditionId, uint256 indexSet) internal view returns (uint256) {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        return ctf.getPositionId(address(usdc), collectionId);
    }

    function test_split_merge_resolve_redeem() public {
        // 1) prepare a binary condition
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        assertEq(ctf.getOutcomeSlotCount(conditionId), 2);

        uint256 yes = _posId(conditionId, 1);
        uint256 no = _posId(conditionId, 2);

        // 2) alice splits 100 USDC into a complete set (mint)
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(ctf), 100e6);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, 100e6);
        vm.stopPrank();

        assertEq(ctf.balanceOf(alice, yes), 100e6, "100 YES");
        assertEq(ctf.balanceOf(alice, no), 100e6, "100 NO");
        assertEq(usdc.balanceOf(address(ctf)), 100e6, "collateral escrowed in CTF");
        assertEq(usdc.balanceOf(alice), 0);

        // 3) merge 40 of the set back into collateral (merge)
        vm.prank(alice);
        ctf.mergePositions(address(usdc), bytes32(0), conditionId, partition, 40e6);
        assertEq(ctf.balanceOf(alice, yes), 60e6);
        assertEq(ctf.balanceOf(alice, no), 60e6);
        assertEq(usdc.balanceOf(alice), 40e6, "40 USDC back");
        assertEq(usdc.balanceOf(address(ctf)), 60e6);

        // 4) oracle resolves YES (payouts [1,0]) and alice redeems her YES
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES wins
        payouts[1] = 0;
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);

        uint256[] memory redeemYes = new uint256[](1);
        redeemYes[0] = 1; // the YES index set
        vm.prank(alice);
        ctf.redeemPositions(address(usdc), bytes32(0), conditionId, redeemYes);

        // 60 YES -> 60 USDC; the NO tokens are now worthless
        assertEq(usdc.balanceOf(alice), 100e6, "40 merged + 60 redeemed = whole again");
        assertEq(ctf.balanceOf(alice, yes), 0, "YES burned on redeem");
        assertEq(usdc.balanceOf(address(ctf)), 0, "escrow drained");
    }
}
