// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/tokens/MockUSDC.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {SuperCluster} from "../src/SuperCluster.sol";
import {InitLendingPool} from "../src/mocks/MockInit.sol";
import {Comet} from "../src/mocks/MockCompound.sol";
import {DolomiteMargin} from "../src/mocks/MockDolomite.sol";
import {InitAdapter} from "../src/adapter/InitAdapter.sol";
import {CompoundAdapter} from "../src/adapter/CompoundAdapter.sol";
import {DolomiteAdapter} from "../src/adapter/DolomiteAdapter.sol";
import {Pilot} from "../src/pilot/Pilot.sol";
import {Faucet} from "../src/mocks/Faucet.sol";

/**
 * @title SuperClusterScript
 * @notice Full deployment script for SuperCluster protocol on Mantle Network
 * @dev Run with:
 *      Mantle Sepolia: forge script script/SuperCluster.s.sol --rpc-url mantle-sepolia --broadcast --verify
 *      Mantle Mainnet: forge script script/SuperCluster.s.sol --rpc-url mantle --broadcast --verify
 *
 * Required environment variables:
 *      - PRIVATE_KEY: Deployer's private key
 */
contract SuperClusterScript is Script {
    // Strategy allocations (basis points, 10000 = 100%)
    uint256 constant INIT_ALLOCATION = 3000; // 30%
    uint256 constant COMPOUND_ALLOCATION = 4000; // 40%
    uint256 constant DOLOMITE_ALLOCATION = 3000; // 30%

    // Default LTV for lending pools (80%)
    uint256 constant DEFAULT_LLTV = 800000000000000000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("==========================================");
        console.log("  SuperCluster Deployment on Mantle");
        console.log("==========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // ============ INFRASTRUCTURE ============
        console.log("\n--- Infrastructure ---");

        MockOracle oracle = new MockOracle();
        console.log("MockOracle:", address(oracle));

        MockUSDC baseToken = new MockUSDC();
        console.log("MockUSDC:", address(baseToken));

        Faucet faucet = new Faucet(address(baseToken));
        console.log("Faucet:", address(faucet));

        // ============ CORE PROTOCOL ============
        console.log("\n--- Core Protocol ---");

        SuperCluster supercluster = new SuperCluster(address(baseToken));
        console.log("SuperCluster:", address(supercluster));

        // ============ MOCK LENDING PROTOCOLS ============
        console.log("\n--- Mock Lending Protocols ---");

        InitLendingPool mockInit =
            new InitLendingPool(address(baseToken), address(baseToken), address(oracle), DEFAULT_LLTV);
        console.log("InitLendingPool:", address(mockInit));

        Comet mockCompound = new Comet(address(baseToken), address(baseToken), address(oracle), DEFAULT_LLTV);
        console.log("Comet (Compound):", address(mockCompound));

        DolomiteMargin mockDolomite = new DolomiteMargin(address(oracle), DEFAULT_LLTV);
        uint256 dolomiteMarketId = mockDolomite.addMarket(address(baseToken));
        console.log("DolomiteMargin:", address(mockDolomite));
        console.log("  Market ID:", dolomiteMarketId);

        // ============ ADAPTERS ============
        console.log("\n--- Adapters ---");

        InitAdapter initAdapter =
            new InitAdapter(address(baseToken), address(mockInit), "Init Capital", "Balanced Lending");
        console.log("InitAdapter:", address(initAdapter));

        CompoundAdapter compoundAdapter =
            new CompoundAdapter(address(baseToken), address(mockCompound), "Compound V3", "High Yield Lending");
        console.log("CompoundAdapter:", address(compoundAdapter));

        DolomiteAdapter dolomiteAdapter = new DolomiteAdapter(
            address(baseToken), address(mockDolomite), dolomiteMarketId, "Dolomite", "Margin Lending"
        );
        console.log("DolomiteAdapter:", address(dolomiteAdapter));

        // ============ PILOT STRATEGY ============
        console.log("\n--- Pilot Strategy ---");

        Pilot pilot = new Pilot(
            "Mantle DeFi Pilot",
            "Multi-protocol DeFi strategies for Mantle ecosystem",
            address(baseToken),
            address(supercluster)
        );
        console.log("Pilot:", address(pilot));

        // Setup strategy allocations
        address[] memory adapters = new address[](3);
        uint256[] memory allocations = new uint256[](3);

        adapters[0] = address(initAdapter);
        allocations[0] = INIT_ALLOCATION;

        adapters[1] = address(compoundAdapter);
        allocations[1] = COMPOUND_ALLOCATION;

        adapters[2] = address(dolomiteAdapter);
        allocations[2] = DOLOMITE_ALLOCATION;

        pilot.setPilotStrategy(adapters, allocations);
        supercluster.registerPilot(address(pilot), address(baseToken));

        // ============ SUMMARY ============
        console.log("\n==========================================");
        console.log("  Deployment Complete!");
        console.log("==========================================");
        console.log("Network: Mantle (Chain ID:", block.chainid, ")");
        console.log("Strategy: Init 30% | Compound 40% | Dolomite 30%");
        console.log("\nKey Contracts:");
        console.log("  MockUSDC:     ", address(baseToken));
        console.log("  Faucet:       ", address(faucet));
        console.log("  SuperCluster: ", address(supercluster));
        console.log("  Pilot:        ", address(pilot));
        console.log("==========================================");

        vm.stopBroadcast();
    }
}
