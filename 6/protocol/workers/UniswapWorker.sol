// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IWorker.sol";
import "../library/SafeMathLib.sol";
import "../library/FullMath.sol";
import "../library/TickMath.sol";
import "../library/FixedPoint96.sol";

import "../../utils/SafeToken.sol";

import "../interfaces/IAggregatorV3Interface.sol";
import "../interfaces/IFlagInterface.sol";
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

  // Mapping from token0, token1 to source
  mapping(address => mapping(address => IAggregatorV3Interface)) public priceFeeds;
  address public usd;
  address private FLAG_ARBITRUM_SEQ_OFFLINE;
  FlagsInterface internal chainlinkFlags;

  function initialize(
    address _operator,
    address _baseToken,
    address _farmToken,
    address _tokenVault,
    IStrategy _addStrat,
    IStrategy _liqStrat,
    uint24 _fee,
    uint32 _twapDuration,
    IUniswapV3Factory _factory,
    address _chainlinkFlags
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

    FLAG_ARBITRUM_SEQ_OFFLINE = address(bytes20(bytes32(uint256(keccak256("chainlink.flags.arbitrum-seq-offline")) - 1)));
    // 0x491B1dDA0A8fa069bbC1125133A975BF4e85a91b
    chainlinkFlags = FlagsInterface(_chainlinkFlags);
    usd = address(0xEeeeeeeEEEeEEeeEEeeEEeEEEEEeeEEEeeEeEeed);
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

    uint256 token0Decimal = IERC20(baseToken).decimals();
    uint256 token1Decimal = IERC20(farmToken).decimals();

    uint256 price0 = getLastPrice(baseToken, farmToken);
    // farmToken -> baseToken
    uint256 amount = SafeMathLib.mul(price0, positions);
    uint256 receiveBaseAmount = SafeMathLib.div(amount, 10**token1Decimal);
    return receiveBaseAmount;
  }

  /// @dev Liquidate the given position by converting it to BaseToken and return back to caller.
  /// @param id The position ID to perform liquidation
  /// @param data Swap token data in the dex protocol.
  function liquidateWithData(uint256 id, bytes calldata data) external override onlyOperator nonReentrant {

    (uint256 closeShare, bytes memory swapData) = abi.decode(data, (uint256, bytes));
    // 1. Convert the position back to LP tokens and use liquidate strategy.
    _removeShare(id, closeShare);

    farmToken.safeTransfer(address(liqStrat), farmToken.balanceOf(address(this)));
    liqStrat.executeWithData(address(0), 0, abi.encode(baseToken, farmToken, 0), swapData);

    // 2. Return all available BaseToken back to the operator.
    uint256 wad = baseToken.myBalance();
    baseToken.safeTransfer(msg.sender, wad);

    emit Liquidate(id, wad);
  }

  /// @dev Internal function to stake all outstanding farm tokens to the given position ID.
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

  /// @dev Internal function to remove shares of the ID and convert to outstanding LP tokens.
  function _removeShare(uint256 id, uint256 closeShare) internal {
    uint256 share = shares[id];

    if (share >= closeShare) {
      ITokenVault(tokenVault).withdraw(farmToken, closeShare, address(this));
      totalShare = SafeMathLib.sub(totalShare, closeShare, "worker:totalShare");
      shares[id] = SafeMathLib.sub(shares[id], closeShare, "worker:sub shares");
      emit RemoveShare(id, closeShare);
    } else {
      _removeShare(id);
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

  function getChainLinkPrice(address token0, address token1) public view returns (uint256, uint256) {
    require(
        address(priceFeeds[token0][token1]) != address(0) || address(priceFeeds[token1][token0]) != address(0),
        "chainLink::getPrice no source"
    );
    bool isRaised = chainlinkFlags.getFlag(FLAG_ARBITRUM_SEQ_OFFLINE);
    if (isRaised) {
        // If flag is raised we shouldn't perform any critical operations
        revert("Chainlink feeds are not being updated");
    }
    if (address(priceFeeds[token0][token1]) != address(0)) {
        (, int256 price, , uint256 lastUpdate, ) = priceFeeds[token0][token1].latestRoundData();
        uint256 decimals = uint256(priceFeeds[token0][token1].decimals());
        return (SafeMathLib.div(SafeMathLib.mul(uint256(price), 1e18), (10**decimals)), lastUpdate);
    }
    (, int256 price, , uint256 lastUpdate, ) = priceFeeds[token1][token0].latestRoundData();
    uint256 decimals = uint256(priceFeeds[token1][token0].decimals());
    return (SafeMathLib.div(SafeMathLib.mul((10**decimals), 1e18), uint256(price)), lastUpdate);
  }

  function setPriceFeed(
      address token0,
      address token1,
      IAggregatorV3Interface source
  ) external onlyOwner {
      require(
          address(priceFeeds[token0][token1]) == address(0),
          "source on existed pair"
      );
      priceFeeds[token0][token1] = source;
  }

  function getLastPrice(address token0, address token1) public view returns (uint256) {
      if (farmToken == token0) {
          (uint price0,) = getChainLinkPrice(token0, usd);
          (uint price1,) = getChainLinkPrice(usd, token1);
          return SafeMathLib.div(SafeMathLib.mul(price0, price1), 1e18);
      } else {
          (uint price0,) = getChainLinkPrice(usd, token0);
          (uint price1,) = getChainLinkPrice(token1, usd);
          return SafeMathLib.div(SafeMathLib.mul(price0, price1), 1e18);
      }
  }
}