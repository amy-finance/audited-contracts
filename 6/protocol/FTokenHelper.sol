// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./library/SafeMathLib.sol";
import "./interfaces/lending/IInterestRateModel.sol";

interface IFToken {
  function tokenCash(address token, address account) external view returns (uint256);
  function addReservesForLeverage(uint addAmount) external;
  function underlying() external view returns (address);
  function totalBorrows() external view returns (uint256);
  function totalReserves() external view returns (uint256);
  function reserveFactor() external view returns (uint256);
}

contract FTokenHelper is OwnableUpgradeSafe {

  mapping (IFToken => IInterestRateModel) public interestRateModel;

  /// initialize
  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
  }

  function setInterestModels(IFToken[] calldata _ftoken, IInterestRateModel[] calldata _interestModel) external onlyOwner {
    for (uint8 i = 0; i < _ftoken.length; i++) {
      interestRateModel[_ftoken[i]] = _interestModel[i];
    }
  }

  function getSupplyRate(IFToken[] calldata _ftoken) external view returns (uint256[] memory) {
    uint256[] memory rates = new uint256[]( _ftoken.length );

    uint256 tokenCash;
    uint256 totalBorrows;
    uint256 totalReserves;
    uint256 reserveFactor;
    address underlying;
    for (uint256 i = 0; i < _ftoken.length; i++) {
      underlying = _ftoken[i].underlying();
      tokenCash = _ftoken[i].tokenCash(underlying, address(_ftoken[i]));
      totalBorrows = _ftoken[i].totalBorrows();
      totalReserves = _ftoken[i].totalReserves();
      reserveFactor = _ftoken[i].reserveFactor();
      rates[i] = interestRateModel[_ftoken[i]].getSupplyRate(
            tokenCash,
            totalBorrows,
            totalReserves,
            reserveFactor
          );
    }

    return rates;
  }

  function APR(IFToken[] calldata _ftoken) external view returns (uint256[] memory) {
    uint256[] memory results = new uint256[]( _ftoken.length );

    uint256 tokenCash;
    uint256 totalBorrows;
    uint256 totalReserves;
    uint256 reserveFactor;
    address underlying;
    for (uint256 i = 0; i < _ftoken.length; i++) {
      underlying = _ftoken[i].underlying();
      tokenCash = _ftoken[i].tokenCash(underlying, address(_ftoken[i]));
      totalBorrows = _ftoken[i].totalBorrows();
      totalReserves = _ftoken[i].totalReserves();
      reserveFactor = _ftoken[i].reserveFactor();
      results[i] = interestRateModel[_ftoken[i]].APR(tokenCash, totalBorrows, totalReserves);
    }

    return results;
  }

  function APY(IFToken[] calldata _ftoken) external view returns (uint256[] memory) {
    uint256[] memory results = new uint256[]( _ftoken.length );

    uint256 tokenCash;
    uint256 totalBorrows;
    uint256 totalReserves;
    uint256 reserveFactor;
    address underlying;
    for (uint256 i = 0; i < _ftoken.length; i++) {
      underlying = _ftoken[i].underlying();
      tokenCash = _ftoken[i].tokenCash(underlying, address(_ftoken[i]));
      totalBorrows = _ftoken[i].totalBorrows();
      totalReserves = _ftoken[i].totalReserves();
      reserveFactor = _ftoken[i].reserveFactor();
      results[i] = interestRateModel[_ftoken[i]].APY(
          tokenCash,
          totalBorrows,
          totalReserves,
          reserveFactor
        );
    }

    return results;
  }
}
