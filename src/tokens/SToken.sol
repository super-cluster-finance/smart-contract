// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SToken
 * @dev Rebasing ERC20 token with scaling factor (Lido-style).
 *      - Represents user shares in underlying baseToken.
 *      - Supports mint/burn by authorized minters and owner.
 *      - Rebase increases scaling factor and user balances proportionally.
 *      - Uses shares model for efficient rebasing.
 *      - Implements standard ERC20 and ERC20Metadata interfaces.
 * @author SuperCluster Dev Team
 */
contract SToken is IERC20, IERC20Metadata, Ownable {
    /// @notice Token name
    string public name;

    /// @notice Token symbol
    string public symbol;

    /// @notice Token decimals
    uint8 public decimals;

    /// @notice Last rebase timestamp
    uint256 public lastRebaseTime;

    /// @notice Minimum interval between rebases
    uint256 public rebaseInterval = 1 days;

    using SafeERC20 for IERC20;

    /// @notice Underlying base token (e.g. USDC, IDRX)
    IERC20 public baseToken;

    /// @dev Shares model for scaling factor
    mapping(address => uint256) private _shares;
    uint256 private _totalShares;

    /// @notice Scaling factor for rebasing (1e18 = no yield)
    uint256 public scalingFactor = 1e18;

    /// @dev Allowances for ERC20
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Authorized minters (SuperCluster, owner)
    mapping(address => bool) public authorizedMinters;

    /// @notice Emitted on rebase
    event Rebase(uint256 yieldAmount, uint256 newScalingFactor, uint256 timestamp);

    /**
     * @dev Deploys SToken contract.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _underlyingToken Address of underlying base token.
     */
    constructor(string memory _name, string memory _symbol, address _underlyingToken) Ownable(msg.sender) {
        name = _name;
        symbol = _symbol;
        decimals = IERC20Metadata(_underlyingToken).decimals();
        baseToken = IERC20(_underlyingToken);
        lastRebaseTime = block.timestamp;
    }

    /**
     * @notice Returns the rebased balance of an account.
     * @param account The user address.
     * @return User's sToken balance (rebased).
     */
    function balanceOf(address account) public view override returns (uint256) {
        return (_shares[account] * scalingFactor) / 1e18;
    }

    /**
     * @notice Returns the total rebased supply.
     * @return Total sToken supply (rebased).
     */
    function totalSupply() public view override returns (uint256) {
        return (_totalShares * scalingFactor) / 1e18;
    }

    /**
     * @notice Approve spender for a given amount.
     * @param spender The address allowed to spend.
     * @param amount The amount approved.
     * @return True if successful.
     */
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Returns allowance for spender.
     * @param owner The owner address.
     * @param spender The spender address.
     * @return Allowance amount.
     */
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @notice Transfer sToken to another address.
     * @param to Recipient address.
     * @param amount Amount to transfer (rebased units).
     * @return True if successful.
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer sToken from one address to another.
     * @param from Sender address.
     * @param to Recipient address.
     * @param amount Amount to transfer (rebased units).
     * @return True if successful.
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }

    /**
     * @dev Internal transfer using shares model.
     * @param from Sender address.
     * @param to Recipient address.
     * @param amount Amount to transfer (rebased units).
     */
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        uint256 sharesToTransfer = (amount * 1e18) / scalingFactor;
        require(_shares[from] >= sharesToTransfer, "ERC20: transfer amount exceeds balance");
        _shares[from] -= sharesToTransfer;
        _shares[to] += sharesToTransfer;
        emit Transfer(from, to, amount);
    }

    /**
     * @dev Internal approve logic.
     * @param owner Owner address.
     * @param spender Spender address.
     * @param amount Amount approved.
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Mint sToken for a user (authorized minters only).
     * @param to Recipient address.
     * @param amount Amount to mint (rebased units).
     */
    function mint(address to, uint256 amount) external {
        require(authorizedMinters[msg.sender] || msg.sender == owner(), "Unauthorized");
        uint256 sharesToMint = (amount * 1e18) / scalingFactor;
        _shares[to] += sharesToMint;
        _totalShares += sharesToMint;
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn sToken from a user (authorized minters only).
     * @param from Address to burn from.
     * @param amount Amount to burn (rebased units).
     */
    function burn(address from, uint256 amount) external {
        require(authorizedMinters[msg.sender] || msg.sender == owner(), "Unauthorized");
        uint256 sharesToBurn = (amount * 1e18) / scalingFactor;
        require(_shares[from] >= sharesToBurn, "Insufficient balance");
        _shares[from] -= sharesToBurn;
        _totalShares -= sharesToBurn;
        emit Transfer(from, address(0), amount);
    }

    /**
     * @notice Set an address as authorized minter.
     * @param minter Address to set.
     * @param authorized True to authorize, false to revoke.
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
    }

    /**
     * @notice Rebase: increase scaling factor and user balances proportionally.
     * @param yieldAmount Amount of yield to distribute.
     * @dev Only callable by owner (SuperCluster).
     */
    function rebase(uint256 yieldAmount) external onlyOwner {
        uint256 supplyBefore = totalSupply();
        require(supplyBefore > 0, "No supply");
        scalingFactor = scalingFactor * (supplyBefore + yieldAmount) / supplyBefore;
        emit Rebase(yieldAmount, scalingFactor, block.timestamp);
    }
}
