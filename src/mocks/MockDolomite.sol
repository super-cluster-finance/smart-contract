// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IDolomiteOracle {
    function getPrice() external view returns (uint256);
}

/**
 * @title DolomiteMargin (Dolomite Style)
 * @notice Mock margin protocol following Dolomite interface.
 *         - Users have multiple sub-accounts identified by accountNumber.
 *         - Supports deposits, withdrawals, borrows with margin accounts.
 *         - Uses marketId to identify different assets.
 * @author SuperCluster Dev Team
 */
contract DolomiteMargin is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // ===== STRUCTS ==============================
    // ============================================

    struct AccountInfo {
        address owner;
        uint256 accountNumber;
    }

    struct Wei {
        bool sign; // true = positive, false = negative
        uint256 value;
    }

    struct Market {
        address token;
        uint256 totalSupplyPar;
        uint256 totalBorrowPar;
        uint256 supplyIndex; // scaled by 1e18
        uint256 borrowIndex; // scaled by 1e18
        bool isClosing;
    }

    // ============================================
    // ===== ERRORS ===============================
    // ============================================

    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error InvalidMarket();
    error InvalidAccount();
    error MarketNotExists();
    error LTVExceedMaxAmount();
    error InvalidOracle();

    // ============================================
    // ===== STATE VARIABLES ======================
    // ============================================

    /// @notice Markets by marketId
    mapping(uint256 => Market) public markets;
    /// @notice Number of markets
    uint256 public numMarkets;
    /// @notice User balances: owner => accountNumber => marketId => Wei
    mapping(address => mapping(uint256 => mapping(uint256 => Wei))) public accountBalances;
    /// @notice Price oracle
    address public oracle;
    /// @notice LTV ratio
    uint256 public ltv;
    /// @notice Interest rate per second (scaled by 1e18)
    uint256 public interestRate = 0; // Disabled for testing
    /// @notice Last accrual timestamp per market
    mapping(uint256 => uint256) public lastAccrualTime;

    // ============================================
    // ===== EVENTS ===============================
    // ============================================

    event Deposit(address indexed owner, uint256 accountNumber, uint256 marketId, uint256 amount);
    event Withdraw(address indexed owner, uint256 accountNumber, uint256 marketId, uint256 amount);
    event Borrow(address indexed owner, uint256 accountNumber, uint256 marketId, uint256 amount);
    event Repay(address indexed owner, uint256 accountNumber, uint256 marketId, uint256 amount);
    event MarketAdded(uint256 indexed marketId, address token);

    // ============================================
    // ===== CONSTRUCTOR ==========================
    // ============================================

    constructor(address _oracle, uint256 _ltv) {
        oracle = _oracle;
        if (oracle == address(0)) revert InvalidOracle();
        if (_ltv > 1e18) revert LTVExceedMaxAmount();
        ltv = _ltv;
    }

    // ============================================
    // ===== MARKET FUNCTIONS =====================
    // ============================================

    /**
     * @notice Add a new market
     * @param token Token address for the market
     * @return marketId The new market ID
     */
    function addMarket(address token) external returns (uint256 marketId) {
        marketId = numMarkets;
        markets[marketId] = Market({
            token: token,
            totalSupplyPar: 0,
            totalBorrowPar: 0,
            supplyIndex: 1e18,
            borrowIndex: 1e18,
            isClosing: false
        });
        lastAccrualTime[marketId] = block.timestamp;
        numMarkets++;

        emit MarketAdded(marketId, token);
        return marketId;
    }

    // ============================================
    // ===== DEPOSIT/WITHDRAW FUNCTIONS ===========
    // ============================================

    /**
     * @notice Deposit tokens to a margin account
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @param amount Amount to deposit
     */
    function deposit(uint256 accountNumber, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (marketId >= numMarkets) revert MarketNotExists();

        _accrueInterest(marketId);

        Market storage market = markets[marketId];

        IERC20(market.token).safeTransferFrom(msg.sender, address(this), amount);

        // Convert to par value
        uint256 parValue = (amount * 1e18) / market.supplyIndex;

        Wei storage balance = accountBalances[msg.sender][accountNumber][marketId];
        if (balance.sign == false && balance.value > 0) {
            // Has borrow, reduce borrow first
            if (parValue >= balance.value) {
                parValue -= balance.value;
                market.totalBorrowPar -= balance.value;
                balance.value = parValue;
                balance.sign = true;
                market.totalSupplyPar += parValue;
            } else {
                balance.value -= parValue;
                market.totalBorrowPar -= parValue;
            }
        } else {
            balance.value += parValue;
            balance.sign = true;
            market.totalSupplyPar += parValue;
        }

        emit Deposit(msg.sender, accountNumber, marketId, amount);
    }

    /**
     * @notice Withdraw tokens from a margin account
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 accountNumber, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (marketId >= numMarkets) revert MarketNotExists();

        _accrueInterest(marketId);

        Market storage market = markets[marketId];
        Wei storage balance = accountBalances[msg.sender][accountNumber][marketId];

        // Convert to par value
        uint256 parValue = (amount * 1e18) / market.supplyIndex;

        if (!balance.sign || balance.value < parValue) revert InsufficientBalance();

        balance.value -= parValue;
        market.totalSupplyPar -= parValue;

        IERC20(market.token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, accountNumber, marketId, amount);
    }

    /**
     * @notice Withdraw all tokens from a margin account
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @return amount Amount withdrawn
     */
    function withdrawAll(uint256 accountNumber, uint256 marketId) external nonReentrant returns (uint256 amount) {
        if (marketId >= numMarkets) revert MarketNotExists();

        _accrueInterest(marketId);

        Market storage market = markets[marketId];
        Wei storage balance = accountBalances[msg.sender][accountNumber][marketId];

        if (!balance.sign || balance.value == 0) revert InsufficientBalance();

        uint256 parValue = balance.value;
        amount = (parValue * market.supplyIndex) / 1e18;

        balance.value = 0;
        market.totalSupplyPar -= parValue;

        IERC20(market.token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, accountNumber, marketId, amount);
        return amount;
    }

    // ============================================
    // ===== BORROW/REPAY FUNCTIONS ===============
    // ============================================

    /**
     * @notice Borrow tokens from a margin account
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @param amount Amount to borrow
     */
    function borrow(uint256 accountNumber, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (marketId >= numMarkets) revert MarketNotExists();

        _accrueInterest(marketId);

        Market storage market = markets[marketId];

        uint256 available = IERC20(market.token).balanceOf(address(this));
        if (amount > available) revert InsufficientLiquidity();

        // Convert to par value
        uint256 parValue = (amount * 1e18) / market.borrowIndex;

        Wei storage balance = accountBalances[msg.sender][accountNumber][marketId];
        if (balance.sign && balance.value > 0) {
            // Has supply, reduce supply first
            if (parValue >= balance.value) {
                parValue -= balance.value;
                market.totalSupplyPar -= balance.value;
                balance.value = parValue;
                balance.sign = false;
                market.totalBorrowPar += parValue;
            } else {
                balance.value -= parValue;
                market.totalSupplyPar -= parValue;
            }
        } else {
            balance.value += parValue;
            balance.sign = false;
            market.totalBorrowPar += parValue;
        }

        IERC20(market.token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, accountNumber, marketId, amount);
    }

    /**
     * @notice Repay borrowed tokens
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @param amount Amount to repay
     */
    function repay(uint256 accountNumber, uint256 marketId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (marketId >= numMarkets) revert MarketNotExists();

        _accrueInterest(marketId);

        Market storage market = markets[marketId];
        Wei storage balance = accountBalances[msg.sender][accountNumber][marketId];

        if (balance.sign || balance.value == 0) revert InvalidAccount();

        // Convert to par value
        uint256 parValue = (amount * 1e18) / market.borrowIndex;

        if (parValue > balance.value) {
            parValue = balance.value;
            amount = (parValue * market.borrowIndex) / 1e18;
        }

        IERC20(market.token).safeTransferFrom(msg.sender, address(this), amount);

        balance.value -= parValue;
        market.totalBorrowPar -= parValue;

        emit Repay(msg.sender, accountNumber, marketId, amount);
    }

    // ============================================
    // ===== INTEREST FUNCTIONS ===================
    // ============================================

    /**
     * @notice Accrue interest for a market
     */
    function accrueInterest(uint256 marketId) external nonReentrant {
        _accrueInterest(marketId);
    }

    function _accrueInterest(uint256 marketId) internal {
        uint256 timeElapsed = block.timestamp - lastAccrualTime[marketId];
        if (timeElapsed == 0) return;

        Market storage market = markets[marketId];

        // Update supply index
        uint256 supplyInterest = (market.supplyIndex * interestRate * timeElapsed) / 1e18;
        market.supplyIndex += supplyInterest;

        // Update borrow index
        uint256 borrowInterest = (market.borrowIndex * interestRate * timeElapsed) / 1e18;
        market.borrowIndex += borrowInterest;

        lastAccrualTime[marketId] = block.timestamp;
    }

    // ============================================
    // ===== VIEW FUNCTIONS =======================
    // ============================================

    /**
     * @notice Get account balance for a market
     * @param owner Account owner
     * @param accountNumber Sub-account number
     * @param marketId Market ID
     * @return sign True if positive (supply), false if negative (borrow)
     * @return value Balance value in par
     */
    function getAccountBalance(address owner, uint256 accountNumber, uint256 marketId)
        external
        view
        returns (bool sign, uint256 value)
    {
        Wei storage balance = accountBalances[owner][accountNumber][marketId];
        return (balance.sign, balance.value);
    }

    /**
     * @notice Get account balance in wei (with interest)
     */
    function getAccountWei(address owner, uint256 accountNumber, uint256 marketId)
        external
        view
        returns (bool sign, uint256 value)
    {
        Wei storage balance = accountBalances[owner][accountNumber][marketId];
        Market storage market = markets[marketId];

        if (balance.sign) {
            value = (balance.value * market.supplyIndex) / 1e18;
        } else {
            value = (balance.value * market.borrowIndex) / 1e18;
        }
        return (balance.sign, value);
    }

    /**
     * @notice Get market info
     */
    function getMarket(uint256 marketId)
        external
        view
        returns (address token, uint256 totalSupplyPar, uint256 totalBorrowPar, uint256 supplyIndex, uint256 borrowIndex)
    {
        Market storage market = markets[marketId];
        return (market.token, market.totalSupplyPar, market.totalBorrowPar, market.supplyIndex, market.borrowIndex);
    }

    /**
     * @notice Get market token address
     */
    function getMarketToken(uint256 marketId) external view returns (address) {
        return markets[marketId].token;
    }

    /**
     * @notice Get total supply in wei
     */
    function getTotalSupplyWei(uint256 marketId) external view returns (uint256) {
        Market storage market = markets[marketId];
        return (market.totalSupplyPar * market.supplyIndex) / 1e18;
    }

    /**
     * @notice Get total borrow in wei
     */
    function getTotalBorrowWei(uint256 marketId) external view returns (uint256) {
        Market storage market = markets[marketId];
        return (market.totalBorrowPar * market.borrowIndex) / 1e18;
    }

    /**
     * @notice Get available liquidity for a market
     */
    function getAvailableLiquidity(uint256 marketId) external view returns (uint256) {
        return IERC20(markets[marketId].token).balanceOf(address(this));
    }

    /**
     * @notice Get number of markets
     */
    function getNumMarkets() external view returns (uint256) {
        return numMarkets;
    }
}
