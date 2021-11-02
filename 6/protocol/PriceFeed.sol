// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

interface IPriceConsumerV3 {
    function getLatestPrice() external view returns (int);
}

interface IPriceOracle {
  function setPrices(
    address[] calldata token0s,
    address[] calldata token1s,
    uint256[] calldata prices
  ) external;
}

contract PriceFeed is OwnableUpgradeSafe {

    using SafeMath for uint;

    struct PricePair {
        address token0;
        address token1;
        address priceConsumer;
        uint8 decimal;
    }

    mapping(address => PricePair) public getPricePair;
    address[] public allPairs;

    address public priceOracle;

    function initialize() public initializer {
        OwnableUpgradeSafe.__Ownable_init();
    }

    function setPriceOracleAddress(address _priceOracle) external onlyOwner {
        priceOracle = _priceOracle;
    }

    function setPricePairs(PricePair[] calldata _pricePairs) external onlyOwner {
        for (uint i = 0; i < _pricePairs.length; i++) {
            address pair = getPairAddress(_pricePairs[i].token0, _pricePairs[i].token1);
            getPricePair[pair] = PricePair({
                token0: _pricePairs[i].token0,
                token1: _pricePairs[i].token1,
                priceConsumer: _pricePairs[i].priceConsumer,
                decimal: _pricePairs[i].decimal
            });
            allPairs.push(pair);
        }
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function getPairAddress(address _token0, address _token1) public pure returns(address pair) {
        bytes32 data = keccak256(abi.encodePacked(_token0, _token1));
        assembly {
            mstore(0, data)
            pair := mload(0)
        }
    }

    function triggerPriceFeed(address[] calldata _pairs) external {
        address[] memory token0s = new address[](_pairs.length);
        address[] memory token1s = new address[](_pairs.length);
        uint256[] memory prices = new uint[](_pairs.length);
        for (uint i = 0; i < _pairs.length; i++) {
            PricePair memory pair = getPricePair[_pairs[i]];
            if (pair.priceConsumer != address(0)) {
                uint price_ = uint(IPriceConsumerV3(pair.priceConsumer).getLatestPrice());
                prices[i] = pair.decimal == uint(8) ? price_.mul(1e10) : price_;
                token0s[i] = pair.token0;
                token1s[i] = pair.token1;
            }
        }
        
        IPriceOracle(priceOracle).setPrices(token0s, token1s, prices);
    }
}