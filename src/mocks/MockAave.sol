// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface Oracle {
    function getPrice() external view returns (uint256);
}

contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error InsufficientShares();
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error LTVExceedMaxAmount();
    error InvalidOracle();

    //!Supply
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

    event Supply(address user, uint256 amount, uint256 shares);
    event Withdraw(address user, uint256 amount, uint256 shares);
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

    function supply(uint256 amount) external nonReentrant {
        _accureInterest();
        if (amount == 0) revert ZeroAmount();
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares = 0;
        if (totalSupplyShares == 0) {
            shares = amount;
        } else {
            require(totalSupplyAssets > 0, "totalSupplyAssets is zero");
            shares = (amount * totalSupplyShares / totalSupplyAssets);
        }

        userSupplyShares[msg.sender] += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += amount;

        emit Supply(msg.sender, amount, shares);
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

    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();

        if (shares > userSupplyShares[msg.sender]) revert InsufficientShares();

        _accureInterest();

        uint256 amount = (shares * totalSupplyAssets) / totalSupplyShares;

        userSupplyShares[msg.sender] -= shares;
        totalSupplyAssets -= amount;
        totalSupplyShares -= shares;

        if (totalSupplyShares == 0) {
            require(totalSupplyAssets == 0, "assets mismatch");
        }

        IERC20(debtToken).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, shares);
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(msg.sender, amount);

        (bool success,) = address(msg.sender).call(data);
        if (!success) revert FlashLoanFailed(token, amount);

        IERC20(token).safeTransfer(address(this), amount);
    }

    /**
     * @dev ✅ ADD: Get user's supply shares (raw shares, not converted to assets)
     * @param user The user address to check
     * @return The amount of supply shares the user holds
     */
    function getUserSupplyShares(address user) external view returns (uint256) {
        return userSupplyShares[user];
    }

    function getUserSupplyBalance(address user) external view returns (uint256) {
        if (totalSupplyShares == 0) return 0;

        // Convert user shares to assets using exchange rate
        // assets = (userShares * totalSupplyAssets) / totalSupplyShares
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
}
