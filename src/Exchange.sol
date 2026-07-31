// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

// the exchange: users sign orders off-chain; the operator matches them and
// submits fills here. ERC1155Holder so it can custody outcome tokens mid-fill.
contract Exchange is EIP712, ERC1155Holder {
    using SafeERC20 for IERC20;

    enum Side {
        BUY, // maker pays collateral to receive outcome tokens
        SELL // maker gives outcome tokens to receive collateral
    }

    struct Order {
        uint256 salt; // uniqueness so identical orders hash differently
        address maker; // funds the order and (for now) signs it
        uint256 tokenId; // the ERC-1155 outcome token being traded
        uint256 makerAmount; // what the maker offers
        uint256 takerAmount; // what the maker wants in return
        uint256 expiration; // unix seconds; 0 = never expires
        uint256 nonce; // for bulk-cancel (bump nonce to invalidate)
        Side side;
        bytes signature; // NOT part of the signed hash
    }

    // the EIP-712 type hash: every field the signer commits to, in order.
    // signature is excluded (you can't sign your own signature).
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint8 side)"
    );

    // orderHash => amount of makerAmount already consumed. a cancel sets this
    // to makerAmount (fully consumed), which also blocks any future fill.
    mapping(bytes32 => uint256) public filled;

    // a registered outcome token: its complement (YES<->NO) and its condition.
    // registering a market lets a fill tell mint/merge/transfer apart.
    struct TokenInfo {
        bool registered;
        uint256 complement;
        bytes32 conditionId;
    }

    mapping(uint256 => TokenInfo) public tokens; // tokenId => info

    IConditionalTokens public immutable ctf;
    IERC20 public immutable collateral;

    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    event MarketRegistered(bytes32 indexed conditionId, uint256 yesTokenId, uint256 noTokenId);

    constructor(IConditionalTokens _ctf, IERC20 _collateral) EIP712("mtech_market", "1") {
        ctf = _ctf;
        collateral = _collateral;
        // let the CTF pull our collateral when we splitPosition during a mint
        _collateral.approve(address(_ctf), type(uint256).max);
    }

    // derive and store the YES/NO outcome-token ids for a prepared condition.
    // idempotent + deterministic -- just computes ids from the CTF.
    function registerMarket(bytes32 conditionId)
        external
        returns (uint256 yesTokenId, uint256 noTokenId)
    {
        // index set 0b01 = YES (slot 0), 0b10 = NO (slot 1)
        uint256 yesId =
            ctf.getPositionId(address(collateral), ctf.getCollectionId(bytes32(0), conditionId, 1));
        uint256 noId =
            ctf.getPositionId(address(collateral), ctf.getCollectionId(bytes32(0), conditionId, 2));

        tokens[yesId] = TokenInfo(true, noId, conditionId);
        tokens[noId] = TokenInfo(true, yesId, conditionId);
        emit MarketRegistered(conditionId, yesId, noId);
        return (yesId, noId);
    }

    // the digest a wallet actually signs: domain-separated hash of the order.
    // _hashTypedDataV4 prepends "\x19\x01" + the domain separator, so a
    // signature for this app/chain/contract can't be replayed elsewhere.
    function hashOrder(Order calldata o) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                o.salt,
                o.maker,
                o.tokenId,
                o.makerAmount,
                o.takerAmount,
                o.expiration,
                o.nonce,
                o.side
            )
        );
        return _hashTypedDataV4(structHash);
    }

    // recover the signer from the signature and require it is the maker
    function verify(Order calldata o) public view returns (address signer) {
        signer = ECDSA.recover(hashOrder(o), o.signature);
        require(signer == o.maker, "Exchange: bad signature");
    }

    // full check before a fill: valid signature, not expired, still fillable.
    // returns the order hash and how much of makerAmount remains.
    function validateOrder(Order calldata o)
        public
        view
        returns (bytes32 orderHash, uint256 remaining)
    {
        orderHash = hashOrder(o);
        require(ECDSA.recover(orderHash, o.signature) == o.maker, "Exchange: bad signature");
        require(o.expiration == 0 || block.timestamp <= o.expiration, "Exchange: expired");
        uint256 done = filled[orderHash];
        require(done < o.makerAmount, "Exchange: filled or cancelled");
        remaining = o.makerAmount - done;
    }

    // the maker (only) invalidates their order by marking it fully consumed
    function cancelOrder(Order calldata o) external {
        require(msg.sender == o.maker, "Exchange: not maker");
        bytes32 orderHash = hashOrder(o);
        filled[orderHash] = o.makerAmount;
        emit OrderCancelled(orderHash, o.maker);
    }

    event Fill(
        bytes32 indexed buyHash,
        bytes32 indexed sellHash,
        uint256 tokenId,
        uint256 tokenAmount,
        uint256 cost
    );

    // TRANSFER match: a BUY and a SELL of the SAME outcome token. the buyer
    // pays the seller, the seller's tokens move to the buyer. no CTF -- a pure
    // asset swap. executed at the seller's (resting) price. operator-submitted.
    function fillTransfer(Order calldata buyOrder, Order calldata sellOrder, uint256 tokenAmount)
        external
    {
        require(buyOrder.side == Side.BUY && sellOrder.side == Side.SELL, "Exchange: sides");
        require(buyOrder.tokenId == sellOrder.tokenId, "Exchange: token mismatch");
        require(tokens[buyOrder.tokenId].registered, "Exchange: unregistered token");

        (bytes32 buyHash, uint256 buyRemainingUsdc) = validateOrder(buyOrder);
        (bytes32 sellHash, uint256 sellRemainingTokens) = validateOrder(sellOrder);

        // prices cross: buyer's limit >= seller's limit (cross-multiplied, no division).
        // buy price = makerAmount(USDC)/takerAmount(tok); sell price = takerAmount/makerAmount
        require(
            buyOrder.makerAmount * sellOrder.makerAmount
                >= sellOrder.takerAmount * buyOrder.takerAmount,
            "Exchange: no cross"
        );

        // execute at the seller's price
        uint256 cost = tokenAmount * sellOrder.takerAmount / sellOrder.makerAmount;
        require(tokenAmount <= sellRemainingTokens, "Exchange: sell exceeded");
        require(cost <= buyRemainingUsdc, "Exchange: buy exceeded");

        filled[buyHash] += cost;
        filled[sellHash] += tokenAmount;

        // both parties approved the exchange: buyer -> seller USDC, seller -> buyer tokens
        collateral.safeTransferFrom(buyOrder.maker, sellOrder.maker, cost);
        IERC1155(address(ctf)).safeTransferFrom(
            sellOrder.maker, buyOrder.maker, buyOrder.tokenId, tokenAmount, ""
        );

        emit Fill(buyHash, sellHash, buyOrder.tokenId, tokenAmount, cost);
    }
}
