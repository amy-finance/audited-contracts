// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IWorker.sol";
import "../../utils/SafeToken.sol";
import "../library/SafeMathLib.sol";

interface ITokenVault {
  function deposit(address _token, uint _amount) external;
  function withdraw(address _token, uint256 _amount, address _receiver) external;
}

interface IDODOV1Helper {
  function querySellQuoteToken(address dodoV1Pool, uint256 quoteAmount) external view returns (uint256 receivedBaseAmount);
  function querySellBaseToken(address dodoV1Pool, uint256 baseAmount) external view returns (uint256 receivedQuoteAmount);
}

interface IDODOV1 {
  function _BASE_TOKEN_() external view returns (address);
  function _QUOTE_TOKEN_() external view returns (address);
}

contract DodoswapWorker is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IWorker {

  using SafeToken for address;

  /// @notice Events
  event AddShare(uint256 indexed id, uint256 share);
  event RemoveShare(uint256 indexed id, uint256 share);
  event Liquidate(uint256 indexed id, uint256 wad);

  address public dodoPair;
  address public dodoSellHelper;
  address public tokenVault;
  address public wNative;
  address public baseToken;
  address public farmingToken;
  address public operator;

  mapping(uint256 => uint256) public shares;
  mapping(address => bool) public okStrats;
  uint256 public totalShare;
  IStrategy public addStrat;
  IStrategy public liqStrat;

  function initialize(
    address _operator,
    address _baseToken,
    address _farmingToken,
    address _tokenVault,
    IStrategy _addStrat,
    IStrategy _liqStrat,
    address _dodoPair,
    address _dodoSellHelper
  ) public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();

    operator = _operator;
    baseToken = _baseToken;
    farmingToken = _farmingToken;
    tokenVault = _tokenVault;
    addStrat = _addStrat;
    liqStrat = _liqStrat;
    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;

    dodoPair = _dodoPair;
    dodoSellHelper = _dodoSellHelper;
  }

  function setParams(
    address _baseToken,
    address _farmingToken,
    address _tokenVault,
    IStrategy _addStrat,
    IStrategy _liqStrat,
    address _dodoPool,
    address _dodoSellHelper
  ) 
    external onlyOwner 
  {
    baseToken = _baseToken;
    farmingToken = _farmingToken;
    tokenVault = _tokenVault;
    addStrat = _addStrat;
    liqStrat = _liqStrat;

    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;

    dodoPair = _dodoPool;
    dodoSellHelper = _dodoSellHelper;
  }

  /// @dev Require that the caller must be an EOA account to avoid flash loans.
  modifier onlyEOA() {
    require(msg.sender == tx.origin, "DodoswapWorker::onlyEOA:: not eoa");
    _;
  }

  /// @dev Require that the caller must be the operator.
  modifier onlyOperator() {
    require(msg.sender == operator, "DodoswapWorker::onlyOperator:: not operator");
    _;
  }

  /// @dev Work on the given position. Must be called by the operator.
  /// @param id The position ID to work on.
  /// @param user The original user that is interacting with the operator.
  /// @param debt The amount of user debt to help the strategy make decisions.
  /// @param data The encoded data, consisting of strategy address and calldata.
  function workWithData(
    uint256 id, 
    address user, 
    uint256 debt, 
    bytes calldata data, 
    bytes calldata swapData
  )
    override external onlyOperator nonReentrant
  {
    _removeShare(id);

    (address strat, bytes memory ext) = abi.decode(data, (address, bytes));
    require(okStrats[strat], "DodoWorker:: unapproved work strategy");

    if (baseToken.myBalance() > 0) {
      baseToken.safeTransfer(strat, baseToken.myBalance());
    }
    if (farmingToken.myBalance() > 0) {
      farmingToken.safeTransfer(strat, farmingToken.myBalance());
    }
    IStrategy(strat).executeWithData(user, debt, ext, swapData);

    _addShare(id);

    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
  }

  /// @dev Return the amount of BaseToken to receive if we are to liquidate the given position.
  /// @param id The position ID to perform health check.
  function health(uint256 id) external override view returns (uint256) {
    // Get the position's LP balance and LP total supply.
    // 获取该仓位的LP余额和LP的总量
    uint256 lpBalance = shares[id];
    uint positions = lpBalance;

    // 调用Dodo将farmingToken目前能够兑换多少的baseToken
    if (farmingToken == IDODOV1(dodoPair)._BASE_TOKEN_()) {
      (uint256 receiveBaseAmount) = IDODOV1Helper(dodoSellHelper).querySellBaseToken(dodoPair, positions);
      return receiveBaseAmount;
    } else if (farmingToken == IDODOV1(dodoPair)._QUOTE_TOKEN_()) {
      (uint256 receiveBaseAmount) = IDODOV1Helper(dodoSellHelper).querySellQuoteToken(dodoPair, positions);
      return receiveBaseAmount;
    }
    return 0;
  }

  /// @dev Liquidate the given position by converting it to BaseToken and return back to caller.
  /// @param id The position ID to perform liquidation
  /// @param swapData Swap token data in the DODO protocol.
  function liquidateWithData(uint256 id, bytes calldata swapData) external override onlyOperator nonReentrant {

    // 1. Convert the position back to LP tokens and use liquidate strategy.
    _removeShare(id);

    farmingToken.safeTransfer(address(liqStrat), farmingToken.balanceOf(address(this)));
    liqStrat.executeWithData(address(0), 0, abi.encode(baseToken, farmingToken, 0), swapData);

    // 2. Return all available BaseToken back to the operator.
    uint256 wad = baseToken.myBalance();
    baseToken.safeTransfer(msg.sender, wad);

    emit Liquidate(id, wad);
  }

  /// @dev Internal function to stake all outstanding LP tokens to the given position ID.
  function _addShare(uint256 id) internal {
    uint256 balance = farmingToken.balanceOf(address(this));
    if (balance > 0) {
      // 1. Approve token to be spend by tokenVault
      address(farmingToken).safeApprove(address(tokenVault), uint256(-1));

      // 2. Convert balance to share
      uint256 share = balance;

      // 3. Deposit balance to tokenVault
      ITokenVault(tokenVault).deposit(farmingToken, balance);

      // 4. Update shares
      shares[id] = SafeMathLib.add(shares[id], share);
      totalShare = SafeMathLib.add(totalShare, share);

      // 5. Reset approve token
      address(farmingToken).safeApprove(address(tokenVault), 0);
      emit AddShare(id, share);
    }
  }

  /// @dev Internal function to remove shares of the ID and convert to outstanding LP tokens.
  function _removeShare(uint256 id) internal {
    uint256 share = shares[id];
    if (share > 0) {
      uint256 balance = share;
      ITokenVault(tokenVault).withdraw(farmingToken, balance, address(this));
      totalShare = SafeMathLib.sub(totalShare, share, "worker:totalShare");
      shares[id] = 0;
      emit RemoveShare(id, share);
    }
  }

  /// @dev Set the given strategies' approval status.
  /// @param strats The strategy addresses.
  /// @param isOk Whether to approve or unapprove the given strategies.
  function setStrategyOk(address[] calldata strats, bool isOk) external override onlyOwner {
    uint256 len = strats.length;
    for (uint256 idx = 0; idx < len; idx++) {
      okStrats[strats[idx]] = isOk;
    }
  }

  // ========================================

  /// @dev Update critical strategy smart contracts. EMERGENCY ONLY. Bad strategies can steal funds.
  /// @param _addStrat The new add strategy contract.
  /// @param _liqStrat The new liquidate strategy contract.
  function setCriticalStrategies(IStrategy _addStrat, IStrategy _liqStrat) external onlyOwner {
    addStrat = _addStrat;
    liqStrat = _liqStrat;
  }

  function getShares(uint256 id) external override view returns (uint256) {
    return shares[id];
  }
}
