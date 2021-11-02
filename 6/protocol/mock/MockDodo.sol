pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "../../utils/SafeToken.sol";

interface IDodoPair {
  function querySellBaseToken(
    address trader, 
    uint256 payBaseAmount
  ) external view  returns (uint256 receiveQuoteAmount,uint256 mtFee);

  function querySellQuoteToken(
    address trader, 
    uint256 payQuoteAmount
  ) external view  returns (uint256 receiveBaseAmount,uint256 mtFee);

  function base() external view returns (address);
  function quote() external view returns (address);
}

contract MockDodo {
    using SafeToken for address;

    address constant _ETH_ADDRESS_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // bnb-token
    function externalBSCToTokenSwap(
        address /*swapProxy*/,
        bytes calldata callDataConcat,
        address /*fromToken*/
    )
        external
    {
        (address toToken, uint amount) = abi.decode(callDataConcat, (address, uint));
        SafeToken.safeTransfer(toToken, msg.sender, amount);
    }

    // token-token  token-bnb
    function externalTokenToTokenSwap(
        address baseToken,
        uint256 fromBaseTokenAmount,
        address /*approveTargetAddress*/,
        address dodoPair,
        bytes calldata callDataConcat
    )
        external
    {
        (address farmingToken, ) = abi.decode(callDataConcat, (address, uint));
        require(farmingToken != address(0), "farmingToken is zero");
        require(baseToken != farmingToken, "baseToken must != farmingToken");
        if (farmingToken == IDodoPair(dodoPair).base()) {
            (uint256 receiveBaseAmount, ) = IDodoPair(dodoPair).querySellQuoteToken(address(this), fromBaseTokenAmount);
            SafeToken.safeTransferFrom(baseToken, msg.sender, address(this), fromBaseTokenAmount);
            require(SafeToken.balanceOf(farmingToken, address(this)) >= receiveBaseAmount, "DODO:: balance not enough");
            SafeToken.safeTransfer(farmingToken, msg.sender, receiveBaseAmount);
        } else if (farmingToken == IDodoPair(dodoPair).quote()) {
            (uint256 receiveBaseAmount, ) = IDodoPair(dodoPair).querySellBaseToken(address(this), fromBaseTokenAmount);
            SafeToken.safeTransferFrom(baseToken, msg.sender, address(this), fromBaseTokenAmount);
            require(SafeToken.balanceOf(farmingToken, address(this)) >= receiveBaseAmount, "DODO:: balance not enough");
            SafeToken.safeTransfer(farmingToken, msg.sender, receiveBaseAmount);
        }
    }
}