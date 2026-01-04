// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IAdapter
 * @notice Interface for protocol adapters in SuperCluster.
 *         - Defines standard functions for deposit, withdraw, rewards, and protocol info.
 *         - Used by Pilot and SuperCluster to interact with DeFi protocols.
 * @author SuperCluster Dev Team
 */
interface IAdapter {
    /**
     * @notice Deposit funds to the external protocol.
     * @param amount Amount of IDRX to deposit.
     * @return shares Shares received from the protocol.
     */
    function deposit(uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw funds from the external protocol.
     * @param shares Amount of shares to withdraw.
     * @return amount Amount of IDRX received.
     */
    function withdraw(uint256 shares) external returns (uint256 amount);

    /**
     * @notice Get current balance in the external protocol.
     * @return balance Current balance in IDRX terms.
     */
    function getBalance() external view returns (uint256 balance);

    /**
     * @notice Get pending rewards from the external protocol.
     * @return rewards Pending rewards in IDRX terms.
     */
    function getPendingRewards() external view returns (uint256 rewards);

    /**
     * @notice Harvest rewards from the external protocol.
     * @return harvested Amount of rewards harvested in IDRX terms.
     */
    function harvest() external returns (uint256 harvested);

    /**
     * @notice Get the external protocol name.
     * @return protocolName Name of the external protocol.
     */
    function getProtocolName() external view returns (string memory protocolName);

    /**
     * @notice Get the external protocol address.
     * @return protocolAddress Address of the external protocol.
     */
    function getProtocolAddress() external view returns (address protocolAddress);

    /**
     * @notice Check if the adapter is active.
     * @return isActive True if adapter is active.
     */
    function isActive() external view returns (bool isActive);

    /**
     * @notice Convert assets to shares using protocol's exchange rate.
     * @param assets Amount of assets to convert.
     * @return shares Amount of shares.
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Get the pilot strategy name.
     * @return strategy The pilot strategy name.
     */
    function getPilotStrategy() external view returns (string memory strategy);

    /**
     * @notice Get total assets held by the adapter in the protocol.
     * @return Total asset amount.
     */
    function getTotalAssets() external view returns (uint256);

    /**
     * @notice Withdraw base token to a receiver address.
     * @param to Address to receive withdrawn tokens.
     * @param amount Amount to withdraw.
     * @return Amount withdrawn.
     */
    function withdrawTo(address to, uint256 amount) external returns (uint256);
}
