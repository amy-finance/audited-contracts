// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "./library/SafeMathLib.sol";

contract InterestRateModel is OwnableUpgradeSafe {
    using SafeMathLib for uint256;

    uint256 public blocksPerYear;
    uint256 public secondsPerBlock;
    uint256 public SECONDS_PER_YEAR;

    uint256 public OPTICAL_USAGE_RATE;
    uint256 public MAX_USAGE_RATE;
    uint256 public BASIC_INTEREST;

    uint256 public interestSlope1;
    uint256 public interestSlope2;

    function initialize(
        uint256 _secondsPerBlock,
        uint256 _interestSlope1,
        uint256 _interestSlope2
    ) public initializer {
        OwnableUpgradeSafe.__Ownable_init();

        SECONDS_PER_YEAR = 365 days;
        secondsPerBlock = _secondsPerBlock;
        blocksPerYear = SECONDS_PER_YEAR.div(_secondsPerBlock);
        interestSlope1 = _interestSlope1;
        interestSlope2 = _interestSlope2;
        OPTICAL_USAGE_RATE = 85e18;
        MAX_USAGE_RATE = 100e18;
        BASIC_INTEREST = 10e16;
    }

    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }

        // borrows / (cash + borrows - reserves)
        return borrows.mul(100e18).div(cash.add(borrows).sub(reserves));
    }

    /// @dev Return the interest rate per year, using 1e18 as denom.
    function _getPureAPR(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        if (borrows == 0 && cash == 0) return 0;

        uint256 utilization = utilizationRate(cash, borrows, reserves);
        if (utilization < OPTICAL_USAGE_RATE) {
            // Less than 85% utilization - 10%-30% APY
            return utilization.mul(interestSlope1).div(OPTICAL_USAGE_RATE).add(BASIC_INTEREST);
        } else if (utilization < MAX_USAGE_RATE) {
            // Between 85% and 100% - 30%-130% APY
            return (
                BASIC_INTEREST
                + interestSlope1
                + utilization
                .sub(OPTICAL_USAGE_RATE)
                .mul(interestSlope2)
                .div(MAX_USAGE_RATE.sub(OPTICAL_USAGE_RATE))
            );
        } else {
            // Not possible, but just in case - 130% APY
            return interestSlope2;
        }
    }

    // @dev Get interest rate by second
    function getInterestRate(
        uint256 cash,
        uint256 borrows
    ) external view returns (uint256) {
        return _getPureAPR(cash, borrows, 0).div(SECONDS_PER_YEAR);
    }

    // @dev Get borrow interest rate by block
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        return _getPureAPR(cash, borrows, reserves).div(blocksPerYear);
    }

    // @dev Get supply interest rate by block
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) public view returns (uint256) {
        uint256 oneMinusReserveFactor = SafeMathLib.sub(
            uint256(1e18),
            reserveFactorMantissa,
            "oneMinusReserveFactor sub"
        );
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        return borrowRate.mul(oneMinusReserveFactor).div(1e18);
    }

    function APR(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256) {
        return getBorrowRate(cash, borrows, reserves);
    }

    function APY(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) external view returns (uint256) {
        return getSupplyRate(cash, borrows, reserves, reserveFactorMantissa);
    }
}
