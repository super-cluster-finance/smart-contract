# SuperCluster Protocol – Smart Contract Suite

[![Solidity](https://img.shields.io/badge/Solidity-0.8.13-blue)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://book.getfoundry.sh/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

SuperCluster is a modular DeFi yield aggregation protocol that enables users to stake tokens, earn yield through automated strategy pilots, and receive rebasing reward tokens. The protocol routes deposits across multiple DeFi protocols (Aave, Morpho) via pluggable adapters while maintaining a unified user experience.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Core Contracts](#core-contracts)
- [Token System](#token-system)
- [User Flows](#user-flows)
- [Deployment](#deployment)
- [Development](#development)
- [Contract Addresses](#contract-addresses)
- [Security](#security)

---

## Overview

SuperCluster abstracts away the complexity of yield farming by:

1. **Unified Entry Point** – Users deposit once via `SuperCluster.sol` and receive `sToken` (rebasing yield token)
2. **Automated Yield Strategies** – Pilots automatically allocate funds across multiple DeFi protocols
3. **Rebasing Rewards** – User balances automatically increase as yield accrues (Lido-style)
4. **DeFi Composability** – Wrapped `wsToken` enables integration with other DeFi protocols

### Supported Networks

| Network      | Chain ID | Status     |
| ------------ | -------- | ---------- |
| Lisk Sepolia | 4202     | ✅ Testnet |

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
└────────────┬───────────────────────────────────────┬────────────────┘
             │                                       │
             ▼                                       ▼
┌────────────────────────┐              ┌────────────────────────────┐
│    AaveAdapter.sol     │              │    MorphoAdapter.sol       │
│  • deposit()           │              │  • deposit()               │
│  • withdraw()          │              │  • withdraw()              │
│  • getBalance()        │              │  • getBalance()            │
│  • harvest()           │              │  • harvest()               │
└────────────────────────┘              └────────────────────────────┘
             │                                       │
             ▼                                       ▼
┌────────────────────────┐              ┌────────────────────────────┐
│   MockAave (Testnet)   │              │  MockMorpho (Testnet)      │
└────────────────────────┘              └────────────────────────────┘
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

**Constructor Parameters:**

- `underlyingToken_`: Base ERC20 token address (e.g., USDC)

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
| `emergencyWithdraw()`                     | Emergency withdrawal to owner                   | Owner        |

**Allocation Model:**

- Allocations are specified in basis points (10000 = 100%)
- Example: `[6000, 4000]` = 60% Adapter A, 40% Adapter B

### Adapter.sol (Abstract Base)

Base contract for protocol integrations implementing `IAdapter`.

| Function                  | Description                          |
| ------------------------- | ------------------------------------ |
| `deposit(amount)`         | Deposit to external protocol         |
| `withdraw(shares)`        | Withdraw from external protocol      |
| `withdrawTo(to, amount)`  | Withdraw directly to receiver        |
| `getBalance()`            | Get current balance in protocol      |
| `harvest()`               | Collect pending rewards              |
| `convertToShares(assets)` | Convert asset amount to share amount |
| `getTotalAssets()`        | Get total assets held by adapter     |

**Implementations:**

- `AaveAdapter.sol` – Integration with Aave V3 lending
- `MorphoAdapter.sol` – Integration with Morpho lending markets

---

## Token System

### SToken (Rebasing)

A Lido-style rebasing token representing user shares in the protocol.

**Key Features:**

- Uses shares model for efficient rebasing
- User balances increase automatically as yield accrues
- Formula: `balance = shares × scalingFactor / 1e18`

```solidity
// User balance increases after rebase without any transaction
uint256 balanceBefore = sToken.balanceOf(user); // 1000 sUSDC
// ... yield accrues and rebase() is called ...
uint256 balanceAfter = sToken.balanceOf(user);  // 1010 sUSDC
```

### WsToken (Non-Rebasing Wrapper)

ERC20-compliant wrapped version for DeFi integrations.

**Use Case:**

- Compatible with AMMs, lending protocols, and other DeFi
- Each wsToken represents an increasing amount of sToken
- Similar to wstETH pattern

```solidity
// Wrap sToken to wsToken
sToken.approve(wsToken, amount);
wsToken.wrap(sTokenAmount);

// Unwrap wsToken to sToken
wsToken.unwrap(wsTokenAmount);
```

### Withdrawal Flow

The `Withdraw.sol` contract manages queued withdrawals:

```
User Request → Operator Finalize → User Claim
     │              │                  │
     ▼              ▼                  ▼
  requestId     baseAmount          tokens
```

| State       | Description                              |
| ----------- | ---------------------------------------- |
| `requested` | User initiated withdrawal, sToken burned |
| `finalized` | Operator confirmed funds available       |
| `claimed`   | User received base tokens                |

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

**Internal Flow:**

1. SuperCluster transfers base token from user
2. Mints equivalent sToken to user
3. Approves pilot to spend base token
4. Calls `pilot.receiveAndInvest(amount)`
5. Pilot distributes to adapters based on allocation strategy

### Withdraw Flow

```solidity
// 1. Request withdrawal
superCluster.withdraw(pilotAddress, baseToken, amount);

// 2. Wait for finalization (automatic in current implementation)

// 3. Claim funds
withdrawManager.claim(requestId);
```

**Internal Flow:**

1. SuperCluster burns user's sToken
2. Calls `pilot.withdrawToManager()` to unwind positions
3. Creates withdrawal request via `withdrawManager.autoRequest()`
4. Auto-finalizes the request
5. User claims base tokens

### Rebase Flow (Admin)

```solidity
// Calculate and distribute yield
superCluster.rebase();
```

**Internal Flow:**

1. `calculateTotalAUM()` aggregates:
   - Base token balance in SuperCluster
   - `getTotalValue()` from all registered pilots
2. Computes yield = newAUM - currentSupply
3. Updates sToken scaling factor
4. All user balances automatically reflect new yield

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
PRIVATE_KEY=your_deployer_private_key
LISK_SEPOLIA_RPC_URL=https://rpc.sepolia-api.lisk.com

# After deploying Oracle & IRM
MOCK_ORACLE=deployed_oracle_address
MOCK_IRM=deployed_irm_address
```

### Foundry Configuration

Your `foundry.toml` should include:

```toml
[profile.default]
src = "src"
out = "out"

[rpc_endpoints]
lisk-sepolia = "${LISK_SEPOLIA_RPC_URL}"

[etherscan]
lisk-sepolia = {key = "empty", url = "https://sepolia-blockscout.lisk.com/api"}
```

### Deployment Scripts

**Step 1: Deploy Oracle & IRM (Testnet)**

```bash
forge script script/DeployOracleAndIRM.s.sol:DeployOracleAndIRM \
  --rpc-url lisk-sepolia \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://sepolia-blockscout.lisk.com/api \
  -vvv
```

**Step 2: Deploy Full Protocol**

```bash
forge script script/SuperCluster.s.sol:SuperClusterScript \
  --rpc-url lisk-sepolia \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://sepolia-blockscout.lisk.com/api \
  -vvv
```

### Deployment Order

1. `MockOracle` & `MockIrm` – Price feed and interest rate model
2. `MockUSDC` – Base token (testnet)
3. `SuperCluster` – Main protocol (auto-deploys SToken, WsToken, WithdrawManager)
4. `LendingPool` (MockAave) – Mock Aave protocol
5. `MockMorpho` – Mock Morpho protocol
6. `AaveAdapter` – Aave integration adapter
7. `MorphoAdapter` – Morpho integration adapter
8. `Pilot` – Strategy manager
9. `Faucet` – Testnet token distribution

---

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Test with Verbosity

```bash
forge test -vvv
```

### Gas Report

```bash
forge test --gas-report
```

### Format

```bash
forge fmt
```

### Local Development

```bash
# Start local Anvil node
anvil

# Deploy to local network
forge script script/SuperCluster.s.sol:SuperClusterScript \
  --rpc-url http://localhost:8545 \
  --broadcast
```

---

## Directory Structure

```
sc-super-cluster/
├── src/
│   ├── SuperCluster.sol          # Main protocol entry point
│   ├── adapter/
│   │   ├── Adapter.sol           # Abstract base adapter
│   │   ├── AaveAdapter.sol       # Aave V3 integration
│   │   └── MorphoAdapter.sol     # Morpho integration
│   ├── interfaces/
│   │   ├── IAdapter.sol          # Adapter interface
│   │   ├── IPilot.sol            # Pilot interface
│   │   ├── ISToken.sol           # SToken interface
│   │   └── IMockMorpho.sol       # Morpho interface
│   ├── mocks/
│   │   ├── MockAave.sol          # Mock Aave LendingPool
│   │   ├── MockMorpho.sol        # Mock Morpho protocol
│   │   ├── MockOracle.sol        # Mock price oracle
│   │   ├── MockIrm.sol           # Mock interest rate model
│   │   ├── Faucet.sol            # Testnet token faucet
│   │   └── tokens/
│   │       └── MockUSDC.sol      # Mock USDC token
│   ├── pilot/
│   │   └── Pilot.sol             # Strategy manager
│   └── tokens/
│       ├── SToken.sol            # Rebasing staking token
│       ├── WsToken.sol           # Wrapped non-rebasing token
│       └── WithDraw.sol          # Withdrawal queue manager
├── script/
│   ├── DeployOracleAndIRM.s.sol  # Oracle/IRM deployment
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

## Contract Interfaces

### IAdapter

```solidity
interface IAdapter {
    function deposit(uint256 amount) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 amount);
    function withdrawTo(address to, uint256 amount) external returns (uint256);
    function getBalance() external view returns (uint256);
    function getPendingRewards() external view returns (uint256);
    function harvest() external returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function getTotalAssets() external view returns (uint256);
    function isActive() external view returns (bool);
}
```

### IPilot

```solidity
interface IPilot {
    function invest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations) external;
    function divest(uint256 amount, address[] calldata adapters, uint256[] calldata allocations) external;
    function harvest(address[] calldata adapters) external;
    function receiveAndInvest(uint256 amount) external;
    function withdrawToManager(address manager, uint256 amount) external;
    function getTotalValue() external view returns (uint256);
    function getStrategy() external view returns (address[] memory, uint256[] memory);
}
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

1. Create adapter contract extending `Adapter.sol`:

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
}
```

2. Deploy and register with pilot:

```solidity
pilot.addAdapter(newAdapterAddress);
pilot.setPilotStrategy(adapters, allocations);
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
- **Documentation**: [docs](https://super-cluster-lisk-docs.vercel.app/)
- **Demo**: [demo](https://super-cluster-lisk.vercel.app/)
- **Discord**: Coming soon
