// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ISToken
 * @notice Interface for rebasing sToken contracts in SuperCluster.
 *         - Defines standard ERC20-like functions plus burn for protocol integration.
 *         - Used by WithdrawManager and protocol contracts for transfers and burning.
 * @author Super Cluster Dev Team
 */
interface ISToken {
    /**
     * @notice Transfer sToken from one address to another.
     * @param from Address to send tokens from.
     * @param to Address to send tokens to.
     * @param amount Amount of tokens to transfer.
     * @return True if transfer succeeds.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /**
     * @notice Get sToken balance of an account.
     * @param account Address to query.
     * @return Balance of sToken.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Burn sToken from an account (for withdrawals).
     * @param from Address to burn tokens from.
     * @param amount Amount of tokens to burn.
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Get allowance for spender.
     * @param owner Owner address.
     * @param spender Spender address.
     * @return Allowance amount.
     */
    function allowance(address owner, address spender) external view returns (uint256);
}
