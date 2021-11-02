// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./ERC721Base.sol";

contract GoldenCat is ERC721Base, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using MathUpgradeable for uint256;
    using SafeMathUpgradeable for uint8;
    using MathUpgradeable for uint8;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    struct Cat {
        uint256 iq; // [100 - 500] -> [8000]
        uint8 generation; // 1-5
        uint8 generationLimit; // 3-5
        uint8 personality; // 1-8
        uint8 appearance; // 1-14, airdrop cats start at 101
    }

    mapping(uint256 => Cat) public cats;
    CountersUpgradeable.Counter public catIdTracker;
    IERC20Upgradeable public amyToken;

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

    function setAmyToken(address _amyTokenAddress) external onlyAdmin {
        amyToken = IERC20Upgradeable(_amyTokenAddress);
    }

    function mintLootBoxCat(address _to, uint256 _catSeed)
        external
        onlyMinter
        nonReentrant
    {
        Cat storage cat = cats[catIdTracker.current()];
        cat.iq = retrieveLootBoxCatIQ(getRandom(_catSeed + 1));
        cat.generation = 1;
        cat.generationLimit = retrieveLootBoxCatGenerationLimit(
            getRandom(_catSeed + 2)
        );
        cat.personality = retrieveLootBoxCatPersonality(
            getRandom(_catSeed + 3)
        );
        cat.appearance = retrieveLootBoxCatAppearance(getRandom(_catSeed + 4));
        _safeMint(_to, catIdTracker.current());
        emit GoldenCatMinted(
            _to,
            1,
            catIdTracker.current(),
            cat.iq,
            cat.generation,
            cat.generationLimit,
            cat.personality,
            cat.appearance
        );
        catIdTracker.increment();
    }

    function mintAirdropCat(
        address _to,
        uint256 _iq,
        uint8 _personalty,
        uint8 _appearance,
        uint8 _generationLimit
    ) external onlyMinter nonReentrant {
        require(
            _personalty > 0 && _personalty <= 8,
            "Invalid input for personality."
        );
        require(_appearance > 0, "Invalid input for appearance.");
        require(_generationLimit <= 5, "Invalid input for generation limit.");
        require(_iq <= 500, "Invalid input for IQ.");
        Cat storage cat = cats[catIdTracker.current()];
        cat.generation = 1;
        cat.iq = _iq;
        cat.generationLimit = _generationLimit;
        cat.personality = _personalty;
        cat.appearance = _appearance;
        _safeMint(_to, catIdTracker.current());
        emit GoldenCatMinted(
            _to,
            2,
            catIdTracker.current(),
            cat.iq,
            cat.generation,
            cat.generationLimit,
            cat.personality,
            cat.appearance
        );
        catIdTracker.increment();
    }

    function mintAssembledCat(
        uint256 _catId1,
        uint256 _catId2,
        uint256 _catId3
    ) external nonReentrant {
        require(
            ownerOf(_catId1) == msg.sender &&
                ownerOf(_catId2) == msg.sender &&
                ownerOf(_catId3) == msg.sender,
            "Cats are unauthorized"
        );
        Cat memory cat1 = cats[_catId1];
        Cat memory cat2 = cats[_catId2];
        Cat memory cat3 = cats[_catId3];
        require(
            cat1.generationLimit > cat1.generation &&
                cat2.generationLimit > cat2.generation &&
                cat3.generationLimit > cat3.generation,
            "Reached the generation limit."
        );
        Cat memory catWithHighestIQ;
        catWithHighestIQ = cat1.iq > cat2.iq ? cat1 : cat2;
        catWithHighestIQ = catWithHighestIQ.iq > cat3.iq
            ? catWithHighestIQ
            : cat3;

        Cat storage cat = cats[catIdTracker.current()];

        // new cat generation limit = highest generation limit cat
        cat.generationLimit = uint8(
            MathUpgradeable.max(
                uint8(
                    MathUpgradeable.max(
                        cat1.generationLimit,
                        cat2.generationLimit
                    )
                ),
                cat3.generationLimit
            )
        );
        // new cat generation = highest generation cat + 1
        cat.generation =
            uint8(
                MathUpgradeable.max(
                    uint8(
                        MathUpgradeable.max(cat1.generation, cat2.generation)
                    ),
                    cat3.generation
                )
            ) +
            1;

        // new cat IQ = sum(3 cats) * 66.67%
        cat.iq = ((cat1.iq.add(cat2.iq)).add(cat3.iq)).div(3).mul(2);

        // new cat personality = highest IQ cat personality
        cat.personality = catWithHighestIQ.personality;

        // new cat appearance = random 11-14
        cat.appearance = uint8(
            uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        msg.sender,
                        cat1.iq,
                        cat2.iq,
                        cat3.iq
                    )
                )
            ).mod(4).add(11)
        );

        // burn amy token at the amount of the cat IQ from the user
        amyToken.safeTransferFrom(msg.sender, address(0x000001), cat.iq * 1e18);

        _burn(_catId1);
        _burn(_catId2);
        _burn(_catId3);
        emit GoldenCatAssembled(msg.sender, _catId1, _catId2, _catId3);
        emit GoldenCatMinted(
            msg.sender,
            3,
            catIdTracker.current(),
            cat.iq,
            cat.generation,
            cat.generationLimit,
            cat.personality,
            cat.appearance
        );

        _safeMint(msg.sender, catIdTracker.current());
        catIdTracker.increment();
    }

    // helper method for getting

    function getRandom(uint256 seed) private view returns (uint256 rand) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        msg.sender,
                        seed
                    )
                )
            );
    }

    function retrieveLootBoxCatIQ(uint256 _rand)
        internal
        pure
        returns (uint256 catIq)
    {
        uint256 index = _rand.mod(10000);
        if (index >= 9990) {
            return 500;
        } else if (index >= 9978) {
            return 490;
        } else if (index >= 9964) {
            return 480;
        } else if (index >= 9948) {
            return 470;
        } else if (index >= 9930) {
            return 460;
        } else if (index >= 9910) {
            return 450;
        } else if (index >= 9888) {
            return 440;
        } else if (index >= 9864) {
            return 430;
        } else if (index >= 9838) {
            return 420;
        } else if (index >= 9810) {
            return 410;
        } else if (index >= 9780) {
            return 400;
        } else if (index >= 9748) {
            return 390;
        } else if (index >= 9714) {
            return 380;
        } else if (index >= 9678) {
            return 370;
        } else if (index >= 9640) {
            return 360;
        } else if (index >= 9600) {
            return 350;
        } else if (index >= 9558) {
            return 340;
        } else if (index >= 9514) {
            return 330;
        } else if (index >= 9468) {
            return 320;
        } else if (index >= 9420) {
            return 310;
        } else if (index >= 9370) {
            return 300;
        } else if (index >= 9304) {
            return 290;
        } else if (index >= 9227) {
            return 280;
        } else if (index >= 9139) {
            return 270;
        } else if (index >= 9040) {
            return 260;
        } else if (index >= 8930) {
            return 250;
        } else if (index >= 8710) {
            return 240;
        } else if (index >= 8380) {
            return 230;
        } else if (index >= 7940) {
            return 220;
        } else if (index >= 7390) {
            return 210;
        } else if (index >= 6790) {
            return 200;
        } else if (index >= 6160) {
            return 190;
        } else if (index >= 5480) {
            return 180;
        } else if (index >= 4800) {
            return 170;
        } else if (index >= 4100) {
            return 160;
        } else if (index >= 3400) {
            return 150;
        } else if (index >= 2600) {
            return 140;
        } else if (index >= 1800) {
            return 130;
        } else if (index >= 900) {
            return 120;
        }
        return 110;
    }

    // return random cat generation limit (value: 2-5)
    function retrieveLootBoxCatGenerationLimit(uint256 _rand)
        internal
        pure
        returns (uint8 catGenerationLimit)
    {
        uint256 index = _rand.mod(100);
        if (index == 99) {
            return 5;
        } else if (index >= 90) {
            return 4;
        } else if (index >= 60) {
            return 3;
        }
        return 2;
    }

    // return random cat generation limit (value: 1-8)
    function retrieveLootBoxCatPersonality(uint256 _rand)
        internal
        pure
        returns (uint8 catPersonality)
    {
        uint256 index = _rand.mod(100);
        if (index >= 95) {
            return 8;
        } else if (index >= 90) {
            return 7;
        } else if (index >= 75) {
            return 6;
        } else if (index >= 60) {
            return 5;
        } else if (index >= 45) {
            return 4;
        } else if (index >= 30) {
            return 3;
        } else if (index >= 15) {
            return 2;
        }
        return 1;
    }

    // return random cat appearance (value: 1-14)
    function retrieveLootBoxCatAppearance(uint256 _rand)
        internal
        pure
        returns (uint8 catAppearance)
    {
        uint256 index = _rand.mod(14);
        return uint8(index.add(1));
    }

    /* ========== EVENTS ========== */

    event GoldenCatMinted(
        address indexed user,
        uint8 mintType,
        uint256 catId,
        uint256 iq,
        uint8 generation,
        uint8 generationLimit,
        uint8 personality,
        uint8 appearance
    );

    event GoldenCatAssembled(
        address indexed account,
        uint256 assembledCatId1,
        uint256 assembledCatId2,
        uint256 assembledCatId3
    );
}
