// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SuperCluster} from "../src/SuperCluster.sol";
import {SToken} from "../src/tokens/SToken.sol";
import {WsToken} from "../src/tokens/WsToken.sol";
import {Pilot} from "../src/pilot/Pilot.sol";
import {IonicAdapter} from "../src/adapter/IonicAdapter.sol";
import {MorphoAdapter} from "../src/adapter/MorphoAdapter.sol";
import {LendingPool} from "../src/mocks/MockIonic.sol";
import {MockMorpho} from "../src/mocks/MockMorpho.sol";
import {MockIDRX} from "../src/mocks/tokens/MockIDRX.sol";
import {MarketParams} from "../src/mocks/interfaces/IMorpho.sol";
import {Withdraw} from "../src/tokens/WithDraw.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockIrm} from "../src/mocks/MockIrm.sol";

contract SuperClusterTest is Test {
    SuperCluster public superCluster;
    SToken public sToken;
    WsToken public wsToken;
    MockIDRX public idrx;
    Pilot public pilot;
    IonicAdapter public ionicAdapter;
    MorphoAdapter public morphoAdapter;
    LendingPool public mockIonic;
    MockMorpho public mockMorpho;

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

        MockIrm mockIrm = new MockIrm();
        MockOracle mockOracle = new MockOracle();
        uint256 ltv = 800000000000000000; // 80% LTV

        //Deploy Mock protocols
        _deployMockProtocols(address(mockIrm), address(mockOracle), ltv);

        // Deploy adapters
        _deployAdapters(address(mockIrm), address(mockOracle), ltv);

        // Deploy pilot
        _deployPilot();

        // Setup pilot strategy
        _setupPilotStrategy();

        superCluster.registerPilot(address(pilot), address(idrx));

        // (Opsional) log untuk debugging
        console.log("SuperCluster:", address(superCluster));
        console.log("SToken:", address(sToken));
    }

    function _deployMockProtocols(address _mockIrm, address _mockOracle, uint256 _ltv) internal {
        mockIonic = new LendingPool(address(idrx), address(idrx), address(_mockOracle), _ltv);

        // Deploy MockMorpho
        mockMorpho = new MockMorpho();

        mockMorpho.enableLltv(_ltv);
        mockMorpho.enableIrm(address(_mockIrm));

        // Create Morpho market
        MarketParams memory params = MarketParams({
            loanToken: address(idrx),
            collateralToken: address(idrx),
            oracle: address(_mockOracle),
            irm: address(_mockIrm),
            lltv: _ltv
        });

        mockMorpho.createMarket(params);
    }

    function _deployAdapters(address _mockIrm, address _mockOracle, uint256 _ltv) internal {
        // Deploy IonicAdapter
        ionicAdapter = new IonicAdapter(address(idrx), address(mockIonic), "Ionic", "Conservative Lending");

        // Deploy MorphoAdapter
        MarketParams memory params = MarketParams({
            loanToken: address(idrx),
            collateralToken: address(idrx),
            oracle: address(_mockOracle),
            irm: address(_mockIrm),
            lltv: _ltv
        });

        morphoAdapter =
            new MorphoAdapter(address(idrx), address(mockMorpho), params, "Morpho Blue", "High Yield Lending");
    }

    function _deployPilot() internal {
        pilot = new Pilot(
            "Conservative DeFi Pilot",
            "Low-risk DeFi strategies focusing on lending protocols",
            address(idrx),
            address(superCluster)
        );
    }

    function _setupPilotStrategy() internal {
        address[] memory adapters = new address[](2);
        uint256[] memory allocations = new uint256[](2);

        adapters[0] = address(ionicAdapter);
        adapters[1] = address(morphoAdapter);
        allocations[0] = 6000; // 60% Ionic
        allocations[1] = 4000; // 40% Morpho

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
        assertEq(pilot.name(), "Conservative DeFi Pilot");
        assertTrue(bytes(pilot.description()).length > 0);
        assertEq(pilot.TOKEN(), address(idrx));
    }

    function test_Pilot_SetStrategy() public {
        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);

        adapters[0] = address(ionicAdapter);
        allocations[0] = 10000; // 100%

        pilot.setPilotStrategy(adapters, allocations);

        (address[] memory returnedAdapters, uint256[] memory returnedAllocations) = pilot.getStrategy();

        assertEq(returnedAdapters.length, 1);
        assertEq(returnedAllocations.length, 1);
        assertEq(returnedAdapters[0], address(ionicAdapter));
        assertEq(returnedAllocations[0], 10000);
    }

    function test_Pilot_Invest() public {
        // Transfer tokens to pilot
        bool status = idrx.transfer(address(pilot), DEPOSIT_AMOUNT);
        require(status, "Transfer failed");

        address[] memory adapters = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        adapters[0] = address(ionicAdapter);
        allocations[0] = 10000;

        // Fund adapter with tokens first
        status = idrx.transfer(address(ionicAdapter), DEPOSIT_AMOUNT);
        require(status, "Transfer failed");

        pilot.invest(DEPOSIT_AMOUNT, adapters, allocations);

        // Check if adapter received tokens
        assertTrue(ionicAdapter.getBalance() > 0);
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

        adapters[0] = address(ionicAdapter);
        allocations[0] = 5000; // Only 50%, should fail

        vm.expectRevert();
        pilot.setPilotStrategy(adapters, allocations);
    }

    // ==================== IONIC ADAPTER TESTS ====================

    function test_IonicAdapter_InitialState() public view {
        assertEq(ionicAdapter.getProtocolName(), "Ionic");
        assertEq(ionicAdapter.getPilotStrategy(), "Conservative Lending");
        assertEq(address(ionicAdapter.LENDINGPOOL()), address(mockIonic));
        assertTrue(ionicAdapter.isActive());
    }

    function test_IonicAdapter_Deposit() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(ionicAdapter), depositAmount);

        uint256 shares = ionicAdapter.deposit(depositAmount);

        assertGt(shares, 0);
        assertGt(ionicAdapter.getBalance(), 0);
        assertEq(ionicAdapter.totalDeposited(), depositAmount);
    }

    function test_IonicAdapter_Withdraw() public {
        uint256 depositAmount = 1000e18;

        // First deposit
        idrx.approve(address(ionicAdapter), depositAmount);
        uint256 shares = ionicAdapter.deposit(depositAmount);

        uint256 balanceBefore = idrx.balanceOf(address(this));

        // Withdraw
        uint256 withdrawn = ionicAdapter.withdraw(shares);

        uint256 balanceAfter = idrx.balanceOf(address(this));

        assertGt(withdrawn, 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_IonicAdapter_ConvertToShares() public view {
        uint256 assets = 1000e18;
        uint256 shares = ionicAdapter.convertToShares(assets);

        // Should be 1:1 initially
        assertEq(shares, assets);
    }

    function test_Fail_IonicAdapter_DepositZero() public {
        idrx.approve(address(ionicAdapter), 0);
        vm.expectRevert();
        ionicAdapter.deposit(0);
    }

    function test_Fail_IonicAdapter_WithdrawExcessive() public {
        idrx.approve(address(ionicAdapter), 0);
        vm.expectRevert();
        ionicAdapter.withdraw(1000e18); // No deposits made
    }

    // ==================== MORPHO ADAPTER TESTS ====================

    function test_MorphoAdapter_InitialState() public view {
        assertEq(morphoAdapter.getProtocolName(), "Morpho Blue");
        assertEq(morphoAdapter.getPilotStrategy(), "High Yield Lending");
        assertTrue(morphoAdapter.isActive());
        assertTrue(morphoAdapter.getMarketId() != bytes32(0));
    }

    function test_MorphoAdapter_Deposit() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(morphoAdapter), depositAmount);

        uint256 shares = morphoAdapter.deposit(depositAmount);

        assertGt(shares, 0);
        assertGt(morphoAdapter.getBalance(), 0);
        assertEq(morphoAdapter.totalDeposited(), depositAmount);
    }

    function test_MorphoAdapter_Withdraw() public {
        uint256 depositAmount = 1000e18;

        // First deposit
        idrx.approve(address(morphoAdapter), depositAmount);
        uint256 shares = morphoAdapter.deposit(depositAmount);

        uint256 balanceBefore = idrx.balanceOf(address(this));

        // Withdraw
        uint256 withdrawn = morphoAdapter.withdraw(shares);

        uint256 balanceAfter = idrx.balanceOf(address(this));

        assertGt(withdrawn, 0);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_MorphoAdapter_GetPosition() public {
        uint256 depositAmount = 1000e18;

        idrx.approve(address(morphoAdapter), depositAmount);
        morphoAdapter.deposit(depositAmount);

        (uint128 supplyShares, uint128 borrowShares, uint128 collateral) = morphoAdapter.getPosition();

        assertGt(supplyShares, 0);
        assertEq(borrowShares, 0); // No borrowing
        assertEq(collateral, 0);
    }

    function test_Fail_MorphoAdapter_DepositZero() public {
        idrx.approve(address(morphoAdapter), 0);
        vm.expectRevert();
        morphoAdapter.deposit(0);
    }
}
