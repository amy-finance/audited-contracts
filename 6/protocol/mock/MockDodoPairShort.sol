pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

// ----------------------------------------------------------------------------
// Safe Math Library
// ----------------------------------------------------------------------------
contract SafeMath {
  function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
    if (a == 0) {
      return 0;
    }
    c = a * b;
    assert(c / a == b);
    return c;
  }

  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    return a / b;
  }

  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
    c = a + b;
    assert(c >= a);
    return c;
  }
}

// Mock WETH/USDT DodoPair
contract MockDodoPairShort is SafeMath {

    address public btc = address(0);
    address public usdt = address(1);

    uint public rate1 = 2500 * 10 ** 18; 
    uint public rate2 = 0.0004 * 10 ** 18; 

    function setRate1(uint _rate1) public {
        rate1 = _rate1;
    }
    function setRate2(uint _rate2) public {
        rate2 = _rate2;
    }
    function querySellBase(
        address /*trader*/, 
        uint256 _payBaseAmount
    ) 
        external view returns (uint256 receiveQuoteAmount, uint256 mtFee) 
    {
        uint256 payBaseAmount = mul(_payBaseAmount,rate2);
        return (payBaseAmount, 0);
    }
    function querySellQuote(
        address /*trader*/, 
        uint256 _payQuoteAmount
    )
        external view returns (uint256 _receiveBaseAmount, uint256 mtFee) 
    {
        uint256 payQuoteAmount = mul(_payQuoteAmount,rate1);
        return (payQuoteAmount, 0);
    }
}