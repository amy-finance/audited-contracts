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
contract MockDodoPair is SafeMath {

    address public base = address(1);
    address public quote = address(2);

    function _BASE_TOKEN_() public view returns (address) {
      return base;
    }

    function _QUOTE_TOKEN_() public view returns (address) {
      return quote;
    }

    string public pairname;
    uint public rate = 2700;

    function setPair(address _base, address _quote) public {
      base = _base;
      quote = _quote;
    }

    function setPairName(string memory _pairName) public {
      pairname = _pairName;
    }

    function setRate(uint _rate) public {
      rate = _rate;
    }

    function querySellBaseToken(
      address /*trader*/, 
      uint256 _payBaseAmount
    )
      external view returns (uint256 receiveQuoteAmount, uint256 mtFee) 
    {
      uint256 payBaseAmount = div(_payBaseAmount, rate);
      return (payBaseAmount, 0);
    }

    function querySellQuoteToken(
      address /*trader*/, 
      uint256 _payQuoteAmount
    )
      external view returns (uint256 _receiveBaseAmount, uint256 mtFee) 
    {
      uint256 payQuoteAmount = mul(_payQuoteAmount, rate);
      return (payQuoteAmount, 0);
    }
}