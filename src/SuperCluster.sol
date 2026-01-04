// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SToken} from "./tokens/SToken.sol";
import {IPilot} from "./interfaces/IPilot.sol";
import {WsToken} from "./tokens/WsToken.sol";
import {Withdraw} from "./tokens/WithDraw.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SuperCluster
 * @dev Main protocol contract for managing deposits, withdrawals, yield, and pilot strategies.
 *      - Supports rebasing sToken and wrapped wsToken.
 *      - Integrates with pilots (strategies) and WithdrawManager for queued withdrawals.
 *      - Handles yield via rebase and distributes it proportionally.
 *      - Uses SafeERC20 for all token transfers.
 * @author SuperCluster Dev Team
 */
contract SuperCluster is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Rebasing token representing user deposits and yield
    SToken public sToken;

    /// @notice Mapping of supported base tokens
    mapping(address => bool) public supportedTokens;

    /// @notice Wrapped sToken (non-rebasing, ERC20-compatible)
    WsToken public wsToken;

    /// @notice Withdraw queue manager contract
    Withdraw public withdrawManager;

    /// @notice List of all registered pilots
    mapping(address => bool) public registeredPilots;
    address[] public pilots;

    /// @notice Emitted when a pilot is registered
    event PilotRegistered(address indexed pilot);

    /// @notice Emitted when a user deposits tokens
    event TokenDeposited(address indexed token, address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws tokens
    event TokenWithdrawn(
        address indexed pilot, address indexed token, address indexed user, uint256 amount, uint256 requestId
    );

    /// @notice Emitted when a pilot is selected for a deposit
    event PilotSelected(address indexed pilot, address indexed token, uint256 amount);

    // --- Errors ---

    error PilotNotRegistered();
    error InsufficientBalance();
    error TokenNotSupported();
    error AmountMustBeGreaterThanZero();

    /**
     * @dev Deploys sToken, wsToken, and WithdrawManager contracts.
     * @param underlyingToken_ The address of the base ERC20 token.
     */
    constructor(address underlyingToken_) Ownable(msg.sender) {
        IERC20Metadata tokenMetadata = IERC20Metadata(underlyingToken_);
        string memory tokenName = tokenMetadata.name();
        string memory tokenSymbol = tokenMetadata.symbol();

        sToken = new SToken(
            string(abi.encodePacked("s", tokenName)), string(abi.encodePacked("s", tokenSymbol)), underlyingToken_
        );

        wsToken = new WsToken(
            string(abi.encodePacked("ws", tokenName)), string(abi.encodePacked("ws", tokenSymbol)), address(sToken)
        );

        withdrawManager = new Withdraw(address(sToken), underlyingToken_, address(this), 0);

        sToken.setAuthorizedMinter(address(this), true);
        wsToken.setAuthorizedMinter(address(this), true);

        supportedTokens[underlyingToken_] = true;
    }

    /**
     * @notice Triggers a rebase on sToken based on current AUM (yield accrued).
     * @dev Only callable by owner.
     */
    function rebase() external onlyOwner {
        uint256 newAUM = calculateTotalAUM();
        uint256 supplyBefore = sToken.totalSupply();
        require(newAUM > supplyBefore, "No yield accrued");
        uint256 yieldAmount = newAUM - supplyBefore;
        sToken.rebase(yieldAmount);
    }

    /**
     * @notice Calculates total assets under management (AUM) across all pilots.
     * @return totalAUM The total AUM value.
     */
    function calculateTotalAUM() public view returns (uint256) {
        uint256 totalAUM = 0;

        totalAUM += sToken.baseToken().balanceOf(address(this));

        for (uint256 i = 0; i < pilots.length; i++) {
            totalAUM += IPilot(pilots[i]).getTotalValue();
        }

        return totalAUM;
    }

    /**
     * @notice Deposit base tokens, mint sToken, and invest via pilot.
     * @param pilot The pilot strategy address.
     * @param token The base token address.
     * @param amount The amount to deposit.
     * @dev Only supports registered pilots and supported tokens.
     */
    function deposit(address pilot, address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (!registeredPilots[pilot]) revert PilotNotRegistered();
        if (!supportedTokens[token]) revert TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        sToken.mint(msg.sender, amount);

        IERC20(token).approve(pilot, amount);

        IPilot(pilot).receiveAndInvest(amount);

        emit TokenDeposited(token, msg.sender, amount);
        emit PilotSelected(pilot, token, amount);
    }

    /**
     * @notice Request withdrawal of base tokens by burning sToken and initiating withdrawal flow.
     * @dev Checks user balance and token/pilot validity, Burns user's sToken, Instructs the pilot to transfer base tokens to the WithdrawManager, Creates a withdrawal request in WithdrawManager for the user, Immediately finalizes the withdrawal request (no delay).
     * @param pilot The address of the pilot strategy to withdraw from.
     * @param token The base token address to withdraw.
     * @param amount The amount of sToken to burn and withdraw (in base token units).
     */
    function withdraw(address pilot, address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (!registeredPilots[pilot]) revert PilotNotRegistered();
        if (sToken.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        sToken.burn(msg.sender, amount);

        IPilot(pilot).withdrawToManager(address(withdrawManager), amount);
        uint256 requestId = withdrawManager.autoRequest(msg.sender, amount);
        withdrawManager.finalizeWithdraw(requestId, amount);

        emit TokenWithdrawn(pilot, token, msg.sender, amount, requestId);
    }

    /**
     * @notice Finalize a withdrawal request after funding WithdrawManager.
     * @param requestId The withdrawal request ID.
     * @param baseAmount The amount to finalize.
     * @dev Only callable by owner.
     */
    function finalizeWithdraw(uint256 requestId, uint256 baseAmount) external onlyOwner nonReentrant {
        uint256 managerBalance = withdrawManager.contractBaseBalance();
        require(managerBalance >= baseAmount, "WithdrawManager: insufficient base balance");

        withdrawManager.finalizeWithdraw(requestId, baseAmount);
    }

    /**
     * @notice Inform WithdrawManager that a withdrawal is ready.
     * @param requestId The withdrawal request ID.
     * @return id The request ID.
     * @return user The user address.
     * @return baseAmount The base token amount.
     * @return finalized Whether finalized.
     * @return claimed Whether claimed.
     * @return availableAt Timestamp when available.
     */
    function informWithdraw(uint256 requestId)
        external
        nonReentrant
        returns (uint256 id, address user, uint256 baseAmount, bool finalized, bool claimed, uint256 availableAt)
    {
        withdrawManager.informWithdraw(requestId);

        (address user_,, uint256 baseAmount_, bool finalized_, bool claimed_, uint256 availableAt_) =
            withdrawManager.getWithdrawInfo(requestId);

        return (requestId, user_, baseAmount_, finalized_, claimed_, availableAt_);
    }

    /**
     * @notice Get all registered pilot addresses.
     * @return Array of pilot addresses.
     */
    function getPilots() external view returns (address[] memory) {
        return pilots;
    }

    /**
     * @notice Register a new pilot strategy and mark its token as supported.
     * @param pilot The pilot address.
     * @param acceptedToken The base token accepted by the pilot.
     * @dev Only callable by owner.
     */
    function registerPilot(address pilot, address acceptedToken) external onlyOwner {
        require(!registeredPilots[pilot], "Pilot already registered");

        registeredPilots[pilot] = true;
        pilots.push(pilot);
        supportedTokens[acceptedToken] = true;

        emit PilotRegistered(pilot);
    }

    /**
     * @notice Set a new WithdrawManager contract address.
     * @param _manager The new WithdrawManager address.
     * @dev Only callable by owner.
     */
    function setWithdrawManager(address _manager) external onlyOwner {
        require(_manager != address(0), "Zero manager");
        withdrawManager = Withdraw(_manager);
    }

    /**
     * @notice Receive base tokens and invest via pilot (called by pilots).
     * @param pilot The pilot address.
     * @param token The base token address.
     * @param amount The amount to receive and invest.
     * @dev Only callable by owner (pilots).
     */
    function receiveAndInvest(address pilot, address token, uint256 amount) external onlyOwner {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (!registeredPilots[pilot]) revert PilotNotRegistered();
        if (IERC20(token).balanceOf(msg.sender) < amount) revert InsufficientBalance();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(pilot, amount);
        IPilot(pilot).receiveAndInvest(amount);
    }
}
