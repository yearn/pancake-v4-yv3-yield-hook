# PancakeSwap v4 Yield Enhancement Hook Technical Specification

## Overview

A yield enhancement hook for PancakeSwap v4 that maximizes returns for LPs by deploying idle liquidity to Yearn V3 vaults while maintaining configurable buffer ratios for active trading.

## PoC Implementation

[CLYearnVaultV3YieldHook.sol](https://github.com/yearn/pancake-v4-yv3-yield-hook/blob/main/src/pool-cl/CLYearnVaultV3YieldHook.sol)

## Core Components

### State Management

```solidity
struct YieldVaults {
  address vault0;
  uint256 amount0TotalBalance; // Total tracked balance for token0
  uint256 amount0IdleBalance; // Unmoved balance for token0
  uint256 vault0ShareBalance; // Vault shares for token0
  address vault1;
  uint256 amount1TotalBalance; // Total tracked balance for token1
  uint256 amount1IdleBalance; // Unmoved balance for token1
  uint256 vault1ShareBalance; // Vault shares for token1
}
```

### Configuration Parameters

- `minBufferBps`: Minimum ratio of idle funds (2000 = 20%)
- `targetBufferBps`: Target ratio for idle funds (4000 = 40%)
- `maxBufferBps`: Maximum ratio of idle funds (5000 = 50%)
- `hookManager`: Address authorized to modify hook parameters

## Hook Callbacks Implementation

### Pool Initialization

```solidity
function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
    external override returns (bytes4)
```

- Initializes YieldVaults structure for the pool
- Sets up vault associations for both tokens
- Records initial zero balances

### Liquidity Addition

```solidity
function beforeAddLiquidity(address, PoolKey calldata key,
    ICLPoolManager.ModifyLiquidityParams calldata params, bytes calldata)
    external override returns (bytes4)
```

- Checks if liquidity is being added within current tick range
- Distributes accumulated yield to active LPs if in range

```solidity
function afterAddLiquidity(address, PoolKey calldata key,
    ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta, bytes calldata)
    external override returns (bytes4, BalanceDelta)
```

- Ensures buffer ratios are maintained
- Deploys excess funds to vaults if needed

### Liquidity Removal

```solidity
function beforeRemoveLiquidity(address, PoolKey calldata key,
    ICLPoolManager.ModifyLiquidityParams calldata params, bytes calldata)
    external override returns (bytes4)
```

- Checks if liquidity being removed is in current tick range
- Distributes yield if removing active liquidity

```solidity
function afterRemoveLiquidity(address, PoolKey calldata key,
    ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta balanceDelta, bytes calldata)
    external override returns (bytes4, BalanceDelta)
```

- Ensures sufficient buffer remains after removal
- Withdraws from vaults if needed

### Swap Handling

```solidity
function beforeSwap(address, PoolKey calldata key,
    ICLPoolManager.SwapParams calldata params, bytes calldata)
    external override returns (bytes4, BeforeSwapDelta, uint24)
```

- Checks if swap will cross a tick boundary
- Distributes yield if crossing tick
- Ensures sufficient buffer for swap

```solidity
function afterSwap(address, PoolKey calldata key,
    ICLPoolManager.SwapParams calldata, BalanceDelta balanceDelta, bytes calldata)
    external override returns (bytes4, int128)
```

- Rebalances buffers based on swap impact
- Withdraws or deposits to maintain target ratios

## Core Functions

### Yield Distribution

```solidity
function _distributeYield(PoolKey calldata key) private
    returns (uint256 donationAmount0, uint256 donationAmount1)
```

1. Calculates yield since last distribution for each token:
   - For each token with a configured vault:
     - Total yield = currentIdleBalance + convertedVaultShares - totalTrackedBalance
2. Handles withdrawals if yield exceeds idle balance:
   - Withdraws required amount from vault to hook
   - Updates vault share balance
3. Updates idle balances
4. Calls `poolManager.donate()` to distribute yield
5. Updates vault state

### Buffer Management

```solidity
function _ensureSwapBuffer(PoolKey calldata key, int256 amount0, int256 amount1)
    private returns (BalanceDelta)
```

1. For each token with configured vault:
   - Calculates current buffer ratio using MAX_BPS (10,000)
   - Checks if ratios within bounds (min/max buffer BPS)
   - Ensures sufficient funds for pending operation
   - Adjusts vault deposits/withdrawals to maintain target ratio

### Fund Management

#### External Fund Deposit

```solidity
function takeFunds(PoolKey calldata key) external
```

1. Locks the vault using vault.lock()
2. Calls internal implementation via encoded function call
3. Accessible by any external caller (permissionless)

#### Internal Fund Processing

```solidity
function _takeFunds(PoolKey calldata key) public selfOnly
```

1. Can only be called through vault lock mechanism
2. For each token with configured vault:
   - Calls vault.take() to move idle token balance
   - Deposits full idle balance into Yearn vault
   - Updates vault share balance
   - Resets idle balance to zero
3. Updates YieldVaults struct with new balances

### Tick Crossing Detection

```solidity
function _checkTickCross(PoolKey calldata key,
    ICLPoolManager.SwapParams calldata params) private returns (bool)
```

1. Gets current tick and price from slot0
2. Gets tick info for current tick
3. Calculates next price using SqrtPriceMath:
   - Uses getNextSqrtPriceFromInput for positive amounts
   - Uses getNextSqrtPriceFromOutput for negative amounts
4. Converts price to tick using TickMath
5. Returns true if tick changes

## Security Considerations

1. **Balance Tracking**

   - Maintain accurate accounting of idle and vault-deployed funds
   - Track vault shares separately from underlying assets

2. **Buffer Management**

   - Enforce minimum buffer constraints
   - Prevent excessive vault withdrawals
   - Handle slippage on vault operations

3. **Yield Distribution**
   - Only distribute to active liquidity positions
   - Ensure accurate yield calculations
   - Handle potential vault share value fluctuations

## Gas Optimization

1. **Storage Access**

   - Cache YieldVaults struct in memory when possible
   - Batch vault operations to minimize calls

2. **Yield Distribution**

   - Only distribute yield on tick crosses or LP changes
   - Optimize vault share calculations

3. **Buffer Management**
   - Only rebalance when significantly out of range
   - Combine vault operations when possible

## Testing Requirements

1. **Yield Calculation Tests**

   - Verify accurate yield tracking
   - Test distribution proportions
   - Validate vault share conversions

2. **Buffer Management Tests**

   - Test ratio maintenance
   - Verify bounds enforcement
   - Check rebalancing triggers

3. **Integration Tests**
   - Full lifecycle with PancakeSwap v4 pools
   - Multiple LP scenarios
   - Complex swap patterns
   - Tick crossing events

## Questions

1.  **Q:** _Does an LP interact with the hook to add / remove positions or the poolManager?_
    **A:** LPs interact with the poolManager

2.  **Q:** _How is the rebalancing of positions done if user directly interacts with the poolManager?_
    **A:** Rebalancing is done when required by checking if it's necessary in the after hooks for swap, addLiq, and removeLiq

3.  **Q:** _Why is the yield paid through donate to active tick because the additional yield is earned through funds in inactive tick?_
    **A:** Yield is given only to the active tick to encourage users to provide liq at-the-money.

4.  **Q:** _If LPs are allowed to have custom range, how does the hook manage each individual position while rebalancing?_
    **A:** The hook is agnostic to individual positions. They can provide (via the poolManager) to the range of their choice. Since yield is distributed through the `donate` method, yield is automatically distrubted to LPs alongside their fees.

5.  **Q:** _What does idle funds / targetBuffer mean? Are these funds deployed in AMM across a range or just left idle to process withdrawals?_
    **A:** The targetBuffer are funds that are left as base asset to provide for low gas cost swaps. Ideally, most swaps will be serviced without having to withdraw from the yield vaults. Withdraws may also be serviced by the before, but the goal of minimizing gas costs is deemed less important when working with modifyLiq operations.
