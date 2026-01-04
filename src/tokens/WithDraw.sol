// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISToken} from "../interfaces/ISToken.sol";

/**
 * @title WithdrawManager
 * @notice Queued withdrawal manager for SToken -> BaseToken withdrawals.
 * @dev Supports request, finalize (operator), and claim (user) flow.
 *      - Designed for rebasing sToken and ERC20 base token.
 *      - Handles delays, emergency withdrawals, and operator funding.
 *      - Uses SafeERC20 for all token transfers.
 * @author SuperCluster Dev Team
 */
contract Withdraw is Ownable {
    using SafeERC20 for IERC20;

    /// @notice SuperCluster contract address (protocol owner)
    address public superCluster;

    /// @notice Underlying base token (e.g. ERC20)
    IERC20 public baseToken;

    /// @notice Rebasing sToken contract
    ISToken public sToken;

    /// @notice Last rebase timestamp (for future extension)
    uint256 public lastRebaseTime;

    /// @notice Delay (in seconds) between finalize and claim availability
    uint256 public withdrawDelay;

    /// @notice Next request ID (auto-increment)
    uint256 public nextRequestId;

    /// @notice Withdraw request struct
    struct Request {
        address user;
        uint256 sAmount;
        uint256 baseAmount;
        uint256 requestedAt;
        uint256 availableAt;
        bool finalized;
        bool claimed;
    }

    /// @notice Mapping of requestId to Request
    mapping(uint256 => Request) public requests;

    // --- Events ---

    /// @notice Emitted when a withdraw is requested
    event WithdrawRequested(uint256 indexed id, address indexed user, uint256 sAmount, uint256 timestamp);

    /// @notice Emitted when a withdraw is finalized
    event WithdrawFinalized(uint256 indexed id, uint256 baseAmount, uint256 availableAt, uint256 timestamp);

    /// @notice Emitted when a withdraw is claimed
    event WithdrawClaimed(uint256 indexed id, address indexed user, uint256 baseAmount, uint256 timestamp);

    /// @notice Emitted when contract is funded for withdrawals
    event Funded(address indexed sender, uint256 amount, uint256 balance);

    /// @notice Emitted when a request is cancelled
    event RequestCancelled(uint256 indexed id, address indexed user, uint256 sAmount);

    /// @notice Emitted when a withdraw is informed (for off-chain tracking)
    event WithdrawInformed(uint256 indexed id, address indexed user, uint256 baseAmount, uint256 timestamp);

    /// @notice Mapping from user address to array of their withdraw request IDs.
    /// @dev Allows users to easily track all their withdrawal requests.
    mapping(address => uint256[]) public userRequests;

    /**
     * @dev Deploys WithdrawManager contract.
     * @param _sToken Address of sToken contract.
     * @param _baseToken Address of base token contract.
     * @param _superCluster Address of SuperCluster contract.
     * @param _withdrawDelay Delay (seconds) between finalize and claim.
     */
    constructor(address _sToken, address _baseToken, address _superCluster, uint256 _withdrawDelay)
        Ownable(msg.sender)
    {
        require(_sToken != address(0) && _baseToken != address(0), "Zero address");
        sToken = ISToken(_sToken);
        baseToken = IERC20(_baseToken);
        superCluster = _superCluster;
        withdrawDelay = _withdrawDelay;
        nextRequestId = 1;
    }

    /**
     * @notice Inform off-chain system about a finalized withdraw.
     * @param id Withdraw request ID.
     */
    function informWithdraw(uint256 id) external onlyOwner {
        Request storage r = requests[id];
        require(r.user != address(0), "Invalid request");
        require(r.finalized, "Not finalized yet");
        require(!r.claimed, "Already claimed");

        emit WithdrawInformed(id, r.user, r.baseAmount, block.timestamp);
    }

    /**
     * @notice Get summarized info for a withdraw request.
     * @param id Withdraw request ID.
     * @return user Request owner.
     * @return sAmount sToken amount.
     * @return baseAmount Base token amount.
     * @return finalized Whether finalized.
     * @return claimed Whether claimed.
     * @return availableAt When claim is available.
     */
    function getWithdrawInfo(uint256 id)
        external
        view
        returns (address user, uint256 sAmount, uint256 baseAmount, bool finalized, bool claimed, uint256 availableAt)
    {
        Request storage r = requests[id];
        return (r.user, r.sAmount, r.baseAmount, r.finalized, r.claimed, r.availableAt);
    }

    /**
     * @notice User requests withdrawal by transferring sToken.
     * @dev User must approve sToken for this contract before calling.
     * @param sAmount Amount of sToken to withdraw.
     * @return id Withdraw request ID.
     */
    function requestWithdraw(uint256 sAmount) external returns (uint256) {
        require(sAmount > 0, "Zero amount");

        // Transfer sToken from user to this contract
        // caller must have approved sToken allowance for this contract
        uint256 allowance = sToken.allowance(msg.sender, address(this));
        require(allowance >= sAmount, "Insufficient allowance for sToken");

        bool ok = sToken.transferFrom(msg.sender, address(this), sAmount);
        require(ok, "sToken transferFrom failed");

        uint256 id = nextRequestId++;
        Request storage r = requests[id];
        r.user = msg.sender;
        r.sAmount = sAmount;
        r.requestedAt = block.timestamp;
        r.finalized = false;
        r.claimed = false;
        r.availableAt = 0;
        r.baseAmount = 0;

        r.baseAmount = sAmount;

        emit WithdrawRequested(id, msg.sender, sAmount, block.timestamp);
        return id;
    }

    /**
     * @notice SuperCluster creates a withdraw request for a user.
     * @dev Only callable by SuperCluster.
     * @param user User address.
     * @param sAmount Amount of sToken to withdraw.
     * @return id Withdraw request ID.
     */
    function autoRequest(address user, uint256 sAmount) external returns (uint256) {
        require(msg.sender == superCluster, "Only SuperCluster");
        require(sAmount > 0, "Zero amount");

        uint256 id = nextRequestId++;
        Request storage r = requests[id];
        r.user = user;
        r.sAmount = sAmount;
        r.requestedAt = block.timestamp;
        r.finalized = false;
        r.claimed = false;
        r.availableAt = 0;
        r.baseAmount = 0;
        r.baseAmount = sAmount;

        userRequests[user].push(id);

        emit WithdrawRequested(id, user, sAmount, block.timestamp);
        return id;
    }

    /**
     * @notice Create a withdraw request for a user (external).
     * @param user User address.
     * @param sAmount Amount of sToken to withdraw.
     * @return id Withdraw request ID.
     */
    function requestWithdrawForUser(address user, uint256 sAmount) external returns (uint256) {
        require(msg.sender != address(0), "Invalid sender");
        require(sAmount > 0, "Zero amount");

        // Transfer sToken from SuperCluster to Withdraw contract
        bool ok = sToken.transferFrom(msg.sender, address(this), sAmount);
        require(ok, "sToken transfer failed");

        uint256 id = nextRequestId++;
        Request storage r = requests[id];
        r.user = user;
        r.sAmount = sAmount;
        r.requestedAt = block.timestamp;

        emit WithdrawRequested(id, user, sAmount, block.timestamp);
        return id;
    }

    /**
     * @notice Operator funds base tokens to fulfill claims.
     * @dev Owner should call after unstaking or off-chain conversion.
     * @param amount Amount of base token to fund.
     */
    function fund(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero fund");
        baseToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount, baseToken.balanceOf(address(this)));
    }

    /**
     * @notice Operator processes a withdraw for a user (burns sToken, sends base token).
     * @param user User address.
     * @param sAmount Amount of sToken.
     * @param baseAmount Amount of base token.
     */
    function processWithdraw(address user, uint256 sAmount, uint256 baseAmount) external onlyOwner {
        require(user != address(0), "Invalid user");
        require(baseAmount > 0 && sAmount > 0, "Zero amount");
        require(baseToken.balanceOf(address(this)) >= baseAmount, "Insufficient base balance");

        sToken.transferFrom(user, address(this), sAmount);
        sToken.burn(address(this), sAmount);

        baseToken.transfer(user, baseAmount);

        uint256 id = nextRequestId++;
        Request storage r = requests[id];
        r.user = user;
        r.sAmount = sAmount;
        r.baseAmount = baseAmount;
        r.requestedAt = block.timestamp;
        r.finalized = true;
        r.claimed = true;
        r.availableAt = block.timestamp;

        emit WithdrawClaimed(id, user, baseAmount, block.timestamp);
    }

    /**
     * @notice Finalize a pending withdraw request.
     * @dev Marks request as ready to be claimed after optional delay.
     * @param id Withdraw request ID.
     * @param baseAmount Amount of base token available for claim.
     */
    function finalizeWithdraw(uint256 id, uint256 baseAmount) external onlyOwner {
        Request storage r = requests[id];
        require(r.user != address(0), "Invalid request");
        require(!r.finalized, "Already finalized");
        require(!r.claimed, "Already claimed");
        require(baseAmount > 0, "Zero base amount");

        // Basic safety: ensure contract has enough base tokens to cover
        require(baseToken.balanceOf(address(this)) >= baseAmount, "Insufficient base funds");

        r.baseAmount = baseAmount;
        r.finalized = true;
        r.availableAt = block.timestamp + withdrawDelay;

        emit WithdrawFinalized(id, baseAmount, r.availableAt, block.timestamp);
    }

    /**
     * @notice Claim finalized withdraw after delay.
     * @param id Withdraw request ID.
     */
    function claim(uint256 id) external {
        Request storage r = requests[id];
        require(r.user != address(0), "Invalid request");
        require(!r.claimed, "Already claimed");
        require(r.finalized, "Not finalized yet");
        require(block.timestamp >= r.availableAt, "Not available yet");

        if (msg.sender != r.user && msg.sender != owner()) {
            revert("Not request owner");
        }

        uint256 baseAmount = r.baseAmount;
        require(baseAmount > 0, "Zero base amount");

        r.claimed = true;

        baseToken.safeTransfer(r.user, baseAmount);

        emit WithdrawClaimed(id, r.user, baseAmount, block.timestamp);
    }

    /**
     * @notice Get full details for a withdraw request.
     * @param id Withdraw request ID.
     * @return user Request owner.
     * @return sAmount sToken amount.
     * @return baseAmount Base token amount.
     * @return requestedAt Timestamp of request.
     * @return availableAt Timestamp when claim is available.
     * @return finalized Whether finalized.
     * @return claimed Whether claimed.
     */
    function getRequest(uint256 id)
        external
        view
        returns (
            address user,
            uint256 sAmount,
            uint256 baseAmount,
            uint256 requestedAt,
            uint256 availableAt,
            bool finalized,
            bool claimed
        )
    {
        Request storage r = requests[id];
        return (r.user, r.sAmount, r.baseAmount, r.requestedAt, r.availableAt, r.finalized, r.claimed);
    }

    /**
     * @notice Get base token balance of this contract.
     * @return Base token balance.
     */
    function contractBaseBalance() external view returns (uint256) {
        return baseToken.balanceOf(address(this));
    }

    /**
     * @notice Get sToken balance of this contract.
     * @return sToken balance.
     */
    function contractSTokenBalance() external view returns (uint256) {
        return IERC20(address(sToken)).balanceOf(address(this));
    }

    /**
     * @notice Set withdraw delay (seconds).
     * @param _delay New delay in seconds.
     */
    function setWithdrawDelay(uint256 _delay) external onlyOwner {
        withdrawDelay = _delay;
    }

    /**
     * @notice Emergency withdraw base tokens to owner.
     * @param amount Amount to withdraw.
     * @param to Recipient address.
     */
    function emergencyWithdrawBase(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid to");
        baseToken.safeTransfer(to, amount);
    }

    /**
     * @notice Emergency withdraw sTokens to owner.
     * @param amount Amount to withdraw.
     * @param to Recipient address.
     */
    function emergencyWithdrawSToken(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid to");
        IERC20(address(sToken)).safeTransfer(to, amount);
    }

    /**
     * @notice Returns all withdraw request IDs for a given user.
     * @param user The user address.
     * @return Array of withdraw request IDs belonging to the user.
     */
    function getRequestsOf(address user) external view returns (uint256[] memory) {
        return userRequests[user];
    }
}
