// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Withdraw} from "../src/tokens/WithDraw.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Mock Tokens
contract BaseToken is ERC20("BaseToken", "BASE") {
    constructor() {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSToken is ERC20("SToken", "STK") {
    constructor() {
        _mint(msg.sender, 1_000_000 ether);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Test Withdraw.sol
contract WithdrawTest is Test {
    Withdraw public withdraw;
    BaseToken public baseToken;
    MockSToken public sToken;

    address public owner;
    address public user1;
    address public user2;
    address public superCluster; // mock SuperCluster

    uint256 public constant DELAY = 1 days;

    function setUp() public {
        owner = address(this);
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        superCluster = vm.addr(3);

        baseToken = new BaseToken();
        sToken = new MockSToken();

        withdraw = new Withdraw(address(sToken), address(baseToken), superCluster, DELAY);

        // Setup token balances & approvals
        sToken.mint(user1, 1000 ether);
        baseToken.mint(owner, 1000 ether);

        vm.prank(user1);
        sToken.approve(address(withdraw), type(uint256).max);

        baseToken.approve(address(withdraw), type(uint256).max);
    }

    /// --- test requestWithdraw()
    function test_RequestWithdraw() public {
        vm.prank(user1);
        uint256 requestId = withdraw.requestWithdraw(100 ether);

        (address reqUser, uint256 sAmount,,,, bool finalized, bool claimed) = withdraw.getRequest(requestId);
        assertEq(reqUser, user1);
        assertEq(sAmount, 100 ether);
        assertFalse(finalized);
        assertFalse(claimed);
    }

    /// --- test autoRequest() by superCluster
    function test_AutoRequest_FromSuperCluster() public {
        vm.prank(superCluster);
        uint256 requestId = withdraw.autoRequest(user1, 50 ether);

        (address reqUser, uint256 sAmount,,,, bool finalized, bool claimed) = withdraw.getRequest(requestId);
        assertEq(reqUser, user1);
        assertEq(sAmount, 50 ether);
        assertFalse(finalized);
        assertFalse(claimed);
    }

    /// --- test fund() from owner
    function test_FundBaseTokens() public {
        uint256 before = baseToken.balanceOf(address(withdraw));
        withdraw.fund(500 ether);
        uint256 afterBal = baseToken.balanceOf(address(withdraw));
        assertEq(afterBal - before, 500 ether);
    }

    /// --- test finalizeWithdraw()
    function test_FinalizeWithdraw() public {
        vm.prank(user1);
        uint256 requestId = withdraw.requestWithdraw(200 ether);

        withdraw.fund(500 ether);
        withdraw.finalizeWithdraw(requestId, 200 ether);

        (,, uint256 baseAmount,, uint256 availableAt, bool finalized, bool claimed) = withdraw.getRequest(requestId);
        assertEq(baseAmount, 200 ether);
        assertTrue(finalized);
        assertFalse(claimed);
        assertGt(availableAt, 0);
    }

    /// --- test claim() after delay
    function test_ClaimAfterDelay() public {
        vm.prank(user1);
        uint256 requestId = withdraw.requestWithdraw(300 ether);

        withdraw.fund(500 ether);
        withdraw.finalizeWithdraw(requestId, 300 ether);

        vm.warp(block.timestamp + DELAY + 1);

        uint256 beforeBase = baseToken.balanceOf(user1);
        vm.prank(user1);
        withdraw.claim(requestId);
        uint256 afterBase = baseToken.balanceOf(user1);

        assertEq(afterBase - beforeBase, 300 ether);
    }

    /// --- test processWithdraw() direct (instant claim by owner)
    function test_ProcessWithdraw_ByOwner() public {
        uint256 beforeBase = baseToken.balanceOf(user1);

        withdraw.fund(1000 ether);
        withdraw.processWithdraw(user1, 100 ether, 100 ether);

        uint256 afterBase = baseToken.balanceOf(user1);
        assertEq(afterBase - beforeBase, 100 ether);
    }

    /// --- test emergencyWithdrawBase()
    function test_EmergencyWithdrawBase() public {
        withdraw.fund(100 ether);
        uint256 beforeOwner = baseToken.balanceOf(owner);
        withdraw.emergencyWithdrawBase(50 ether, owner);
        uint256 afterOwner = baseToken.balanceOf(owner);
        assertEq(afterOwner - beforeOwner, 50 ether);
    }

    /// --- test emergencyWithdrawSToken()
    function test_EmergencyWithdrawSToken() public {
        vm.prank(user1);
        withdraw.requestWithdraw(100 ether);

        uint256 beforeOwner = sToken.balanceOf(owner);
        withdraw.emergencyWithdrawSToken(50 ether, owner);
        uint256 afterOwner = sToken.balanceOf(owner);
        assertEq(afterOwner - beforeOwner, 50 ether);
    }
}
