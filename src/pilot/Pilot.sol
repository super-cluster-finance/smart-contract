// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPilot} from "../interfaces/IPilot.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";

/**
 * @title Pilot
 * @notice Strategy manager for SuperCluster protocol.
 *         - Manages allocation of base tokens to adapters (DeFi protocols).
 *         - Supports invest, divest, harvest, and emergency withdraw flows.
 *         - Integrates with SuperCluster for auto-invest and withdrawals.
 *         - Tracks strategy adapters and allocations.
 * @author SuperCluster Dev Team
 */
contract Pilot is IPilot, Ownable, ReentrancyGuard {
    /// @notice Name of the pilot strategy
    string public override name;

    /// @notice Description of the pilot strategy
    string public _description;

    /// @notice Base token managed by this pilot (e.g. IDRX)
    address public immutable TOKEN;

    /// @notice SuperCluster protocol address
    address public superClusterAddress;

    /// @notice List of strategy adapters (DeFi protocols)
    address[] public strategyAdapters;

    /// @notice List of allocations for each adapter (basis points, sum to 10000)
    uint256[] public strategyAllocations;

    /// @notice Mapping to track active adapters
    mapping(address => bool) public isActiveAdapter;

    // --- Events ---

    /// @notice Emitted when strategy is updated
    event StrategyUpdated(address[] adapters, uint256[] allocations);

    /// @notice Emitted when funds are invested
    event Invested(uint256 amount, address[] adapters, uint256[] allocations);

    /// @notice Emitted when funds are divested
    event Divested(uint256 amount, address[] adapters, uint256[] allocations);

    /// @notice Emitted when rewards are harvested
    event Harvested(address[] adapters, uint256 totalHarvested);

    // --- Errors ---

    error InvalidAllocation();
    error AdapterNotActive();
    error InvalidArrayLength();
    error InsufficientBalance();
    error ZeroAmount();

    /**
     * @dev Deploys Pilot contract.
     * @param _name Name of pilot.
     * @param __description Description of pilot.
     * @param _token Base token address.
     * @param _superClusterAddress SuperCluster protocol address.
     */
    constructor(string memory _name, string memory __description, address _token, address _superClusterAddress)
        Ownable(msg.sender)
    {
        name = _name;
        _description = __description;
        TOKEN = _token;
        superClusterAddress = address(_superClusterAddress);
    }

    /**
     * @notice Invest funds according to pilot's strategy.
     * @param amount Amount of base token to invest.
     * @param adapters List of adapter addresses.
     * @param allocations List of allocations (basis points, sum to 10000).
     * @dev Only owner can call. Funds are distributed to adapters.
     */
    function invest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations)
        external
        override
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (adapters.length != allocations.length) revert InvalidArrayLength();

        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocation += allocations[i];
            if (!isActiveAdapter[adapters[i]]) revert AdapterNotActive();
        }
        if (totalAllocation != 10000) revert InvalidAllocation();

        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        for (uint256 i = 0; i < adapters.length; i++) {
            uint256 adapterAmount = (amount * allocations[i]) / 10000;
            if (adapterAmount > 0) {
                IERC20(TOKEN).approve(adapters[i], adapterAmount);
                IAdapter(adapters[i]).deposit(adapterAmount);
            }
        }

        emit Invested(amount, adapters, allocations);
    }

    /**
     * @notice Auto-invest funds from SuperCluster.
     * @param amount Amount of base token to invest.
     * @dev Only callable by SuperCluster.
     */
    function receiveAndInvest(uint256 amount) external override {
        require(msg.sender == superClusterAddress, "Only SuperCluster");

        bool status = IERC20(TOKEN).transferFrom(msg.sender, address(this), amount);
        require(status, "Transfer failed");

        IERC20(TOKEN).approve(address(this), amount);

        if (strategyAdapters.length > 0 && strategyAllocations.length > 0) {
            _distributeToAdapters(amount);
        }
    }

    /**
     * @dev Internal: Distribute funds to adapters based on allocation.
     * @param totalAmount Total amount to distribute.
     */
    function _distributeToAdapters(uint256 totalAmount) internal {
        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            address adapter = strategyAdapters[i];
            uint256 allocation = strategyAllocations[i];

            if (allocation > 0 && isActiveAdapter[adapter]) {
                uint256 adapterAmount = (totalAmount * allocation) / 10000;

                if (adapterAmount > 0) {
                    IERC20(TOKEN).approve(adapter, adapterAmount);

                    IAdapter(adapter).deposit(adapterAmount);
                }
            }
        }
    }

    /**
     * @notice Divest funds from external protocols.
     * @param amount Amount of base token to divest.
     * @param adapters List of adapter addresses.
     * @param allocations List of allocations (basis points, sum to 10000).
     * @dev Only owner can call. Withdraws funds from adapters.
     */
    function divest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations)
        external
        override
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (adapters.length != allocations.length) revert InvalidArrayLength();

        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocation += allocations[i];
            if (!isActiveAdapter[adapters[i]]) revert AdapterNotActive();
        }
        if (totalAllocation != 10000) revert InvalidAllocation();

        for (uint256 i = 0; i < adapters.length; i++) {
            uint256 adapterAmount = (amount * allocations[i]) / 10000;
            if (adapterAmount > 0) {
                uint256 shares = IAdapter(adapters[i]).convertToShares(adapterAmount);
                IAdapter(adapters[i]).withdraw(shares);
            }
        }

        emit Divested(amount, adapters, allocations);
    }

    /**
     * @notice Harvest rewards from external protocols.
     * @param adapters List of adapter addresses.
     * @dev Only owner can call. Harvests rewards from adapters.
     */
    function harvest(address[] calldata adapters) external override onlyOwner nonReentrant {
        uint256 totalHarvested = 0;

        for (uint256 i = 0; i < adapters.length; i++) {
            if (!isActiveAdapter[adapters[i]]) revert AdapterNotActive();

            uint256 harvested = IAdapter(adapters[i]).harvest();
            totalHarvested += harvested;
        }

        emit Harvested(adapters, totalHarvested);
    }

    /**
     * @notice Get current strategy allocation.
     * @return adapters List of adapter addresses.
     * @return allocations List of allocations (basis points).
     */
    function getStrategy() external view override returns (address[] memory adapters, uint256[] memory allocations) {
        return (strategyAdapters, strategyAllocations);
    }

    /**
     * @notice Get pilot's description.
     * @return Description string.
     */
    function description() external view override returns (string memory) {
        return _description;
    }

    /**
     * @notice Set pilot name.
     * @param _name New name.
     * @dev Only owner can call.
     */
    function setPilot(string memory _name) external onlyOwner {
        name = _name;
    }

    /**
     * @notice Set pilot description.
     * @param __description New description.
     * @dev Only owner can call.
     */
    function setDescription(string memory __description) external onlyOwner {
        _description = __description;
    }

    /**
     * @notice Set strategy allocation.
     * @param adapters List of adapter addresses.
     * @param allocations List of allocations (basis points, sum to 10000).
     * @dev Only owner can call.
     */
    function setPilotStrategy(address[] calldata adapters, uint256[] calldata allocations) external onlyOwner {
        if (adapters.length != allocations.length) revert InvalidArrayLength();

        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocation += allocations[i];
        }
        if (totalAllocation != 10000) revert InvalidAllocation();

        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            isActiveAdapter[strategyAdapters[i]] = false;
        }

        strategyAdapters = adapters;
        strategyAllocations = allocations;

        for (uint256 i = 0; i < adapters.length; i++) {
            isActiveAdapter[adapters[i]] = true;
        }

        emit StrategyUpdated(adapters, allocations);
    }

    /**
     * @notice Add adapter to active list.
     * @param adapter Adapter address.
     * @dev Only owner can call.
     */
    function addAdapter(address adapter) external onlyOwner {
        isActiveAdapter[adapter] = true;
    }

    /**
     * @notice Remove adapter from active list.
     * @param adapter Adapter address.
     * @dev Only owner can call.
     */
    function removeAdapter(address adapter) external onlyOwner {
        isActiveAdapter[adapter] = false;
    }

    /**
     * @notice Emergency withdraw all base tokens to owner.
     * @dev Only owner can call.
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = IERC20(TOKEN).balanceOf(address(this));
        if (balance > 0) {
            bool status = IERC20(TOKEN).transfer(owner(), balance);
            require(status, "Transfer failed");
        }
    }

    /**
     * @notice Withdraw for user (called by SuperCluster).
     * @param amount Amount to withdraw.
     * @dev Only callable by SuperCluster.
     */
    function withdrawForUser(uint256 amount) external override {
        require(msg.sender == superClusterAddress, "Only SuperCluster");

        _withdrawFromAdapters(amount);

        bool status = IERC20(TOKEN).transfer(superClusterAddress, amount);
        require(status, "Transfer failed");
    }

    /**
     * @dev Internal: Withdraw from adapters proportionally.
     * @param totalAmount Total amount to withdraw.
     */
    function _withdrawFromAdapters(uint256 totalAmount) internal {
        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            address adapter = strategyAdapters[i];
            uint256 allocation = strategyAllocations[i];

            if (allocation > 0 && isActiveAdapter[adapter]) {
                uint256 adapterWithdrawAmount = (totalAmount * allocation) / 10000;

                if (adapterWithdrawAmount > 0) {
                    uint256 sharesToWithdraw = IAdapter(adapter).convertToShares(adapterWithdrawAmount);

                    if (sharesToWithdraw > 0) {
                        IAdapter(adapter).withdraw(sharesToWithdraw);
                    }
                }
            }
        }
    }

    /**
     * @notice Get total value from all adapters plus idle funds.
     * @return total Total value in base token.
     */
    function getTotalValue() external view override returns (uint256 total) {
        uint256 totalValue = IERC20(TOKEN).balanceOf(address(this)); // Idle funds

        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            if (isActiveAdapter[strategyAdapters[i]]) {
                totalValue += IAdapter(strategyAdapters[i]).getBalance();
            }
        }

        return totalValue;
    }

    /**
     * @notice Get total pilot holdings (idle + adapters).
     * @return total Total holdings in base token.
     */
    function getTotalPilotHoldings() public view returns (uint256 total) {
        total = IERC20(TOKEN).balanceOf(address(this));
        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            address adapter = strategyAdapters[i];
            if (!isActiveAdapter[adapter]) continue;
            total += IAdapter(adapter).getTotalAssets();
        }
    }

    /**
     * @notice Withdraw to WithdrawManager contract (for queued withdrawals).
     * @param withdrawManager WithdrawManager contract address.
     * @param totalAmount Total amount to withdraw.
     * @dev Only callable by SuperCluster.
     */
    function withdrawToManager(address withdrawManager, uint256 totalAmount) external {
        require(msg.sender == superClusterAddress, "Only SuperCluster");
        require(totalAmount > 0, "Invalid amount");
        require(strategyAdapters.length > 0, "No adapter set");

        uint256 remainingAmount = totalAmount;
        uint256 totalHoldings = getTotalPilotHoldings();
        require(totalHoldings > 0, "Zero holdings");

        for (uint256 i = 0; i < strategyAdapters.length; i++) {
            address adapter = strategyAdapters[i];
            if (!isActiveAdapter[adapter]) continue;

            uint256 adapterBalance = IAdapter(adapter).getTotalAssets();
            if (adapterBalance == 0) continue;

            uint256 adapterAmount = (adapterBalance * totalAmount) / totalHoldings;

            if (adapterAmount > adapterBalance) {
                adapterAmount = adapterBalance;
            }

            if (adapterAmount > remainingAmount) {
                adapterAmount = remainingAmount;
            }

            IAdapter(adapter).withdrawTo(withdrawManager, adapterAmount);

            remainingAmount -= adapterAmount;
            if (remainingAmount == 0) break;
        }
    }
}
