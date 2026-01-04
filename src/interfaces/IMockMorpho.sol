// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Id, MarketParams} from "../mocks/interfaces/IMorpho.sol";

/**
 * @title IMockMorpho
 * @notice Interface for the MockMorpho lending protocol used in SuperCluster.
 *         - Supports supplying, withdrawing, querying positions and markets, and protocol configuration.
 *         - Used by MorphoAdapter and tests for protocol integration.
 * @author SuperCluster Dev Team
 */
interface IMockMorpho {
    /**
     * @notice Supply assets to a market.
     * @param marketParams Market parameters struct.
     * @param assets Amount of assets to supply.
     * @param shares Amount of shares to supply (optional).
     * @param onBehalf Address to supply on behalf of.
     * @param data Additional data for supply.
     * @return assetsSupplied Amount of assets supplied.
     * @return sharesReceived Amount of supply shares received.
     */
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesReceived);

    /**
     * @notice Withdraw assets or shares from a market.
     * @param marketParams Market parameters struct.
     * @param assets Amount of assets to withdraw (optional).
     * @param shares Amount of shares to withdraw (optional).
     * @param onBehalf Address to withdraw on behalf of.
     * @param receiver Address to receive withdrawn assets.
     * @return assetsWithdrawn Amount of assets withdrawn.
     * @return sharesBurned Amount of supply shares burned.
     */
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesBurned);

    /**
     * @notice Get position data for a user in a market.
     * @param id Market ID.
     * @param user User address.
     * @return supplyShares Amount of supply shares.
     * @return borrowShares Amount of borrow shares.
     * @return collateral Amount of collateral.
     */
    function position(Id id, address user)
        external
        view
        returns (uint128 supplyShares, uint128 borrowShares, uint128 collateral);

    /**
     * @notice Get market data for a given market ID.
     * @param id Market ID.
     * @return totalSupplyAssets Total supplied assets.
     * @return totalSupplyShares Total supply shares.
     * @return totalBorrowAssets Total borrowed assets.
     * @return totalBorrowShares Total borrow shares.
     * @return lastUpdate Timestamp of last update.
     * @return fee Protocol fee.
     */
    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    /**
     * @notice Create a new market with given parameters.
     * @param marketParams Market parameters struct.
     */
    function createMarket(MarketParams memory marketParams) external;

    /**
     * @notice Enable interest rate model (IRM) for protocol.
     * @param irm Address of IRM contract.
     */
    function enableIrm(address irm) external;

    /**
     * @notice Enable loan-to-value (LLTV) ratio for protocol.
     * @param lltv Loan-to-value ratio.
     */
    function enableLltv(uint256 lltv) external;

    /**
     * @notice Accrue interest for a market.
     * @param marketParams Market parameters struct.
     */
    function accrueInterest(MarketParams memory marketParams) external;

    /**
     * @notice Get market parameters for a given market ID.
     * @param id Market ID.
     * @return marketParams Market parameters struct.
     */
    function idToMarketParams(Id id) external view returns (MarketParams memory marketParams);
}
