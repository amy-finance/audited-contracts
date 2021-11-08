// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../../interfaces/IStrategy.sol";
import "../../interfaces/univ3/ISwapRouter.sol";
import "../../../utils/SafeToken.sol";
import "../../library/Path.sol";


contract StrategyWithdrawTrading is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IStrategy {
  using SafeToken for address;
  using SafeMath for uint256;

  /// _router The Uniswap router smart contract.
  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();
  }

  /// Execute worker strategy.
  function executeWithData(
    address /* user */,
    uint256 /* debt */,
    bytes calldata /* _data */,
    bytes calldata _swapData
  )
    external override payable nonReentrant
  {
    (
      address baseToken,
      address farmToken,
      address router,
      bytes memory _path,
      uint256 amountIn,
      uint256 amountOutMin
    ) = abi.decode(_swapData, (address, address, address, bytes, uint256, uint256));

    // 1. Approve router to do their stuffs
    farmToken.safeApprove(router, uint256(-1));

    // 2. Convert farm tokens to base tokens.
    ISwapRouter(router).exactInput(ISwapRouter.ExactInputParams({
        path: _path,
        recipient: address(this),
        deadline: now,
        amountIn: amountIn,
        amountOutMinimum: amountOutMin
    }));

    require(baseToken.myBalance() > 0, "swap baseToken is zero");
    // 3. Transfer Farm Token to Vault
    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
    farmToken.safeTransfer(msg.sender, farmToken.myBalance());

    // 4. Reset approval for safety reason
    farmToken.safeApprove(router, 0);
  }
}
