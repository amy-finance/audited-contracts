// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

interface IWorker {
  /// @dev For dodo  
  function workWithData(uint256 id, address user, uint256 debt, bytes calldata data, bytes calldata swapData) external;

  /// @dev Return the amount of ETH wei to get back if we are to liquidate the position.
  function health(uint256 id) external view returns (uint256);

  /// @dev Liquidate the given position to token. Send all token back to its Vault.
  function liquidateWithData(uint256 id, bytes calldata swapData) external;

  /// @dev SetStretegy that be able to executed by the worker.
  function setStrategyOk(address[] calldata strats, bool isOk) external;

  /// @dev Position shares
  function getShares(uint256 id) external view returns(uint256);
}
