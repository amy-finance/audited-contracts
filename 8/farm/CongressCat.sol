// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./ERC721Base.sol";

contract CongressCat is ERC721Base, ReentrancyGuardUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;

    bool public salesEnabled; // indicate if the sale is started
    uint256 public salesPrice; // (in wei), 0.06 eth
    uint256 public salesLimitPerUser;
    uint256 public salesCap;
    uint256 public salesCount;

    // sales count -> cat id shuffle
    mapping(uint256 => uint256) public catShuffleIndices;
    CountersUpgradeable.Counter public catIdTracker;
    mapping(address => uint256) public userPurchaseCount;

    function initialize(
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI,
        string memory _contractURI
    ) public override initializer {
        super.initialize(_name, _symbol, _baseTokenURI, _contractURI);
        super.__ReentrancyGuard_init();
        catIdTracker.increment(); // the first id = #1
    }

    /* ========== OWNER METHODS ========== */

    // set sales enabled
    function setSalesEnabled(bool _salesEnabled) external onlyOwner {
        salesEnabled = _salesEnabled;
        emit SalesEnabledSet(_salesEnabled);
    }

    function setSalesData(
        uint256 _salesPrice,
        uint256 _salesCap,
        uint256 _salesLimitPerUser
    ) external onlyOwner {
        require(_salesPrice != 0, "Invalid price");
        require(_salesCap >= salesCount, "Invalid cap");
        salesPrice = _salesPrice;
        salesCap = _salesCap;
        salesLimitPerUser = _salesLimitPerUser;
        emit SalesDataSet(_salesPrice, _salesCap, _salesLimitPerUser);
    }

    function withdrawContractBalance(address _receiver)
        external
        nonReentrant
        onlyOwner
    {
        require(_receiver != address(0), "Invalid receiver");
        // access contract balance
        uint256 withdrawalAmount = address(this).balance;
        // transfer balance
        payable(_receiver).transfer(withdrawalAmount);
        // emit event
        emit ContractBalanceWithdrawn(_receiver, withdrawalAmount);
    }

    /* ========== USER METHODS ========== */

    function mint(uint256 _amount) external payable nonReentrant whenNotPaused {
        require(tx.origin == msg.sender, "Allowed for EOA only");
        require(salesEnabled == true, "Sales not started");
        require(salesPrice != 0, "Sales not set up");
        require(salesCount + _amount <= salesCap, "Sales cap reached");
        require(_amount != 0, "Amount invalid");
        require(
            userPurchaseCount[msg.sender] + _amount <= salesLimitPerUser,
            "User purchase limit reached"
        );

        uint256 catTotalPayment = salesPrice * _amount;
        require(msg.value == catTotalPayment, "Incorrect payment amount");
        // update purchase count
        userPurchaseCount[msg.sender] = userPurchaseCount[msg.sender] + _amount;

        for (uint256 i = 0; i < _amount; i++) {
            uint256 index = salesCount + i;
            uint256 catId = getRandomCatId(index);
            _mint(msg.sender, catId);
        }

        salesCount = salesCount + _amount;
        emit CatSold(msg.sender, _amount, catTotalPayment);
    }

    function getRandomCatId(uint256 index) internal returns (uint256) {
        uint256 swapIndex = (getRandom(index) % (salesCap - index)) + index;
        // current index value (init if it's 0)
        uint256 catShuffleIndicesIndexCurrentValue = catShuffleIndices[index] ==
            0
            ? index + 1
            : catShuffleIndices[index];
        // swap index value (init if it's 0)
        uint256 catShuffleIndicesSwapIndexCurrentValue = catShuffleIndices[
            swapIndex
        ] == 0
            ? swapIndex + 1
            : catShuffleIndices[swapIndex];
        catShuffleIndices[swapIndex] = catShuffleIndicesIndexCurrentValue;
        catShuffleIndices[index] = catShuffleIndicesSwapIndexCurrentValue;
        return catShuffleIndices[index];
    }

    function getRandom(uint256 _seed) private view returns (uint256 rand) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        block.timestamp,
                        msg.sender,
                        _seed
                    )
                )
            );
    }

    /* ========== EVENTS ========== */
    event SalesEnabledSet(bool enabled);
    event SalesDataSet(uint256 price, uint256 cap, uint256 limit);
    event CatSold(address indexed account, uint256 amount, uint256 paid);
    event ContractBalanceWithdrawn(address indexed account, uint256 amount);
}
