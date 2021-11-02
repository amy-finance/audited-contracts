// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

interface IStrategy {
  function executeWithData(address user, uint256 debt, bytes calldata data, bytes calldata swapData) external payable;
}
