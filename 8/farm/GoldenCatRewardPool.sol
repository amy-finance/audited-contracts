// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import "./GoldenCat.sol";

// preparation tasks
// 1. admin open the pool
// 2. admin set rewards_block_count
// 	(how many blocks that reward is applicable)
// 3. admin supply rewards
// 	-> calculate rewards_per_block
// 	(how much reward is given from pool to all staking users in 1 block = reward)
// 	-> calculate rewards_end_time
// 	(the last block that the pool gives reward)

// how it works
// for actions (supply reward, stake, withdraw, claim reward)
// - update pool rewards_accumulated_per_token
// (previous rewards_accumulated_per_token + ((now - last update block) * rewards_per_block) / staking_amount
// - update individual rewards_amount_withdrawable
// - update individual rewards_amount_paid

contract GoldenCatRewardPool is
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC721ReceiverUpgradeable
{
    using SafeMathUpgradeable for uint256;
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct PoolUser {
        mapping(uint256 => uint256) catIds;
        uint256 stakingCatCount;
        // user staking amount
        uint256 stakingIQAmount;
        // reward amount available to withdraw
        uint256 rewardsAmountWithdrawable;
        // reward amount paid (also used to jot the past reward skipped)
        uint256 rewardsAmountPerStakingIQPaid;
    }

    struct Pool {
        // reward token contract
        IERC20Upgradeable rewardsToken;
        // reward token distributor
        address rewardsDistributor;
        // total staking amount
        uint256 stakingCatCount;
        // total staking amount
        uint256 stakingIQAmount;
        // total reward amount available
        uint256 rewardsAmountAvailable;
        // total block numbers for the current distributing period
        // set by admin
        uint256 rewardsBlockCount;
        // reward end time
        uint256 rewardsEndBlock;
        // reward tokens to give to all pool users per block
        // calculated by rewardsEndBlock with rewardsBlockCount
        uint256 rewardsPerBlock;
        // from beginning until now, how much reward is given to 1 staking token
        uint256 rewardsAccumulatedPerStakingIQ;
        // the reward last update block
        // it only changes in 2 situations
        // 1. depositReward
        // 2. updatePool modifier used in stake, withdraw, claimReward, depositReward
        uint256 rewardsLastCalculationBlock;
        // required iq
        uint256 iqTotalRequired;
        // pool user mapping;
        mapping(address => PoolUser) users;
    }

    // golden cat contract
    GoldenCat public goldenCat;
    mapping(uint256 => Pool) public pools;
    CountersUpgradeable.Counter public poolIdTracker;

    // initialize
    function initialize(address _goldenCatAddress) public initializer {
        super.__Ownable_init();
        super.__Pausable_init();
        super.__ReentrancyGuard_init();
        goldenCat = GoldenCat(_goldenCatAddress);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /* ========== ADMIN METHODS ========== */

    // admin step 1: createPool
    function createPool(
        IERC20Upgradeable _rewardsToken,
        address _rewardsDistributor,
        uint256 _iqTotalRequired
    ) external onlyOwner {
        Pool storage pool = pools[poolIdTracker.current()];
        pool.rewardsToken = _rewardsToken;
        pool.rewardsDistributor = _rewardsDistributor;
        pool.iqTotalRequired = _iqTotalRequired;
        // to indicate the pool is activated
        pool.rewardsLastCalculationBlock = block.number;
        emit PoolCreated(
            poolIdTracker.current(),
            address(_rewardsToken),
            _rewardsDistributor,
            _iqTotalRequired
        );
        poolIdTracker.increment();
    }

    // admin step 2: set duration
    // eg. use 15s as block time, 7 days = 7 * 24 * 60 * 60 / 15 = 40320
    function setRewardsBlockCount(uint256 _poolId, uint256 _rewardsBlockCount)
        external
        onlyOwner
        poolExists(_poolId)
    {
        Pool storage pool = pools[_poolId];
        // you need to finish one pool period before another one
        require(
            block.number >= pool.rewardsEndBlock,
            "Current pool end block not finished."
        );
        pool.rewardsBlockCount = _rewardsBlockCount;
        emit PoolRewardsBlockCountSet(_poolId, _rewardsBlockCount);
    }

    // admin step 3: set pool rewards distributor
    function setPoolRewardsDistributor(
        uint256 _poolId,
        address _rewardsDistributor
    ) external onlyOwner poolExists(_poolId) {
        require(_rewardsDistributor != address(0), "Invalid Input.");
        Pool storage pool = pools[_poolId];
        pool.rewardsDistributor = _rewardsDistributor;
        emit PoolRewardsDistributorSet(_poolId, _rewardsDistributor);
    }

    // admin step 4: supply reward
    function supplyRewards(uint256 _poolId, uint256 _rewardsTokenAmount)
        external
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, address(0));
        Pool storage pool = pools[_poolId];
        // check rewardsDistributor
        require(
            msg.sender == pool.rewardsDistributor,
            "Incorrect rewards distributor."
        );
        // check reward amount != 0
        require(
            _rewardsTokenAmount > 0,
            "Invalid input for rewards token amount."
        );
        // check current pool ended
        if (block.number >= pool.rewardsEndBlock) {
            // new or renewed pool
            // set up a new rate with new data
            // rewardsPerBlock = total reward / block number;
            pool.rewardsPerBlock = _rewardsTokenAmount.div(
                pool.rewardsBlockCount
            );
        } else {
            // existing pool
            // * caution
            // * cannot use the rewardsAmountAvailable to calculate directly because some rewards is not claimed
            // new total = (end block - current block) * rewardsPerBlock + rewards newly supplied
            // rewardsPerBlock = new total reward / block number;
            pool.rewardsPerBlock = (pool.rewardsEndBlock.sub(block.number))
                .mul(pool.rewardsPerBlock)
                .add(_rewardsTokenAmount)
                .div(pool.rewardsBlockCount);
        }
        pool.rewardsEndBlock = block.number.add(pool.rewardsBlockCount);
        pool.rewardsLastCalculationBlock = block.number;
        // transfer token
        pool.rewardsToken.safeTransferFrom(
            pool.rewardsDistributor,
            address(this),
            _rewardsTokenAmount
        );
        // update pool info
        pool.rewardsAmountAvailable = pool.rewardsAmountAvailable.add(
            _rewardsTokenAmount
        );
        emit PoolRewardSupplied(_poolId, _rewardsTokenAmount);
    }

    /* ========== USER METHODS ========== */

    function resetPoolUserStakingIQAmount(uint256 _poolId, address _userAddress)
        private
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_userAddress];
        // handle no cat case
        if (poolUser.stakingCatCount == 0) {
            pool.stakingIQAmount = pool.stakingIQAmount.sub(
                poolUser.stakingIQAmount
            );
            poolUser.stakingIQAmount = 0;
            return;
        }
        // calculate IQ
        uint256 stakingIQAmount = 0;
        bool stakingSamePersonality = true;
        (, , , uint8 cat0Personality, ) = goldenCat.cats(poolUser.catIds[0]);
        if (poolUser.stakingCatCount < 3) {
            stakingSamePersonality = false;
        }
        for (uint256 i = 0; i < 3; i++) {
            uint256 catId = poolUser.catIds[i];
            if (catId != 0) {
                (uint256 catIq, , , uint256 catPersonality, ) = goldenCat.cats(
                    catId
                );
                stakingIQAmount = stakingIQAmount.add(catIq);
                if (catPersonality != cat0Personality) {
                    stakingSamePersonality = false;
                }
            }
        }
        if (stakingSamePersonality) {
            if (cat0Personality < 7) {
                // handle common personality
                // total iQ * 1.1
                stakingIQAmount = stakingIQAmount.mul(11).div(10);
            } else {
                // handle rare personality
                // total iQ * 1.25
                stakingIQAmount = stakingIQAmount.mul(5).div(4);
            }
        }
        if (stakingIQAmount < pool.iqTotalRequired) {
            stakingIQAmount = 0;
        }
        pool.stakingIQAmount = pool
            .stakingIQAmount
            .sub(poolUser.stakingIQAmount)
            .add(stakingIQAmount);
        poolUser.stakingIQAmount = stakingIQAmount;

        emit PoolUserStakingIQAmountReset(
            _poolId,
            pool.stakingIQAmount,
            _userAddress,
            poolUser.stakingIQAmount
        );
    }

    function stake(uint256 _poolId, uint256[] calldata _catIds)
        external
        nonReentrant
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, msg.sender);

        _claimReward(_poolId);

        require(
            _catIds.length > 0 && _catIds.length <= 3,
            "Invalid cat ids length."
        );
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        // validation
        require(
            poolUser.stakingCatCount.add(_catIds.length) <= 3,
            "Invalid cat ids length."
        );
        // transfer cat
        for (uint256 i = 0; i < _catIds.length; i++) {
            uint256 catId = _catIds[i];
            require(catId != 0, "Invalid cat id.");
            require(
                goldenCat.ownerOf(catId) == msg.sender,
                "Unauthorized cat."
            );
            if (poolUser.catIds[poolUser.stakingCatCount.add(i)] != 0) {
                resortUserCatIds(_poolId, msg.sender);
            }
            require(
                poolUser.catIds[poolUser.stakingCatCount.add(i)] == 0,
                "Need to resort"
            );
            goldenCat.safeTransferFrom(msg.sender, address(this), catId);
            poolUser.catIds[poolUser.stakingCatCount.add(i)] = catId;
        }
        // update pool stakingCatCount
        poolUser.stakingCatCount = poolUser.stakingCatCount.add(_catIds.length);
        pool.stakingCatCount = pool.stakingCatCount.add(_catIds.length);

        // calculate IQ
        resetPoolUserStakingIQAmount(_poolId, msg.sender);
        emit PoolUserStaked(
            _poolId,
            msg.sender,
            _catIds,
            poolUser.stakingIQAmount
        );
    }

    function exit(uint256 _poolId) external nonReentrant poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        require(poolUser.stakingCatCount > 0, "Not staking");
        uint256[] memory catIdIndices = new uint256[](poolUser.stakingCatCount);
        for (uint256 i = 0; i < poolUser.stakingCatCount; i++) {
            catIdIndices[i] = i;
        }
        _withdraw(_poolId, catIdIndices);
    }

    function withdraw(uint256 _poolId, uint256[] calldata _catIdIndices)
        external
        nonReentrant
        poolExists(_poolId)
    {
        _withdraw(_poolId, _catIdIndices);
    }

    function resortUserCatIds(uint256 _poolId, address _user) private {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        uint256[] memory updatedCatIds = new uint256[](3);
        uint256 catsCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            if (poolUser.catIds[i] != 0) {
                updatedCatIds[catsCount] = poolUser.catIds[i];
                catsCount++;
            }
        }
        poolUser.catIds[0] = updatedCatIds[0];
        poolUser.catIds[1] = updatedCatIds[1];
        poolUser.catIds[2] = updatedCatIds[2];
    }

    function resetPoolUserCatData(uint256 _poolId, address _user)
        external
        onlyOwner
    {
        resortUserCatIds(_poolId, _user);
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        uint256 catsCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            if (poolUser.catIds[i] != 0) {
                catsCount++;
            }
        }
        pool.stakingCatCount =
            pool.stakingCatCount -
            poolUser.stakingCatCount +
            catsCount;
        poolUser.stakingCatCount = catsCount;
    }

    function rescuePoolUserCat(uint256 _catId, address _to) external onlyOwner {
        goldenCat.safeTransferFrom(address(this), _to, _catId);
    }

    function _withdraw(uint256 _poolId, uint256[] memory _catIdIndices)
        private
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, msg.sender);

        _claimReward(_poolId);

        require(
            _catIdIndices.length > 0 && _catIdIndices.length <= 3,
            "Invalid cat indices length."
        );
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        // handle no cat staking
        require(poolUser.stakingCatCount > 0, "No staking cat.");
        uint256[] memory catIdsWithdrawn = new uint256[](_catIdIndices.length);
        for (uint256 i = 0; i < _catIdIndices.length; i++) {
            uint256 catId = poolUser.catIds[_catIdIndices[i]];
            require(catId != 0, "Invalid cat id.");
            catIdsWithdrawn[i] = catId;
            poolUser.catIds[_catIdIndices[i]] = 0;
            goldenCat.safeTransferFrom(address(this), msg.sender, catId);
        }

        // REDO re-sort

        // re-sort the array
        resortUserCatIds(_poolId, msg.sender);

        // update pool stakingCatCount
        poolUser.stakingCatCount = poolUser.stakingCatCount.sub(
            _catIdIndices.length
        );
        pool.stakingCatCount = pool.stakingCatCount.sub(_catIdIndices.length);

        uint256 stakingIQBefore = poolUser.stakingIQAmount;
        // calculate IQ
        resetPoolUserStakingIQAmount(_poolId, msg.sender);

        emit PoolUserWithdrawn(
            _poolId,
            msg.sender,
            catIdsWithdrawn,
            stakingIQBefore.sub(poolUser.stakingIQAmount)
        );
    }

    // user claimReward
    function claimReward(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, msg.sender);
        _claimReward(_poolId);
    }

    // user claimReward private
    function _claimReward(uint256 _poolId) private poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        uint256 rewardsAmountWithdrawable = poolUser.rewardsAmountWithdrawable;
        if (rewardsAmountWithdrawable > 0) {
            pool.rewardsAmountAvailable = pool.rewardsAmountAvailable.sub(
                rewardsAmountWithdrawable
            );
            emit PoolUserRewardClaimed(
                _poolId,
                msg.sender,
                rewardsAmountWithdrawable
            );
            poolUser.rewardsAmountWithdrawable = 0;
            pool.rewardsToken.safeTransfer(
                msg.sender,
                rewardsAmountWithdrawable
            );
        }
    }

    /* ========== HELPER METHODS ========== */

    // updatePoolReward
    function updatePoolRewardInfo(uint256 _poolId, address _userAddress)
        public
    {
        Pool storage pool = pools[_poolId];

        // update reward per token accumulated
        pool
            .rewardsAccumulatedPerStakingIQ = getUpdatedRewardAccumulatedPerStakingIQ(
            _poolId
        );

        // check if the current reward peroid is ended
        if (block.number < pool.rewardsEndBlock) {
            // if the pool is ongoing
            // update reward last calcuation time
            pool.rewardsLastCalculationBlock = block.number;
        } else {
            // update reward last calcuation time
            pool.rewardsLastCalculationBlock = pool.rewardsEndBlock;
        }
        if (_userAddress != address(0)) {
            PoolUser storage poolUser = pool.users[_userAddress];
            // update user.rewardsAmountWithdrawable
            // = rewardsAmountWithdrawable + new changes
            // = rewardsAmountWithdrawable + (staking amount * accumulated reward per token)
            poolUser.rewardsAmountWithdrawable = poolUser
                .rewardsAmountWithdrawable
                .add(
                    poolUser.stakingIQAmount.mul(
                        pool.rewardsAccumulatedPerStakingIQ.sub(
                            poolUser.rewardsAmountPerStakingIQPaid
                        )
                    )
                );
            // as user rewardsAmountWithdrawable is updated, we need to reduct the current rewardsAccumulatedPerStakingIQ
            poolUser.rewardsAmountPerStakingIQPaid = pool
                .rewardsAccumulatedPerStakingIQ;
            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingIQ,
                _userAddress,
                poolUser.rewardsAmountWithdrawable,
                poolUser.rewardsAmountPerStakingIQPaid
            );
        } else {
            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingIQ,
                _userAddress,
                0,
                0
            );
        }
    }

    /* ========== VIEW METHODS ========== */

    // get updated reward per token
    // rewardsAccumulatedPerStakingIQ + new changes from time = rewardsLastCalculationBlock
    function getUpdatedRewardAccumulatedPerStakingIQ(uint256 _poolId)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        // no one is staking, just return
        if (pool.stakingIQAmount == 0) {
            return pool.rewardsAccumulatedPerStakingIQ;
        }
        // check if the current reward peroid is ended
        if (block.number < pool.rewardsEndBlock) {
            // if the pool is ongoing
            // reward per token
            // = rewardsAccumulatedPerStakingIQ + new changes
            // = rewardsAccumulatedPerStakingIQ + ((now - last update) * rewards per block / staking amount)
            return
                pool.rewardsAccumulatedPerStakingIQ.add(
                    block
                        .number
                        .sub(pool.rewardsLastCalculationBlock)
                        .mul(pool.rewardsPerBlock)
                        .div(pool.stakingIQAmount)
                );
        }
        // if pool reward period is ended
        // reward per token
        // = rewardsAccumulatedPerStakingIQ + new changes
        // = rewardsAccumulatedPerStakingIQ + ((end time - last update) * rewards per block / staking amount)
        return
            pool.rewardsAccumulatedPerStakingIQ.add(
                pool
                    .rewardsEndBlock
                    .sub(pool.rewardsLastCalculationBlock)
                    .mul(pool.rewardsPerBlock)
                    .div(pool.stakingIQAmount)
            );
    }

    function getPoolUserEarned(uint256 _poolId, address _userAddress)
        external
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_userAddress];
        return
            poolUser.rewardsAmountWithdrawable.add(
                poolUser.stakingIQAmount.mul(
                    pool.rewardsAccumulatedPerStakingIQ.sub(
                        poolUser.rewardsAmountPerStakingIQPaid
                    )
                )
            );
    }

    function getPoolUser(uint256 _poolId, address _userAddress)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_userAddress];
        return (
            poolUser.catIds[0],
            poolUser.catIds[1],
            poolUser.catIds[2],
            poolUser.stakingCatCount,
            poolUser.stakingIQAmount,
            poolUser.rewardsAmountWithdrawable,
            poolUser.rewardsAmountPerStakingIQPaid
        );
    }

    /* ========== MODIFIERS ========== */

    modifier poolExists(uint256 _poolId) {
        Pool storage pool = pools[_poolId];
        require(pool.rewardsLastCalculationBlock > 0, "Pool doesn't exist.");
        _;
    }

    /* ========== EVENTS ========== */

    event PoolCreated(
        uint256 poolId,
        address rewardToken,
        address rewardDistributor,
        uint256 iqTotalRequired
    );
    event PoolRewardsBlockCountSet(uint256 poolId, uint256 rewardsBlockCount);
    event PoolRewardsDistributorSet(uint256 poolId, address rewardsDistributor);
    event PoolRewardSupplied(uint256 poolId, uint256 rewardsTokenAmount);

    event PoolUserStaked(
        uint256 poolId,
        address indexed user,
        uint256[] catIds,
        uint256 catIQ
    );
    event PoolUserWithdrawn(
        uint256 poolId,
        address indexed user,
        uint256[] catIds,
        uint256 catIQ
    );
    event PoolUserRewardClaimed(
        uint256 poolId,
        address indexed user,
        uint256 reward
    );

    event PoolRewardInfoUpdated(
        uint256 poolId,
        uint256 poolRewardsLastCalculationBlock,
        uint256 poolRewardsAccumulatedPerStakingIQ,
        address poolUserAddress,
        uint256 poolUserRewardsAmountWithdrawable,
        uint256 poolUserRewardsAmountPerStakingIQPaid
    );

    event PoolUserStakingIQAmountReset(
        uint256 poolId,
        uint256 poolStakingIQAmount,
        address poolUserAddress,
        uint256 poolUserStakingIQAmount
    );
}
