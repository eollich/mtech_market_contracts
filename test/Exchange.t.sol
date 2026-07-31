// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Exchange} from "../src/Exchange.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IConditionalTokens} from "../src/interfaces/IConditionalTokens.sol";

contract ExchangeTest is Test {
    Exchange exchange;
    MockUSDC usdc;
    IConditionalTokens ctf;
    address maker;
    uint256 makerPk;

    function setUp() public {
        usdc = new MockUSDC();
        ctf = IConditionalTokens(deployCode("ConditionalTokens.sol:ConditionalTokens"));
        // this test contract is the owner + operator; fee starts at 0
        exchange = new Exchange(ctf, IERC20(address(usdc)), address(this), 0);
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

    function test_fill_transfer() public {
        // a market with a registered YES token
        address oracle = makeAddr("oracle");
        bytes32 questionId = keccak256("rain?");
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        (uint256 yesId,) = exchange.registerMarket(conditionId);

        (address buyer, uint256 buyerPk) = makeAddrAndKey("buyer");
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");

        // seller mints a complete set (100 USDC -> 100 YES + 100 NO), keeps YES
        usdc.mint(seller, 100e6);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(seller);
        usdc.approve(address(ctf), 100e6);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, 100e6);
        ctf.setApprovalForAll(address(exchange), true); // exchange may move seller's YES
        vm.stopPrank();

        // buyer funds + approves the exchange for USDC
        usdc.mint(buyer, 1000e6);
        vm.prank(buyer);
        usdc.approve(address(exchange), type(uint256).max);

        // BUY 100 YES @0.55 and SELL 100 YES @0.55 (they cross)
        Exchange.Order memory buyOrder = Exchange.Order({
            salt: 1,
            maker: buyer,
            tokenId: yesId,
            makerAmount: 55e6, // pays 55 USDC
            takerAmount: 100e6, // for 100 YES
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.BUY,
            signature: ""
        });
        buyOrder.signature = _sign(buyerPk, buyOrder);

        Exchange.Order memory sellOrder = Exchange.Order({
            salt: 2,
            maker: seller,
            tokenId: yesId,
            makerAmount: 100e6, // gives 100 YES
            takerAmount: 55e6, // for 55 USDC
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.SELL,
            signature: ""
        });
        sellOrder.signature = _sign(sellerPk, sellOrder);

        // operator submits the matched pair
        exchange.fillTransfer(buyOrder, sellOrder, 100e6);

        assertEq(ctf.balanceOf(buyer, yesId), 100e6, "buyer got 100 YES");
        assertEq(ctf.balanceOf(seller, yesId), 0, "seller's YES moved out");
        assertEq(usdc.balanceOf(buyer), 1000e6 - 55e6, "buyer paid 55");
        assertEq(usdc.balanceOf(seller), 55e6, "seller received 55");
    }

    function test_fill_mint() public {
        address oracle = makeAddr("oracle");
        bytes32 questionId = keccak256("rain?");
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        (uint256 yesId, uint256 noId) = exchange.registerMarket(conditionId);

        (address ybuyer, uint256 yPk) = makeAddrAndKey("ybuyer");
        (address nbuyer, uint256 nPk) = makeAddrAndKey("nbuyer");

        usdc.mint(ybuyer, 1000e6);
        usdc.mint(nbuyer, 1000e6);
        vm.prank(ybuyer);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(nbuyer);
        usdc.approve(address(exchange), type(uint256).max);

        // BUY YES @0.60 x BUY NO @0.45 -> prices sum to 1.05, they mint
        Exchange.Order memory yesBuy = Exchange.Order({
            salt: 1,
            maker: ybuyer,
            tokenId: yesId,
            makerAmount: 60e6,
            takerAmount: 100e6,
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.BUY,
            signature: ""
        });
        yesBuy.signature = _sign(yPk, yesBuy);

        Exchange.Order memory noBuy = Exchange.Order({
            salt: 2,
            maker: nbuyer,
            tokenId: noId,
            makerAmount: 45e6,
            takerAmount: 100e6,
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.BUY,
            signature: ""
        });
        noBuy.signature = _sign(nPk, noBuy);

        exchange.fillMint(yesBuy, noBuy, 100e6);

        assertEq(ctf.balanceOf(ybuyer, yesId), 100e6, "YES buyer holds 100 YES");
        assertEq(ctf.balanceOf(nbuyer, noId), 100e6, "NO buyer holds 100 NO");
        assertEq(usdc.balanceOf(ybuyer), 1000e6 - 60e6, "YES buyer paid 60");
        assertEq(usdc.balanceOf(nbuyer), 1000e6 - 45e6, "NO buyer paid 45");
        assertEq(usdc.balanceOf(address(ctf)), 100e6, "100 USDC locked backing the set");
        assertEq(usdc.balanceOf(address(exchange)), 5e6, "surplus spread retained");
    }

    function test_fill_merge() public {
        address oracle = makeAddr("oracle");
        bytes32 questionId = keccak256("rain?");
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        (uint256 yesId, uint256 noId) = exchange.registerMarket(conditionId);

        (address yseller, uint256 yPk) = makeAddrAndKey("yseller");
        (address nseller, uint256 nPk) = makeAddrAndKey("nseller");

        // each seller mints a set to obtain tokens (spends exactly 100 USDC -> 0)
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        for (uint256 i = 0; i < 2; i++) {
            address s = i == 0 ? yseller : nseller;
            usdc.mint(s, 100e6);
            vm.startPrank(s);
            usdc.approve(address(ctf), 100e6);
            ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, 100e6);
            ctf.setApprovalForAll(address(exchange), true);
            vm.stopPrank();
        }

        // SELL YES @0.55 x SELL NO @0.40 -> prices sum to 0.95 <= 1, they merge
        Exchange.Order memory yesSell = Exchange.Order({
            salt: 1,
            maker: yseller,
            tokenId: yesId,
            makerAmount: 100e6, // gives 100 YES
            takerAmount: 55e6, // wants 55 USDC
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.SELL,
            signature: ""
        });
        yesSell.signature = _sign(yPk, yesSell);

        Exchange.Order memory noSell = Exchange.Order({
            salt: 2,
            maker: nseller,
            tokenId: noId,
            makerAmount: 100e6, // gives 100 NO
            takerAmount: 40e6, // wants 40 USDC
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.SELL,
            signature: ""
        });
        noSell.signature = _sign(nPk, noSell);

        exchange.fillMerge(yesSell, noSell, 100e6);

        assertEq(ctf.balanceOf(yseller, yesId), 0, "YES seller's YES burned");
        assertEq(ctf.balanceOf(nseller, noId), 0, "NO seller's NO burned");
        assertEq(usdc.balanceOf(yseller), 55e6, "YES seller received 55");
        assertEq(usdc.balanceOf(nseller), 40e6, "NO seller received 40");
        // both sellers minted a full set (200 escrowed); merging one set released
        // 100. the remaining 100 backs their unused halves (yseller NO + nseller YES).
        assertEq(usdc.balanceOf(address(ctf)), 100e6, "one set burned; the other still backed");
        assertEq(usdc.balanceOf(address(exchange)), 5e6, "surplus spread retained");
    }

    function test_non_operator_reverts() public {
        Exchange.Order memory a = _order();
        a.signature = _sign(makerPk, a);
        vm.prank(address(0xBAD));
        vm.expectRevert("Exchange: not operator");
        exchange.fillTransfer(a, a, 1);
    }

    function test_transfer_fee_accrues_and_withdraws() public {
        exchange.setFeeRateBps(100); // 1%

        address oracle = makeAddr("oracle2");
        bytes32 questionId = keccak256("fee mkt");
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        (uint256 yesId,) = exchange.registerMarket(conditionId);

        (address buyer, uint256 buyerPk) = makeAddrAndKey("feebuyer");
        (address seller, uint256 sellerPk) = makeAddrAndKey("feeseller");

        usdc.mint(seller, 100e6);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(seller);
        usdc.approve(address(ctf), 100e6);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, 100e6);
        ctf.setApprovalForAll(address(exchange), true);
        vm.stopPrank();

        usdc.mint(buyer, 1000e6);
        vm.prank(buyer);
        usdc.approve(address(exchange), type(uint256).max);

        Exchange.Order memory buyOrder = Exchange.Order({
            salt: 1,
            maker: buyer,
            tokenId: yesId,
            makerAmount: 55e6,
            takerAmount: 100e6,
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.BUY,
            signature: ""
        });
        buyOrder.signature = _sign(buyerPk, buyOrder);
        Exchange.Order memory sellOrder = Exchange.Order({
            salt: 2,
            maker: seller,
            tokenId: yesId,
            makerAmount: 100e6,
            takerAmount: 55e6,
            expiration: 0,
            nonce: 0,
            side: Exchange.Side.SELL,
            signature: ""
        });
        sellOrder.signature = _sign(sellerPk, sellOrder);

        exchange.fillTransfer(buyOrder, sellOrder, 100e6);

        // cost 55, fee 1% = 0.55 -> seller nets 54.45, exchange keeps 0.55
        assertEq(usdc.balanceOf(seller), 54_450000, "seller net of fee");
        assertEq(usdc.balanceOf(address(exchange)), 550000, "fee accrued");

        // owner withdraws the accrued fee
        exchange.withdrawFees(address(0xFEE), 550000);
        assertEq(usdc.balanceOf(address(0xFEE)), 550000);
    }

    function test_register_market() public {
        address oracle = makeAddr("oracle");
        bytes32 questionId = keccak256("will it rain?");
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        (uint256 yesId, uint256 noId) = exchange.registerMarket(conditionId);
        assertTrue(yesId != noId);

        (bool rY, uint256 compY, bytes32 condY) = exchange.tokens(yesId);
        (bool rN, uint256 compN,) = exchange.tokens(noId);
        assertTrue(rY && rN, "both registered");
        assertEq(compY, noId, "YES complement is NO");
        assertEq(compN, yesId, "NO complement is YES");
        assertEq(condY, conditionId);
    }
}
