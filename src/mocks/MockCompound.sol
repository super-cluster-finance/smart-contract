// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICompoundOracle {
    function getPrice() external view returns (uint256);
}

/**
 * @title Comet (Compound V3 Style)
 * @notice Mock lending pool following Compound V3 (Comet) interface.
 *         - Users supply assets directly (no cTokens).
 *         - Users withdraw assets directly.
 *         - Simpler interface compared to Compound V2.
 * @author SuperCluster Dev Team
 */
contract Comet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // ===== ERRORS ===============================
    // ============================================

    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error LTVExceedMaxAmount();
    error InvalidOracle();
    error Paused();

    // ============================================
    // ===== STATE VARIABLES ======================
    // ============================================

    /// @notice Total principal supplied
    uint256 public totalSupply;
    /// @notice Total principal borrowed
    uint256 public totalBorrow;
    /// @notice Base asset token
    address public baseToken;
    /// @notice Collateral token
    address public collateralToken;
    /// @notice Price oracle
    address public oracle;
    /// @notice Loan-to-value ratio
    uint256 public ltv;
    /// @notice Supply rate per second (scaled by 1e18)
    uint256 public supplyRate = 0; // Disabled for testing
    /// @notice Borrow rate per second (scaled by 1e18)
    uint256 public borrowRate = 0; // Disabled for testing
    /// @notice Last accrual timestamp
    uint256 public lastAccrualTime;
    /// @notice Base index for supply (scaled by 1e18)
    uint256 public baseSupplyIndex = 1e18;
    /// @notice Base index for borrow (scaled by 1e18)
    uint256 public baseBorrowIndex = 1e18;
    /// @notice Protocol paused state
    bool public isPaused;

    // ============================================
    // ===== EVENTS ===============================
    // ============================================

    /// @notice Emitted when user supplies base asset
    event Supply(address indexed from, address indexed dst, uint256 amount);
    /// @notice Emitted when user withdraws base asset
    event Withdraw(address indexed src, address indexed to, uint256 amount);
    /// @notice Emitted when user supplies collateral
    event SupplyCollateral(address indexed from, address indexed dst, address indexed asset, uint256 amount);
    /// @notice Emitted when user withdraws collateral
    event WithdrawCollateral(address indexed src, address indexed to, address indexed asset, uint256 amount);
    /// @notice Emitted when user borrows
    event Borrow(address indexed src, uint256 amount);
    /// @notice Emitted when user repays
    event Repay(address indexed src, uint256 amount);

    // ============================================
    // ===== USER MAPPINGS ========================
    // ============================================

    /// @notice User's principal supply balance
    mapping(address => uint256) public userBasic;
    /// @notice User's principal borrow balance
    mapping(address => uint256) public userBorrow;
    /// @notice User's collateral balance per asset
    mapping(address => mapping(address => uint256)) public userCollateral;

    // ============================================
    // ===== CONSTRUCTOR ==========================
    // ============================================

    /**
     * @notice Initialize the Comet contract
     * @param _collateralToken Collateral token address
     * @param _baseToken Base asset token address
     * @param _oracle Price oracle address
     * @param _ltv Loan-to-value ratio
     */
    constructor(address _collateralToken, address _baseToken, address _oracle, uint256 _ltv) {
        collateralToken = _collateralToken;
        baseToken = _baseToken;
        oracle = _oracle;
        if (oracle == address(0)) revert InvalidOracle();
        if (_ltv > 1e18) revert LTVExceedMaxAmount();
        ltv = _ltv;
        lastAccrualTime = block.timestamp;
    }

    // ============================================
    // ===== MODIFIERS ============================
    // ============================================

    modifier whenNotPaused() {
        if (isPaused) revert Paused();
        _;
    }

    // ============================================
    // ===== SUPPLY FUNCTIONS =====================
    // ============================================

    /**
     * @notice Supply base asset to the protocol
     * @param asset The asset to supply (must be baseToken)
     * @param amount Amount to supply
     */
    function supply(address asset, uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();
        require(asset == baseToken, "Invalid asset");

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount);

        // Convert to principal
        uint256 principal = (amount * 1e18) / baseSupplyIndex;

        userBasic[msg.sender] += principal;
        totalSupply += principal;

        emit Supply(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Supply base asset on behalf of another address
     * @param dst Destination address
     * @param asset The asset to supply
     * @param amount Amount to supply
     */
    function supplyTo(address dst, address asset, uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();
        require(asset == baseToken, "Invalid asset");

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 principal = (amount * 1e18) / baseSupplyIndex;

        userBasic[dst] += principal;
        totalSupply += principal;

        emit Supply(msg.sender, dst, amount);
    }

    // ============================================
    // ===== WITHDRAW FUNCTIONS ===================
    // ============================================

    /**
     * @notice Withdraw base asset from the protocol
     * @param asset The asset to withdraw (must be baseToken)
     * @param amount Amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();
        require(asset == baseToken, "Invalid asset");

        // Convert to principal
        uint256 principal = (amount * 1e18) / baseSupplyIndex;

        if (principal > userBasic[msg.sender]) revert InsufficientBalance();

        userBasic[msg.sender] -= principal;
        totalSupply -= principal;

        IERC20(baseToken).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Withdraw base asset to another address
     * @param to Destination address
     * @param asset The asset to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawTo(address to, address asset, uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();
        require(asset == baseToken, "Invalid asset");

        uint256 principal = (amount * 1e18) / baseSupplyIndex;

        if (principal > userBasic[msg.sender]) revert InsufficientBalance();

        userBasic[msg.sender] -= principal;
        totalSupply -= principal;

        IERC20(baseToken).safeTransfer(to, amount);

        emit Withdraw(msg.sender, to, amount);
    }

    // ============================================
    // ===== COLLATERAL FUNCTIONS =================
    // ============================================

    /**
     * @notice Supply collateral to the protocol
     * @param asset Collateral asset address
     * @param amount Amount to supply
     */
    function supplyCollateral(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        userCollateral[msg.sender][asset] += amount;

        emit SupplyCollateral(msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw collateral from the protocol
     * @param asset Collateral asset address
     * @param amount Amount to withdraw
     */
    function withdrawCollateral(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > userCollateral[msg.sender][asset]) revert InsufficientCollateral();

        userCollateral[msg.sender][asset] -= amount;

        // Check if position is still healthy after withdrawal
        _checkHealth(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, msg.sender, asset, amount);
    }

    // ============================================
    // ===== BORROW/REPAY FUNCTIONS ===============
    // ============================================

    /**
     * @notice Borrow base asset
     * @param amount Amount to borrow
     */
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();

        uint256 available = IERC20(baseToken).balanceOf(address(this));
        if (amount > available) revert InsufficientLiquidity();

        uint256 principal = (amount * 1e18) / baseBorrowIndex;

        userBorrow[msg.sender] += principal;
        totalBorrow += principal;

        _checkHealth(msg.sender);

        IERC20(baseToken).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    /**
     * @notice Repay borrowed amount
     * @param amount Amount to repay
     */
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        _accrueInterest();

        if (amount == 0) revert ZeroAmount();

        uint256 principal = (amount * 1e18) / baseBorrowIndex;

        if (principal > userBorrow[msg.sender]) {
            principal = userBorrow[msg.sender];
            amount = (principal * baseBorrowIndex) / 1e18;
        }

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount);

        userBorrow[msg.sender] -= principal;
        totalBorrow -= principal;

        emit Repay(msg.sender, amount);
    }

    // ============================================
    // ===== INTEREST FUNCTIONS ===================
    // ============================================

    /**
     * @notice Accrue interest (external)
     */
    function accrueInterest() external nonReentrant {
        _accrueInterest();
    }

    /**
     * @notice Internal interest accrual
     */
    function _accrueInterest() internal {
        uint256 timeElapsed = block.timestamp - lastAccrualTime;
        if (timeElapsed == 0) return;

        // Update supply index
        uint256 supplyInterest = (baseSupplyIndex * supplyRate * timeElapsed) / 1e18;
        baseSupplyIndex += supplyInterest;

        // Update borrow index
        uint256 borrowInterest = (baseBorrowIndex * borrowRate * timeElapsed) / 1e18;
        baseBorrowIndex += borrowInterest;

        lastAccrualTime = block.timestamp;
    }

    /**
     * @notice Check if user position is healthy
     */
    function _checkHealth(address user) internal view {
        uint256 collateralPrice = ICompoundOracle(oracle).getPrice();
        uint256 collateralDecimals = 10 ** IERC20Metadata(collateralToken).decimals();

        uint256 borrowed = (userBorrow[user] * baseBorrowIndex) / 1e18;
        uint256 collateralValue = (userCollateral[user][collateralToken] * collateralPrice) / collateralDecimals;
        uint256 maxBorrow = (collateralValue * ltv) / 1e18;

        if (borrowed > maxBorrow) revert InsufficientCollateral();
    }

    // ============================================
    // ===== VIEW FUNCTIONS =======================
    // ============================================

    /**
     * @notice Get user's supply balance (with accrued interest)
     */
    function balanceOf(address account) external view returns (uint256) {
        return (userBasic[account] * baseSupplyIndex) / 1e18;
    }

    /**
     * @notice Get user's borrow balance (with accrued interest)
     */
    function borrowBalanceOf(address account) external view returns (uint256) {
        return (userBorrow[account] * baseBorrowIndex) / 1e18;
    }

    /**
     * @notice Get user's collateral balance for an asset
     */
    function collateralBalanceOf(address account, address asset) external view returns (uint256) {
        return userCollateral[account][asset];
    }

    /**
     * @notice Get total supply with interest
     */
    function totalSupplyBase() external view returns (uint256) {
        return (totalSupply * baseSupplyIndex) / 1e18;
    }

    /**
     * @notice Get total borrow with interest
     */
    function totalBorrowBase() external view returns (uint256) {
        return (totalBorrow * baseBorrowIndex) / 1e18;
    }

    /**
     * @notice Get base token address
     */
    function baseTokenAddress() external view returns (address) {
        return baseToken;
    }

    /**
     * @notice Get available liquidity
     */
    function getAvailableLiquidity() external view returns (uint256) {
        return IERC20(baseToken).balanceOf(address(this));
    }

    /**
     * @notice Get utilization rate (scaled by 1e18)
     */
    function getUtilization() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (totalBorrow * 1e18) / totalSupply;
    }

    /**
     * @notice Get supply APR (scaled by 1e18)
     */
    function getSupplyRate() external view returns (uint256) {
        return supplyRate * 365 days;
    }

    /**
     * @notice Get borrow APR (scaled by 1e18)
     */
    function getBorrowRate() external view returns (uint256) {
        return borrowRate * 365 days;
    }

    // ============================================
    // ===== ADMIN FUNCTIONS ======================
    // ============================================

    /**
     * @notice Pause the protocol
     */
    function pause() external {
        isPaused = true;
    }

    /**
     * @notice Unpause the protocol
     */
    function unpause() external {
        isPaused = false;
    }
}
