// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title WsToken (Wrapped sToken)
 * @notice Non-rebasing ERC20 wrapper for rebasing sToken (Lido-style).
 *         - Users can wrap sToken to receive wsToken (fixed supply).
 *         - Each wsToken represents an increasing amount of sToken as rebases happen.
 *         - Conversion rate follows wstETH pattern.
 * @author SuperCluster Dev Team
 */
contract WsToken is ERC20, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The underlying rebasing sToken contract
    IERC20 public immutable STOKENCONTRACT;

    /// @notice Authorized minters (for protocol integrations)
    mapping(address => bool) public authorizedMinters;

    /// @notice Emitted when a user wraps sToken to wsToken
    event Wrapped(address indexed user, uint256 sTokenAmount, uint256 wsTokenAmount);

    /// @notice Emitted when a user unwraps wsToken to sToken
    event Unwrapped(address indexed user, uint256 wsTokenAmount, uint256 sTokenAmount);

    /**
     * @dev Deploys WsToken contract.
     * @param _name Name of wsToken.
     * @param _symbol Symbol of wsToken.
     * @param _sToken Address of underlying rebasing sToken.
     */
    constructor(string memory _name, string memory _symbol, address _sToken) ERC20(_name, _symbol) Ownable(msg.sender) {
        require(_sToken != address(0), "underlying zero");
        STOKENCONTRACT = IERC20(_sToken);
    }

    /**
     * @notice Set or revoke authorized minter status.
     * @param minter Address to set.
     * @param authorized True to authorize, false to revoke.
     */
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
    }

    /**
     * @notice Wrap sToken to receive wsToken (non-rebasing).
     * @dev User must approve sToken for this contract before calling.
     * @param sTokenAmount Amount of sToken to wrap.
     */
    function wrap(uint256 sTokenAmount) external {
        require(sTokenAmount > 0, "Amount must be > 0");

        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        uint256 _totalSupply = totalSupply();

        STOKENCONTRACT.safeTransferFrom(msg.sender, address(this), sTokenAmount);

        uint256 wsTokenAmount;
        if (_totalSupply == 0 || stTokenBalance == 0) {
            wsTokenAmount = sTokenAmount;
        } else {
            wsTokenAmount = (sTokenAmount * _totalSupply) / stTokenBalance;
            require(wsTokenAmount > 0, "wsToken amount too small");
        }

        _mint(msg.sender, wsTokenAmount);

        emit Wrapped(msg.sender, sTokenAmount, wsTokenAmount);
    }

    /**
     * @notice Unwrap wsToken to receive underlying sToken.
     * @param wsTokenAmount Amount of wsToken to burn.
     */
    function unwrap(uint256 wsTokenAmount) external {
        require(wsTokenAmount > 0, "Amount must be > 0");
        require(balanceOf(msg.sender) >= wsTokenAmount, "Insufficient wsToken balance");

        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "Total supply zero");

        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        require(stTokenBalance > 0, "No STOKEN in contract");

        uint256 sTokenAmount = (wsTokenAmount * stTokenBalance) / _totalSupply;
        require(sTokenAmount > 0, "sToken amount too small");

        _burn(msg.sender, wsTokenAmount);
        STOKENCONTRACT.safeTransfer(msg.sender, sTokenAmount);

        emit Unwrapped(msg.sender, wsTokenAmount, sTokenAmount);
    }

    /**
     * @notice Unwrap wsToken and send sToken to a recipient.
     * @param wsTokenAmount Amount of wsToken to burn.
     * @param recipient Address to receive sToken.
     */
    function unwrapTo(uint256 wsTokenAmount, address recipient) external {
        require(recipient != address(0), "Recipient zero");
        require(wsTokenAmount > 0, "Amount must be > 0");

        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "Total supply zero");

        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        require(stTokenBalance > 0, "No STOKEN in contract");

        uint256 sTokenAmount = (wsTokenAmount * stTokenBalance) / _totalSupply;
        require(sTokenAmount > 0, "sToken amount too small");

        _burn(msg.sender, wsTokenAmount);
        STOKENCONTRACT.safeTransfer(recipient, sTokenAmount);

        emit Unwrapped(recipient, wsTokenAmount, sTokenAmount);
    }

    // --------------------------------------------------------------------
    // Helper / view functions
    // --------------------------------------------------------------------

    /**
     * @notice Returns how many sToken one wsToken is worth (scaled by 1e18).
     * @dev stPerWs = stTokenBalance * 1e18 / totalSupply
     * @return Amount of sToken per wsToken (1e18 precision).
     */
    function stTokenPerWsToken() public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return 1e18; // 1:1 initially
        }
        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        return (stTokenBalance * 1e18) / _totalSupply;
    }

    /**
     * @notice Returns how many wsToken equals one sToken (scaled by 1e18).
     * @dev wsPerSt = totalSupply * 1e18 / stTokenBalance
     * @return Amount of wsToken per sToken (1e18 precision).
     */
    function wsTokenPerStToken() public view returns (uint256) {
        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        uint256 _totalSupply = totalSupply();
        if (stTokenBalance == 0) {
            return 1e18;
        }
        return (_totalSupply * 1e18) / stTokenBalance;
    }

    /**
     * @notice Convert sToken amount to wsToken amount using current rate.
     * @param sTokenAmount Amount of sToken to convert.
     * @return Equivalent wsToken amount.
     */
    function sTokenToWsToken(uint256 sTokenAmount) external view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        if (_totalSupply == 0 || stTokenBalance == 0) {
            return sTokenAmount;
        }
        return (sTokenAmount * _totalSupply) / stTokenBalance;
    }

    /**
     * @notice Convert wsToken amount to sToken amount using current rate.
     * @param wsTokenAmount Amount of wsToken to convert.
     * @return Equivalent sToken amount.
     */
    function wsTokenToSToken(uint256 wsTokenAmount) external view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 stTokenBalance = STOKENCONTRACT.balanceOf(address(this));
        if (_totalSupply == 0 || stTokenBalance == 0) {
            return 0;
        }
        return (wsTokenAmount * stTokenBalance) / _totalSupply;
    }

    /**
     * @notice Returns current sToken balance held by this contract.
     * @return sToken balance.
     */
    function getSTokenBalance() external view returns (uint256) {
        return STOKENCONTRACT.balanceOf(address(this));
    }
}
