// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Exchange} from "../src/Exchange.sol";

contract ExchangeTest is Test {
    Exchange exchange;
    address maker;
    uint256 makerPk;

    function setUp() public {
        exchange = new Exchange();
        (maker, makerPk) = makeAddrAndKey("maker");
    }

    function _order() internal view returns (Exchange.Order memory o) {
        o = Exchange.Order({
            salt: 1,
            maker: maker,
            tokenId: 123,
            makerAmount: 55e6, // 55 USDC
            takerAmount: 100e6, // for 100 outcome tokens (price 0.55)
            expiration: block.timestamp + 1 hours,
            nonce: 0,
            side: Exchange.Side.BUY,
            signature: ""
        });
    }

    function _sign(uint256 pk, Exchange.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, exchange.hashOrder(o));
        return abi.encodePacked(r, s, v); // 65-byte r||s||v
    }

    function test_verify_recovers_maker() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        assertEq(exchange.verify(o), maker);
    }

    function test_wrong_signer_reverts() public {
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        Exchange.Order memory o = _order();
        o.signature = _sign(attackerPk, o); // signed by someone who isn't the maker
        vm.expectRevert("Exchange: bad signature");
        exchange.verify(o);
    }

    function test_tampered_order_reverts() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        o.makerAmount = 1; // change a committed field after signing -> digest changes
        vm.expectRevert("Exchange: bad signature");
        exchange.verify(o);
    }

    function test_validate_returns_remaining() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        (, uint256 remaining) = exchange.validateOrder(o);
        assertEq(remaining, o.makerAmount);
    }

    function test_expired_reverts() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        vm.warp(o.expiration + 1); // jump past expiration
        vm.expectRevert("Exchange: expired");
        exchange.validateOrder(o);
    }

    function test_cancel_then_validate_reverts() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        vm.prank(maker);
        exchange.cancelOrder(o);
        vm.expectRevert("Exchange: filled or cancelled");
        exchange.validateOrder(o);
    }

    function test_only_maker_can_cancel() public {
        Exchange.Order memory o = _order();
        o.signature = _sign(makerPk, o);
        vm.prank(address(0xBAD));
        vm.expectRevert("Exchange: not maker");
        exchange.cancelOrder(o);
    }
}
