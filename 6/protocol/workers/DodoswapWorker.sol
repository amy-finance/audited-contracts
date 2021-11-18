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

  /// 需要是一个EOA账户, 避免闪电贷攻击
  /// @dev Require that the caller must be an EOA account to avoid flash loans.
  modifier onlyEOA() {
    require(msg.sender == tx.origin, "DodoswapWorker::onlyEOA:: not eoa");
    _;
  }

  /// 只有操作者才能调用
  /// @dev Require that the caller must be the operator.
  modifier onlyOperator() {
    require(msg.sender == operator, "DodoswapWorker::onlyOperator:: not operator");
    _;
  }

  /// 操作给定的仓位，必须是操作者才能调用
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
    // 1. 将这个仓位转换为 shares
    _removeShare(id);

    // 2. 解析出策略 和 附加数据
    (address strat, bytes memory ext) = abi.decode(data, (address, bytes));
    require(okStrats[strat], "DodoWorker:: unapproved work strategy");

    if (baseToken.myBalance() > 0) {
      baseToken.safeTransfer(strat, baseToken.myBalance());
    }
    if (farmingToken.myBalance() > 0) {
      farmingToken.safeTransfer(strat, farmingToken.myBalance());
    }
    IStrategy(strat).executeWithData(user, debt, ext, swapData);

    // 3. 把 Farming tokens 放到资金池中
    _addShare(id);

    // 4. 将剩余的BaseToken返还给操作者, 找零操作
    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
  }

  /// 如果我们要清算给定头寸，则返回能接收到的BaseToken的数量
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

  /// 清算指定的头寸, 转换成BaseToken返回给调用者
  /// @dev Liquidate the given position by converting it to BaseToken and return back to caller.
  /// @param id The position ID to perform liquidation
  /// @param swapData Swap token data in the DODO protocol.
  function liquidateWithData(uint256 id, bytes calldata swapData) external override onlyOperator nonReentrant {

    // 1. 把仓位的份额换算成LP tokens 并用清算策略进行清算
    // 1. Convert the position back to LP tokens and use liquidate strategy.
    _removeShare(id);

    farmingToken.safeTransfer(address(liqStrat), farmingToken.balanceOf(address(this)));
    liqStrat.executeWithData(address(0), 0, abi.encode(baseToken, farmingToken, 0), swapData);

    // 2. 把所有可用的BaseToken都返回给操作者
    // 2. Return all available BaseToken back to the operator.
    uint256 wad = baseToken.myBalance();
    baseToken.safeTransfer(msg.sender, wad);

    emit Liquidate(id, wad);
  }

  /// 内部函数, 添加指定ID的池子的份额
  /// @dev Internal function to stake all outstanding LP tokens to the given position ID.
  function _addShare(uint256 id) internal {
    uint256 balance = farmingToken.balanceOf(address(this));
    if (balance > 0) {
      // 1. 给tokenVault合约授权
      // 1. Approve token to be spend by tokenVault
      address(farmingToken).safeApprove(address(tokenVault), uint256(-1));

      // 2. 把余额转换为份额
      // 2. Convert balance to share
      uint256 share = balance;
      // 3. 将余额充值到tokenVault合约中
      // 3. Deposit balance to tokenVault
      ITokenVault(tokenVault).deposit(farmingToken, balance);

      // 4. 更新份额
      // 4. Update shares
      shares[id] = SafeMathLib.add(shares[id], share);
      totalShare = SafeMathLib.add(totalShare, share);

      // 5. 复位token的授权
      // 5. Reset approve token
      address(farmingToken).safeApprove(address(tokenVault), 0);
      emit AddShare(id, share);
    }
  }

  /// 内部函数，减少指定ID的池子的份额
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

  /// 设置策略授权状态
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

  /// 设置危机策略, 不好的策略能够窃取资金
  /// @dev Update critical strategy smart contracts. EMERGENCY ONLY. Bad strategies can steal funds.
  /// @param _addStrat The new add strategy contract.
  /// @param _liqStrat The new liquidate strategy contract.
  function setCriticalStrategies(IStrategy _addStrat, IStrategy _liqStrat) external onlyOwner {
    addStrat = _addStrat;
    liqStrat = _liqStrat;
  }

  function getShares(uint256 id) external view override returns(uint256) {
    return shares[id];
  }

}
