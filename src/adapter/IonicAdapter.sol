// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../mocks/MockIonic.sol";

/**
 * @title IonicAdapter
 * @notice Adapter for integrating SuperCluster with Ionic-style lending protocol.
 *         - Handles deposits (mint), withdrawals (redeem), and balance queries.
 *         - Converts between assets and cTokens using exchange rate.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract IonicAdapter is Adapter {
    /// @notice Ionic-style lending pool contract
    LendingPool public immutable LENDINGPOOL;

    /**
     * @dev Deploys IonicAdapter contract.
     * @param _token Base token address.
     * @param _protocolAddress Ionic lending pool address.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(address _token, address _protocolAddress, string memory _protocolName, string memory _pilotStrategy)
        Adapter(_token, _protocolAddress, _protocolName, _pilotStrategy)
    {
        LENDINGPOOL = LendingPool(_protocolAddress);
    }

    /**
     * @notice Deposit base token into Ionic protocol (mint cTokens).
     * @param amount Amount of base token to deposit.
     * @return shares Amount of cTokens received.
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(PROTOCOL_ADDRESS, amount);

        // Get cToken balance before mint
        uint256 cTokensBefore = LENDINGPOOL.balanceOf(address(this));

        // Mint cTokens (Ionic/Compound V2 interface)
        LENDINGPOOL.mint(amount);

        // Calculate cTokens received
        uint256 cTokensAfter = LENDINGPOOL.balanceOf(address(this));
        shares = cTokensAfter - cTokensBefore;

        _updateTotalDeposited(amount, true);

        emit Deposited(amount);
        return shares;
    }

    /**
     * @notice Withdraw base token from Ionic to a receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return withdrawnAmount Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 withdrawnAmount) {
        if (amount == 0) revert InvalidAmount();

        uint256 shares = convertToShares(amount);
        uint256 currentShares = LENDINGPOOL.balanceOf(address(this));

        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Redeem cTokens (Ionic/Compound V2 interface)
        LENDINGPOOL.redeem(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        withdrawnAmount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(to, withdrawnAmount);
        require(status, "Transfer failed");

        _updateTotalDeposited(withdrawnAmount, false);

        emit Withdrawn(withdrawnAmount);
        return withdrawnAmount;
    }

    /**
     * @notice Withdraw base token from Ionic to caller by redeeming cTokens.
     * @param shares Amount of cTokens to redeem.
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        uint256 currentShares = LENDINGPOOL.balanceOf(address(this));
        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Redeem cTokens (Ionic/Compound V2 interface)
        LENDINGPOOL.redeem(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(msg.sender, amount);
        require(status, "Transfer failed");

        _updateTotalDeposited(amount, false);

        emit Withdrawn(amount);
        return amount;
    }

    /**
     * @notice Get current supply balance in assets from Ionic.
     * @return Current supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        return LENDINGPOOL.totalSupplyAssets();
    }

    /**
     * @notice Get cTokens (shares) held by this adapter.
     * @return cToken amount.
     */
    function getSupplyShares() external view returns (uint256) {
        return LENDINGPOOL.balanceOf(address(this));
    }

    /**
     * @notice Convert asset amount to supply shares using current exchange rate.
     * @param assets Amount of base token.
     * @return Equivalent supply shares.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;

        uint256 totalSupplyAssets = LENDINGPOOL.totalSupplyAssets();
        uint256 totalSupplyShares = LENDINGPOOL.totalSupplyShares();

        if (totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return assets;
        }

        return (assets * totalSupplyShares) / totalSupplyAssets;
    }

    /**
     * @notice Convert supply shares to asset amount using current exchange rate.
     * @param shares Amount of supply shares.
     * @return Equivalent base token amount.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;

        uint256 totalSupplyAssets = LENDINGPOOL.totalSupplyAssets();
        uint256 totalSupplyShares = LENDINGPOOL.totalSupplyShares();

        if (totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return shares;
        }

        return (shares * totalSupplyAssets) / totalSupplyShares;
    }

    /**
     * @notice Get pending rewards (Ionic does not support rewards in this mock).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (Ionic does not support rewards in this mock).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get lending pool info from Ionic.
     * @return totalSupplyAssets Total supplied assets.
     * @return totalSupplyShares Total cToken supply.
     * @return totalBorrowAssets Total borrowed assets.
     * @return totalBorrowShares Total borrow shares.
     */
    function getLendingPoolInfo()
        external
        view
        returns (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        )
    {
        totalSupplyAssets = LENDINGPOOL.totalSupplyAssets();
        totalSupplyShares = LENDINGPOOL.totalSupplyShares();
        totalBorrowAssets = LENDINGPOOL.totalBorrowAssets();
        totalBorrowShares = LENDINGPOOL.totalBorrowShares();
    }

    /**
     * @notice Manually accrue interest in Ionic (for testing).
     */
    function accureInterest() external {
        LENDINGPOOL.accureInterest();
    }

    /**
     * @notice Get exchange rate from cTokens to underlying.
     * @return Exchange rate scaled by 1e18.
     */
    function exchangeRate() external view returns (uint256) {
        return LENDINGPOOL.exchangeRateStored();
    }

    /**
     * @notice Get total assets held by this adapter in Ionic.
     * @return Total underlying balance for this adapter.
     */
    function getTotalAssets() external view override returns (uint256) {
        return LENDINGPOOL.balanceOfUnderlying(address(this));
    }
}
