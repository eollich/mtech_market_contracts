// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// the exchange: users sign orders off-chain; the operator matches them and
// submits fills here. this first slice is just the signed-order primitive --
// the Order struct, its EIP-712 hash, and signature verification.
contract Exchange is EIP712 {
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

    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);

    constructor() EIP712("mtech_market", "1") {}

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
}
