// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAdapter} from "../interfaces/IAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Adapter
 * @notice Abstract base adapter for protocol integrations in SuperCluster.
 *         - Handles deposits, withdrawals, and protocol queries.
 *         - Tracks protocol name, address, strategy, and deposited amounts.
 *         - Can be activated/deactivated by owner.
 *         - Child contracts implement protocol-specific logic.
 * @author SuperCluster Dev Team
 */
abstract contract Adapter is IAdapter, Ownable, ReentrancyGuard {
    /// @notice Base token managed by this adapter (e.g. IDRX, USDC)
    address public immutable TOKEN;

    /// @notice Address of the integrated protocol (e.g. Aave, Morpho)
    address public immutable PROTOCOL_ADDRESS;

    /// @notice Name of the protocol (e.g. "Aave")
    string public protocolName;

    /// @notice Strategy name for pilot integration
    string public pilotStrategy;

    /// @notice Whether the adapter is active
    bool public isActive;

    /// @notice Total deposited amount tracked by this adapter
    uint256 public totalDeposited;

    // --- Events ---

    /// @notice Emitted when adapter is activated
    event AdapterActivated();

    /// @notice Emitted when adapter is deactivated
    event AdapterDeactivated();

    /// @notice Emitted when deposit occurs
    event Deposited(uint256 amount);

    /// @notice Emitted when withdrawal occurs
    event Withdrawn(uint256 amount);

    // --- Errors ---

    error AdapterNotActive();
    error InvalidAmount();
    error InsufficientBalance();

    /**
     * @dev Modifier to restrict actions to active adapters only.
     */
    modifier onlyActive() {
        _onlyActive();
        _;
    }

    /**
     * @dev Deploys Adapter contract.
     * @param _token Base token address.
     * @param _protocolAddress Integrated protocol address.
     * @param _protocolName Name of the protocol.
     * @param _protocolStrategy Strategy name for pilot.
     */
    constructor(address _token, address _protocolAddress, string memory _protocolName, string memory _protocolStrategy)
        Ownable(msg.sender)
    {
        TOKEN = _token;
        PROTOCOL_ADDRESS = _protocolAddress;
        protocolName = _protocolName;
        pilotStrategy = _protocolStrategy;
        isActive = true;
    }

    /**
     * @dev Internal check for active status.
     */
    function _onlyActive() internal view {
        if (!isActive) revert AdapterNotActive();
    }

    /**
     * @notice Get balance from protocol (must be implemented by child contracts).
     * @return Protocol balance in base token.
     */
    function getBalance() external view virtual override returns (uint256);

    /**
     * @dev Update internal tracking of total deposited.
     * @param amount Amount to update.
     * @param isDeposit True if deposit, false if withdrawal.
     */
    function _updateTotalDeposited(uint256 amount, bool isDeposit) internal {
        if (isDeposit) {
            totalDeposited += amount;
        } else {
            totalDeposited = totalDeposited >= amount ? totalDeposited - amount : 0;
        }
    }

    /**
     * @notice Get protocol name.
     * @return Protocol name string.
     */
    function getProtocolName() external view override returns (string memory) {
        return protocolName;
    }

    /**
     * @notice Get protocol address.
     * @return Protocol address.
     */
    function getProtocolAddress() external view override returns (address) {
        return PROTOCOL_ADDRESS;
    }

    /**
     * @notice Get pilot strategy name.
     * @return Strategy name string.
     */
    function getPilotStrategy() external view override returns (string memory) {
        return pilotStrategy;
    }

    /**
     * @notice Activate the adapter (owner only).
     */
    function activate() external onlyOwner {
        isActive = true;
        emit AdapterActivated();
    }

    /**
     * @notice Deactivate the adapter (owner only).
     */
    function deactivate() external onlyOwner {
        isActive = false;
        emit AdapterDeactivated();
    }

    /**
     * @notice Withdraw base token to receiver.
     * @param receiver Address to receive withdrawn tokens.
     * @param amount Amount to withdraw.
     * @return Amount withdrawn.
     */
    function withdrawTo(address receiver, uint256 amount) external virtual returns (uint256) {
        require(receiver != address(0), "Invalid receiver");
        require(amount > 0, "Invalid amount");

        bool status = IERC20(TOKEN).transfer(receiver, amount);
        require(status, "Transfer failed");

        return amount;
    }
}
