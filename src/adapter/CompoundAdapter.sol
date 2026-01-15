// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Comet} from "../mocks/MockCompound.sol";

/**
 * @title CompoundAdapter
 * @notice Adapter for integrating SuperCluster with Compound V3 (Comet) style lending protocol.
 *         - Handles deposits (supply), withdrawals (withdraw), and balance queries.
 *         - Uses Compound V3's direct supply/withdraw interface.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract CompoundAdapter is Adapter {
    /// @notice Compound V3 Comet contract
    Comet public immutable COMET;

    /**
     * @dev Deploys CompoundAdapter contract.
     * @param _token Base token address.
     * @param _protocolAddress Comet contract address.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(address _token, address _protocolAddress, string memory _protocolName, string memory _pilotStrategy)
        Adapter(_token, _protocolAddress, _protocolName, _pilotStrategy)
    {
        COMET = Comet(_protocolAddress);
    }

    /**
     * @notice Deposit base token into Compound V3 protocol.
     * @param amount Amount of base token to deposit.
     * @return shares Amount of shares received (in Compound V3, this equals the supplied amount).
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(PROTOCOL_ADDRESS, amount);

        // Get balance before supply
        uint256 balanceBefore = COMET.balanceOf(address(this));

        // Supply to Compound V3
        COMET.supply(TOKEN, amount);

        // Calculate shares received
        uint256 balanceAfter = COMET.balanceOf(address(this));
        shares = balanceAfter - balanceBefore;

        _updateTotalDeposited(amount, true);

        emit Deposited(amount);
        return shares;
    }

    /**
     * @notice Withdraw base token from Compound V3 to a receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return withdrawnAmount Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 withdrawnAmount) {
        if (amount == 0) revert InvalidAmount();

        uint256 currentBalance = COMET.balanceOf(address(this));
        if (currentBalance < amount) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw from Compound V3
        COMET.withdraw(TOKEN, amount);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        withdrawnAmount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(to, withdrawnAmount);
        require(status, "Transfer failed");

        _updateTotalDeposited(withdrawnAmount, false);

        emit Withdrawn(withdrawnAmount);
        return withdrawnAmount;
    }

    /**
     * @notice Withdraw base token from Compound V3 to caller.
     * @param shares Amount of shares to redeem (in Compound V3, shares = amount).
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        uint256 currentBalance = COMET.balanceOf(address(this));
        if (currentBalance < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw from Compound V3
        COMET.withdraw(TOKEN, shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(msg.sender, amount);
        require(status, "Transfer failed");

        _updateTotalDeposited(amount, false);

        emit Withdrawn(amount);
        return amount;
    }

    /**
     * @notice Get current supply balance in Compound V3.
     * @return Current supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        return COMET.totalSupplyBase();
    }

    /**
     * @notice Get this adapter's balance in Compound V3.
     * @return Balance amount.
     */
    function getSupplyBalance() external view returns (uint256) {
        return COMET.balanceOf(address(this));
    }

    /**
     * @notice Convert asset amount to shares (1:1 in Compound V3).
     * @param assets Amount of base token.
     * @return Equivalent shares.
     */
    function convertToShares(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1 in Compound V3
    }

    /**
     * @notice Convert shares to asset amount (1:1 in Compound V3).
     * @param shares Amount of shares.
     * @return Equivalent base token amount.
     */
    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1 in Compound V3
    }

    /**
     * @notice Get pending rewards (Compound V3 rewards not implemented in mock).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (Compound V3 rewards not implemented in mock).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get Compound V3 protocol info.
     * @return totalSupplyBase Total supplied assets.
     * @return totalBorrowBase Total borrowed assets.
     * @return utilization Current utilization rate.
     * @return supplyRate Current supply APR.
     */
    function getProtocolInfo()
        external
        view
        returns (uint256 totalSupplyBase, uint256 totalBorrowBase, uint256 utilization, uint256 supplyRate)
    {
        totalSupplyBase = COMET.totalSupplyBase();
        totalBorrowBase = COMET.totalBorrowBase();
        utilization = COMET.getUtilization();
        supplyRate = COMET.getSupplyRate();
    }

    /**
     * @notice Manually accrue interest in Compound V3 (for testing).
     */
    function accrueInterest() external {
        COMET.accrueInterest();
    }

    /**
     * @notice Get supply index.
     * @return Current base supply index.
     */
    function getSupplyIndex() external view returns (uint256) {
        return COMET.baseSupplyIndex();
    }

    /**
     * @notice Get total assets held by this adapter in Compound V3.
     * @return Total underlying balance for this adapter.
     */
    function getTotalAssets() external view override returns (uint256) {
        return COMET.balanceOf(address(this));
    }
}
