// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";

// the exchange: users sign orders off-chain; the operator matches them and
// submits fills here. ERC1155Holder so it can custody outcome tokens mid-fill.
contract Exchange is EIP712, ERC1155Holder, Ownable {
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

    address public operator; // only address allowed to submit fills
    uint256 public feeRateBps; // fee on fills, in basis points (100 = 1%)

    modifier onlyOperator() {
        require(msg.sender == operator, "Exchange: not operator");
        _;
    }

    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
    event MarketRegistered(bytes32 indexed conditionId, uint256 yesTokenId, uint256 noTokenId);
    event OperatorSet(address indexed operator);
    event FeeRateSet(uint256 bps);

    constructor(IConditionalTokens _ctf, IERC20 _collateral, address _operator, uint256 _feeRateBps)
        EIP712("mtech_market", "1")
        Ownable(msg.sender)
    {
        ctf = _ctf;
        collateral = _collateral;
        operator = _operator;
        feeRateBps = _feeRateBps;
        // let the CTF pull our collateral when we splitPosition during a mint
        _collateral.approve(address(_ctf), type(uint256).max);
    }

    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
        emit OperatorSet(_operator);
    }

    function setFeeRateBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "Exchange: fee too high"); // cap at 10%
        feeRateBps = _bps;
        emit FeeRateSet(_bps);
    }

    // the owner pulls accrued revenue (transfer fees + mint/merge spread) in USDC
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        collateral.safeTransfer(to, amount);
    }

    // derive and store the YES/NO outcome-token ids for a prepared condition.
    // idempotent + deterministic -- just computes ids from the CTF.
    function registerMarket(bytes32 conditionId) external returns (uint256 yesTokenId, uint256 noTokenId) {
        // index set 0b01 = YES (slot 0), 0b10 = NO (slot 1)
        uint256 yesId = ctf.getPositionId(address(collateral), ctf.getCollectionId(bytes32(0), conditionId, 1));
        uint256 noId = ctf.getPositionId(address(collateral), ctf.getCollectionId(bytes32(0), conditionId, 2));

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
                ORDER_TYPEHASH, o.salt, o.maker, o.tokenId, o.makerAmount, o.takerAmount, o.expiration, o.nonce, o.side
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
    function validateOrder(Order calldata o) public view returns (bytes32 orderHash, uint256 remaining) {
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

    event Fill(bytes32 indexed buyHash, bytes32 indexed sellHash, uint256 tokenId, uint256 tokenAmount, uint256 cost);

    // TRANSFER match: a BUY and a SELL of the SAME outcome token. the buyer
    // pays the seller, the seller's tokens move to the buyer. no CTF -- a pure
    // asset swap. executed at the seller's (resting) price. operator-submitted.
    function fillTransfer(Order calldata buyOrder, Order calldata sellOrder, uint256 tokenAmount)
        external
        onlyOperator
    {
        require(buyOrder.side == Side.BUY && sellOrder.side == Side.SELL, "Exchange: sides");
        require(buyOrder.tokenId == sellOrder.tokenId, "Exchange: token mismatch");
        require(tokens[buyOrder.tokenId].registered, "Exchange: unregistered token");

        (bytes32 buyHash, uint256 buyRemainingUsdc) = validateOrder(buyOrder);
        (bytes32 sellHash, uint256 sellRemainingTokens) = validateOrder(sellOrder);

        // prices cross: buyer's limit >= seller's limit (cross-multiplied, no division).
        // buy price = makerAmount(USDC)/takerAmount(tok); sell price = takerAmount/makerAmount
        require(
            buyOrder.makerAmount * sellOrder.makerAmount >= sellOrder.takerAmount * buyOrder.takerAmount,
            "Exchange: no cross"
        );

        // execute at the seller's price
        uint256 cost = tokenAmount * sellOrder.takerAmount / sellOrder.makerAmount;
        require(tokenAmount <= sellRemainingTokens, "Exchange: sell exceeded");
        require(cost <= buyRemainingUsdc, "Exchange: buy exceeded");

        filled[buyHash] += cost;
        filled[sellHash] += tokenAmount;

        // buyer pays `cost`: the seller receives cost - fee, the exchange keeps the fee
        uint256 fee = cost * feeRateBps / 10000;
        collateral.safeTransferFrom(buyOrder.maker, sellOrder.maker, cost - fee);
        if (fee > 0) {
            collateral.safeTransferFrom(buyOrder.maker, address(this), fee);
        }
        IERC1155(address(ctf)).safeTransferFrom(sellOrder.maker, buyOrder.maker, buyOrder.tokenId, tokenAmount, "");

        emit Fill(buyHash, sellHash, buyOrder.tokenId, tokenAmount, cost);
    }

    event Mint(bytes32 indexed yesHash, bytes32 indexed noHash, uint256 setAmount);

    // MINT match: BUY YES x BUY NO on complementary tokens. neither buyer owns
    // tokens -- the exchange collects USDC from both, splits a complete set via
    // the CTF, and hands each their side. if their prices sum to > 1 the surplus
    // stays in the exchange as spread.
    function fillMint(Order calldata yesBuy, Order calldata noBuy, uint256 setAmount) external onlyOperator {
        require(yesBuy.side == Side.BUY && noBuy.side == Side.BUY, "Exchange: sides");
        TokenInfo memory yInfo = tokens[yesBuy.tokenId];
        require(yInfo.registered && yInfo.complement == noBuy.tokenId, "Exchange: not complements");

        (bytes32 yesHash, uint256 yesRemaining) = validateOrder(yesBuy);
        (bytes32 noHash, uint256 noRemaining) = validateOrder(noBuy);

        // the two buyers together must cover a $1 set: priceYes + priceNo >= 1
        require(
            yesBuy.makerAmount * noBuy.takerAmount + noBuy.makerAmount * yesBuy.takerAmount
                >= yesBuy.takerAmount * noBuy.takerAmount,
            "Exchange: no cross"
        );

        uint256 costYes = setAmount * yesBuy.makerAmount / yesBuy.takerAmount;
        uint256 costNo = setAmount * noBuy.makerAmount / noBuy.takerAmount;
        require(costYes <= yesRemaining && costNo <= noRemaining, "Exchange: exceeded");

        filled[yesHash] += costYes;
        filled[noHash] += costNo;

        // collect USDC from both buyers into the exchange
        collateral.safeTransferFrom(yesBuy.maker, address(this), costYes);
        collateral.safeTransferFrom(noBuy.maker, address(this), costNo);

        // mint a complete set: setAmount USDC (pulled from us) -> setAmount YES + NO to us
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ctf.splitPosition(address(collateral), bytes32(0), yInfo.conditionId, partition, setAmount);

        // hand each buyer their side
        IERC1155(address(ctf)).safeTransferFrom(address(this), yesBuy.maker, yesBuy.tokenId, setAmount, "");
        IERC1155(address(ctf)).safeTransferFrom(address(this), noBuy.maker, noBuy.tokenId, setAmount, "");

        emit Mint(yesHash, noHash, setAmount);
    }

    event Merge(bytes32 indexed yesHash, bytes32 indexed noHash, uint256 setAmount);

    // MERGE match: SELL YES x SELL NO on complementary tokens. both sellers
    // deliver their tokens; the exchange burns the set via the CTF back into
    // USDC and pays each seller their price. surplus (if prices sum < 1) stays.
    function fillMerge(Order calldata yesSell, Order calldata noSell, uint256 setAmount) external onlyOperator {
        require(yesSell.side == Side.SELL && noSell.side == Side.SELL, "Exchange: sides");
        TokenInfo memory yInfo = tokens[yesSell.tokenId];
        require(yInfo.registered && yInfo.complement == noSell.tokenId, "Exchange: not complements");

        (bytes32 yesHash, uint256 yesRemaining) = validateOrder(yesSell);
        (bytes32 noHash, uint256 noRemaining) = validateOrder(noSell);

        // sellers together accept <= $1 for the set they destroy: priceYes + priceNo <= 1
        require(
            yesSell.takerAmount * noSell.makerAmount + noSell.takerAmount * yesSell.makerAmount
                <= yesSell.makerAmount * noSell.makerAmount,
            "Exchange: no cross"
        );

        require(setAmount <= yesRemaining && setAmount <= noRemaining, "Exchange: exceeded");
        filled[yesHash] += setAmount;
        filled[noHash] += setAmount;

        // pull both tokens into the exchange
        IERC1155(address(ctf)).safeTransferFrom(yesSell.maker, address(this), yesSell.tokenId, setAmount, "");
        IERC1155(address(ctf)).safeTransferFrom(noSell.maker, address(this), noSell.tokenId, setAmount, "");

        // burn the set -> setAmount USDC back to the exchange
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ctf.mergePositions(address(collateral), bytes32(0), yInfo.conditionId, partition, setAmount);

        // pay each seller their price
        uint256 payYes = setAmount * yesSell.takerAmount / yesSell.makerAmount;
        uint256 payNo = setAmount * noSell.takerAmount / noSell.makerAmount;
        collateral.safeTransfer(yesSell.maker, payYes);
        collateral.safeTransfer(noSell.maker, payNo);

        emit Merge(yesHash, noHash, setAmount);
    }
}
