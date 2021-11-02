// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import "../../interfaces/IStrategy.sol";
import "../../../utils/SafeToken.sol";
import "../../../utils/Address.sol";

contract DodoStrategyWithdrawTrading is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IStrategy {
  using Address for address;
  using SafeToken for address;
  using SafeMath for uint256;

  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();
  }

  /// @dev Execute worker strategy. Take BaseToken. Return LP tokens.
  /// @param data Extra calldata information passed along to this strategy.
  function executeWithData(
    address /* user */, 
    uint256 /* debt */, 
    bytes calldata data, 
    bytes calldata swapData
  )
    external override payable nonReentrant 
  {
    // 1. Find out what farming token we are dealing with and min additional LP tokens.
    (
      address baseToken,
      address farmingToken,
      address dodoApprove,
      address dodoProxy
    ) = abi.decode(data, (address, address, address, address));

    // 2. Approve router to do their stuffs
    farmingToken.safeApprove(dodoApprove, uint256(-1));

    // 3. Convert farming tokens to base tokens.
    bytes memory returndata = dodoProxy.functionCall(swapData, "execute: low-level call failed!");
    if (returndata.length > 0) { // Return data is optional
      // solhint-disable-next-line max-line-length
      require(abi.decode(returndata, (bool)), "execute: DODO Proxy operation did not succeed!");
    }

    require(baseToken.myBalance() > 0, "swap baseToken is zero");
    // 4. Transfer Farming Token to Vault
    baseToken.safeTransfer(msg.sender, baseToken.myBalance());

    // 5. Reset approval for safety reason
    farmingToken.safeApprove(dodoApprove, 0);
  }
}
