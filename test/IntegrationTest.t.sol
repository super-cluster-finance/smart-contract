// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SuperClusterTest, console, MockIDRX, Withdraw} from "./SuperClusterTest.t.sol";

contract IntegrationTest is SuperClusterTest {
    function test_Integration_FullUserFlow() public {
        console.log("=== Testing Full User Flow ===");

        // User deposits to SuperCluster
        vm.startPrank(user1);
        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);
        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);

        uint256 sTokenBalance = sToken.balanceOf(user1);
        assertEq(sTokenBalance, DEPOSIT_AMOUNT);
        console.log("User deposited and received sTokens");
        vm.stopPrank();

        // Check adapter balances
        uint256 ionicBalance = ionicAdapter.getBalance();
        uint256 morphoBalance = morphoAdapter.getBalance();

        assertGt(ionicBalance, 0);
        assertGt(morphoBalance, 0);
        console.log("Pilot invested in adapters");
        console.log("Ionic balance:", ionicBalance);
        console.log("Morpho balance:", morphoBalance);

        // Check total AUM calculation
        uint256 totalAUM = superCluster.calculateTotalAUM();
        assertGt(totalAUM, 0);
        console.log("Total AUM calculated:", totalAUM);

        // Trigger rebase
        vm.warp(block.timestamp + 1 days);
        idrx.approve(address(superCluster), 100e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 100e18);
        superCluster.rebase();
        console.log("Rebase completed");

        // Simulate yield and rebase again
        idrx.approve(address(superCluster), 100e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 100e18);
        idrx.approve(address(superCluster), 50e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 50e18);

        vm.warp(block.timestamp + 1 days);
        superCluster.rebase();

        // User's sToken balance should increase due to rebase
        uint256 newSTokenBalance = sToken.balanceOf(user1);
        assertGt(newSTokenBalance, sTokenBalance, "Balance should increase after yield");
        console.log("After yield - sToken balance:", newSTokenBalance);

        uint256 idrxBeforeWithdraw = idrx.balanceOf(user1);

        Withdraw withdrawManager = Withdraw(superCluster.withdrawManager());
        console.log("Balance IDRX WithdrawManager before finalize:", idrx.balanceOf(address(withdrawManager)));

        // --- Withdraw flow ---
        vm.startPrank(user1);
        superCluster.withdraw(address(pilot), address(idrx), newSTokenBalance);
        vm.stopPrank();

        // Fund WithdrawManager with enough IDRX for the withdrawal (including yield)
        vm.prank(owner);
        idrx.approve(address(superCluster), newSTokenBalance);
        superCluster.receiveAndInvest(address(pilot), address(idrx), newSTokenBalance);
        console.log("WithdrawManager balance after transfer:", idrx.balanceOf(address(withdrawManager)));

        // Get latest requestId for user1
        uint256 requestId = withdrawManager.nextRequestId() - 1;

        // Claim
        vm.warp(block.timestamp + 4 days);
        vm.prank(user1);
        withdrawManager.claim(requestId);

        uint256 sTokenAfterWithdraw = sToken.balanceOf(user1);
        assertEq(sTokenAfterWithdraw, 0, "User sToken should be zero after withdraw");

        uint256 idrxAfterWithdraw = idrx.balanceOf(user1) - idrxBeforeWithdraw;
        console.log("User1 IDRX after withdraw:", idrxAfterWithdraw);
        assertApproxEqRel(
            idrxAfterWithdraw,
            newSTokenBalance,
            1e16,
            "User1 should receive IDRX equal to sToken withdrawn (including yield)"
        );

        console.log("=== Full Integration Test Complete ===");
    }

    function test_Integration_MultipleUsers() public {
        console.log("=== Testing Multiple Users ===");

        uint256 depositAmount1 = 1000e18;
        uint256 depositAmount2 = 2000e18;

        // User 1 deposits
        vm.startPrank(user1);
        idrx.approve(address(superCluster), depositAmount1);
        superCluster.deposit(address(pilot), address(idrx), depositAmount1);
        vm.stopPrank();

        // User1 initial balance
        uint256 user1Balance = sToken.balanceOf(user1);
        assertEq(user1Balance, depositAmount1, "User1 balance should be 1:1 on first deposit");

        // Simulate yield
        idrx.approve(address(superCluster), 150e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 150e18);

        // Rebase after yield
        vm.warp(block.timestamp + 1 days);
        superCluster.rebase();

        // User1 balance should increase after yield
        uint256 user1BalanceAfterYield = sToken.balanceOf(user1);
        assertGt(user1BalanceAfterYield, depositAmount1, "User1 balance should increase after yield");
        console.log("User1 balance after first yield:", user1BalanceAfterYield);

        // User 2 deposits after yield
        vm.startPrank(user2);
        idrx.approve(address(superCluster), depositAmount2);
        superCluster.deposit(address(pilot), address(idrx), depositAmount2);
        vm.stopPrank();

        // User2 should get 1:1 sToken
        uint256 user2Balance = sToken.balanceOf(user2);
        console.log("User2 balance received:", user2Balance);
        console.log("Deposit amount 2:", depositAmount2);
        assertApproxEqRel(user2Balance, depositAmount2, 1e16); // 1% tolerance
        console.log("User2 balance received:", user2Balance);

        // Check balances after user2 deposit
        uint256 balance1 = sToken.balanceOf(user1);
        uint256 balance2 = sToken.balanceOf(user2);
        console.log("User1 sToken balance:", balance1);
        console.log("User2 sToken balance:", balance2);

        // Simulate another yield
        idrx.approve(address(superCluster), 200e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 200e18);

        // Rebase again
        vm.warp(block.timestamp + 1 days);
        superCluster.rebase();

        // Check new balances (should increase proportionally)
        uint256 newBalance1 = sToken.balanceOf(user1);
        uint256 newBalance2 = sToken.balanceOf(user2);
        console.log("User1 balance after second yield:", newBalance1);
        console.log("User2 balance after second yield:", newBalance2);

        assertGt(newBalance1, balance1, "User1 balance should increase after second yield");
        assertGt(newBalance2, balance2, "User2 balance should increase after second yield");

        // Withdraw both users
        vm.startPrank(user1);
        superCluster.withdraw(address(pilot), address(idrx), newBalance1);
        vm.stopPrank();
        vm.startPrank(user2);
        superCluster.withdraw(address(pilot), address(idrx), newBalance2);
        vm.stopPrank();

        assertEq(sToken.balanceOf(user1), 0, "User1 sToken should be zero after withdraw");
        assertLe(sToken.balanceOf(user2), 1, "User2 sToken should be zero (or 1 wei) after withdraw");

        console.log("Multiple users test complete");
        console.log("User1 balance after yield:", newBalance1);
        console.log("User2 balance after yield:", newBalance2);
    }

    function test_Integration_PilotStrategy() public {
        console.log("=== Testing Pilot Strategy Management ===");

        // Set up initial strategy
        address[] memory adapters = new address[](2);
        uint256[] memory allocations = new uint256[](2);
        adapters[0] = address(ionicAdapter);
        adapters[1] = address(morphoAdapter);
        allocations[0] = 7000; // 70% Ionic
        allocations[1] = 3000; // 30% Morpho

        pilot.setPilotStrategy(adapters, allocations);

        // Transfer funds to pilot
        bool status = idrx.transfer(address(pilot), DEPOSIT_AMOUNT);
        require(status, "Transfer failed");

        // Invest using strategy
        pilot.invest(DEPOSIT_AMOUNT, adapters, allocations);

        // Check allocation
        uint256 ionicBalance = ionicAdapter.getBalance();
        uint256 morphoBalance = morphoAdapter.getBalance();

        uint256 expectedIonic = (DEPOSIT_AMOUNT * 7000) / 10000;
        uint256 expectedMorpho = (DEPOSIT_AMOUNT * 3000) / 10000;

        assertApproxEqRel(ionicBalance, expectedIonic, 1e16); // 1% tolerance
        assertApproxEqRel(morphoBalance, expectedMorpho, 1e16);

        console.log("Strategy allocation working correctly");
        console.log("Expected Ionic:", expectedIonic, "Actual:", ionicBalance);
        console.log("Expected Morpho:", expectedMorpho, "Actual:", morphoBalance);

        // Test strategy update
        allocations[0] = 5000; // 50% Ionic
        allocations[1] = 5000; // 50% Morpho

        pilot.setPilotStrategy(adapters, allocations);

        (, uint256[] memory newAllocations) = pilot.getStrategy();
        assertEq(newAllocations[0], 5000);
        assertEq(newAllocations[1], 5000);

        console.log("Strategy updated successfully");
    }

    function test_Integration_AdapterInteraction() public {
        console.log("=== Testing Adapter Interactions ===");

        uint256 depositAmount = 1000e18;

        // Test Ionic Adapter
        idrx.approve(address(ionicAdapter), depositAmount);
        uint256 ionicShares = ionicAdapter.deposit(depositAmount);

        uint256 ionicBalance = ionicAdapter.getBalance();
        assertGt(ionicBalance, 0);
        console.log("IonicAdapter deposit successful, balance:", ionicBalance);

        // Test conversion functions
        uint256 convertedShares = ionicAdapter.convertToShares(depositAmount);
        uint256 convertedAssets = ionicAdapter.convertToAssets(ionicShares);

        console.log("Converted shares:", convertedShares);
        console.log("Converted assets:", convertedAssets);

        // Test Morpho Adapter
        idrx.approve(address(morphoAdapter), depositAmount);
        uint256 morphoShares = morphoAdapter.deposit(depositAmount);

        uint256 morphoBalance = morphoAdapter.getBalance();
        assertGt(morphoBalance, 0);
        console.log("MorphoAdapter deposit successful, balance:", morphoBalance);

        // Test withdrawals
        uint256 withdrawnIonic = ionicAdapter.withdraw(ionicShares);
        uint256 withdrawnMorpho = morphoAdapter.withdraw(morphoShares);

        assertGt(withdrawnIonic, 0);
        assertGt(withdrawnMorpho, 0);

        console.log("Withdrawals successful");
        console.log("Withdrawn from Ionic:", withdrawnIonic);
        console.log("Withdrawn from Morpho:", withdrawnMorpho);
    }

    function test_Integration_ErrorHandling() public {
        console.log("=== Testing Error Handling ===");

        // Test SuperCluster errors
        vm.startPrank(user1);

        // Should fail: Zero amount
        vm.expectRevert();
        superCluster.deposit(address(pilot), address(idrx), 0);

        // Should fail: Unsupported token
        MockIDRX unsupportedToken = new MockIDRX();
        vm.expectRevert();
        superCluster.deposit(address(pilot), address(unsupportedToken), 1000e18);

        vm.stopPrank();

        // Test Adapter errors
        vm.expectRevert();
        ionicAdapter.deposit(0);

        vm.expectRevert();
        ionicAdapter.withdraw(1000e18); // No balance

        // Test Pilot errors
        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        adapters[0] = address(ionicAdapter);
        allocations[0] = 5000; // Invalid: not 100%

        vm.expectRevert();
        pilot.setPilotStrategy(adapters, allocations);

        console.log("Error handling tests passed");
    }

    function test_MultipleUsers_WrapUnwrap_WithRebaseYield() public {
        console.log("=== Testing Multiple Users Wrap/Unwrap with Rebasing Yield ===");

        uint256 depositAmount1 = 1000e18;
        uint256 depositAmount2 = 2000e18;

        // User 1 deposits and wraps
        vm.startPrank(user1);
        idrx.approve(address(superCluster), depositAmount1);
        superCluster.deposit(address(pilot), address(idrx), depositAmount1);
        sToken.approve(address(wsToken), depositAmount1);
        wsToken.wrap(depositAmount1);
        uint256 wsTokenBalance1 = wsToken.balanceOf(user1);
        assertEq(wsTokenBalance1, depositAmount1, "User1 wsToken balance should be 1:1");
        assertEq(sToken.balanceOf(user1), 0, "User1 sToken should be zero after wrap");
        vm.stopPrank();

        // User 2 deposits and wraps
        vm.startPrank(user2);
        idrx.approve(address(superCluster), depositAmount2);
        superCluster.deposit(address(pilot), address(idrx), depositAmount2);
        sToken.approve(address(wsToken), depositAmount2);
        wsToken.wrap(depositAmount2);
        uint256 wsTokenBalance2 = wsToken.balanceOf(user2);
        assertEq(wsTokenBalance2, depositAmount2, "User2 wsToken balance should be 1:1");
        assertEq(sToken.balanceOf(user2), 0, "User2 sToken should be zero after wrap");
        vm.stopPrank();

        // Simulate yield: add yield to pilot and rebase
        idrx.approve(address(superCluster), 300e18);
        superCluster.receiveAndInvest(address(pilot), address(idrx), 300e18);

        vm.warp(block.timestamp + 1 days);
        superCluster.rebase();

        // After rebase, wsToken contract's sToken balance should increase
        uint256 sTokenInWsToken = sToken.balanceOf(address(wsToken));
        assertGt(
            sTokenInWsToken, depositAmount1 + depositAmount2, "sToken in wsToken contract should increase after yield"
        );
        console.log("sToken in wsToken contract after rebase:", sTokenInWsToken);

        uint256 wsPerSt = wsToken.wsTokenPerStToken();
        console.log("Price 1 sToken in wsToken (1e18):", wsPerSt);

        // User 1 unwraps
        vm.startPrank(user1);
        wsToken.unwrap(wsTokenBalance1);
        uint256 sTokenAfterUnwrap1 = sToken.balanceOf(user1);
        assertGt(sTokenAfterUnwrap1, depositAmount1, "User1 should receive more sToken after unwrap due to yield");
        assertEq(wsToken.balanceOf(user1), 0, "User1 wsToken should be zero after unwrap");
        vm.stopPrank();

        // User 2 unwraps
        vm.startPrank(user2);
        wsToken.unwrap(wsTokenBalance2);
        uint256 sTokenAfterUnwrap2 = sToken.balanceOf(user2);
        assertGt(sTokenAfterUnwrap2, depositAmount2, "User2 should receive more sToken after unwrap due to yield");
        assertEq(wsToken.balanceOf(user2), 0, "User2 wsToken should be zero after unwrap");
        vm.stopPrank();

        // Proportionality check
        uint256 expectedRatio = (depositAmount2 * 1e18) / depositAmount1;
        uint256 actualRatio = (sTokenAfterUnwrap2 * 1e18) / sTokenAfterUnwrap1;
        assertApproxEqRel(actualRatio, expectedRatio, 1e16); // 1% tolerance

        console.log("User1 sToken after unwrap:", sTokenAfterUnwrap1);

        vm.startPrank(user1);
        console.log("Balance before withdraw:", idrx.balanceOf(user1));

        superCluster.withdraw(address(pilot), address(idrx), sTokenAfterUnwrap1);
        vm.stopPrank();

        vm.warp(block.timestamp + 4 days);
        uint256 balanceIdrxBeforeWithdraw = idrx.balanceOf(user1);
        console.log("Balance idx user before withdraw:", balanceIdrxBeforeWithdraw);
        vm.prank(owner);
        Withdraw withdrawManager = Withdraw(superCluster.withdrawManager());
        idrx.approve(address(superCluster), sTokenAfterUnwrap1);
        superCluster.receiveAndInvest(address(pilot), address(idrx), sTokenAfterUnwrap1);

        console.log("Balance manager transfer", idrx.balanceOf(address(withdrawManager)));
        console.log("Widraw Manager amount:", sTokenAfterUnwrap1);
        uint256 requestId = withdrawManager.nextRequestId() - 1;

        vm.prank(user1);
        withdrawManager.claim(requestId);

        uint256 sTokenAfterWithdraw1 = sToken.balanceOf(user1);
        console.log("User1 sToken after withdraw:", sTokenAfterWithdraw1);
        assertEq(sTokenAfterWithdraw1, 0, "User1 sToken should be zero after withdraw");

        uint256 balanceIdrxAfterWithdraw = idrx.balanceOf(user1);
        uint256 idrxAfterWithdraw1 = balanceIdrxAfterWithdraw - balanceIdrxBeforeWithdraw;
        console.log("User1 IDRX after withdraw:", idrxAfterWithdraw1);
        assertApproxEqRel(
            idrxAfterWithdraw1,
            sTokenAfterUnwrap1,
            1e16,
            "User1 should receive IDRX equal to sToken withdrawn (including yield)"
        );

        vm.startPrank(user2);
        console.log("Balance before withdraw:", idrx.balanceOf(user2));
        console.log("Withdrawing sToken amount:", sTokenAfterUnwrap2);

        superCluster.withdraw(address(pilot), address(idrx), sTokenAfterUnwrap2);
        vm.stopPrank();

        vm.warp(block.timestamp + 4 days);
        uint256 balanceIdrxBeforeWithdraw2 = idrx.balanceOf(user2);
        console.log("Balance idx user before withdraw:", balanceIdrxBeforeWithdraw2);

        idrx.approve(address(superCluster), sTokenAfterUnwrap2);
        superCluster.receiveAndInvest(address(pilot), address(idrx), sTokenAfterUnwrap2);

        console.log("Balance manager transfer", idrx.balanceOf(address(withdrawManager)));
        console.log("Widraw Manager amount:", sTokenAfterUnwrap2);
        requestId = withdrawManager.nextRequestId() - 1;
        console.log("Balance stoken before withdraw:", sToken.balanceOf(user2));
        console.log("Stoken to withdraw:", sTokenAfterUnwrap2);

        vm.prank(user2);
        withdrawManager.claim(requestId);

        uint256 sTokenAfterWithdraw2 = sToken.balanceOf(user2);
        console.log("User1 sToken after withdraw:", sTokenAfterWithdraw2);
        assertEq(sTokenAfterWithdraw2, 0, "User1 sToken should be zero after withdraw");

        uint256 balanceIdrxAfterWithdraw2 = idrx.balanceOf(user2);
        uint256 idrxAfterWithdraw2 = balanceIdrxAfterWithdraw2 - balanceIdrxBeforeWithdraw2;
        console.log("User1 IDRX after withdraw:", idrxAfterWithdraw2);
        assertApproxEqRel(
            idrxAfterWithdraw2,
            sTokenAfterUnwrap2,
            1e16,
            "User1 should receive IDRX equal to sToken withdrawn (including yield)"
        );

        console.log("Multiple users wrap/unwrap with rebasing yield test complete");
    }

    function test_flow_to_widraw() public {
        vm.startPrank(user1);
        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);
        uint256 idrxBeforeDeposit = idrx.balanceOf(user1);
        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);

        uint256 sTokenBalance = sToken.balanceOf(user1);
        assertEq(sTokenBalance, DEPOSIT_AMOUNT);
        console.log("User deposited and received sTokens");
        vm.stopPrank();

        // Check adapter balances
        uint256 ionicBalance = ionicAdapter.getBalance();
        uint256 morphoBalance = morphoAdapter.getBalance();

        assertGt(ionicBalance, 0);
        assertGt(morphoBalance, 0);
        console.log("Pilot invested in adapters");
        console.log("Ionic balance:", ionicBalance);
        console.log("Morpho balance:", morphoBalance);

        // Check total AUM calculation
        uint256 totalAUM = superCluster.calculateTotalAUM();
        assertGt(totalAUM, 0);
        console.log("Total AUM calculated:", totalAUM);

        vm.startPrank(user1);
        superCluster.withdraw(address(pilot), address(idrx), sTokenBalance);
        vm.stopPrank();

        uint256 balanceInWithdrawManager = idrx.balanceOf(address(superCluster.withdrawManager()));

        assertEq(balanceInWithdrawManager, DEPOSIT_AMOUNT, "WithdrawManager should have the withdrawn amount");

        Withdraw withdrawManager = Withdraw(superCluster.withdrawManager());

        vm.prank(user1);
        uint256[] memory myRequests = withdrawManager.getRequestsOf(address(user1));

        require(myRequests.length > 0, "No withdraw requests for user1");
        console.log("User1 withdraw requests:", myRequests[0]);

        vm.startPrank(user1);
        vm.warp(1 days);
        withdrawManager.claim(myRequests[0]);
        vm.stopPrank();

        uint256 idrxAfterWithdraw = idrx.balanceOf(user1);
        assertEq(idrxBeforeDeposit, idrxAfterWithdraw, "User1 should receive IDRX equal to sToken withdrawn");
    }
}
