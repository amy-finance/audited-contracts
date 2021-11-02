// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./interfaces/IAggregatorV3Interface.sol";
import "./interfaces/IFlagInterface.sol";
import "./library/SafeMathLib.sol";
import "./IPriceOracle.sol";

contract ChainLinkPriceOracle is OwnableUpgradeSafe, IPriceOracle {

  // Mapping from token0, token1 to source
  mapping(address => mapping(address => IAggregatorV3Interface)) public priceFeeds;

  event SetPriceFeed(address indexed token0, address indexed token1, IAggregatorV3Interface source);
  event PriceUpdate(address indexed token0, address indexed token1, uint256 price);

  address public feeder;
  address public baseToken;
  uint public bufferDay;
  address private FLAG_ARBITRUM_SEQ_OFFLINE;
  FlagsInterface internal chainlinkFlags;

  struct PriceData {
    uint192 price;
    uint64 lastUpdate;
  }

  /// @notice Public price data mapping storage.
  mapping (address => mapping (address => PriceData)) public store;

  struct Price {
    uint256 price;
    uint256 expiration;
  }

  mapping(address => Price) public prices;

  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    bufferDay = 7 days;
    // Identifier of the Sequencer offline flag on the Flags contract 
    FLAG_ARBITRUM_SEQ_OFFLINE = address(bytes20(bytes32(uint256(keccak256("chainlink.flags.arbitrum-seq-offline")) - 1)));
    chainlinkFlags = FlagsInterface(0x3C14e07Edd0dC67442FA96f1Ec6999c57E810a83);
  }

  function setBaseToken(address _baseToken) public onlyOwner {
    baseToken = _baseToken;
  }

  function setBufferDay(uint _bufferDay) public onlyOwner {
    require(_bufferDay >= 1 days && _bufferDay <= 7 days, "out of range");
    bufferDay = _bufferDay;
  }

  /// @dev Set sources for multiple token pairs
  /// @param token0s Token0 address to set source
  /// @param token1s Token1 address to set source
  /// @param allSources source for the token pair
  function setPriceFeeds(
    address[] calldata token0s,
    address[] calldata token1s,
    IAggregatorV3Interface[] calldata allSources
  ) external onlyOwner {
    require(
      token0s.length == token1s.length && token0s.length == allSources.length,
      "ChainLinkPriceOracle::setPriceFeeds:: inconsistent length"
    );
    for (uint256 idx = 0; idx < token0s.length; idx++) {
      _setPriceFeed(token0s[idx], token1s[idx], allSources[idx]);
    }
  }

  /// @dev Set source for the token pair
  /// @param token0 Token0 address to set source
  /// @param token1 Token1 address to set source
  /// @param source source for the token pair
  function _setPriceFeed(
    address token0,
    address token1,
    IAggregatorV3Interface source
  ) internal {
    require(
      address(priceFeeds[token0][token1]) == address(0),
      "ChainLinkPriceOracle::setPriceFeed:: source on existed pair"
    );
    priceFeeds[token0][token1] = source;
    emit SetPriceFeed(token0, token1, source);
  }

  /// @dev Return the price of token0/token1, multiplied by 1e18
  /// @param token0 Token0 to set oracle sources
  /// @param token1 Token1 to set oracle sources
  function getPrice(address token0, address token1) public view override returns (uint256, uint256) {
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

  function getExpiration(address /*token*/) external view returns (uint256) {
    return now + bufferDay;
  }

  function getPrice(address token) public view returns (uint256) {
    require(baseToken != address(0), "not set baseToken");
    (uint price,) = getPrice(token, baseToken);
    return price;
  }

  function get(address token) external view returns (uint256, bool) {
    return (getPrice(token), true);
  }
}
