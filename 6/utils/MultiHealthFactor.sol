// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "../protocol/interfaces/lending/IBankController.sol";

contract MultiHealthFactor is OwnableUpgradeSafe {

    address public bankController;

    function initialize(address _bankController) public initializer {
        OwnableUpgradeSafe.__Ownable_init();
        bankController = _bankController;
    }

    function setBankController(address _bankController) external onlyOwner {
        bankController = _bankController;
    }

    function multiHeathFactor(address[] calldata accounts) external view returns(uint[] memory factors)
    {
        uint[] memory tmp_factors = new uint[](accounts.length);
        for (uint i = 0; i < accounts.length; i++) {
            tmp_factors[i] = IBankController(bankController).getHealthFactor(accounts[i]);
        }
        factors = tmp_factors;
    }
}
