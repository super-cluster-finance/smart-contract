// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IPilot
 * @notice Interface for pilot strategy contracts in SuperCluster.
 *         - Defines standard functions for investing, divesting, harvesting, and managing adapters.
 *         - Used by SuperCluster to interact with pilot strategies and manage user funds.
 * @author SuperCluster Dev Team
 */
interface IPilot {
    /**
     * @notice Invest funds according to pilot's strategy.
     * @param amount Amount of IDRX to invest.
     * @param adapters Array of adapter addresses to use.
     * @param allocations Array of allocation percentages (must sum to 10000 = 100%).
     */
    function invest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations) external;

    /**
     * @notice Divest funds from external protocols.
     * @param amount Amount of IDRX to divest.
     * @param adapters Array of adapter addresses to divest from.
     * @param allocations Array of divestment percentages.
     */
    function divest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations) external;

    /**
     * @notice Harvest rewards from external protocols.
     * @param adapters Array of adapter addresses to harvest from.
     */
    function harvest(address[] calldata adapters) external;

    /**
     * @notice Get current strategy allocation.
     * @return adapters Array of adapter addresses.
     * @return allocations Array of current allocation percentages.
     */
    function getStrategy() external view returns (address[] memory adapters, uint256[] memory allocations);

    /**
     * @notice Get total value managed by this pilot (including idle IDRX + adapter balances).
     * @return Total value in IDRX terms.
     */
    function getTotalValue() external view returns (uint256);

    /**
     * @notice Get pilot's name.
     * @return Name string.
     */
    function name() external view returns (string memory);

    /**
     * @notice Get pilot's description.
     * @return Description string.
     */
    function description() external view returns (string memory);

    /**
     * @notice Set pilot's name (owner only).
     * @param _name New pilot name.
     */
    function setPilot(string memory _name) external;

    /**
     * @notice Set pilot's description (owner only).
     * @param _description New pilot description.
     */
    function setDescription(string memory _description) external;

    /**
     * @notice Set strategy allocation (owner only).
     * @param adapters Array of adapter addresses.
     * @param allocations Array of allocation percentages (must sum to 10000).
     */
    function setPilotStrategy(address[] calldata adapters, uint256[] calldata allocations) external;

    /**
     * @notice Add adapter to active list (owner only).
     * @param adapter Adapter address to add.
     */
    function addAdapter(address adapter) external;

    /**
     * @notice Remove adapter from active list (owner only).
     * @param adapter Adapter address to remove.
     */
    function removeAdapter(address adapter) external;

    /**
     * @notice Emergency withdraw all IDRX tokens (owner only).
     */
    function emergencyWithdraw() external;

    /**
     * @notice Check if adapter is active.
     * @param adapter Adapter address to check.
     * @return True if adapter is active.
     */
    function isActiveAdapter(address adapter) external view returns (bool);

    /**
     * @notice Receive funds from SuperCluster and auto-invest.
     * @param amount Amount of IDRX received from SuperCluster.
     */
    function receiveAndInvest(uint256 amount) external;

    /**
     * @notice Withdraw funds for user withdrawal from SuperCluster.
     * @param amount Amount to withdraw for user.
     */
    function withdrawForUser(uint256 amount) external;

    /**
     * @notice Withdraw funds to WithdrawManager contract (for queued withdrawals).
     * @param withdrawManager WithdrawManager contract address.
     * @param amount Amount to withdraw.
     */
    function withdrawToManager(address withdrawManager, uint256 amount) external;
}
