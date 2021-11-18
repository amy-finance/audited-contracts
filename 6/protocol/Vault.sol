// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";

import "./interfaces/IWorker.sol";
import "./interfaces/IVault.sol";
import "../utils/SafeToken.sol";
import "./WNativeRelayer.sol";
import "./FToken.sol";

contract Vault is IVault, FToken, OwnableUpgradeSafe {

  using SafeToken for address;
  using SafeMathLib for uint256;

  event AddDebt(uint256 indexed id, uint256 debtShare);
  event RemoveDebt(uint256 indexed id, uint256 debtShare);
  event Work(uint256 indexed id, uint256 principal, uint256 loan);
  event Kill(uint256 indexed id, address indexed killer, address owner, uint256 posVal, uint256 debt, uint256 prize, uint256 left);

  /// @dev Flags for manage execution scope
  uint private constant _NOT_ENTERED = 1;
  uint private constant _ENTERED = 2;
  uint private constant _NO_ID = uint(-1);
  address private constant _NO_ADDRESS = address(1);
  uint private beforeLoan;
  uint private afterLoan;
  /// @dev Temporay variables to manage execution scope
  uint public _IN_EXEC_LOCK;
  uint public POSITION_ID;
  address public STRATEGY;

  /// @dev token - address of the token to be deposited in this pool
  address public token;

  struct Position {
    address worker;
    address owner;
    uint256 debtShare;
    uint256 id;
  }

  struct WorkEntity {
    address worker;
    uint256 principalAmount;
    uint256 loan;
    uint256 maxReturn;
  }

  mapping (uint256 => Position) public positions;
  mapping (uint256 => uint256) public positionToLoan;
  uint256 public nextPositionID;
  uint256 public lastAccrueTime;

  modifier onlyEOA() {
    require(msg.sender == tx.origin, "onlyEoa:: not eoa");
    _;
  }

  /// Get token from msg.sender
  modifier transferTokenToVault(uint256 value) {
    if (msg.value != 0) {
      require(token == config.getWrappedNativeAddr(), "baseToken is not wNative");
      require(value == msg.value, "value != msg.value");
      IWETH(config.getWrappedNativeAddr()).deposit{value: msg.value}();
    } else {
      SafeToken.safeTransferFrom(token, msg.sender, address(this), value);
    }
    _;
  }

  /// Ensure that the function is called with the execution scope
  modifier inExec() {
    require(POSITION_ID != _NO_ID, "inExec:: not within execution scope");
    require(STRATEGY == msg.sender, "inExec:: not from the strategy");
    require(_IN_EXEC_LOCK == _NOT_ENTERED, "inExec:: in exec lock");
    _IN_EXEC_LOCK = _ENTERED;
    _;
    _IN_EXEC_LOCK = _NOT_ENTERED;
  }

  /// Add more debt to the bank debt pool.
  modifier accrue(uint256 value) {
    if (now > lastAccrueTime) {
      uint256 interest = pendingInterest(value);

      uint256 securityFund = divExp(mulExp(reserveFactor, interest), expScale);
      totalReserves = totalReserves.add(securityFund);

      vaultDebtVal = vaultDebtVal.add(interest.sub(securityFund));
      lastAccrueTime = now;
    }
    _;
  }

  /// initialize
  function initialize(
    IVaultConfig _config,
    address _token,
    string memory _name,
    string memory _symbol,
    uint8 _decimals,
    uint256 _initialExchangeRate,
    address _controller,
    address _initialInterestRateModel,
    uint256 _borrowSafeRatio,
    address _arbSys
  ) public initializer {
    OwnableUpgradeSafe.__Ownable_init();

    // init ftoken
    initFtoken(
      _initialExchangeRate,
      _controller,
      _initialInterestRateModel,
      _token,
      _borrowSafeRatio,
      _name, _symbol, _arbSys
    );

    nextPositionID = 1;
    config = _config;
    lastAccrueTime = now;
    token = _token;

    // free-up execution scope
    _IN_EXEC_LOCK = _NOT_ENTERED;
    POSITION_ID = _NO_ID;
    STRATEGY = _NO_ADDRESS;
  }

  /// @dev Return the pending interest that will be accrued in the next call.
  /// @param value Balance value to subtract off address(this).balance when called from payable functions.
  function pendingInterest(uint256 value) public view returns (uint256) {
    if (now > lastAccrueTime) {
      uint256 timePast = SafeMathLib.sub(now, lastAccrueTime, "timePast");
      uint256 balance = SafeMathLib.sub(SafeToken.myBalance(token), value, "pendingInterest: balance");
      uint256 ratePerSec = config.getInterestRate(balance, vaultDebtVal);
      return ratePerSec.mul(vaultDebtVal).mul(timePast).div(1e18);
    } else {
      return 0;
    }
  }

  /// @dev Return the Token debt value given the debt share. Be careful of unaccrued interests.
  /// @param debtShare The debt share to be converted.
  function debtShareToVal(uint256 debtShare) public view returns (uint256) {
    if (vaultDebtShare == 0) return debtShare; // When there's no share, 1 share = 1 val.
    return debtShare.mul(vaultDebtVal).div(vaultDebtShare);
  }

  /// @dev Return the debt share for the given debt value. Be careful of unaccrued interests.
  /// @param debtVal The debt value to be converted.
  function debtValToShare(uint256 debtVal) public view returns (uint256) {
    if (vaultDebtShare == 0) return debtVal; // When there's no share, 1 share = 1 val.
    return debtVal.mul(vaultDebtShare).div(vaultDebtVal);
  }

  /// @dev Return Token value and debt of the given position. Be careful of unaccrued interests.
  /// @param id The position ID to query.
  function positionInfo(uint256 id) public view returns (uint256, uint256) {
    Position storage pos = positions[id];
    return (IWorker(pos.worker).health(id), debtShareToVal(pos.debtShare));
  }

  /// @dev Return the total token entitled to the token holders. Be careful of unaccrued interests.
  function totalToken() public view override returns (uint256) {
    return totalCash.add(totalBorrows).sub(totalReserves);
  }

  /// @dev Add more token to the lending pool. Hope to get some good returns.
  function deposit(uint256 amountToken) external override payable {
    depositToken(amountToken);
  }

  /// @dev Withdraw token from the lending and burning ibToken.
  function withdraw(uint256 share) external override {
    withdrawTokens(share);
  }

  /// @dev Create a new farming position to unlock your yield farming potential.
  /// @param id The ID of the position to unlock the earning. Use ZERO for new position.
  /// @param workEntity The amount of Token to borrow from the pool.
  /// @param data The calldata to pass along to the worker for more working context.
  /// @param swapData Dex swap data
  function work(
    uint id,
    WorkEntity calldata workEntity,
    bytes calldata data,
    bytes calldata swapData
  )
    external payable
    onlyEOA transferTokenToVault(workEntity.principalAmount) accrue(workEntity.principalAmount) nonReentrant
  {
    Position storage pos;
    if (id == 0) {
      require(userToPositionId[msg.sender][workEntity.worker] == 0, "user has position");
      id = nextPositionID++;
      pos = positions[id];
      pos.id = id;
      pos.worker = workEntity.worker;
      pos.owner = msg.sender;
      userToPositions[msg.sender][pos.worker] = pos;
      userToPositionId[msg.sender][pos.worker] = id;
    } else {
      pos = positions[id];
      require(id < nextPositionID, "Vault::work:: bad position id");
      require(pos.worker == workEntity.worker, "Vault::work:: bad position worker");
      require(pos.owner == msg.sender, "Vault::work:: not position owner");
    }
    emit Work(id, workEntity.principalAmount, workEntity.loan);

    POSITION_ID = id;
    (STRATEGY, ) = abi.decode(data, (address, bytes));

    require(config.isWorker(workEntity.worker), "Vault::work:: not a worker");
    require(workEntity.loan == 0 || config.acceptDebt(workEntity.worker), "worker not accept more debt");
    beforeLoan = positionToLoan[id];
    uint256 debt = _removeDebt(id).add(workEntity.loan);
    afterLoan = beforeLoan.add(workEntity.loan);

    uint back;
    {
      uint256 sendBEP20 = workEntity.principalAmount.add(workEntity.loan);
      require(sendBEP20 <= SafeToken.myBalance(token), "insufficient funds in the vault");
      uint256 beforeBEP20 = SafeMathLib.sub(SafeToken.myBalance(token), sendBEP20, "beforeBEP20");
      SafeToken.safeTransfer(token, workEntity.worker, sendBEP20);
      IWorker(workEntity.worker).workWithData(id, msg.sender, debt, data, swapData);
      back = SafeMathLib.sub(SafeToken.myBalance(token), beforeBEP20, "back");
    }

    uint lessDebt = Math.min(debt, back);
    debt = SafeMathLib.sub(debt, lessDebt, "debt");
    if (debt > 0) {
      require(debt >= config.minDebtSize(), "Vault::work too small debt size");
      uint256 health = IWorker(workEntity.worker).health(id);
      uint256 workFactor = config.workFactor(workEntity.worker, debt);
      require(health.mul(workFactor) >= debt.mul(10000), "Vault::work:: bad work factor");
      _addDebt(id, debt);
    }

    POSITION_ID = _NO_ID;
    STRATEGY = _NO_ADDRESS;
    beforeLoan = 0;
    afterLoan = 0;

    if (back > lessDebt) {
      if(token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), back.sub(lessDebt));
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(back.sub(lessDebt));
        SafeToken.safeTransferETH(msg.sender, back.sub(lessDebt));
      } else {
        SafeToken.safeTransfer(token, msg.sender, back.sub(lessDebt));
      }
    }
  }

  /// @dev Kill the given to the position. Liquidate it immediately if killFactor condition is met.
  /// @param id The position ID to be killed.
  /// @param swapData Swap token data in the dex protocol.
  function kill(uint256 id, bytes calldata swapData) external onlyEOA accrue(0) nonReentrant {
    Position storage pos = positions[id];
    require(pos.debtShare > 0, "kill:: no debt");

    uint256 debt = _removeDebt(id);
    uint256 health = IWorker(pos.worker).health(id);
    uint256 killFactor = config.killFactor(pos.worker, debt);
    require(health.mul(killFactor) < debt.mul(10000), "kill:: can't liquidate");

    uint back;
    {
      uint256 beforeToken = SafeToken.myBalance(token);
      IWorker(pos.worker).liquidateWithData(id, swapData);
      back = SafeToken.myBalance(token).sub(beforeToken);
    }
    // 5% of the liquidation value will become a Clearance Fees
    uint256 clearanceFees = back.mul(config.getKillBps()).div(10000);
    // 30% for liquidator reward
    uint256 prize = clearanceFees.mul(securityFactor).div(10000);
    // 30% for $AMY token stakers reward
    // 30% to be converted to $AMY/USDT LP Pair on Dex
    // 10% to security fund
    uint256 securityFund = clearanceFees.sub(prize);

    uint256 rest = back.sub(clearanceFees);
    // Clear position debt and return funds to liquidator and position owner.
    if (prize > 0) {
      if (token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), prize);
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(prize);
        SafeToken.safeTransferETH(msg.sender, prize);
      } else {
        SafeToken.safeTransfer(token, msg.sender, prize);
      }
    }

    if (securityFund > 0) {
      totalReserves = totalReserves.add(securityFund);
    }

    uint lessDebt = Math.min(debt, back);
    debt = SafeMathLib.sub(debt, lessDebt, "debt");
    if (debt > 0) {
      _addDebt(id, debt);
    }
    uint256 left = rest > debt ? rest - debt : 0;
    if (left > 0) {
      if (token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), left);
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(left);
        SafeToken.safeTransferETH(pos.owner, left);
      } else {
        SafeToken.safeTransfer(token, pos.owner, left);
      }
    }
    emit Kill(id, msg.sender, pos.owner, health, debt, prize, left);
  }

  /// @dev Internal function to add the given debt value to the given position.
  function _addDebt(uint256 id, uint256 debtVal) internal {
    Position storage pos = positions[id];
    uint256 debtShare = debtValToShare(debtVal);
    pos.debtShare = pos.debtShare.add(debtShare);
    vaultDebtShare = vaultDebtShare.add(debtShare);
    vaultDebtVal = vaultDebtVal.add(debtVal);

    uint loan = afterLoan;
    positionToLoan[id] = loan;
    borrowInternalForLeverage(pos.worker, loan);

    userToPositions[msg.sender][pos.worker].debtShare = pos.debtShare;

    emit AddDebt(id, debtShare);
  }

  /// @dev Internal function to clear the debt of the given position. Return the debt value.
  function _removeDebt(uint256 id) internal returns (uint256) {
    Position storage pos = positions[id];
    uint256 debtShare = pos.debtShare;
    if (debtShare > 0) {
      uint256 debtVal = debtShareToVal(debtShare);
      pos.debtShare = 0;
      vaultDebtShare = SafeMathLib.sub(vaultDebtShare, debtShare, "vaultDebtShare");
      vaultDebtVal = SafeMathLib.sub(vaultDebtVal, debtVal, "vaultDebtVal");

      repayInternalForLeverage(pos.worker, positionToLoan[id]);
      positionToLoan[id] = 0;

      userToPositions[msg.sender][pos.worker].debtShare = pos.debtShare;

      emit RemoveDebt(id, debtShare);
      return debtVal;
    } else {
      return 0;
    }
  }

  /// @dev Update bank configuration to a new address. Must only be called by owner.
  /// @param _config The new configurator address.
  function updateConfig(IVaultConfig _config) external onlyOwner {
    config = _config;
  }

  /// @dev Fallback function to accept ETH. Workers will send ETH back the pool.
  receive() external payable {}

  mapping (address => bool) public isOldFarmMigrated;
  // user => worker => position
  mapping (address => mapping (address => Position)) public userToPositions;

  event OldFarmDataMigrated(address _sender, uint256 _amount, address _oldFarm, address _newFarm);

  function migrateOldFarm() external {
    require(!isOldFarmMigrated[msg.sender], "Already migrated");
    isOldFarmMigrated[msg.sender] = true;

    (address farm, uint256 poolId) = config.getFarmConfig(address(this));
    (address oldFarm, uint256 oldPoolId) = config.getOldFarmConfig(address(this));
    PoolUser memory user = IFarm(oldFarm).getPoolUser(oldPoolId, msg.sender);
    PoolUser memory userNew = IFarm(farm).getPoolUser(poolId, msg.sender);

    require(user.stakingAmount == 0, "Staking amount should be zero");

    uint256 amount = accountTokens[msg.sender].sub(userNew.stakingAmount);

    IFarm(farm).stake(poolId, msg.sender, amount);
    emit OldFarmDataMigrated(msg.sender, amount, oldFarm, farm);
  }
}
