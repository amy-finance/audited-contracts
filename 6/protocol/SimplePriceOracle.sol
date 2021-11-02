// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./IPriceOracle.sol";

contract SimplePriceOracle is OwnableUpgradeSafe, IPriceOracle {
  event PriceUpdate(address indexed token0, address indexed token1, uint256 price);

  address public feeder;
  address public baseToken;
  uint public bufferDay;

  struct PriceData {
    uint192 price;
    uint64 lastUpdate;
  }

  mapping (address => mapping (address => PriceData)) public store;

  modifier onlyFeeder() {
    require(msg.sender == feeder, "SimplePriceOracle::onlyFeeder:: only feeder");
    _;
  }

  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    bufferDay = 7 days;
    feeder = msg.sender;
  }

  function setFeeder(address _feeder) public onlyOwner {
    feeder = _feeder;
  }

  function setBaseToken(address _baseToken) public onlyOwner {
    baseToken = _baseToken;
  }

  function setBufferDay(uint _bufferDay) public onlyOwner {
    bufferDay = _bufferDay;
  }

  /// @dev Set the prices of the token token pairs. Must be called by the owner.
  function setPrices(
    address[] calldata token0s,
    address[] calldata token1s,
    uint256[] calldata prices
  )
    external onlyFeeder
  {
    uint256 len = token0s.length;
    require(token1s.length == len, "SimplePriceOracle::setPrices:: bad token1s length");
    require(prices.length == len, "SimplePriceOracle::setPrices:: bad prices length");
    for (uint256 idx = 0; idx < len; idx++) {
      address token0 = token0s[idx];
      address token1 = token1s[idx];
      uint256 price = prices[idx];
      store[token0][token1] = PriceData({
        price: uint192(price),
        lastUpdate: uint64(now)
      });

      if (token1 == baseToken) {
        set(token0, price);
      }
      emit PriceUpdate(token0, token1, price);
    }
  }

  /// @dev Return the wad price of token0/token1, multiplied by 1e18
  /// NOTE: (if you have 1 token0 how much you can sell it for token1)
  function getPrice(address token0, address token1)
    external view override
    returns (uint256 price, uint256 lastUpdate)
  {
    PriceData memory data = store[token0][token1];
    price = uint256(data.price);
    lastUpdate = uint256(data.lastUpdate);
    require(price != 0 && lastUpdate != 0, "Oracle::getPrice: bad price data");
    return (price, lastUpdate);
  }

  struct Price {
    uint256 price;
    uint256 expiration;
  }

  mapping(address => Price) public prices;

  function getExpiration(address token) external view returns (uint256) {
    return prices[token].expiration;
  }

  // function getPrice(address token) external view returns (uint256) {
  //   return prices[token].price;
  // }

  function get(address token) external view returns (uint256, bool) {
    return (prices[token].price, valid(token));
  }

  function valid(address token) public view returns (bool) {
    return now < prices[token].expiration;
  }

  // 设置价格为 @val, 保持有效时间为 @exp second.
  function set(
    address token,
    uint256 val
  ) public onlyFeeder {
      prices[token].price = val;
      prices[token].expiration = now + bufferDay;

      store[token][baseToken] = PriceData({
        price: uint192(val),
        lastUpdate: uint64(now)
      });
  }
}
