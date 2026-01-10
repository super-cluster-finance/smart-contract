// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface Oracle {
    function getPrice() external view returns (uint256);
}

/**
 * @title LendingPool (Ionic/Compound V2 Style)
 * @notice Mock lending pool following Ionic (Compound V2 fork) interface.
 *         - Users mint cTokens by depositing underlying assets.
 *         - Users redeem cTokens to withdraw underlying assets.
 *         - Supports borrowing with collateral.
 * @author SuperCluster Dev Team
 */
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error InsufficientShares();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error LTVExceedMaxAmount();
    error InvalidOracle();

    //! Supply (cToken shares)
    uint256 public totalSupplyShares;
    uint256 public totalSupplyAssets;
    //!Borrow
    uint256 public totalBorrowShares;
    uint256 public totalBorrowAssets;
    uint256 public lastAccrued = block.timestamp;
    uint256 public borrowRate = 1e17;
    uint256 public ltv;
    address public debtToken;
    address public collateralToken;
    address public oracle;

    /// @notice Emitted when user mints cTokens (deposits underlying)
    event Mint(address indexed minter, uint256 mintAmount, uint256 mintTokens);
    /// @notice Emitted when user redeems cTokens (withdraws underlying)
    event Redeem(address indexed redeemer, uint256 redeemAmount, uint256 redeemTokens);
    event SupplyCollateral(address user, uint256 amount);
    event Borrow(address user, uint256 amount, uint256 shares);
    event Repay(address user, uint256 amount, uint256 shares);

    error FlashLoanFailed(address token, uint256 amount);

    mapping(address => uint256) public userSupplyShares;
    mapping(address => uint256) public userBorrowShares;
    mapping(address => uint256) public userCollaterals;

    constructor(address _collateralToken, address _debtToken, address _oracle, uint256 _ltv) {
        collateralToken = _collateralToken;
        debtToken = _debtToken;
        oracle = _oracle;
        if (oracle == address(0)) revert InvalidOracle();
        if (_ltv > 1e18) revert LTVExceedMaxAmount();
        ltv = _ltv;
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange.
     * @dev Follows Ionic/Compound V2 interface.
     * @param mintAmount The amount of the underlying asset to supply.
     * @return 0 on success, otherwise a failure code.
     */
    function mint(uint256 mintAmount) external nonReentrant returns (uint256) {
        _accureInterest();
        if (mintAmount == 0) revert ZeroAmount();
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), mintAmount);

        uint256 mintTokens = 0;
        if (totalSupplyShares == 0) {
            mintTokens = mintAmount;
        } else {
            require(totalSupplyAssets > 0, "totalSupplyAssets is zero");
            mintTokens = (mintAmount * totalSupplyShares / totalSupplyAssets);
        }

        userSupplyShares[msg.sender] += mintTokens;
        totalSupplyShares += mintTokens;
        totalSupplyAssets += mintAmount;

        emit Mint(msg.sender, mintAmount, mintTokens);
        return 0; // Success
    }

    function borrow(uint256 amount) external nonReentrant {
        _accureInterest();

        uint256 shares = 0;
        if (totalBorrowShares == 0) {
            shares = amount;
        } else {
            shares = (amount * totalBorrowShares / totalBorrowAssets);
        }

        _isHealthy(msg.sender);
        if (totalBorrowAssets > totalSupplyAssets) revert InsufficientLiquidity();

        userBorrowShares[msg.sender] += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += amount;

        IERC20(debtToken).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, amount, shares);
    }

    function repay(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();

        _accureInterest();

        uint256 borrowAmount = (shares * totalBorrowAssets) / totalBorrowShares;

        userBorrowShares[msg.sender] -= shares;
        totalBorrowShares -= shares;
        totalBorrowAssets -= borrowAmount;

        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), borrowAmount);

        emit Repay(msg.sender, borrowAmount, shares);
    }

    function accureInterest() external nonReentrant {
        _accureInterest();
    }

    function _accureInterest() internal {
        uint256 interestPerYear = totalBorrowAssets * borrowRate / 1e18;
        // 1000 * 1e17 / 1e18 = 100/year

        uint256 elapsedTime = block.timestamp - lastAccrued;
        // 1 day

        uint256 interest = (interestPerYear * elapsedTime) / 365 days;
        // interest = $100 * 1 day / 365 day  = $0.27

        totalSupplyAssets += interest;
        totalBorrowAssets += interest;
        lastAccrued = block.timestamp;
    }

    function supplyCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accureInterest();

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        userCollaterals[msg.sender] += amount;

        emit SupplyCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > userCollaterals[msg.sender]) revert InsufficientCollateral();

        _accureInterest();

        userCollaterals[msg.sender] -= amount;

        _isHealthy(msg.sender);

        IERC20(collateralToken).safeTransfer(msg.sender, amount);
    }

    function _isHealthy(address user) internal view {
        uint256 collateralPrice = Oracle(oracle).getPrice(); // harga WETH dalam USDC
        uint256 collateralDecimals = 10 ** IERC20Metadata(collateralToken).decimals(); // 1e18

        uint256 borrowed = 0;
        if (totalBorrowShares != 0) {
            borrowed = userBorrowShares[user] * totalBorrowAssets / totalBorrowShares;
        }

        uint256 collateralValue = userCollaterals[user] * collateralPrice / collateralDecimals;
        uint256 maxBorrow = collateralValue * ltv / 1e18;

        if (borrowed > maxBorrow) revert InsufficientCollateral();
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset.
     * @dev Follows Ionic/Compound V2 interface.
     * @param redeemTokens The number of cTokens to redeem into underlying.
     * @return 0 on success, otherwise a failure code.
     */
    function redeem(uint256 redeemTokens) external nonReentrant returns (uint256) {
        if (redeemTokens == 0) revert ZeroAmount();

        if (redeemTokens > userSupplyShares[msg.sender]) revert InsufficientShares();

        _accureInterest();

        uint256 redeemAmount = (redeemTokens * totalSupplyAssets) / totalSupplyShares;

        userSupplyShares[msg.sender] -= redeemTokens;
        totalSupplyAssets -= redeemAmount;
        totalSupplyShares -= redeemTokens;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(debtToken).safeTransfer(msg.sender, redeemAmount);

        emit Redeem(msg.sender, redeemAmount, redeemTokens);
        return 0; // Success
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset.
     * @dev Follows Ionic/Compound V2 interface.
     * @param redeemAmount The amount of underlying to receive from redeeming cTokens.
     * @return 0 on success, otherwise a failure code.
     */
    function redeemUnderlying(uint256 redeemAmount) external nonReentrant returns (uint256) {
        if (redeemAmount == 0) revert ZeroAmount();

        _accureInterest();

        // Calculate tokens needed for this underlying amount
        uint256 redeemTokens = (redeemAmount * totalSupplyShares) / totalSupplyAssets;

        if (redeemTokens > userSupplyShares[msg.sender]) revert InsufficientShares();

        userSupplyShares[msg.sender] -= redeemTokens;
        totalSupplyAssets -= redeemAmount;
        totalSupplyShares -= redeemTokens;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(debtToken).safeTransfer(msg.sender, redeemAmount);

        emit Redeem(msg.sender, redeemAmount, redeemTokens);
        return 0; // Success
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(msg.sender, amount);

        (bool success,) = address(msg.sender).call(data);
        if (!success) revert FlashLoanFailed(token, amount);

        IERC20(token).safeTransfer(address(this), amount);
    }

    /**
     * @notice Get the cToken balance for an account.
     * @param owner The address to check.
     * @return The balance of cTokens.
     */
    function balanceOf(address owner) external view returns (uint256) {
        return userSupplyShares[owner];
    }

    /**
     * @notice Get user's supply shares (alias for balanceOf).
     * @param user The user address to check.
     * @return The amount of cTokens the user holds.
     */
    function getUserSupplyShares(address user) external view returns (uint256) {
        return userSupplyShares[user];
    }

    /**
     * @notice Get the underlying balance of an account.
     * @param owner The address to check.
     * @return The amount of underlying owned by `owner`.
     */
    function balanceOfUnderlying(address owner) external view returns (uint256) {
        if (totalSupplyShares == 0) return 0;
        return (userSupplyShares[owner] * totalSupplyAssets) / totalSupplyShares;
    }

    /**
     * @notice Get user's supply balance (alias for balanceOfUnderlying).
     * @param user The user address to check.
     * @return The underlying balance.
     */
    function getUserSupplyBalance(address user) external view returns (uint256) {
        if (totalSupplyShares == 0) return 0;
        return (userSupplyShares[user] * totalSupplyAssets) / totalSupplyShares;
    }

    function getUserBorrowShares(address user) external view returns (uint256) {
        return userBorrowShares[user];
    }

    function getUserBorrowBalance(address user) external view returns (uint256) {
        if (totalBorrowShares == 0) return 0;

        // Convert user borrow shares to assets
        return (userBorrowShares[user] * totalBorrowAssets) / totalBorrowShares;
    }

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 supplyBalance,
            uint256 supplyShares,
            uint256 borrowBalance,
            uint256 borrowShares,
            uint256 healthFactor
        )
    {
        supplyShares = userSupplyShares[user];
        borrowShares = userBorrowShares[user];

        // Convert to asset values
        if (totalSupplyShares > 0) {
            supplyBalance = (supplyShares * totalSupplyAssets) / totalSupplyShares;
        }

        if (totalBorrowShares > 0) {
            borrowBalance = (borrowShares * totalBorrowAssets) / totalBorrowShares;
        }

        // Calculate health factor
        if (borrowBalance == 0) {
            healthFactor = type(uint256).max; // No debt = infinite health
        } else {
            // Health factor = (collateral * LTV) / debt
            // Using LTV from constructor
            uint256 collateralValue = (supplyBalance * ltv) / 1e18;
            healthFactor = (collateralValue * 1e18) / borrowBalance;
        }
    }

    /**
     * @notice Get the current exchange rate from cTokens to underlying.
     * @return The exchange rate scaled by 1e18.
     */
    function exchangeRateStored() external view returns (uint256) {
        if (totalSupplyShares == 0) {
            return 1e18; // Initial exchange rate 1:1
        }
        return (totalSupplyAssets * 1e18) / totalSupplyShares;
    }

    /**
     * @notice Get the current exchange rate (same as exchangeRateStored for mock).
     * @return The exchange rate scaled by 1e18.
     */
    function exchangeRateCurrent() external view returns (uint256) {
        if (totalSupplyShares == 0) {
            return 1e18;
        }
        return (totalSupplyAssets * 1e18) / totalSupplyShares;
    }

    /**
     * @notice Get the underlying token address.
     * @return The underlying token address.
     */
    function underlying() external view returns (address) {
        return debtToken;
    }

    /**
     * @notice Get total supply of cTokens.
     * @return Total cToken supply.
     */
    function totalSupply() external view returns (uint256) {
        return totalSupplyShares;
    }

    /**
     * @notice Get cash (underlying balance) held by this contract.
     * @return Cash balance.
     */
    function getCash() external view returns (uint256) {
        return IERC20(debtToken).balanceOf(address(this));
    }
}
