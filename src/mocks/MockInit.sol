// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IInitOracle {
    function getPrice() external view returns (uint256);
}

/**
 * @title InitLendingPool (Init Capital Style)
 * @notice Mock lending pool following Init Capital interface.
 *         - Users supply assets and receive shares.
 *         - Users withdraw by burning shares.
 *         - Simple supply/withdraw interface without cToken complexity.
 * @author SuperCluster Dev Team
 */
contract InitLendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // ===== ERRORS ===============================
    // ============================================

    error ZeroAmount();
    error InsufficientShares();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error LTVExceedMaxAmount();
    error InvalidOracle();

    // ============================================
    // ===== STATE VARIABLES ======================
    // ============================================

    /// @notice Total shares issued to suppliers
    uint256 public totalSupplyShares;
    /// @notice Total assets supplied
    uint256 public totalSupplyAssets;
    /// @notice Total shares for borrowers
    uint256 public totalBorrowShares;
    /// @notice Total assets borrowed
    uint256 public totalBorrowAssets;
    /// @notice Last interest accrual timestamp
    uint256 public lastAccrued = block.timestamp;
    /// @notice Annual borrow rate (10% = 1e17)
    uint256 public borrowRate = 1e17;
    /// @notice Loan-to-value ratio (e.g., 80% = 8e17)
    uint256 public ltv;
    /// @notice Underlying asset token
    address public asset;
    /// @notice Collateral token
    address public collateralToken;
    /// @notice Price oracle
    address public oracle;

    // ============================================
    // ===== EVENTS ===============================
    // ============================================

    /// @notice Emitted when user supplies assets
    event Supply(address indexed user, uint256 amount, uint256 shares);
    /// @notice Emitted when user withdraws assets
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    /// @notice Emitted when user deposits collateral
    event DepositCollateral(address indexed user, uint256 amount);
    /// @notice Emitted when user withdraws collateral
    event WithdrawCollateral(address indexed user, uint256 amount);
    /// @notice Emitted when user borrows
    event Borrow(address indexed user, uint256 amount, uint256 shares);
    /// @notice Emitted when user repays
    event Repay(address indexed user, uint256 amount, uint256 shares);

    // ============================================
    // ===== USER MAPPINGS ========================
    // ============================================

    /// @notice User's supply shares
    mapping(address => uint256) public userSupplyShares;
    /// @notice User's borrow shares
    mapping(address => uint256) public userBorrowShares;
    /// @notice User's collateral balance
    mapping(address => uint256) public userCollaterals;

    // ============================================
    // ===== CONSTRUCTOR ==========================
    // ============================================

    /**
     * @notice Initialize the lending pool
     * @param _collateralToken Collateral token address
     * @param _asset Underlying asset token address
     * @param _oracle Price oracle address
     * @param _ltv Loan-to-value ratio (scaled by 1e18)
     */
    constructor(address _collateralToken, address _asset, address _oracle, uint256 _ltv) {
        collateralToken = _collateralToken;
        asset = _asset;
        oracle = _oracle;
        if (oracle == address(0)) revert InvalidOracle();
        if (_ltv > 1e18) revert LTVExceedMaxAmount();
        ltv = _ltv;
    }

    // ============================================
    // ===== SUPPLY FUNCTIONS =====================
    // ============================================

    /**
     * @notice Supply assets to the lending pool
     * @param amount Amount of assets to supply
     * @return shares Amount of shares received
     */
    function supply(uint256 amount) external nonReentrant returns (uint256 shares) {
        _accrueInterest();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        if (totalSupplyShares == 0) {
            shares = amount;
        } else {
            require(totalSupplyAssets > 0, "totalSupplyAssets is zero");
            shares = (amount * totalSupplyShares) / totalSupplyAssets;
        }

        userSupplyShares[msg.sender] += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += amount;

        emit Supply(msg.sender, amount, shares);
        return shares;
    }

    /**
     * @notice Withdraw assets from the lending pool by shares
     * @param shares Amount of shares to burn
     * @return amount Amount of assets received
     */
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (shares > userSupplyShares[msg.sender]) revert InsufficientShares();

        _accrueInterest();

        amount = (shares * totalSupplyAssets) / totalSupplyShares;

        userSupplyShares[msg.sender] -= shares;
        totalSupplyAssets -= amount;
        totalSupplyShares -= shares;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
        return amount;
    }

    /**
     * @notice Withdraw specific amount of assets
     * @param amount Amount of assets to withdraw
     * @return withdrawnAmount Actual amount withdrawn
     */
    function withdrawAssets(uint256 amount) external nonReentrant returns (uint256 withdrawnAmount) {
        if (amount == 0) revert ZeroAmount();

        _accrueInterest();

        // Calculate shares needed
        uint256 shares = (amount * totalSupplyShares) / totalSupplyAssets;

        if (shares > userSupplyShares[msg.sender]) revert InsufficientShares();

        userSupplyShares[msg.sender] -= shares;
        totalSupplyAssets -= amount;
        totalSupplyShares -= shares;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
        return amount;
    }

    /**
     * @notice Withdraw all assets for the caller
     * @return amount Total amount withdrawn
     */
    function withdrawAll() external nonReentrant returns (uint256 amount) {
        uint256 shares = userSupplyShares[msg.sender];
        if (shares == 0) revert ZeroAmount();

        _accrueInterest();

        amount = (shares * totalSupplyAssets) / totalSupplyShares;

        userSupplyShares[msg.sender] = 0;
        totalSupplyAssets -= amount;
        totalSupplyShares -= shares;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
        return amount;
    }

    // ============================================
    // ===== BORROW FUNCTIONS =====================
    // ============================================

    /**
     * @notice Borrow assets using collateral
     * @param amount Amount to borrow
     */
    function borrow(uint256 amount) external nonReentrant {
        _accrueInterest();

        uint256 shares = 0;
        if (totalBorrowShares == 0) {
            shares = amount;
        } else {
            shares = (amount * totalBorrowShares) / totalBorrowAssets;
        }

        _checkHealth(msg.sender);
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();

        userBorrowShares[msg.sender] += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += amount;

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount, shares);
    }

    /**
     * @notice Repay borrowed assets
     * @param shares Amount of borrow shares to repay
     */
    function repay(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();

        _accrueInterest();

        uint256 borrowAmount = (shares * totalBorrowAssets) / totalBorrowShares;

        userBorrowShares[msg.sender] -= shares;
        totalBorrowShares -= shares;
        totalBorrowAssets -= borrowAmount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), borrowAmount);

        emit Repay(msg.sender, borrowAmount, shares);
    }

    // ============================================
    // ===== COLLATERAL FUNCTIONS =================
    // ============================================

    /**
     * @notice Deposit collateral
     * @param amount Amount of collateral to deposit
     */
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrueInterest();

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        userCollaterals[msg.sender] += amount;

        emit DepositCollateral(msg.sender, amount);
    }

    /**
     * @notice Withdraw collateral
     * @param amount Amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > userCollaterals[msg.sender]) revert InsufficientCollateral();

        _accrueInterest();

        userCollaterals[msg.sender] -= amount;
        _checkHealth(msg.sender);

        IERC20(collateralToken).safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, amount);
    }

    // ============================================
    // ===== INTEREST FUNCTIONS ===================
    // ============================================

    /**
     * @notice Manually accrue interest (external)
     */
    function accrueInterest() external nonReentrant {
        _accrueInterest();
    }

    /**
     * @notice Internal interest accrual
     */
    function _accrueInterest() internal {
        uint256 interestPerYear = (totalBorrowAssets * borrowRate) / 1e18;
        uint256 elapsedTime = block.timestamp - lastAccrued;
        uint256 interest = (interestPerYear * elapsedTime) / 365 days;

        totalSupplyAssets += interest;
        totalBorrowAssets += interest;
        lastAccrued = block.timestamp;
    }

    /**
     * @notice Check if user position is healthy
     */
    function _checkHealth(address user) internal view {
        uint256 collateralPrice = IInitOracle(oracle).getPrice();
        uint256 collateralDecimals = 10 ** IERC20Metadata(collateralToken).decimals();

        uint256 borrowed = 0;
        if (totalBorrowShares != 0) {
            borrowed = (userBorrowShares[user] * totalBorrowAssets) / totalBorrowShares;
        }

        uint256 collateralValue = (userCollaterals[user] * collateralPrice) / collateralDecimals;
        uint256 maxBorrow = (collateralValue * ltv) / 1e18;

        if (borrowed > maxBorrow) revert InsufficientCollateral();
    }

    // ============================================
    // ===== VIEW FUNCTIONS =======================
    // ============================================

    /**
     * @notice Get user's supply shares
     */
    function getUserSupplyShares(address user) external view returns (uint256) {
        return userSupplyShares[user];
    }

    /**
     * @notice Get user's supply balance in assets
     */
    function getUserSupplyBalance(address user) external view returns (uint256) {
        if (totalSupplyShares == 0) return 0;
        return (userSupplyShares[user] * totalSupplyAssets) / totalSupplyShares;
    }

    /**
     * @notice Get user's borrow shares
     */
    function getUserBorrowShares(address user) external view returns (uint256) {
        return userBorrowShares[user];
    }

    /**
     * @notice Get user's borrow balance in assets
     */
    function getUserBorrowBalance(address user) external view returns (uint256) {
        if (totalBorrowShares == 0) return 0;
        return (userBorrowShares[user] * totalBorrowAssets) / totalBorrowShares;
    }

    /**
     * @notice Get user's collateral balance
     */
    function getUserCollateral(address user) external view returns (uint256) {
        return userCollaterals[user];
    }

    /**
     * @notice Get current exchange rate (assets per share)
     */
    function exchangeRate() external view returns (uint256) {
        if (totalSupplyShares == 0) {
            return 1e18;
        }
        return (totalSupplyAssets * 1e18) / totalSupplyShares;
    }

    /**
     * @notice Get underlying asset address
     */
    function underlying() external view returns (address) {
        return asset;
    }

    /**
     * @notice Get total supply shares
     */
    function totalSupply() external view returns (uint256) {
        return totalSupplyShares;
    }

    /**
     * @notice Get available liquidity
     */
    function getAvailableLiquidity() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Convert assets to shares
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        if (assets == 0 || totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return assets;
        }
        return (assets * totalSupplyShares) / totalSupplyAssets;
    }

    /**
     * @notice Convert shares to assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (shares == 0 || totalSupplyAssets == 0 || totalSupplyShares == 0) {
            return shares;
        }
        return (shares * totalSupplyAssets) / totalSupplyShares;
    }

    /**
     * @notice Get user account data
     */
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 supplyBalance,
            uint256 supplyShares,
            uint256 borrowBalance,
            uint256 borrowShares,
            uint256 collateralBalance,
            uint256 healthFactor
        )
    {
        supplyShares = userSupplyShares[user];
        borrowShares = userBorrowShares[user];
        collateralBalance = userCollaterals[user];

        if (totalSupplyShares > 0) {
            supplyBalance = (supplyShares * totalSupplyAssets) / totalSupplyShares;
        }

        if (totalBorrowShares > 0) {
            borrowBalance = (borrowShares * totalBorrowAssets) / totalBorrowShares;
        }

        if (borrowBalance == 0) {
            healthFactor = type(uint256).max;
        } else {
            uint256 collateralValue = (supplyBalance * ltv) / 1e18;
            healthFactor = (collateralValue * 1e18) / borrowBalance;
        }
    }
}
