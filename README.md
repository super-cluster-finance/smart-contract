# SuperCluster Protocol – Smart Contract Suite

[![Solidity](https://img.shields.io/badge/Solidity-0.8.13-blue)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://book.getfoundry.sh/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Mantle](https://img.shields.io/badge/Network-Mantle-black)](https://mantle.xyz/)

SuperCluster is a modular DeFi yield aggregation protocol that enables users to stake tokens, earn yield through automated strategy pilots, and receive rebasing reward tokens. The protocol routes deposits across multiple DeFi protocols (Init Capital, Compound V3, Dolomite) via pluggable adapters while maintaining a unified user experience.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Core Contracts](#core-contracts)
- [Token System](#token-system)
- [User Flows](#user-flows)
- [Deployment](#deployment)
- [Contract Addresses](#contract-addresses)
- [Development](#development)
- [Security](#security)

---

## Overview

SuperCluster abstracts away the complexity of yield farming by:

1. **Unified Entry Point** – Users deposit once via `SuperCluster.sol` and receive `sToken` (rebasing yield token)
2. **Automated Yield Strategies** – Pilots automatically allocate funds across multiple DeFi protocols
3. **Rebasing Rewards** – User balances automatically increase as yield accrues (Lido-style)
4. **DeFi Composability** – Wrapped `wsToken` enables integration with other DeFi protocols

### Supported Networks

| Network        | Chain ID | Status     |
| -------------- | -------- | ---------- |
| Mantle Mainnet | 5000     | 🔜 Coming  |
| Mantle Sepolia | 5003     | ✅ Testnet |

### Integrated Protocols

| Protocol     | Allocation | Description                    |
| ------------ | ---------- | ------------------------------ |
| Init Capital | 30%        | Position-based lending         |
| Compound V3  | 40%        | Direct supply/withdraw (Comet) |
| Dolomite    | 30%        | Margin account lending         |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           User Interface                             │
└────────────────────────────────┬────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         SuperCluster.sol                             │
│  • deposit(pilot, token, amount)    • withdraw(pilot, token, amount)│
│  • rebase()                         • calculateTotalAUM()            │
│  • registerPilot()                  • setWithdrawManager()           │
└────────────┬───────────────────────────────────────┬────────────────┘
             │                                       │
             ▼                                       ▼
┌────────────────────────┐              ┌────────────────────────────┐
│      SToken.sol        │              │    WithdrawManager.sol     │
│  (Rebasing ERC20)      │              │  • requestWithdraw()       │
│  • mint/burn           │              │  • finalizeWithdraw()      │
│  • rebase()            │              │  • claim()                 │
│  • shares model        │              │  • fund()                  │
└────────────────────────┘              └────────────────────────────┘
             │
             ▼
┌────────────────────────┐
│     WsToken.sol        │
│  (Non-rebasing wrap)   │
│  • wrap() / unwrap()   │
└────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                           Pilot.sol                                  │
│  • receiveAndInvest()   • invest()    • divest()    • harvest()     │
│  • setPilotStrategy()   • getTotalValue()   • withdrawToManager()   │
└────────────┬─────────────────────┬─────────────────────┬────────────┘
             │                     │                     │
             ▼                     ▼                     ▼
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│   InitAdapter.sol  │  │ CompoundAdapter.sol│  │ DolomiteAdapter.sol│
│  • deposit()       │  │  • deposit()       │  │  • deposit()       │
│  • withdraw()      │  │  • withdraw()      │  │  • withdraw()      │
│  • getBalance()    │  │  • getBalance()    │  │  • getBalance()    │
└────────────────────┘  └────────────────────┘  └────────────────────┘
             │                     │                     │
             ▼                     ▼                     ▼
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│  InitLendingPool   │  │  Comet (Mock)      │  │  DolomiteMargin    │
│  (Mock)            │  │                    │  │  (Mock)            │
└────────────────────┘  └────────────────────┘  └────────────────────┘
```

---

## Core Contracts

### SuperCluster.sol

The main protocol entry point that orchestrates all operations.

| Function                              | Description                                        | Access |
| ------------------------------------- | -------------------------------------------------- | ------ |
| `deposit(pilot, token, amount)`       | Deposit tokens, mint sToken, auto-invest via pilot | Public |
| `withdraw(pilot, token, amount)`      | Burn sToken, initiate withdrawal request           | Public |
| `rebase()`                            | Update sToken supply based on accrued yield        | Owner  |
| `calculateTotalAUM()`                 | Calculate total assets across all pilots           | View   |
| `registerPilot(pilot, acceptedToken)` | Register a new pilot strategy                      | Owner  |
| `setWithdrawManager(manager)`         | Set withdrawal queue contract                      | Owner  |
| `getPilots()`                         | Get all registered pilot addresses                 | View   |

**Auto-deployed Contracts:**

- `SToken` – Rebasing staking token (`s{TokenName}`)
- `WsToken` – Wrapped non-rebasing token (`ws{TokenName}`)
- `WithdrawManager` – Queued withdrawal handler

### Pilot.sol

Strategy controller that manages fund allocation across DeFi protocols.

| Function                                  | Description                                     | Access       |
| ----------------------------------------- | ----------------------------------------------- | ------------ |
| `receiveAndInvest(amount)`                | Receive funds from SuperCluster and auto-invest | SuperCluster |
| `invest(amount, adapters, allocations)`   | Manual investment with custom allocation        | Owner        |
| `divest(amount, adapters, allocations)`   | Withdraw from protocols                         | Owner        |
| `harvest(adapters)`                       | Collect yield rewards                           | Owner        |
| `setPilotStrategy(adapters, allocations)` | Configure strategy allocation                   | Owner        |
| `getTotalValue()`                         | Get total AUM (idle + invested)                 | View         |
| `withdrawToManager(manager, amount)`      | Withdraw to WithdrawManager                     | SuperCluster |

**Default Allocation:**

- Init Capital: 30%
- Compound V3: 40%  
- Dolomite: 30%

### Adapters

Base contract for protocol integrations implementing `IAdapter`.

| Adapter               | Protocol     | Description                              |
| --------------------- | ------------ | ---------------------------------------- |
| `InitAdapter.sol`     | Init Capital | Position-based lending with share system |
| `CompoundAdapter.sol` | Compound V3  | Direct supply/withdraw (1:1 conversion)  |
| `DolomiteAdapter.sol` | Dolomite     | Margin account system with market IDs    |

---

## Token System

### SToken (Rebasing)

A Lido-style rebasing token representing user shares in the protocol.

```solidity
// User balance increases after rebase without any transaction
uint256 balanceBefore = sToken.balanceOf(user); // 1000 sUSDC
// ... yield accrues and rebase() is called ...
uint256 balanceAfter = sToken.balanceOf(user);  // 1010 sUSDC
```

### WsToken (Non-Rebasing Wrapper)

ERC20-compliant wrapped version for DeFi integrations.

```solidity
// Wrap sToken to wsToken
sToken.approve(wsToken, amount);
wsToken.wrap(sTokenAmount);

// Unwrap wsToken to sToken
wsToken.unwrap(wsTokenAmount);
```

---

## User Flows

### Deposit Flow

```solidity
// 1. Approve SuperCluster to spend base token
IERC20(baseToken).approve(superCluster, amount);

// 2. Deposit via SuperCluster
superCluster.deposit(pilotAddress, baseToken, amount);

// User receives: sToken (rebasing yield token)
```

### Withdraw Flow

```solidity
// 1. Request withdrawal
superCluster.withdraw(pilotAddress, baseToken, amount);

// 2. Wait for finalization (automatic in current implementation)

// 3. Claim funds
withdrawManager.claim(requestId);
```

---

## Deployment

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone repository
git clone https://github.com/super-cluster-finance/smart-contract.git
cd smart-contract

# Install dependencies
forge install
```

### Environment Setup

Create `.env` file:

```bash
# Deployer private key
PRIVATE_KEY=your_deployer_private_key

# Mantle Network RPC URLs
MANTLE_RPC_URL=https://rpc.mantle.xyz
MANTLE_SEPOLIA_RPC_URL=https://rpc.sepolia.mantle.xyz

# Explorer API Key (optional, for verification)
MANTLESCAN_API_KEY=your_api_key
```

### Foundry Configuration

The `foundry.toml` is pre-configured for Mantle:

```toml
[rpc_endpoints]
mantle = "${MANTLE_RPC_URL}"
mantle-sepolia = "${MANTLE_SEPOLIA_RPC_URL}"

[etherscan]
mantle = { key = "${MANTLESCAN_API_KEY}", url = "https://explorer.mantle.xyz/api", chain = 5000 }
mantle-sepolia = { key = "${MANTLESCAN_API_KEY}", url = "https://explorer.sepolia.mantle.xyz/api", chain = 5003 }
```

### Deploy to Mantle

**Single Command Deployment:**

```bash
# Deploy to Mantle Sepolia (Testnet)
forge script script/SuperCluster.s.sol --rpc-url mantle-sepolia --broadcast --verify

# Deploy to Mantle Mainnet
forge script script/SuperCluster.s.sol --rpc-url mantle --broadcast --verify
```

The deployment script deploys all contracts in order:

1. `MockOracle` – Price feed
2. `MockUSDC` – Base token (testnet)
3. `Faucet` – Token distribution
4. `SuperCluster` – Main protocol (auto-deploys SToken, WsToken, WithdrawManager)
5. `InitLendingPool` – Mock Init Capital
6. `Comet` – Mock Compound V3
7. `DolomiteMargin` – Mock Dolomite
8. `InitAdapter`, `CompoundAdapter`, `DolomiteAdapter` – Protocol adapters
9. `Pilot` – Strategy manager with 30/40/30 allocation

---

## Contract Addresses

### Mantle Sepolia (Testnet)

| Contract          | Address                                      |
| ----------------- | -------------------------------------------- |
| SuperCluster      | `0x07f5Ad7AcD80855fcE8645C3c37bA037A7a5C668` |
| Pilot             | `0xDA5eDA6A07ec1BF0c0FB910E2DA32F011b4D5dff` |
| MockUSDC          | `0x996D5d20b363A65c98df75325DED909387b9B3D9` |
| Faucet            | `0xFe1a6E7daE9B878E4f51FeFD743D6FFf5Ac24fCE` |
| sToken            | `0xBF402fC74064E44C366FCe9f6A790dB711FC7eA6` |
| WithdrawManager   | `0x4023bD831FCB6beCdCB137cE7456ac08242EDFAd` |
| wsToken           | `0x7eB42527c1848B6323111374C78A861C037dc8a2` |

**Explorer:** [explorer.sepolia.mantle.xyz](https://explorer.sepolia.mantle.xyz)

---

## Development

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# With verbosity
forge test -vvv

# Gas report
forge test --gas-report
```

### Local Development

```bash
# Start local Anvil node
anvil

# Deploy to local network
forge script script/SuperCluster.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## Directory Structure

```
super-cluster-mantle/
├── src/
│   ├── SuperCluster.sol          # Main protocol entry point
│   ├── adapter/
│   │   ├── Adapter.sol           # Abstract base adapter
│   │   ├── InitAdapter.sol       # Init Capital integration
│   │   ├── CompoundAdapter.sol   # Compound V3 integration
│   │   └── DolomiteAdapter.sol   # Dolomite integration
│   ├── interfaces/
│   │   ├── IAdapter.sol          # Adapter interface
│   │   ├── IPilot.sol            # Pilot interface
│   │   └── ISToken.sol           # SToken interface
│   ├── mocks/
│   │   ├── MockInit.sol          # Mock Init Capital LendingPool
│   │   ├── MockCompound.sol      # Mock Compound V3 (Comet)
│   │   ├── MockDolomite.sol      # Mock Dolomite Margin
│   │   ├── MockOracle.sol        # Mock price oracle
│   │   ├── Faucet.sol            # Testnet token faucet
│   │   ├── interfaces/
│   │   │   └── IOracle.sol       # Oracle interface
│   │   └── tokens/
│   │       └── MockUSDC.sol      # Mock USDC token
│   ├── pilot/
│   │   └── Pilot.sol             # Strategy manager
│   └── tokens/
│       ├── SToken.sol            # Rebasing staking token
│       ├── WsToken.sol           # Wrapped non-rebasing token
│       └── WithDraw.sol          # Withdrawal queue manager
├── script/
│   └── SuperCluster.s.sol        # Full protocol deployment
├── test/
│   ├── IntegrationTest.t.sol     # Integration tests
│   ├── SuperClusterTest.t.sol    # Core contract tests
│   └── WithDrawTest.t.sol        # Withdrawal tests
├── lib/                          # Dependencies (forge-std, OpenZeppelin)
├── broadcast/                    # Deployment artifacts
└── foundry.toml                  # Foundry configuration
```

---

## Security Considerations

### Access Control

| Contract        | Admin Functions                                                     | Restriction |
| --------------- | ------------------------------------------------------------------- | ----------- |
| SuperCluster    | `rebase()`, `registerPilot()`, `setWithdrawManager()`               | `onlyOwner` |
| Pilot           | `invest()`, `divest()`, `setPilotStrategy()`, `emergencyWithdraw()` | `onlyOwner` |
| Adapter         | `activate()`, `deactivate()`                                        | `onlyOwner` |
| WithdrawManager | `fund()`, `finalizeWithdraw()`                                      | `onlyOwner` |

### Security Features

- **ReentrancyGuard** – All state-changing functions in SuperCluster and Pilot
- **SafeERC20** – Safe token transfers throughout the protocol
- **Access Control** – Ownable pattern for admin functions
- **Input Validation** – Zero-amount checks, supported token checks, pilot registration checks

### Known Limitations (Testnet)

| Issue                                        | Impact                      | Status                   |
| -------------------------------------------- | --------------------------- | ------------------------ |
| Mock adapters use simplified interest models | Not production-grade yields | Testnet only             |
| Single owner access control                  | Centralization risk         | Use multisig for mainnet |
| No time-lock on admin functions              | Immediate execution         | Add timelock for mainnet |

---

## Extending the Protocol

### Adding a New Adapter

```solidity
contract NewProtocolAdapter is Adapter {
    constructor(address _token, address _protocol, string memory _name, string memory _strategy)
        Adapter(_token, _protocol, _name, _strategy) {}

    function deposit(uint256 amount) external override onlyActive returns (uint256) {
        // Protocol-specific deposit logic
    }

    function withdraw(uint256 shares) external override onlyActive returns (uint256) {
        // Protocol-specific withdrawal logic
    }

    function getBalance() external view override returns (uint256) {
        // Return current balance in protocol
    }

    function getTotalAssets() external view override returns (uint256) {
        // Return total assets held
    }
}
```

### Creating a New Pilot Strategy

```solidity
Pilot newPilot = new Pilot(
    "Aggressive DeFi Pilot",
    "High-yield strategies across lending protocols",
    baseTokenAddress,
    superClusterAddress
);

superCluster.registerPilot(address(newPilot), baseTokenAddress);
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Links

- **GitHub**: [super-cluster-finance/smart-contract](https://github.com/super-cluster-finance/smart-contract)
- **Explorer (Mantle Sepolia)**: [explorer.sepolia.mantle.xyz](https://explorer.sepolia.mantle.xyz)
- **Mantle Network**: [mantle.xyz](https://mantle.xyz)
