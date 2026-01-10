// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/tokens/MockUSDC.sol";
import {SuperCluster} from "../src/SuperCluster.sol";
import {MockMorpho} from "../src/mocks/MockMorpho.sol";
import {LendingPool} from "../src/mocks/MockIonic.sol";
import {IonicAdapter} from "../src/adapter/IonicAdapter.sol";
import {MorphoAdapter} from "../src/adapter/MorphoAdapter.sol";
import {Pilot} from "../src/pilot/Pilot.sol";
import {MarketParams} from "../src/mocks/MockMorpho.sol";
import {Faucet} from "../src/mocks/Faucet.sol";

contract SuperClusterScript is Script {
    function run() external {
        // Load deployer private key from environment variable
        uint256 superClusterPrivateKey = vm.envUint("PRIVATE_KEY");

        // Start broadcasting transactions
        vm.startBroadcast(superClusterPrivateKey);

        console.log("=== Starting SuperCluster Deployment ===");
        uint256 lltv = 800000000000000000;
        address mockOracle = vm.envAddress("MOCK_ORACLE");
        address mockIrm = vm.envAddress("MOCK_IRM");

        console.log("=== Mock USDC Smart Contracts ===");
        MockUSDC base = new MockUSDC();
        console.log("BaseToken deployed at:", address(base));

        // Create Morpho market
        MarketParams memory params = MarketParams({
            loanToken: address(base),
            collateralToken: address(base),
            oracle: address(mockOracle),
            irm: address(mockIrm),
            lltv: lltv
        });

        console.log("=== Faucet Smart Contracts ===");
        Faucet faucet = new Faucet(address(base));
        console.log("Faucet deployed at:", address(faucet));

        console.log("=== Super Cluster Smart Contracts ===");
        SuperCluster supercluster = new SuperCluster(address(base));
        console.log("SuperCluster deployed at:", address(supercluster));

        console.log("=== Mock Lending Protocol ===");

        console.log("=== Ionic Smart Contracts ===");
        LendingPool mockIonic = new LendingPool(address(base), address(base), address(mockOracle), lltv);
        console.log("MockIonic LendingPool deployed at:", address(mockIonic));

        console.log("=== Morpho Smart Morpho ===");
        MockMorpho mockMorpho = new MockMorpho();

        mockMorpho.enableIrm(address(mockIrm));
        mockMorpho.enableLltv(lltv);

        mockMorpho.createMarket(params);

        console.log("Mock morpho deployed at:", address(mockMorpho));

        console.log("=== ADAPTER ===");

        console.log("=== Ionic Adapter Smart Contracts ===");
        IonicAdapter ionicAdapter = new IonicAdapter(address(base), address(mockIonic), "Ionic", "Conservative Lending");
        console.log("IonicAdapter deployed at:", address(ionicAdapter));

        console.log("=== Morpho Adapter Smart Contracts ===");
        MorphoAdapter morphoAdapter =
            new MorphoAdapter(address(base), address(mockMorpho), params, "Morpho V1", "Conservative Lending");
        console.log("MorphoAdapter deployed at:", address(morphoAdapter));

        console.log("=== Pilot ===");
        Pilot pilot = new Pilot(
            "Conservative DeFi Pilot",
            "Low-risk DeFi strategies focusing on lending protocols",
            address(base),
            address(supercluster)
        );
        console.log("Pilot deployed at:", address(pilot));

        address[] memory adapters = new address[](2);
        uint256[] memory allocations = new uint256[](2);

        adapters[0] = address(ionicAdapter);
        allocations[0] = 6000; // 60% Ionic

        adapters[1] = address(morphoAdapter);
        allocations[1] = 4000; // 40% Morpho

        pilot.setPilotStrategy(adapters, allocations);

        pilot.setPilotStrategy(adapters, allocations);

        supercluster.registerPilot(address(pilot), address(base));

        vm.stopBroadcast();
    }
}
