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

/// @notice CLYearnVaultV3YieldHook is a ...
/// @dev note the code is not production ready, it is only to share how a hook looks like
contract CLYearnVaultV3YieldHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

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

    mapping(PoolId => YieldVaults) public yieldVaults;
    address public hookManager;

    uint16 public minBufferBps = 2_000;
    uint16 public targetBufferBps = 4_000;
    uint16 public maxBufferBps = 5_000;

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

    constructor(
        ICLPoolManager _poolManager,
        address _hookManager
    ) CLBaseHook(_poolManager) {
        hookManager = _hookManager;
    }

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

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        _ensureSwapBuffer(key);

        return (
            this.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

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

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        _ensureSwapBuffer(
            key,
            int256(balanceDelta.amount0()),
            int256(balanceDelta.amount1())
        );

        return (
            this.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

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

    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta balanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        _ensureSwapBuffer(
            key,
            int256(balanceDelta.amount0()),
            int256(balanceDelta.amount1())
        );

        return (this.afterSwap.selector, 0);
    }

    // TODO: is this right?
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

    function _ensureSwapBuffer(
        PoolKey calldata key
    ) private returns (BalanceDelta) {
        return _ensureSwapBuffer(key, 0, 0);
    }

    function _ensureSwapBuffer(
        PoolKey calldata key,
        int256 amount0,
        int256 amount1
    ) private returns (BalanceDelta _delta) {
        PoolId id = key.toId();

        YieldVaults memory _yieldVaults = yieldVaults[id];

        if (_yieldVaults.vault0 != address(0)) {
            // manage token0
        }

        if (_yieldVaults.vault1 != address(0)) {
            // manage token1
        }

        // do stuff
    }

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
                        address(this)
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
                        address(this)
                    );
                _yieldVaults.amount1IdleBalance = 0;
            } else {
                _yieldVaults.amount1IdleBalance -= donationAmount1;
            }
        }

        yieldVaults[id] = _yieldVaults;

        poolManager.donate(key, donationAmount0, donationAmount1, "");
    }

    function _getVaultForToken(address token) private returns (address vault) {
        // get appropriate vault from a registry
    }
}
