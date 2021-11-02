// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

import "./interfaces/IVaultConfig.sol";
import "./interfaces/IWorkerConfig.sol";
import "./interfaces/InterestModel.sol";

contract ConfigurableInterestVaultConfig is IVaultConfig, OwnableUpgradeSafe {
  /// The minimum debt size per position.
  uint256 public override minDebtSize;
  /// The portion of interests allocated to the reserve pool.
  uint256 public override getReservePoolBps;
  /// The reward for successfully killing a position.
  uint256 public override getKillBps;
  /// Mapping for worker address to its configuration.
  mapping(address => IWorkerConfig) public workers;
  /// Interest rate model
  InterestModel public interestModel;
  // address for wrapped native eg WBNB, WETH
  address public wrappedNative;
  // address for wNtive Relayer
  address public wNativeRelayer;

  // address of fairLaunch contract
  address public fairLaunch;

  mapping (address => address) public farms;
  mapping (address => uint256) public poolIds;
  mapping (address => address) public oldFarms;
  mapping (address => uint256) public oldPoolIds;

  function initialize(
    uint256 _minDebtSize,
    uint256 _reservePoolBps,
    uint256 _killBps,
    InterestModel _interestModel,
    address _wrappedNative,
    address _wNativeRelayer
  ) public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    setParams(
      _minDebtSize, _reservePoolBps, _killBps, _interestModel, _wrappedNative, _wNativeRelayer);
  }

  /// @dev Set all the basic parameters. Must only be called by the owner.
  /// @param _minDebtSize The new minimum debt size value.
  /// @param _reservePoolBps The new interests allocated to the reserve pool value.
  /// @param _killBps The new reward for killing a position value.
  /// @param _interestModel The new interest rate model contract.
  function setParams(
    uint256 _minDebtSize,
    uint256 _reservePoolBps,
    uint256 _killBps,
    InterestModel _interestModel,
    address _wrappedNative,
    address _wNativeRelayer
  ) public onlyOwner {
    minDebtSize = _minDebtSize;
    getReservePoolBps = _reservePoolBps;
    getKillBps = _killBps;
    interestModel = _interestModel;
    wrappedNative = _wrappedNative;
    wNativeRelayer = _wNativeRelayer;
  }

  /// @dev Set the configuration for the given workers. Must only be called by the owner.
  function setWorkers(address[] calldata addrs, IWorkerConfig[] calldata configs) external onlyOwner {
    require(addrs.length == configs.length, "ConfigurableInterestVaultConfig::setWorkers:: bad length");
    for (uint256 idx = 0; idx < addrs.length; idx++) {
      workers[addrs[idx]] = configs[idx];
    }
  }

  function setMinDebtSize(uint256 _minDebtSize) external onlyOwner {
    minDebtSize = _minDebtSize;
  }
  function setReservePoolBps(uint256 _reservePoolBps) external onlyOwner {
    getReservePoolBps = _reservePoolBps;
  }
  function setKillBps(uint256 _killBps) external onlyOwner {
    getKillBps = _killBps;
  }
  function setInterestModel(InterestModel _interestModel) external onlyOwner {
    interestModel = _interestModel;
  }
  function setWrappedNative(address _wrappedNative) external onlyOwner {
    wrappedNative = _wrappedNative;
  }
  function setWNativeRelayer(address _wNativeRelayer) external onlyOwner {
    wNativeRelayer = _wNativeRelayer;
  }

  /// @dev Return the address of wrapped native token
  function getWrappedNativeAddr() external view override returns (address) {
    return wrappedNative;
  }

  function getWNativeRelayer() external view override returns (address) {
    return wNativeRelayer;
  }

  /// @dev Return the address of fair launch contract
  function getFairLaunchAddr() external view override returns (address) {
    return fairLaunch;
  }

  /// @dev Return the interest rate per second, using 1e18 as denom.
  function getInterestRate(uint256 floating, uint256 debt) external view override returns (uint256) {
    return interestModel.getInterestRate(floating, debt);
  }

  /// @dev Return whether the given address is a worker.
  function isWorker(address worker) external view override returns (bool) {
    return address(workers[worker]) != address(0);
  }

  /// @dev Return whether the given worker accepts more debt. Revert on non-worker.
  function acceptDebt(address worker) external view override returns (bool) {
    return workers[worker].acceptDebt(worker);
  }

  /// @dev Return the work factor for the worker + debt, using 1e4 as denom. Revert on non-worker.
  function workFactor(address worker, uint256 debt) external view override returns (uint256) {
    return workers[worker].workFactor(worker, debt);
  }

  /// @dev Return the kill factor for the worker + debt, using 1e4 as denom. Revert on non-worker.
  function killFactor(address worker, uint256 debt) external view override returns (uint256) {
    return workers[worker].killFactor(worker, debt);
  }

  function setFarmConfig(address _vault, uint256 _poolId, address _farm) external override onlyOwner {
    farms[_vault] = _farm;
    poolIds[_vault] = _poolId;
  }

  function getFarmConfig(address _vault) external override view returns(address farm, uint256 poolId) {
    farm = farms[_vault];
    poolId = poolIds[_vault];
  }

  function setOldFarmConfig(address _vault, uint256 _poolId, address _farm) external override onlyOwner {
    oldFarms[_vault] = _farm;
    oldPoolIds[_vault] = _poolId;
  }

  function getOldFarmConfig(address _vault) external override view returns(address farm, uint256 poolId) {
    farm = oldFarms[_vault];
    poolId = oldPoolIds[_vault];
  }
}
