// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "../adapter/Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Id, MarketParams} from "../mocks/interfaces/IMorpho.sol";
import {IMockMorpho} from "../interfaces/IMockMorpho.sol";

/**
 * @title MorphoAdapter
 * @notice Adapter for integrating SuperCluster with MockMorpho lending protocol.
 *         - Handles deposits, withdrawals, and balance queries.
 *         - Converts between assets and shares using MockMorpho exchange rate.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract MorphoAdapter is Adapter {
    /// @notice MockMorpho protocol contract
    IMockMorpho public immutable MORPHO;

    /// @notice Market parameters for this adapter
    MarketParams public marketParams;

    /// @notice Market ID for this adapter
    Id public marketId;

    /**
     * @dev Deploys MorphoAdapter contract.
     * @param _token Base token address.
     * @param _morpho MockMorpho protocol address.
     * @param _marketParams Market parameters struct.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(
        address _token,
        address _morpho,
        MarketParams memory _marketParams,
        string memory _protocolName,
        string memory _pilotStrategy
    ) Adapter(_token, _morpho, _protocolName, _pilotStrategy) {
        MORPHO = IMockMorpho(_morpho);
        marketParams = _marketParams;
        marketId = Id.wrap(keccak256(abi.encode(_marketParams)));
    }

    /**
     * @notice Deposit base token into MockMorpho protocol.
     * @param amount Amount of base token to deposit.
     * @return shares Amount of supply shares received.
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        // Transfer from caller (Pilot)
        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(address(MORPHO), amount);

        (uint256 assetsSupplied, uint256 sharesReturned) = MORPHO.supply(marketParams, amount, 0, address(this), "");

        _updateTotalDeposited(assetsSupplied, true);

        emit Deposited(assetsSupplied);
        return sharesReturned;
    }

    /**
     * @notice Withdraw base token from MockMorpho protocol.
     * @param shares Amount of supply shares to withdraw.
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        (uint128 supplyShares,,) = MORPHO.position(marketId, address(this));
        if (uint256(supplyShares) < shares) revert InsufficientBalance();

        (uint256 assetsWithdrawn,) = MORPHO.withdraw(marketParams, 0, shares, address(this), msg.sender);

        _updateTotalDeposited(assetsWithdrawn, false);

        emit Withdrawn(assetsWithdrawn);
        return assetsWithdrawn;
    }

    /**
     * @notice Get current supply position in assets.
     * @return Current supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        (uint128 supplyShares,,) = MORPHO.position(marketId, address(this));
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(marketId);

        if (totalSupplyShares == 0) return 0;
        return (uint256(supplyShares) * uint256(totalSupplyAssets)) / uint256(totalSupplyShares);
    }

    /**
     * @notice Get raw supply shares held by this adapter in MockMorpho.
     * @return Supply shares amount.
     */
    function getSupplyShares() external view returns (uint256) {
        (uint128 supplyShares,,) = MORPHO.position(marketId, address(this));
        return uint256(supplyShares);
    }

    /**
     * @notice Get full position data for this adapter.
     */
    function getPosition() external view returns (uint128 supplyShares, uint128 borrowShares, uint128 collateral) {
        return MORPHO.position(marketId, address(this));
    }

    /**
     * @notice Get market information for this adapter.
     */
    function getMarketData()
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        )
    {
        return MORPHO.market(marketId);
    }

    /**
     * @notice Get total assets held by this adapter in MockMorpho.
     * @return Total supply balance for this adapter.
     */
    function getTotalAssets() public view override returns (uint256) {
        return this.getBalance();
    }

    /**
     * @notice Withdraw specified assets and send directly to receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return assetsWithdrawn Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 assetsWithdrawn) {
        if (amount == 0) revert InvalidAmount();

        (assetsWithdrawn,) = MORPHO.withdraw(marketParams, amount, 0, address(this), to);

        _updateTotalDeposited(assetsWithdrawn, false);

        emit Withdrawn(assetsWithdrawn);
        return assetsWithdrawn;
    }

    /**
     * @notice Convert asset amount to supply shares using current exchange rate.
     * @param assets Amount of base token.
     * @return Equivalent supply shares.
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        if (assets == 0) return 0;
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(marketId);
        if (totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return assets;
        }
        return (assets * uint256(totalSupplyShares)) / uint256(totalSupplyAssets);
    }

    /**
     * @notice Convert supply shares to asset amount using current exchange rate.
     * @param shares Amount of supply shares.
     * @return Equivalent base token amount.
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (shares == 0) return 0;
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(marketId);
        if (totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return shares;
        }
        return (shares * uint256(totalSupplyAssets)) / uint256(totalSupplyShares);
    }

    /**
     * @notice Get pending rewards (MockMorpho does not support rewards).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (MockMorpho does not support rewards).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get market ID for this adapter.
     * @return Market ID (bytes32).
     */
    function getMarketId() external view returns (bytes32) {
        return Id.unwrap(marketId);
    }

    /**
     * @notice Get market parameters for this adapter.
     * @return MarketParams struct.
     */
    function getMarketParams() external view returns (MarketParams memory) {
        return marketParams;
    }

    /**
     * @notice Accrue interest manually in MockMorpho (for testing).
     */
    function accrueInterest() external {
        MORPHO.accrueInterest(marketParams);
    }
}
