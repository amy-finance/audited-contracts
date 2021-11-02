// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

interface InterestModel {
  /// @dev Return the interest rate per second, using 1e18 as denom.
  function getInterestRate(uint256 floating, uint256 debt) external view returns (uint256);
}