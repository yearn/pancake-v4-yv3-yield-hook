// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {SqrtPriceMath} from "pancake-v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {ICLPoolManager, Tick, Currency} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

/// @title CLYearnVaultV3YieldHook - A Pancake V4 hook for yield generation using Yearn vaults
/// @notice This hook enables liquidity providers to earn additional yield by depositing idle assets into Yearn vaults
/// @dev This hook manages buffer levels for swaps and automatically deposits/withdraws from Yearn vaults
/// @dev Note: This code is not production ready, it is only to demonstrate hook functionality
/// @custom:security-contact security@pancakeswap.com
contract CLYearnVaultV3YieldHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Struct containing vault information for a pool
    /// @param vault0 Address of the Yearn vault for token0
    /// @param amount0TotalBalance Total balance of token0 managed by this hook
    /// @param amount0IdleBalance Idle balance of token0 not yet deposited in vault
    /// @param vault0ShareBalance Amount of vault shares owned for token0
    /// @param vault1 Address of the Yearn vault for token1
    /// @param amount1TotalBalance Total balance of token1 managed by this hook
    /// @param amount1IdleBalance Idle balance of token1 not yet deposited in vault
    /// @param vault1ShareBalance Amount of vault shares owned for token1
    struct YieldVaults {
        address vault0;
        uint256 amount0TotalBalance;
        uint256 amount0IdleBalance;
        uint256 vault0ShareBalance;
        address vault1;
        uint256 amount1TotalBalance;
        uint256 amount1IdleBalance;
        uint256 vault1ShareBalance;
    }

    /// @notice Mapping of pool IDs to their corresponding yield vault information
    mapping(PoolId => YieldVaults) public yieldVaults;

    /// @notice Address of the hook manager contract
    address public hookManager;

    /// @notice Minimum buffer size in basis points (20%)
    uint16 public minBufferBps = 2_000;

    /// @notice Target buffer size in basis points (40%)
    uint16 public targetBufferBps = 4_000;

    /// @notice Maximum buffer size in basis points (50%)
    uint16 public maxBufferBps = 5_000;

    uint256 private constant MAX_BPS = 10_000;

    //event BufferUpdated(
    //    PoolId indexed poolId,
    //    address token,
    //    uint256 newBuffer
    //);
    //event YieldDistributed(
    //    PoolId indexed poolId,
    //    uint256 amount0,
    //    uint256 amount1
    //);
    //event FundsDeployed(PoolId indexed poolId, address token, uint256 amount);
    //event FundsWithdrawn(PoolId indexed poolId, address token, uint256 amount);

    /// @notice Contract constructor
    /// @param _poolManager Address of the Pancake V4 pool manager
    /// @param _hookManager Address of the hook manager contract
    constructor(
        ICLPoolManager _poolManager,
        address _hookManager
    ) CLBaseHook(_poolManager) {
        hookManager = _hookManager;
    }

    /// @notice Returns the hooks that this contract will be registered to
    /// @return bitmap Represents which hooks are implemented
    function getHooksRegistrationBitmap()
        external
        pure
        override
        returns (uint16)
    {
        return
            _hooksRegistrationBitmapFrom(
                Permissions({
                    beforeInitialize: false,
                    afterInitialize: true,
                    beforeAddLiquidity: true,
                    afterAddLiquidity: true,
                    beforeRemoveLiquidity: true,
                    afterRemoveLiquidity: true,
                    beforeSwap: true,
                    afterSwap: true,
                    beforeDonate: false,
                    afterDonate: false,
                    beforeSwapReturnsDelta: false,
                    afterSwapReturnsDelta: false,
                    afterAddLiquidityReturnsDelta: false,
                    afterRemoveLiquidityReturnsDelta: false
                })
            );
    }

    /// @notice Called after a pool is initialized
    /// @dev Sets up the Yearn vaults for both tokens in the pool
    /// @param key The pool key containing token pair and fee information
    /// @param . sqrtPriceX96 The initial sqrt price of the pool
    /// @param . tick The initial tick of the pool
    /// @param . hookData Additional data used by the hook
    /// @return The function selector
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId id = key.toId();

        yieldVaults[id] = YieldVaults({
            vault0: _getVaultForToken(Currency.unwrap(key.currency0)),
            amount0TotalBalance: 0,
            amount0IdleBalance: 0,
            vault0ShareBalance: 0,
            vault1: _getVaultForToken(Currency.unwrap(key.currency1)),
            amount1TotalBalance: 0,
            amount1IdleBalance: 0,
            vault1ShareBalance: 0
        });

        return (this.afterInitialize.selector);
    }

    /// @notice Called before liquidity is added to the pool
    /// @dev Distributes yield if the current tick is within the provided tick range
    /// @param key The pool key containing token pair and fee information
    /// @param params The parameters for adding liquidity
    /// @param . hookData Additional data used by the hook
    /// @return The function selector
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId id = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(id);

        if (tick >= params.tickLower && tick < params.tickUpper) {
            _distributeYield(key);
        }

        return this.beforeAddLiquidity.selector;
    }

    /// @notice Called after liquidity is added to the pool
    /// @dev Ensures proper swap buffer levels are maintained
    /// @param key The pool key containing token pair and fee information
    /// @param . params The parameters for adding liquidity
    /// @param . delta The change in token balances from the operation
    /// @param . hookData Additional data used by the hook
    /// @return selector The function selector
    /// @return deltaAdjusted The adjusted balance delta
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta _beforeDelta,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BalanceDelta _afterDelta)
    {
        _afterDelta = _ensureSwapBuffer(key);
        _takeFunds(key);

        return (this.afterAddLiquidity.selector, _afterDelta);
    }

    /// @notice Called before liquidity is removed from the pool
    /// @dev Distributes yield if the current tick is within the provided tick range
    /// @param key The pool key containing token pair and fee information
    /// @param params The parameters for removing liquidity
    /// @param . hookData Additional data used by the hook
    /// @return The function selector
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        PoolId id = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(id);

        if (tick >= params.tickLower && tick < params.tickUpper) {
            _distributeYield(key);
        }

        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Called after liquidity is removed from the pool
    /// @dev Ensures proper swap buffer levels are maintained after removal
    /// @param key The pool key containing token pair and fee information
    /// @param . params The parameters for removing liquidity
    /// @param balanceDelta The change in token balances from the operation
    /// @param . hookData Additional data used by the hook
    /// @return selector The function selector
    /// @return deltaAdjusted The adjusted balance delta
    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        return (
            this.afterRemoveLiquidity.selector,
            _ensureSwapBuffer(key, balanceDelta)
        );
    }

    /// @notice Called before a swap occurs
    /// @dev Checks if the swap will cross a tick and distributes yield if necessary
    /// @param key The pool key containing token pair and fee information
    /// @param params The parameters for the swap
    /// @param . hookData Additional data used by the hook
    /// @return selector The function selector
    /// @return delta The before swap delta
    /// @return hookFee The fee charged by the hook
    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_checkTickCross(key, params)) {
            _distributeYield(key);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Called after a swap occurs
    /// @dev Ensures proper swap buffer levels are maintained after the swap
    /// @param key The pool key containing token pair and fee information
    /// @param . params The parameters for the swap
    /// @param balanceDelta The change in token balances from the operation
    /// @param . hookData Additional data used by the hook
    /// @return selector The function selector
    /// @return hookWithdraw The amount to withdraw from the hook
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {


        return (this.afterSwap.selector,         _ensureSwapBuffer(
            key,
            balanceDelta
        ));
    }

    /// @notice External function to deposit idle funds into Yearn vaults
    /// @dev Locks the vault and calls internal _takeFunds function
    /// @param key The pool key containing token pair and fee information
    function takeFunds(PoolKey calldata key) external {
        vault.lock(abi.encodeCall(this._takeFunds, (key)));
    }

    /// @notice Internal implementation for depositing idle funds into Yearn vaults
    /// @dev Takes idle balances of both tokens and deposits them into their respective Yearn vaults
    /// @dev Updates vault share balances and resets idle balances to zero
    /// @param key The pool key containing token pair and fee information
    function _takeFunds(PoolKey calldata key) public selfOnly {
        PoolId id = key.toId();
        YieldVaults memory _yieldVaults = yieldVaults[id];

        if (_yieldVaults.vault0 != address(0)) {
            vault.take(
                key.currency0,
                address(this),
                _yieldVaults.amount0IdleBalance
            );
            _yieldVaults.vault0ShareBalance += IERC4626(_yieldVaults.vault0)
                .deposit(_yieldVaults.amount0IdleBalance, address(this));
            _yieldVaults.amount0IdleBalance = 0;
        }

        if (_yieldVaults.vault1 != address(0)) {
            vault.take(
                key.currency1,
                address(this),
                _yieldVaults.amount1IdleBalance
            );
            _yieldVaults.vault1ShareBalance += IERC4626(_yieldVaults.vault1)
                .deposit(_yieldVaults.amount1IdleBalance, address(this));
            _yieldVaults.amount1IdleBalance = 0;
        }
    }

    // TODO: is this right?
    /// @notice Checks if a swap will cross a tick boundary
    /// @dev Calculates the next sqrt price and tick after the swap
    /// @param key The pool key containing token pair and fee information
    /// @param params The parameters for the swap
    /// @return bool True if the swap crosses a tick boundary
    function _checkTickCross(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params
    ) private returns (bool) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick, , ) = poolManager.getSlot0(id);

        Tick.Info memory tickInfo = poolManager.getPoolTickInfo(id, tick);

        uint160 nextSqrtPriceX96;
        if (params.amountSpecified > 0) {
            nextSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                sqrtPriceX96,
                tickInfo.liquidityGross,
                uint256(params.amountSpecified),
                params.zeroForOne
            );
        } else {
            nextSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                sqrtPriceX96,
                tickInfo.liquidityGross,
                uint256(-params.amountSpecified),
                params.zeroForOne
            );
        }

        int24 nextTick = TickMath.getTickAtSqrtRatio(nextSqrtPriceX96);

        return tick != nextTick;
    }

    /// @notice Ensures the swap buffer is maintained within acceptable limits
    /// @dev Overloaded function that calls _ensureSwapBuffer with zero amounts
    /// @param key The pool key containing token pair and fee information
    /// @return BalanceDelta The balance changes required to maintain buffer
    function _ensureSwapBuffer(
        PoolKey calldata key
    ) private returns (BalanceDelta) {
        return _ensureSwapBuffer(key, 0, 0);
    }

    /// @notice Ensures the swap buffer is maintained within acceptable limits
    /// @dev Overloaded function that calls _ensureSwapBuffer with zero amounts
    /// @param key The pool key containing token pair and fee information
    /// @return BalanceDelta The balance changes required to maintain buffer
    function _ensureSwapBuffer(
        PoolKey calldata key,
        BalanceDelta delta
    ) private returns (BalanceDelta) {
        return
            _ensureSwapBuffer(
                key,
                int256(delta.amount0),
                int256(delta.amount1)
            );
    }

    /// @notice Ensures the swap buffer is maintained within acceptable limits
    /// @dev Adjusts buffer levels based on current pool balances and specified amounts
    /// @param key The pool key containing token pair and fee information
    /// @param amount0 The amount of token0 being added/removed
    /// @param amount1 The amount of token1 being added/removed
    /// @return _delta The balance changes required to maintain buffer
    function _ensureSwapBuffer(
        PoolKey calldata key,
        int256 amount0,
        int256 amount1
    ) private returns (BalanceDelta _delta) {
        PoolId id = key.toId();

        YieldVaults memory _yieldVaults = yieldVaults[id];

        if (_yieldVaults.vault0 != address(0)) {
            uint256 poolToken0Balance; // TODO: figure out how to get this
            uint256 currentRatio = MAX_BPS -
                uint256(
                    int256(_yieldVaults.amount0TotalBalance * MAX_BPS) /
                        (int256(poolToken0Balance) + amount0)
                );

            if (
                currentRatio < minBufferBps ||
                currentRatio > maxBufferBps ||
                int256(poolToken0Balance - _yieldVaults.amount0TotalBalance) <
                -amount0
            ) {
                // adjust to target and free required funds
            }
        }

        if (_yieldVaults.vault1 != address(0)) {
            uint256 poolToken1Balance; // TODO: figure out how to get this
            uint256 currentRatio = MAX_BPS -
                uint256(
                    int256(_yieldVaults.amount1TotalBalance * MAX_BPS) /
                        (int256(poolToken1Balance) + amount1)
                );

            if (
                currentRatio < minBufferBps ||
                currentRatio > maxBufferBps ||
                int256(poolToken1Balance - _yieldVaults.amount1TotalBalance) <
                -amount1
            ) {
                // adjust to target and free required funds
            }
        }
    }

    /// @notice Distributes accumulated yield to the pool
    /// @dev Calculates and distributes yield from both token vaults
    /// @param key The pool key containing token pair and fee information
    /// @return donationAmount0 Amount of token0 yield distributed
    /// @return donationAmount1 Amount of token1 yield distributed
    function _distributeYield(
        PoolKey calldata key
    ) private returns (uint256 donationAmount0, uint256 donationAmount1) {
        PoolId id = key.toId();
        YieldVaults memory _yieldVaults = yieldVaults[id];

        if (_yieldVaults.vault0 != address(0)) {
            donationAmount0 =
                (_yieldVaults.amount0IdleBalance +
                    IERC4626(_yieldVaults.vault0).convertToAssets(
                        _yieldVaults.vault0ShareBalance
                    )) -
                _yieldVaults.amount0TotalBalance;
            if (donationAmount0 > _yieldVaults.amount0IdleBalance) {
                _yieldVaults.vault0ShareBalance -= IERC4626(_yieldVaults.vault0)
                    .withdraw(
                        donationAmount0 - _yieldVaults.amount0IdleBalance,
                        address(this),
                        address(vault)
                    );
                _yieldVaults.amount0IdleBalance = 0;
            } else {
                _yieldVaults.amount0IdleBalance -= donationAmount0;
            }
        }

        if (_yieldVaults.vault1 != address(0)) {
            donationAmount1 =
                (_yieldVaults.amount1IdleBalance +
                    IERC4626(_yieldVaults.vault1).convertToAssets(
                        _yieldVaults.vault1ShareBalance
                    )) -
                _yieldVaults.amount1TotalBalance;
            if (donationAmount1 > _yieldVaults.amount1IdleBalance) {
                _yieldVaults.vault1ShareBalance -= IERC4626(_yieldVaults.vault1)
                    .withdraw(
                        donationAmount1 - _yieldVaults.amount1IdleBalance,
                        address(this),
                        address(vault)
                    );
                _yieldVaults.amount1IdleBalance = 0;
            } else {
                _yieldVaults.amount1IdleBalance -= donationAmount1;
            }
        }

        // TODO: do we need to call settle? or is it done automaticall
        poolManager.donate(key, donationAmount0, donationAmount1, "");
        yieldVaults[id] = _yieldVaults;
    }

    /// @notice Retrieves the appropriate Yearn vault for a given token
    /// @dev Queries a registry to find the best vault for the token
    /// @param token The address of the token to find a vault for
    /// @return vault The address of the corresponding Yearn vault
    function _getVaultForToken(address token) private returns (address vault) {
        // get appropriate vault from a registry
    }
}
