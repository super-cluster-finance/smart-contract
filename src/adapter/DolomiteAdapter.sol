// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Adapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DolomiteMargin} from "../mocks/MockDolomite.sol";

/**
 * @title DolomiteAdapter
 * @notice Adapter for integrating SuperCluster with Dolomite margin protocol.
 *         - Handles deposits, withdrawals, and balance queries.
 *         - Uses Dolomite's margin account system with accountNumber.
 *         - Implements IAdapter interface for protocol compatibility.
 * @author SuperCluster Dev Team
 */
contract DolomiteAdapter is Adapter {
    /// @notice Dolomite Margin contract
    DolomiteMargin public immutable DOLOMITE;
    /// @notice Market ID for the base token
    uint256 public immutable MARKET_ID;
    /// @notice Account number used by this adapter (default: 0)
    uint256 public constant ACCOUNT_NUMBER = 0;

    /**
     * @dev Deploys DolomiteAdapter contract.
     * @param _token Base token address.
     * @param _protocolAddress Dolomite Margin contract address.
     * @param _marketId Market ID for the base token.
     * @param _protocolName Protocol name.
     * @param _pilotStrategy Strategy name for pilot.
     */
    constructor(
        address _token,
        address _protocolAddress,
        uint256 _marketId,
        string memory _protocolName,
        string memory _pilotStrategy
    ) Adapter(_token, _protocolAddress, _protocolName, _pilotStrategy) {
        DOLOMITE = DolomiteMargin(_protocolAddress);
        MARKET_ID = _marketId;
    }

    /**
     * @notice Deposit base token into Dolomite protocol.
     * @param amount Amount of base token to deposit.
     * @return shares Amount deposited (1:1 in Dolomite).
     */
    function deposit(uint256 amount) external override onlyActive returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(PROTOCOL_ADDRESS, amount);

        // Get balance before deposit
        (, uint256 balanceBefore) = DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);

        // Deposit to Dolomite
        DOLOMITE.deposit(ACCOUNT_NUMBER, MARKET_ID, amount);

        // Calculate shares received
        (, uint256 balanceAfter) = DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);
        shares = balanceAfter - balanceBefore;

        _updateTotalDeposited(amount, true);

        emit Deposited(amount);
        return shares;
    }

    /**
     * @notice Withdraw base token from Dolomite to a receiver.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount of base token to withdraw.
     * @return withdrawnAmount Amount actually withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external override onlyActive returns (uint256 withdrawnAmount) {
        if (amount == 0) revert InvalidAmount();

        (bool sign, uint256 currentBalance) = DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);
        if (!sign || currentBalance < amount) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw from Dolomite
        DOLOMITE.withdraw(ACCOUNT_NUMBER, MARKET_ID, amount);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        withdrawnAmount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(to, withdrawnAmount);
        require(status, "Transfer failed");

        _updateTotalDeposited(withdrawnAmount, false);

        emit Withdrawn(withdrawnAmount);
        return withdrawnAmount;
    }

    /**
     * @notice Withdraw base token from Dolomite to caller.
     * @param shares Amount of shares to redeem.
     * @return amount Amount of base token received.
     */
    function withdraw(uint256 shares) external override onlyActive returns (uint256 amount) {
        if (shares == 0) revert InvalidAmount();

        (bool sign, uint256 currentBalance) = DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);
        if (!sign || currentBalance < shares) revert InsufficientBalance();

        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));

        // Withdraw from Dolomite
        DOLOMITE.withdraw(ACCOUNT_NUMBER, MARKET_ID, shares);

        uint256 balanceAfter = IERC20(TOKEN).balanceOf(address(this));
        amount = balanceAfter - balanceBefore;

        bool status = IERC20(TOKEN).transfer(msg.sender, amount);
        require(status, "Transfer failed");

        _updateTotalDeposited(amount, false);

        emit Withdrawn(amount);
        return amount;
    }

    /**
     * @notice Get total supply balance in Dolomite for this market.
     * @return Current total supply balance in base token.
     */
    function getBalance() external view override returns (uint256) {
        return DOLOMITE.getTotalSupplyWei(MARKET_ID);
    }

    /**
     * @notice Get this adapter's balance in Dolomite.
     * @return sign True if positive balance.
     * @return value Balance amount.
     */
    function getAccountBalance() external view returns (bool sign, uint256 value) {
        return DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);
    }

    /**
     * @notice Convert asset amount to shares (1:1 in Dolomite).
     * @param assets Amount of base token.
     * @return Equivalent shares.
     */
    function convertToShares(uint256 assets) public pure returns (uint256) {
        return assets;
    }

    /**
     * @notice Convert shares to asset amount (1:1 in Dolomite).
     * @param shares Amount of shares.
     * @return Equivalent base token amount.
     */
    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares;
    }

    /**
     * @notice Get pending rewards (Dolomite rewards not implemented in mock).
     * @return Always returns 0.
     */
    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Harvest rewards (Dolomite rewards not implemented in mock).
     * @return Always returns 0.
     */
    function harvest() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Get Dolomite market info.
     * @return token Market token address.
     * @return totalSupplyPar Total supply in par.
     * @return totalBorrowPar Total borrow in par.
     * @return supplyIndex Current supply index.
     * @return borrowIndex Current borrow index.
     */
    function getMarketInfo()
        external
        view
        returns (
            address token,
            uint256 totalSupplyPar,
            uint256 totalBorrowPar,
            uint256 supplyIndex,
            uint256 borrowIndex
        )
    {
        return DOLOMITE.getMarket(MARKET_ID);
    }

    /**
     * @notice Manually accrue interest in Dolomite (for testing).
     */
    function accrueInterest() external {
        DOLOMITE.accrueInterest(MARKET_ID);
    }

    /**
     * @notice Get total assets held by this adapter in Dolomite.
     * @return Total underlying balance for this adapter.
     */
    function getTotalAssets() external view override returns (uint256) {
        (bool sign, uint256 value) = DOLOMITE.getAccountWei(address(this), ACCOUNT_NUMBER, MARKET_ID);
        if (!sign) return 0;
        return value;
    }

    /**
     * @notice Get the market ID used by this adapter.
     */
    function getMarketId() external view returns (uint256) {
        return MARKET_ID;
    }
}
