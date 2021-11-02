// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IWorker.sol";
import "../../utils/SafeToken.sol";
import "../library/SafeMathLib.sol";
import "../library/FullMath.sol";
import "../library/TickMath.sol";
import "../library/FixedPoint96.sol";

import "../interfaces/univ3/IUniswapV3Pool.sol";
import "../interfaces/univ3/IUniswapV3Factory.sol";
import "../interfaces/univ3/ISwapRouter.sol";

interface ITokenVault {
  function deposit(address _token, uint _amount) external;
  function withdraw(address _token, uint256 _amount, address _receiver) external;
}

contract UniswapWorker is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IWorker {

  using SafeToken for address;

  // Events
  event AddShare(uint256 indexed id, uint256 share);
  event RemoveShare(uint256 indexed id, uint256 share);
  event Liquidate(uint256 indexed id, uint256 wad);

  IUniswapV3Pool public pool;
  IUniswapV3Factory public factory;

  address public tokenVault;
  address public wNative;
  address public baseToken;
  address public farmToken;
  address public operator;
  uint24 public fee;
  uint32 public twapDuration;

  mapping(uint256 => uint256) public shares;
  mapping(address => bool) public okStrats;
  uint256 public totalShare;
  IStrategy public addStrat;
  IStrategy public liqStrat;

  function initialize(
    address _operator,
    address _baseToken,
    address _farmToken,
    address _tokenVault,
    IStrategy _addStrat,
    IStrategy _liqStrat,
    uint24 _fee,
    uint32 _twapDuration,
    IUniswapV3Factory _factory
  ) public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();

    operator = _operator;

    baseToken = _baseToken;
    farmToken = _farmToken;
    tokenVault = _tokenVault;

    fee = _fee;
    factory = _factory;
    twapDuration = _twapDuration;
    pool = IUniswapV3Pool(factory.getPool(baseToken, farmToken, fee));

    addStrat = _addStrat;
    liqStrat = _liqStrat;
    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;
  }

  function setParams(
    IStrategy _addStrat,
    IStrategy _liqStrat
  )
    external onlyOwner
  {
    addStrat = _addStrat;
    liqStrat = _liqStrat;

    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;
  }

  /// @dev Require that the caller must be an EOA account to avoid flash loans.
  modifier onlyEOA() {
    require(msg.sender == tx.origin, "worker not eoa");
    _;
  }

  /// @dev Require that the caller must be the operator.
  modifier onlyOperator() {
    require(msg.sender == operator, "worker::not operator");
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
    require(okStrats[strat], "unapproved work strategy");

    if (baseToken.myBalance() > 0) {
      baseToken.safeTransfer(strat, baseToken.myBalance());
    }
    if (farmToken.myBalance() > 0) {
      farmToken.safeTransfer(strat, farmToken.myBalance());
    }
    IStrategy(strat).executeWithData(user, debt, ext, swapData);

    _addShare(id);

    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
  }

  /// @dev Return the amount of BaseToken to receive if we are to liquidate the given position.
  /// @param id The position ID to perform health check.
  function health(uint256 id) external override view returns (uint256) {
    uint256 positions = shares[id];

    address token0 = IUniswapV3Pool(pool).token0();
    address token1 = IUniswapV3Pool(pool).token1();
    uint256 token0Decimal = IERC20(token0).decimals();
    uint256 token1Decimal = IERC20(token1).decimals();

    uint256 price0 = getPrice(token0, token1);
    uint256 receiveBaseAmount = 0;
    // farmToken -> baseToken
    if (farmToken == token0) {
      uint256 amount = SafeMathLib.mul(price0, positions);
      uint256 decimal = SafeMathLib.sub(18, token0Decimal);
      uint256 value = SafeMathLib.div(amount, 10**decimal);
      receiveBaseAmount = SafeMathLib.div(value, 10**token0Decimal);
    } else if (farmToken == token1) {
      uint256 decimal = SafeMathLib.sub(18, token0Decimal);
      uint256 price0_ = SafeMathLib.div(price0, 10**decimal);
      uint256 price1 = SafeMathLib.mul(SafeMathLib.div(1e36, price0), 10**token1Decimal);
      uint256 amount = SafeMathLib.mul(price1, positions);
      receiveBaseAmount = SafeMathLib.div(SafeMathLib.div(amount, 10**token1Decimal), 1e18);
    }
    return receiveBaseAmount;
  }

  /// @dev Liquidate the given position by converting it to BaseToken and return back to caller.
  /// @param id The position ID to perform liquidation
  /// @param swapData Swap token data in the DODO protocol.
  function liquidateWithData(uint256 id, bytes calldata swapData) external override onlyOperator nonReentrant {

    // 1. Convert the position back to LP tokens and use liquidate strategy.
    _removeShare(id);

    farmToken.safeTransfer(address(liqStrat), farmToken.balanceOf(address(this)));
    liqStrat.executeWithData(address(0), 0, abi.encode(baseToken, farmToken, 0), swapData);

    // 2. Return all available BaseToken back to the operator.
    uint256 wad = baseToken.myBalance();
    baseToken.safeTransfer(msg.sender, wad);

    emit Liquidate(id, wad);
  }

  /// @dev Internal function to stake all outstanding LP tokens to the given position ID.
  function _addShare(uint256 id) internal {
    uint256 balance = farmToken.balanceOf(address(this));
    if (balance > 0) {
      // 1. Approve token to be spend by tokenVault
      address(farmToken).safeApprove(address(tokenVault), uint256(-1));

      // 2. Deposit balance to tokenVault
      ITokenVault(tokenVault).deposit(farmToken, balance);

      // 3. Update shares
      shares[id] = SafeMathLib.add(shares[id], balance);
      totalShare = SafeMathLib.add(totalShare, balance);

      // 4. Reset approve token
      address(farmToken).safeApprove(address(tokenVault), 0);
      emit AddShare(id, balance);
    }
  }

  /// @dev Internal function to remove shares of the ID and convert to outstanding LP tokens.
  function _removeShare(uint256 id) internal {
    uint256 share = shares[id];
    if (share > 0) {
      ITokenVault(tokenVault).withdraw(farmToken, share, address(this));
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

  function getSqrtTwapX96(address tokenIn, address tokenOut, uint32 twapInterval) public view returns (uint160 sqrtPriceX96) {
    IUniswapV3Pool uniswapV3Pool = IUniswapV3Pool(factory.getPool(tokenIn, tokenOut, fee));
    if (twapInterval == 0) {
        // return the current price if twapInterval == 0
        (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(uniswapV3Pool).slot0();
    } else {
      uint32[] memory secondsAgos = new uint32[](2);
      secondsAgos[0] = twapInterval; // before
      secondsAgos[1] = 0; // now

      (int56[] memory tickCumulatives,) = IUniswapV3Pool(uniswapV3Pool).observe(secondsAgos);

      // tick(imprecise as it's an integer) to price
      sqrtPriceX96 = TickMath.getSqrtRatioAtTick(int24((tickCumulatives[1] - tickCumulatives[0]) / twapInterval));
    }
  }

  function getPrice(address tokenIn, address tokenOut) public view returns(uint256 priceX96) {
    uint160 sqrtPriceX96 = getSqrtTwapX96(tokenIn, tokenOut, twapDuration);
    return FullMath.mulDiv(uint(sqrtPriceX96), uint(sqrtPriceX96), FixedPoint96.Q96) * 1e18 >> (96);
  }

  function setTwapInterval(uint32 _twapDuration) external onlyOwner {
    twapDuration = _twapDuration;
  }
}