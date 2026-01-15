// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SuperCluster} from "../src/SuperCluster.sol";
import {SToken} from "../src/tokens/SToken.sol";
import {WsToken} from "../src/tokens/WsToken.sol";
import {Pilot} from "../src/pilot/Pilot.sol";
import {InitAdapter} from "../src/adapter/InitAdapter.sol";
import {CompoundAdapter} from "../src/adapter/CompoundAdapter.sol";
import {DolomiteAdapter} from "../src/adapter/DolomiteAdapter.sol";
import {InitLendingPool} from "../src/mocks/MockInit.sol";
import {Comet} from "../src/mocks/MockCompound.sol";
import {DolomiteMargin} from "../src/mocks/MockDolomite.sol";
import {MockIDRX} from "../src/mocks/tokens/MockIDRX.sol";
import {Withdraw} from "../src/tokens/WithDraw.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract SuperClusterTest is Test {
    SuperCluster public superCluster;
    SToken public sToken;
    WsToken public wsToken;
    MockIDRX public idrx;
    Pilot public pilot;
    InitAdapter public initAdapter;
    CompoundAdapter public compoundAdapter;
    DolomiteAdapter public dolomiteAdapter;
    InitLendingPool public mockInit;
    Comet public mockCompound;
    DolomiteMargin public mockDolomite;
    uint256 public dolomiteMarketId;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant INITIAL_SUPPLY = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        idrx = new MockIDRX();
        idrx.mint(owner, INITIAL_SUPPLY);
        idrx.mint(user1, INITIAL_SUPPLY);
        idrx.mint(user2, INITIAL_SUPPLY);

        superCluster = new SuperCluster(address(idrx));

        sToken = superCluster.sToken();
        wsToken = superCluster.wsToken();

        MockOracle mockOracle = new MockOracle();
        uint256 ltv = 800000000000000000; // 80% LTV

        // Deploy Mock protocols
        _deployMockProtocols(address(mockOracle), ltv);

        // Deploy adapters
        _deployAdapters();

        // Deploy pilot
        _deployPilot();

        // Setup pilot strategy
        _setupPilotStrategy();

        superCluster.registerPilot(address(pilot), address(idrx));

        // (Opsional) log untuk debugging
        console.log("SuperCluster:", address(superCluster));
        console.log("SToken:", address(sToken));
    }

    function _deployMockProtocols(address _mockOracle, uint256 _ltv) internal {
        // Deploy MockInit (Init Capital style)
        mockInit = new InitLendingPool(address(idrx), address(idrx), address(_mockOracle), _ltv);

        // Deploy MockCompound (Compound V3 style)
        mockCompound = new Comet(address(idrx), address(idrx), address(_mockOracle), _ltv);

        // Deploy MockDolomite (Margin Account style)
        mockDolomite = new DolomiteMargin(address(_mockOracle), _ltv);
        // Add market for IDRX
        dolomiteMarketId = mockDolomite.addMarket(address(idrx));
    }

    function _deployAdapters() internal {
        // Deploy InitAdapter (30%)
        initAdapter = new InitAdapter(address(idrx), address(mockInit), "Init Capital", "Balanced Lending");

        // Deploy CompoundAdapter (40%)
        compoundAdapter = new CompoundAdapter(address(idrx), address(mockCompound), "Compound V3", "High Yield Lending");

        // Deploy DolomiteAdapter (30%)
        dolomiteAdapter = new DolomiteAdapter(
            address(idrx), address(mockDolomite), dolomiteMarketId, "Dolomite", "Margin Lending"
        );
    }

    function _deployPilot() internal {
        pilot = new Pilot(
            "DeFi Yield Pilot",
            "Multi-protocol DeFi strategies focusing on lending protocols",
            address(idrx),
            address(superCluster)
        );
    }

    function _setupPilotStrategy() internal {
        address[] memory adapters = new address[](3);
        uint256[] memory allocations = new uint256[](3);

        adapters[0] = address(initAdapter);
        adapters[1] = address(compoundAdapter);
        adapters[2] = address(dolomiteAdapter);
        allocations[0] = 3000; // 30% Init
        allocations[1] = 4000; // 40% Compound
        allocations[2] = 3000; // 30% Dolomite

        pilot.setPilotStrategy(adapters, allocations);
    }

    // ==================== SUPERCLUSTER TESTS ====================

    function test_SuperCluster_Deploy() public view {
        assertEq(sToken.name(), "sMockIDRX");
        assertEq(wsToken.name(), "wsMockIDRX");
        assertTrue(superCluster.supportedTokens(address(idrx)));
        assertEq(superCluster.owner(), owner);
    }

    function test_SuperCluster_Deposit() public {
        vm.startPrank(user1);
        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);

        uint256 balanceBefore = sToken.balanceOf(user1);

        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);

        uint256 balanceAfter = sToken.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT); // 1:1
        vm.stopPrank();
    }

    function test_SuperCluster_Withdraw() public {
        console.log("=== TEST: SuperCluster Withdraw Flow ===");

        // === STEP 1: Deposit ===
        vm.startPrank(user1);
        uint256 idrxBalanceBefore = idrx.balanceOf(user1);
        console.log("User1 IDRX balance before deposit:", idrxBalanceBefore);

        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);
        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 sTokenBalanceAfterDeposit = sToken.balanceOf(user1);
        console.log("User1 sToken after deposit:", sTokenBalanceAfterDeposit);
        assertGt(sTokenBalanceAfterDeposit, 0, "Deposit should mint sToken");

        // === STEP 2: Withdraw Request ===
        vm.startPrank(user1);
        console.log("Requesting withdraw of", DEPOSIT_AMOUNT, "IDRX...");
        superCluster.withdraw(address(pilot), address(idrx), DEPOSIT_AMOUNT);
        vm.stopPrank();

        // check pending withdraw
        Withdraw withdrawManager = Withdraw(superCluster.withdrawManager());
        (,, uint256 pendingAmount,,,,) = withdrawManager.requests(1);
        console.log("Pending withdraw amount:", pendingAmount);
        assertEq(pendingAmount, DEPOSIT_AMOUNT, "Withdraw request should be recorded");

        // === STEP 3: Warp time (simulate delay period) ===
        vm.warp(block.timestamp + 1 days);

        // === STEP 4: Finalize withdraw (by SuperCluster) ===
        // fund withdrawManager first
        idrx.transfer(address(withdrawManager), DEPOSIT_AMOUNT);

        console.log("Withdraw finalized. WithdrawManager IDRX balance:", idrx.balanceOf(address(withdrawManager)));

        // === STEP 5: Warp again for claim delay ===
        vm.warp(block.timestamp + 1 days);

        // === STEP 6: User claim ===
        uint256 idrxBeforeClaim = idrx.balanceOf(user1);
        vm.startPrank(user1);
        withdrawManager.claim(1);
        vm.stopPrank();

        uint256 idrxAfterClaim = idrx.balanceOf(user1);

        console.log("User1 IDRX before claim:", idrxBeforeClaim);
        console.log("User1 IDRX after claim:", idrxAfterClaim);
        console.log("WithdrawManager IDRX after claim:", idrx.balanceOf(address(withdrawManager)));

        // === Assertion ===
        assertEq(idrxAfterClaim, idrxBalanceBefore, "User1 should have full balance restored after withdraw and claim");

        console.log("=== Withdraw flow complete and verified ===");
    }

    function test_SuperCluster_claim() public {
        // Deposit
        vm.startPrank(user1);
        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);
        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Withdraw
        vm.startPrank(user1);
        superCluster.withdraw(address(pilot), address(idrx), DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Fund withdraw manager
        Withdraw withdrawManager = Withdraw(superCluster.withdrawManager());
        idrx.transfer(address(withdrawManager), DEPOSIT_AMOUNT);

        // Warp time
        vm.warp(block.timestamp + 1 days);

        // Claim
        vm.prank(user1);
        withdrawManager.claim(1);

        // Assert
        uint256 userBalanceAfter = idrx.balanceOf(user1);
        assertEq(userBalanceAfter, INITIAL_SUPPLY, "User balance should be restored after claim");
    }

    function test_SuperCluster_RegisterPilot() public {
        address newPilot = makeAddr("newPilot");

        superCluster.registerPilot(newPilot, address(idrx));

        assertTrue(superCluster.registeredPilots(newPilot));
        address[] memory pilots = superCluster.getPilots();
        bool found = false;
        for (uint256 i = 0; i < pilots.length; i++) {
            if (pilots[i] == newPilot) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_SuperCluster_Rebase() public {
        // Deposit to SuperCluster
        vm.startPrank(user1);
        idrx.approve(address(superCluster), DEPOSIT_AMOUNT);
        superCluster.deposit(address(pilot), address(idrx), DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 balanceBefore = sToken.balanceOf(user1);

        // Simulate yield/rebase 10%
        uint256 yieldAmount = DEPOSIT_AMOUNT / 10;
        bool status = idrx.transfer(address(pilot), yieldAmount);
        require(status, "Transfer failed");
        vm.startPrank(owner);
        superCluster.rebase();

        uint256 balanceAfter = sToken.balanceOf(user1);
        assertEq(balanceAfter, balanceBefore + yieldAmount);
    }

    function test_Fail_SuperCluster_Deposit_Zero_Amount() public {
        vm.prank(user1);
        vm.expectRevert();
        superCluster.deposit(address(pilot), address(idrx), 0);
    }

    function test_Fail_SuperCluster_Deposit_Unsupported_Token() public {
        MockIDRX unsupportedToken = new MockIDRX();
        vm.prank(user1);
        vm.expectRevert();
        superCluster.deposit(address(pilot), address(unsupportedToken), DEPOSIT_AMOUNT);
    }

    // ==================== STOKEN TESTS ====================

    function test_SToken_InitialState() public view {
        assertEq(sToken.name(), "sMockIDRX");
        assertEq(sToken.symbol(), "sIDRX");
        assertEq(sToken.decimals(), 18);
        assertEq(sToken.totalSupply(), 0);
    }

    function test_Fail_SToken_UnauthorizedMint() public {
        vm.prank(user1);
        vm.expectRevert("Unauthorized");
        sToken.mint(user1, 1000e18);
    }

    // ==================== PILOT TESTS ====================

    function test_Pilot_InitialState() public view {
        assertEq(pilot.name(), "DeFi Yield Pilot");
        assertTrue(bytes(pilot.description()).length > 0);
        assertEq(pilot.TOKEN(), address(idrx));
    }

    function test_Pilot_SetStrategy() public {
        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);

        adapters[0] = address(initAdapter);
        allocations[0] = 10000; // 100%

        pilot.setPilotStrategy(adapters, allocations);

        (address[] memory returnedAdapters, uint256[] memory returnedAllocations) = pilot.getStrategy();

        assertEq(returnedAdapters.length, 1);
        assertEq(returnedAllocations.length, 1);
        assertEq(returnedAdapters[0], address(initAdapter));
        assertEq(returnedAllocations[0], 10000);
    }

    function test_Pilot_Invest() public {
        // Transfer tokens to pilot
        bool status = idrx.transfer(address(pilot), DEPOSIT_AMOUNT);
        require(status, "Transfer failed");

        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        adapters[0] = address(initAdapter);
        allocations[0] = 10000;

        // Fund adapter with tokens first
        status = idrx.transfer(address(initAdapter), DEPOSIT_AMOUNT);
        require(status, "Transfer failed");

        pilot.invest(DEPOSIT_AMOUNT, adapters, allocations);

        // Check if adapter received tokens
        assertTrue(initAdapter.getBalance() > 0);
    }

    function test_Pilot_GetTotalValue() public {
        // Transfer some tokens to pilot (idle funds)
        bool status = idrx.transfer(address(pilot), 500e18);
        require(status, "Transfer failed");

        uint256 totalValue = pilot.getTotalValue();

        // Should include idle funds
        assertGe(totalValue, 500e18);
    }

    function test_Fail_Pilot_InvalidAllocation() public {
        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);

        adapters[0] = address(initAdapter);
        allocations[0] = 5000; // Only 50%, should fail

        vm.expectRevert();
        pilot.setPilotStrategy(adapters, allocations);
    }

    // ==================== INIT ADAPTER TESTS ====================

    function test_InitAdapter_InitialState() public view {
        assertEq(initAdapter.getProtocolName(), "Init Capital");
        assertEq(initAdapter.getPilotStrategy(), "Balanced Lending");
        assertEq(address(initAdapter.LENDING_POOL()), address(mockInit));
        assertTrue(initAdapter.isActive());
    }

    function test_InitAdapter_Deposit() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(initAdapter), depositAmount);

        uint256 shares = initAdapter.deposit(depositAmount);

        assertGt(shares, 0);
        assertGt(initAdapter.getBalance(), 0);
        assertEq(initAdapter.totalDeposited(), depositAmount);
    }

    function test_InitAdapter_Withdraw() public {
        uint256 depositAmount = 1000e18;

        // First deposit
        idrx.approve(address(initAdapter), depositAmount);
        uint256 shares = initAdapter.deposit(depositAmount);

        uint256 balanceBefore = idrx.balanceOf(address(this));

        // Withdraw
        uint256 withdrawn = initAdapter.withdraw(shares);

        uint256 balanceAfter = idrx.balanceOf(address(this));

        assertGt(withdrawn, 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_InitAdapter_ConvertToShares() public view {
        uint256 assets = 1000e18;
        uint256 shares = initAdapter.convertToShares(assets);

        // Should be 1:1 initially
        assertEq(shares, assets);
    }

    function test_InitAdapter_ConvertToAssets() public view {
        uint256 shares = 1000e18;
        uint256 assets = initAdapter.convertToAssets(shares);

        // Should be 1:1 initially
        assertEq(assets, shares);
    }

    function test_Fail_InitAdapter_DepositZero() public {
        idrx.approve(address(initAdapter), 0);
        vm.expectRevert();
        initAdapter.deposit(0);
    }

    function test_Fail_InitAdapter_WithdrawExcessive() public {
        idrx.approve(address(initAdapter), 0);
        vm.expectRevert();
        initAdapter.withdraw(1000e18); // No deposits made
    }

    // ==================== COMPOUND ADAPTER TESTS ====================

    function test_CompoundAdapter_InitialState() public view {
        assertEq(compoundAdapter.getProtocolName(), "Compound V3");
        assertEq(compoundAdapter.getPilotStrategy(), "High Yield Lending");
        assertEq(address(compoundAdapter.COMET()), address(mockCompound));
        assertTrue(compoundAdapter.isActive());
    }

    function test_CompoundAdapter_Deposit() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(compoundAdapter), depositAmount);

        uint256 shares = compoundAdapter.deposit(depositAmount);

        assertGt(shares, 0);
        assertGt(compoundAdapter.getBalance(), 0);
        assertEq(compoundAdapter.totalDeposited(), depositAmount);
    }

    function test_CompoundAdapter_Withdraw() public {
        uint256 depositAmount = 1000e18;

        // First deposit
        idrx.approve(address(compoundAdapter), depositAmount);
        uint256 shares = compoundAdapter.deposit(depositAmount);

        uint256 balanceBefore = idrx.balanceOf(address(this));

        // Withdraw
        uint256 withdrawn = compoundAdapter.withdraw(shares);

        uint256 balanceAfter = idrx.balanceOf(address(this));

        assertGt(withdrawn, 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_CompoundAdapter_ConvertToShares() public view {
        uint256 assets = 1000e18;
        uint256 shares = compoundAdapter.convertToShares(assets);

        // Should be 1:1 in Compound V3
        assertEq(shares, assets);
    }

    function test_CompoundAdapter_ConvertToAssets() public view {
        uint256 shares = 1000e18;
        uint256 assets = compoundAdapter.convertToAssets(shares);

        // Should be 1:1 in Compound V3
        assertEq(assets, shares);
    }

    function test_Fail_CompoundAdapter_DepositZero() public {
        idrx.approve(address(compoundAdapter), 0);
        vm.expectRevert();
        compoundAdapter.deposit(0);
    }

    function test_Fail_CompoundAdapter_WithdrawExcessive() public {
        idrx.approve(address(compoundAdapter), 0);
        vm.expectRevert();
        compoundAdapter.withdraw(1000e18); // No deposits made
    }

    // ==================== DOLOMITE ADAPTER TESTS ====================

    function test_DolomiteAdapter_InitialState() public view {
        assertEq(dolomiteAdapter.getProtocolName(), "Dolomite");
        assertEq(dolomiteAdapter.getPilotStrategy(), "Margin Lending");
        assertEq(address(dolomiteAdapter.DOLOMITE()), address(mockDolomite));
        assertEq(dolomiteAdapter.MARKET_ID(), dolomiteMarketId);
        assertTrue(dolomiteAdapter.isActive());
    }

    function test_DolomiteAdapter_Deposit() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(dolomiteAdapter), depositAmount);

        uint256 shares = dolomiteAdapter.deposit(depositAmount);

        assertGt(shares, 0);
        assertGt(dolomiteAdapter.getBalance(), 0);
        assertEq(dolomiteAdapter.totalDeposited(), depositAmount);
    }

    function test_DolomiteAdapter_Withdraw() public {
        uint256 depositAmount = 1000e18;

        // First deposit
        idrx.approve(address(dolomiteAdapter), depositAmount);
        uint256 shares = dolomiteAdapter.deposit(depositAmount);

        uint256 balanceBefore = idrx.balanceOf(address(this));

        // Withdraw
        uint256 withdrawn = dolomiteAdapter.withdraw(shares);

        uint256 balanceAfter = idrx.balanceOf(address(this));

        assertGt(withdrawn, 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_DolomiteAdapter_GetAccountBalance() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(dolomiteAdapter), depositAmount);
        dolomiteAdapter.deposit(depositAmount);

        (bool sign, uint256 value) = dolomiteAdapter.getAccountBalance();

        assertTrue(sign); // Positive balance
        assertGt(value, 0);
    }

    function test_DolomiteAdapter_ConvertToShares() public view {
        uint256 assets = 1000e18;
        uint256 shares = dolomiteAdapter.convertToShares(assets);

        // Should be 1:1 in Dolomite
        assertEq(shares, assets);
    }

    function test_DolomiteAdapter_ConvertToAssets() public view {
        uint256 shares = 1000e18;
        uint256 assets = dolomiteAdapter.convertToAssets(shares);

        // Should be 1:1 in Dolomite
        assertEq(assets, shares);
    }

    function test_Fail_DolomiteAdapter_DepositZero() public {
        idrx.approve(address(dolomiteAdapter), 0);
        vm.expectRevert();
        dolomiteAdapter.deposit(0);
    }

    function test_Fail_DolomiteAdapter_WithdrawExcessive() public {
        idrx.approve(address(dolomiteAdapter), 0);
        vm.expectRevert();
        dolomiteAdapter.withdraw(1000e18); // No deposits made
    }
}
