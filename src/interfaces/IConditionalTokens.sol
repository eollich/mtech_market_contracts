// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// minimal 0.8 view of the 0.5.x Gnosis Conditional Tokens Framework. the CTF
// takes IERC20 for collateral, but at the abi level that's just an address, so
// we use address here and stay abi-compatible. deployed via vm.deployCode.
interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;

    // split collateral into a full set of outcome tokens (mint)
    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    // burn a full set of outcome tokens back into collateral (merge)
    function mergePositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    // after resolution, exchange winning outcome tokens for collateral
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);

    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);

    // ERC-1155 balance of an outcome-token position
    function balanceOf(address account, uint256 id) external view returns (uint256);

    // ERC-1155 operator approval (let the exchange move your outcome tokens)
    function setApprovalForAll(address operator, bool approved) external;
}
