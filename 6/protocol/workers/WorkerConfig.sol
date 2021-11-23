// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "../interfaces/IWorkerConfig.sol";
import "../IPriceOracle.sol";
import "../../utils/SafeToken.sol";

contract WorkerConfig is OwnableUpgradeSafe, IWorkerConfig {
  using SafeToken for address;
  using SafeMath for uint256;

  struct Config {
    bool acceptDebt;
    uint64 workFactor;
    uint64 killFactor;
    uint64 maxPriceDiff;
  }

  IPriceOracle public oracle;
  mapping (address => Config) public workers;

  function initialize(IPriceOracle _oracle) public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    oracle = _oracle;
  }

  /// @dev Set oracle address. Must be called by owner.
  function setOracle(IPriceOracle _oracle) external onlyOwner {
    oracle = _oracle;
  }

  /// @dev Set worker configurations. Must be called by owner.
  function setConfigs(address[] calldata addrs, Config[] calldata configs) external onlyOwner {
    uint256 len = addrs.length;
    require(configs.length == len, "WorkConfig::setConfigs:: bad len");
    for (uint256 idx = 0; idx < len; idx++) {
      workers[addrs[idx]] = Config({
        acceptDebt: configs[idx].acceptDebt,
        workFactor: configs[idx].workFactor,
        killFactor: configs[idx].killFactor,
        maxPriceDiff: configs[idx].maxPriceDiff
      });
    }
  }

  /// @dev Return whether the given worker is stable, presumably not under manipulation.
  function isStable(address worker) public pure returns (bool) {
    return true;
  }

  /// @dev Return whether the given worker accepts more debt.
  function acceptDebt(address worker) external override view returns (bool) {
    require(isStable(worker), "WorkerConfig::acceptDebt:: !stable");
    return workers[worker].acceptDebt;
  }

  /// @dev Return the work factor for the worker + BaseToken debt, using 1e4 as denom.
  function workFactor(address worker, uint256 /* debt */) external override view returns (uint256) {
    require(isStable(worker), "WorkerConfig::workFactor:: !stable");
    return uint256(workers[worker].workFactor);
  }

  /// @dev Return the kill factor for the worker + BaseToken debt, using 1e4 as denom.
  function killFactor(address worker, uint256 /* debt */) external override view returns (uint256) {
    require(isStable(worker), "WorkerConfig::killFactor:: !stable");
    return uint256(workers[worker].killFactor);
  }
}