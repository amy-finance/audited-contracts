// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "./interfaces/IAggregatorV3Interface.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

contract PriceConsumerV3 {
    using SafeMath for int;

    IAggregatorV3Interface internal priceFeed;

    // Network: BSC TestNet
    // Aggregator: BTC/USD
    // Address: 0x5741306c21795FdCBb9b265Ea0255F499DFe515C BTC
    // Address: 0x143db3CEEfbdfe5631aDD3E50f7614B6ba708BA7 ETH
    constructor() public {
        priceFeed = IAggregatorV3Interface(0x5741306c21795FdCBb9b265Ea0255F499DFe515C);
    }

    // Returns the latest price
    function getLatestPrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return price;
    }
}