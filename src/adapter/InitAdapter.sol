// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InitLendingPool} from "../mocks/MockInit.sol";

/**
 * @title InitAdapter
 * @notice Adapter for integrating SuperCluster with Init Capital style lending protocol.
 *         - Handles deposits (supply), withdrawals (withdraw), and balance queries.
 *         - Converts between assets and shares using exchange rate.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract InitAdapter is Adapter {
    /// @notice Init-style lending pool contract
    InitLendingPool public immutable LENDING_POOL;

    /**
     * @dev Deploys InitAdapter contract.
     * @param _token Base token address.
     * @param _protocolAddress Init lending pool address.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(address _token, address _protocolAddress, string memory _protocolName, string memory _pilotStrategy)
        Adapter(_token, _protocolAddress, _protocolName, _pilotStrategy)
    {
        LENDING_POOL = InitLendingPool(_protocolAddress);
    }

    /**
     * @notice Deposit base token into Init protocol (supply assets).
     * @param amount Amount of base token to deposit.
     * @return shares Amount of shares received.
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(PROTOCOL_ADDRESS, amount);

        // Get shares before supply
        uint256 sharesBefore = LENDING_POOL.getUserSupplyShares(address(this));

        // Supply assets (Init Capital interface)
        LENDING_POOL.supply(amount);

        // Calculate shares received
        uint256 sharesAfter = LENDING_POOL.getUserSupplyShares(address(this));
        shares = sharesAfter - sharesBefore;

        _updateTotalDeposited(amount, true);

        emit Deposited(amount);
        return shares;
    }

    /**
     * @notice Withdraw base token from Init to a receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return withdrawnAmount Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 withdrawnAmount) {
        if (amount == 0) revert InvalidAmount();

        uint256 shares = convertToShares(amount);
        uint256 currentShares = LENDING_POOL.getUserSupplyShares(address(this));

        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw assets (Init Capital interface)
        LENDING_POOL.withdraw(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        withdrawnAmount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(to, withdrawnAmount);
        require(status, "Transfer failed");

        _updateTotalDeposited(withdrawnAmount, false);

        emit Withdrawn(withdrawnAmount);
        return withdrawnAmount;
    }

    /**
     * @notice Withdraw base token from Init to caller by redeeming shares.
     * @param shares Amount of shares to redeem.
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        uint256 currentShares = LENDING_POOL.getUserSupplyShares(address(this));
        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw by shares (Init Capital interface)
        LENDING_POOL.withdraw(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(msg.sender, amount);
        require(status, "Transfer failed");

        _updateTotalDeposited(amount, false);

        emit Withdrawn(amount);
        return amount;
    }

    /**
     * @notice Get current supply balance in assets from Init.
     * @return Current supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        return LENDING_POOL.totalSupplyAssets();
    }

    /**
     * @notice Get shares held by this adapter.
     * @return Share amount.
     */
    function getSupplyShares() external view returns (uint256) {
        return LENDING_POOL.getUserSupplyShares(address(this));
    }

    /**
     * @notice Convert asset amount to supply shares using current exchange rate.
     * @param assets Amount of base token.
     * @return Equivalent supply shares.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;

        uint256 totalAssets = LENDING_POOL.totalSupplyAssets();
        uint256 totalShares = LENDING_POOL.totalSupplyShares();

        if (totalAssets == 0 || totalShares == 0) {
            return assets;
        }

        return (assets * totalShares) / totalAssets;
    }

    /**
     * @notice Convert supply shares to asset amount using current exchange rate.
     * @param shares Amount of supply shares.
     * @return Equivalent base token amount.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;

        uint256 totalAssets = LENDING_POOL.totalSupplyAssets();
        uint256 totalShares = LENDING_POOL.totalSupplyShares();

        if (totalAssets == 0 || totalShares == 0) {
            return shares;
        }

        return (shares * totalAssets) / totalShares;
    }

    /**
     * @notice Get pending rewards (Init does not support rewards in this mock).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (Init does not support rewards in this mock).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get lending pool info from Init.
     * @return totalAssets Total supplied assets.
     * @return totalShares Total supply shares.
     * @return totalBorrowAssets Total borrowed assets.
     * @return totalBorrowShares Total borrow shares.
     */
    function getLendingPoolInfo()
        external
        view
        returns (uint256 totalAssets, uint256 totalShares, uint256 totalBorrowAssets, uint256 totalBorrowShares)
    {
        totalAssets = LENDING_POOL.totalSupplyAssets();
        totalShares = LENDING_POOL.totalSupplyShares();
        totalBorrowAssets = LENDING_POOL.totalBorrowAssets();
        totalBorrowShares = LENDING_POOL.totalBorrowShares();
    }

    /**
     * @notice Manually accrue interest in Init (for testing).
     */
    function accrueInterest() external {
        LENDING_POOL.accrueInterest();
    }

    /**
     * @notice Get exchange rate from shares to underlying.
     * @return Exchange rate scaled by 1e18.
     */
    function exchangeRate() external view returns (uint256) {
        return LENDING_POOL.exchangeRate();
    }

    /**
     * @notice Get total assets held by this adapter in Init.
     * @return Total underlying balance for this adapter.
     */
    function getTotalAssets() external view override returns (uint256) {
        return LENDING_POOL.getUserSupplyBalance(address(this));
    }
}
