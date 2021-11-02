// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./ERC721Base.sol";
import "./GoldenCat.sol";

contract GoldenCatLootBox is ERC721Base, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    struct LootBox {
        address aibTokenAddress;
        uint256 catSeed;
    }

    mapping(uint256 => LootBox) public lootBoxes;
    CountersUpgradeable.Counter public lootBoxIdTracker;
    GoldenCat public goldenCat;

    function initialize(
        string memory _name,
        string memory _symbol,
        string memory _baseTokenURI,
        string memory _contractURI
    ) public override initializer {
        super.initialize(_name, _symbol, _baseTokenURI, _contractURI);
        super.__ReentrancyGuard_init();
        lootBoxIdTracker.increment(); // the first id = #1
    }

    function setGoldenCat(address _goldenCatAddress) external onlyAdmin {
        goldenCat = GoldenCat(_goldenCatAddress);
    }

    function mint(address _to, address _aibTokenAddress)
        external
        nonReentrant
        onlyMinter
    {
        _safeMint(_to, lootBoxIdTracker.current());
        LootBox storage lootBox = lootBoxes[lootBoxIdTracker.current()];
        lootBox.aibTokenAddress = _aibTokenAddress;

        uint256 seed = lootBoxIdTracker.current() == 0
            ? 0
            : lootBoxes[lootBoxIdTracker.current() - 1].catSeed;
        lootBox.catSeed = getRandom(seed, _aibTokenAddress);
        emit LootBoxMinted(
            _to,
            lootBoxIdTracker.current(),
            _aibTokenAddress,
            lootBox.catSeed
        );
        lootBoxIdTracker.increment();
    }

    function unbox(uint256 _lootBoxId) external nonReentrant {
        require(ownerOf(_lootBoxId) == msg.sender, "Unauthorized.");
        LootBox storage lootBox = lootBoxes[_lootBoxId];

        // mint golden cat
        goldenCat.mintLootBoxCat(msg.sender, lootBox.catSeed);

        // burn current loot box
        _burn(_lootBoxId);
        emit LootBoxUnboxed(msg.sender, _lootBoxId);
    }

    function getRandom(uint256 _seed, address _aibTokenAddress)
        private
        view
        returns (uint256 rand)
    {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        msg.sender,
                        _seed,
                        _aibTokenAddress
                    )
                )
            );
    }

    /* ========== EVENTS ========== */

    event LootBoxMinted(
        address indexed user,
        uint256 id,
        address aibTokenAddress,
        uint256 catSeed
    );
    event LootBoxUnboxed(address indexed user, uint256 id);
}
