[Previous sections remain unchanged until Core Functions]

## Core Functions

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
    uint256 amount0TotalBalance;    // Total tracked balance for token0
    uint256 amount0IdleBalance;     // Unmoved balance for token0
    uint256 vault0ShareBalance;     // Vault shares for token0
    address vault1;
    uint256 amount1TotalBalance;    // Total tracked balance for token1
    uint256 amount1IdleBalance;     // Unmoved balance for token1
    uint256 vault1ShareBalance;     // Vault shares for token1
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
1. Calculates yield since last distribution:
   - Current idle balance + converted vault shares - total tracked balance
2. Withdraws yield from vaults if necessary
3. Updates idle balances
4. Calls `poolManager.donate()` to distribute yield
5. Updates vault state

### Buffer Management
```solidity
function _ensureSwapBuffer(PoolKey calldata key, int256 amount0, int256 amount1)
    private returns (BalanceDelta)
```
1. Calculates current buffer ratios for both tokens
2. Checks if ratios are within bounds (min/max buffer BPS)
3. Ensures sufficient funds for pending operation
4. Adjusts vault deposits/withdrawals to maintain target ratio

### Fund Management

#### External Fund Deposit
```solidity
function takeFunds(PoolKey calldata key) external
```

The primary entry point for depositing idle funds into Yearn vaults. This function:
1. Locks the vault
2. Calls internal implementation via encoded function call
3. Accessible by any external caller (permissionless)

#### Internal Fund Processing
```solidity
function _takeFunds(PoolKey calldata key) external selfOnly
```

Handles the actual deposit of idle funds into Yearn vaults:

1. **State Loading**
   - Retrieves pool ID from key
   - Loads current YieldVaults state into memory

2. **Token Processing**
   - If vault is configured:
     - Calls `vault.take()` to move idle token balance to hook
     - Deposits full idle balance into Yearn vault
     - Updates vault share balance with received shares
     - Resets idle balance to zero

3. **State Updates**
   - Updates YieldVaults struct with new balances
   - Maintains accurate accounting of shares and idle funds

### Tick Crossing Detection
```solidity
function _checkTickCross(PoolKey calldata key, 
    ICLPoolManager.SwapParams calldata params) private returns (bool)
```
1. Gets current tick and price
2. Calculates next price based on swap parameters
3. Determines if swap will cross to new tick

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

1. 
    **Q:** *Does an LP interact with the hook to add / remove positions or the poolManager?*
    **A:** LPs interact with the poolManager

2. 
    **Q:** *How is the rebalancing of positions done if user directly interacts with the poolManager?*
    **A:** Rebalancing is done when required by checking if it's necessary in the after hooks for swap, addLiq, and removeLiq

3. 
    **Q:** *Why is the yield paid through donate to active tick because the additional yield is earned through funds in inactive tick?*
    **A:** Yield is given only to the active tick to encourage users to provide liq at-the-money.

4. 
    **Q:** *If LPs are allowed to have custom range, how does the hook manage each individual position while rebalancing?*
    **A:** The hook is agnostic to individual positions. They can provide (via the poolManager) to the range of their choice. Since yield is distributed through the `donate` method, yield is automatically distrubted to LPs alongside their fees.

5. 
    **Q:** *What does idle funds / targetBuffer mean? Are these funds deployed in AMM across a range or just left idle to process withdrawals?*
    **A:** The targetBuffer are funds that are left as base asset to provide for low gas cost swaps. Ideally, most swaps will be serviced without having to withdraw from the yield vaults. Withdraws may also be serviced by the before, but the goal of minimizing gas costs is deemed less important when working with modifyLiq operations. 

[Rest of the specification remains unchanged]

Would you like me to add more detail to any part of the fund management documentation or update other sections to better align with these functions?