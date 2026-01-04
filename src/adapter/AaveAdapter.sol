// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../mocks/MockAave.sol";

/**
 * @title AaveAdapter
 * @notice Adapter for integrating SuperCluster with MockAave lending protocol.
 *         - Handles deposits, withdrawals, and balance queries.
 *         - Converts between assets and shares using MockAave exchange rate.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract AaveAdapter is Adapter {
    /// @notice MockAave lending pool contract
    LendingPool public immutable LENDINGPOOL;

    /**
     * @dev Deploys AaveAdapter contract.
     * @param _token Base token address.
     * @param _protocolAddress MockAave lending pool address.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(address _token, address _protocolAddress, string memory _protocolName, string memory _pilotStrategy)
        Adapter(_token, _protocolAddress, _protocolName, _pilotStrategy)
    {
        LENDINGPOOL = LendingPool(_protocolAddress);
    }

    /**
     * @notice Deposit base token into MockAave protocol.
     * @param amount Amount of base token to deposit.
     * @return shares Amount of supply shares received.
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(PROTOCOL_ADDRESS, amount);

        LENDINGPOOL.supply(amount);

        shares = amount;

        _updateTotalDeposited(amount, true);

        emit Deposited(amount);
        return shares;
    }

    /**
     * @notice Withdraw base token from MockAave to a receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return withdrawnAmount Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 withdrawnAmount) {
        if (amount == 0) revert InvalidAmount();

        uint256 shares = convertToShares(amount);
        uint256 currentShares = LENDINGPOOL.getUserSupplyShares(address(this));

        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        LENDINGPOOL.withdraw(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        withdrawnAmount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(to, withdrawnAmount);
        require(status, "Transfer failed");

        _updateTotalDeposited(withdrawnAmount, false);

        emit Withdrawn(withdrawnAmount);
        return withdrawnAmount;
    }

    /**
     * @notice Withdraw base token from MockAave to caller.
     * @param shares Amount of supply shares to withdraw.
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        uint256 currentShares = LENDINGPOOL.getUserSupplyShares(address(this));
        if (currentShares < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        LENDINGPOOL.withdraw(shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(msg.sender, amount);
        require(status, "Transfer failed");

        _updateTotalDeposited(amount, false);

        emit Withdrawn(amount);
        return amount;
    }

    /**
     * @notice Get current supply balance in assets from MockAave.
     * @return Current supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        return LENDINGPOOL.totalSupplyAssets();
    }

    /**
     * @notice Get raw supply shares held by this adapter in MockAave.
     * @return Supply shares amount.
     */
    function getSupplyShares() external view returns (uint256) {
        return LENDINGPOOL.getUserSupplyShares(address(this));
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
     * @notice Get pending rewards (MockAave does not support rewards).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (MockAave does not support rewards).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get lending pool info from MockAave.
     * @return totalSupplyAssets Total supplied assets.
     * @return totalSupplyShares Total supply shares.
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
     * @notice Manually accrue interest in MockAave (for testing).
     */
    function accureInterest() external {
        LENDINGPOOL.accureInterest();
    }

    /**
     * @notice Get total assets held by this adapter in MockAave.
     * @return Total supply balance for this adapter.
     */
    function getTotalAssets() external view override returns (uint256) {
        return LENDINGPOOL.getUserSupplyBalance(address(this));
    }
}
