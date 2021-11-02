// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./uniswap-v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import "./uniswap-v3-core/contracts/libraries/LowGasSafeMath.sol";

import "./uniswap-v3-periphery/contracts/base/PeripheryPayments.sol";
import "./uniswap-v3-periphery/contracts/base/PeripheryImmutableState.sol";
import "./uniswap-v3-periphery/contracts/libraries/PoolAddress.sol";
import "./uniswap-v3-periphery/contracts/libraries/CallbackValidation.sol";
import "./uniswap-v3-periphery/contracts/libraries/TransferHelper.sol";
import "./uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

interface IFToken {
    function liquidateBorrow(address borrower, uint256 repayAmount, address fTokenCollateral) external returns (bytes memory);
    function underlying() external returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function withdrawTokens(uint256 withdrawTokensIn) external returns (uint256, bytes memory);
}

/// @title Flash contract implementation
contract FlashLiquidate is IUniswapV3FlashCallback, PeripheryImmutableState, PeripheryPayments {
    
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    ISwapRouter public immutable swapRouter;

    address private vaultBorrow;
    address private vaultColl;
    address private borrower;
    uint256 private repayAmount;

    LiquidateCache private liquidateParams;

    // fee1 is the fee of the pool from the initial borrow
    // fee2 is the fee of the pool swap coll to borrow
    // fee3 not used
    struct FlashParams {
        address token0;
        address token1;
        uint24 fee1;
        uint256 amount0;
        uint256 amount1;
        uint24 fee2;
        uint24 fee3;
    }

    struct LiquidateCache {
        address vaultBorrow;
        address vaultColl;
        address borrower;
        uint256 repayAmount;
    }

    // fee2 and fee3 are the two other fees associated with the two other pools of token0 and token1
    struct FlashCallbackData {
        uint256 amount0;
        uint256 amount1;
        address payer;
        PoolAddress.PoolKey poolKey;
        uint24 poolFee2;
        uint24 poolFee3;
    }

    constructor(
        ISwapRouter _swapRouter,
        address _factory,
        address _WETH9
    ) PeripheryImmutableState(_factory, _WETH9) {
        swapRouter = _swapRouter;
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData
    /// @notice implements the callback called from flash
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        LiquidateCache memory cache = LiquidateCache(vaultBorrow, vaultColl, borrower, repayAmount);

        address token0 = decoded.poolKey.token0;
        address token1 = decoded.poolKey.token1;

        // console.log("balance0: %s", IERC20(token0).balanceOf(address(this)));
        // console.log("balance1: %s", IERC20(token1).balanceOf(address(this)));

        address borrowUnderying = IFToken(cache.vaultBorrow).underlying();
        address collUnderying = IFToken(cache.vaultColl).underlying();
        // console.log("vaultBorrow  %s ", vaultBorrow);
        // console.log("vaultColl    %s ", vaultColl);
        // console.log("repayAmount  %s ", repayAmount);
        // console.log("borUnderying %s ", borrowUnderying);
        TransferHelper.safeApprove(borrowUnderying, cache.vaultBorrow, repayAmount);
        (bool success,) = vaultBorrow.call(
            abi.encodeWithSelector(
                IFToken.liquidateBorrow.selector, 
                cache.borrower, 
                cache.repayAmount, 
                collUnderying
            )
        );
        require(success, "liquidateBorrow failed");
        uint seizeTokens = IFToken(cache.vaultColl).balanceOf(address(this));
        IFToken(vaultColl).withdrawTokens(seizeTokens);
        // console.log("prize: %s", seizeTokens);

        uint256 amount0Owed = 0;
        if (decoded.amount0 > 0) {
            amount0Owed = LowGasSafeMath.add(decoded.amount0, fee1);
        }
        uint256 amount1Owed = 0;
        if (decoded.amount1 > 0) {
            amount1Owed = LowGasSafeMath.add(decoded.amount1, fee1);
        }
        require(amount0Owed == 0 || amount1Owed == 0, "amount0 or amount1 is equal to 0");

        if (collUnderying != borrowUnderying) {
            TransferHelper.safeApprove(collUnderying, address(swapRouter), IERC20(collUnderying).balanceOf(address(this)));
            swapRouter.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: collUnderying,
                    tokenOut: borrowUnderying,
                    fee: decoded.poolFee2,
                    recipient: address(this),
                    deadline: block.timestamp + 200,
                    amountOut: amount0Owed != 0 ? amount0Owed : amount1Owed,
                    amountInMaximum: IERC20(collUnderying).balanceOf(address(this)),
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // console.log("collUnderying swap to token1 %s", amountIn);
        // console.log("balance0:    %s", IERC20(token0).balanceOf(address(this)));
        // console.log("balance1:    %s", IERC20(token1).balanceOf(address(this)));
        // console.log("amount1Owed: %s", amount1Owed);
        require((amount0Owed != 0 ? amount0Owed : amount1Owed) <= IERC20(borrowUnderying).balanceOf(address(this)), "no profits");

        TransferHelper.safeApprove(token0, address(this), amount0Owed);
        TransferHelper.safeApprove(token1, address(this), amount1Owed);

        if (amount0Owed > 0) pay(token0, address(this), msg.sender, amount0Owed);
        if (amount1Owed > 0) pay(token1, address(this), msg.sender, amount1Owed);

        // if profitable pay profits to payer
        if (IERC20(collUnderying).balanceOf(address(this)) > 0) {
            TransferHelper.safeTransfer(collUnderying, decoded.payer, IERC20(collUnderying).balanceOf(address(this)));
        }
        if (IERC20(token0).balanceOf(address(this)) > 0) {
            TransferHelper.safeTransfer(token0, decoded.payer, IERC20(token0).balanceOf(address(this)));
        }
        if (IERC20(token1).balanceOf(address(this)) > 0) {
            TransferHelper.safeTransfer(token1, decoded.payer, IERC20(token1).balanceOf(address(this)));
        }
        // console.log("balance0: %s", IERC20(token0).balanceOf(address(this)));
        // console.log("balance1: %s", IERC20(token1).balanceOf(address(this)));

        delete vaultBorrow;
        delete vaultColl;
        delete repayAmount;
        delete borrower;
    }

    /// @param params The parameters necessary for flash and the callback, passed in as FlashParams
    /// @notice Calls the pools flash function with data needed in `uniswapV3FlashCallback`
    function flashLiquidite(
        FlashParams memory params,
        LiquidateCache memory cache
    )
        external 
    {
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee1});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        vaultBorrow = cache.vaultBorrow;
        vaultColl = cache.vaultColl;
        repayAmount = cache.repayAmount;
        borrower = cache.borrower;

        // recipient of borrowed amounts
        // amount of token0 requested to borrow
        // amount of token1 requested to borrow
        // need amount0 and amount1 in callback to pay back pool
        // recipient of flash should be THIS contract
        pool.flash(
            address(this),
            params.amount0,
            params.amount1,
            abi.encode(
                FlashCallbackData({
                    amount0: params.amount0,
                    amount1: params.amount1,
                    payer: msg.sender,
                    poolKey: poolKey,
                    poolFee2: params.fee2,
                    poolFee3: params.fee3
                })
            )
        );
    }
}