// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "./GoldenCatLootBox.sol";

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

contract TokenRewardPoolV1 is
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeMathUpgradeable for uint256;
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct PoolUser {
        // user staking amount
        uint256 stakingAmount;
        // reward amount available to withdraw
        uint256 rewardsAmountWithdrawable;
        // reward amount paid (also used to jot the past reward skipped)
        uint256 rewardsAmountPerStakingTokenPaid;
        // reward start counting block
        uint256 lootBoxStakingStartBlock;
    }

    struct Pool {
        // staking token contract
        IERC20Upgradeable stakingToken;
        // reward token contract
        IERC20Upgradeable rewardsToken;
        // reward token distributor
        address rewardsDistributor;
        // loot box contract
        GoldenCatLootBox goldenCatLootBox;
        // total staking amount
        uint256 stakingAmount;
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
        uint256 rewardsAccumulatedPerStakingToken;
        // the reward last update block
        // it only changes in 2 situations
        // 1. depositReward
        // 2. updatePool modifier used in stake, withdraw, claimReward, depositReward
        uint256 rewardsLastCalculationBlock;
        // pool user mapping;
        mapping(address => PoolUser) users;
        // loot box configuration mapping;
        // pool id => pool loot box configuration struct
        // *** rule: higher the config id => higher the staking amount
        mapping(uint256 => PoolLootBoxConfiguration) lootBoxConfigurations;
        // loot box configuration counter;
        CountersUpgradeable.Counter lootBoxConfigurationIdTracker; // starts from 0
    }

    // To support the structure of multiple loot box giveaway
    // eg. deposit more can get 1 loot box in a short time
    struct PoolLootBoxConfiguration {
        bool enabled;
        // rewards amount needed for loot box
        uint256 stakingAmountRequired;
        // rewards block needed for loot box
        uint256 stakingBlockCountRequired;
    }

    mapping(uint256 => Pool) public pools;
    CountersUpgradeable.Counter public poolIdTracker; // starts from 0

    uint256 public constant DENOMINATOR = 1e18;

    // initialize
    function initialize() public initializer {
        super.__Ownable_init();
        super.__Pausable_init();
        super.__ReentrancyGuard_init();
    }

    // admin step 1: createPool
    function createPool(
        IERC20Upgradeable _stakingToken,
        IERC20Upgradeable _rewardsToken,
        address _rewardsDistributor,
        GoldenCatLootBox _goldenCatLootBox
    ) public onlyOwner {
        Pool storage pool = pools[poolIdTracker.current()];
        pool.stakingToken = _stakingToken;
        pool.rewardsToken = _rewardsToken;
        pool.rewardsDistributor = _rewardsDistributor;
        pool.goldenCatLootBox = _goldenCatLootBox;
        // to indicate the pool is activated
        pool.rewardsLastCalculationBlock = block.number;
        // pool.lootBoxStakingAmountRequired = type(uint256).max;
        // pool.lootBoxStakingBlockCountRequired = 0;
        emit PoolCreated(
            poolIdTracker.current(),
            address(_stakingToken),
            address(_rewardsToken),
            _rewardsDistributor
        );
        poolIdTracker.increment();
    }

    function createPoolLootBoxConfiguration(
        uint256 _poolId,
        bool _enabled,
        uint256 _stakingAmountRequired,
        uint256 _stakingBlockCountRequired
    ) external onlyOwner poolExists(_poolId) {
        require(_stakingAmountRequired != 0, "Invalid Stake Amount Required.");
        require(
            _stakingBlockCountRequired != 0,
            "Invalid Stake Block Count Required."
        );
        Pool storage pool = pools[_poolId];
        // make sure the current config staking amount is larger than all existing ones
        if (pool.lootBoxConfigurationIdTracker.current() > 0) {
            uint256 i = pool.lootBoxConfigurationIdTracker.current().sub(1);
            while (i >= 0) {
                PoolLootBoxConfiguration
                    storage existingPoolLootBoxConfiguration = pool
                        .lootBoxConfigurations[i];
                if (existingPoolLootBoxConfiguration.enabled) {
                    require(
                        _stakingAmountRequired >
                            existingPoolLootBoxConfiguration
                                .stakingAmountRequired,
                        "Stake Amount Less Than Existing Config."
                    );
                    require(
                        _stakingBlockCountRequired <
                            existingPoolLootBoxConfiguration
                                .stakingBlockCountRequired,
                        "Block count higher than lower ID config."
                    );
                }
                if (i == 0) {
                    break;
                } else {
                    i--;
                }
            }
        }
        // update value
        PoolLootBoxConfiguration storage poolLootBoxConfiguration = pool
            .lootBoxConfigurations[
                pool.lootBoxConfigurationIdTracker.current()
            ];
        poolLootBoxConfiguration.enabled = _enabled;
        poolLootBoxConfiguration.stakingAmountRequired = _stakingAmountRequired;
        poolLootBoxConfiguration
            .stakingBlockCountRequired = _stakingBlockCountRequired;
        pool.lootBoxConfigurationIdTracker.increment();
        emit PoolLootBoxConfigurationCreated(
            _poolId,
            pool.lootBoxConfigurationIdTracker.current().sub(1),
            _enabled,
            _stakingAmountRequired,
            _stakingBlockCountRequired
        );
    }

    function updatePoolLootBoxConfiguration(
        uint256 _poolId,
        uint256 _poolLootBoxConfigurationId,
        bool _enabled,
        uint256 _stakingAmountRequired,
        uint256 _stakingBlockCountRequired
    ) external onlyOwner poolExists(_poolId) {
        require(_stakingAmountRequired != 0, "Invalid Stake Amount Required.");
        require(
            _stakingBlockCountRequired != 0,
            "Invalid Stake Block Count Required."
        );
        Pool storage pool = pools[_poolId];
        require(
            _poolLootBoxConfigurationId <
                pool.lootBoxConfigurationIdTracker.current(),
            "Configuration Not Created"
        );
        // make sure the current config staking amount is larger than all existing ones
        if (_poolLootBoxConfigurationId > 0) {
            uint256 i = _poolLootBoxConfigurationId.sub(1);
            while (i >= 0) {
                PoolLootBoxConfiguration
                    storage existingPoolLootBoxConfiguration = pool
                        .lootBoxConfigurations[i];
                if (existingPoolLootBoxConfiguration.enabled) {
                    require(
                        _stakingAmountRequired >
                            existingPoolLootBoxConfiguration
                                .stakingAmountRequired,
                        "Stake amount less than lower ID config."
                    );
                    require(
                        _stakingBlockCountRequired <
                            existingPoolLootBoxConfiguration
                                .stakingBlockCountRequired,
                        "Block count higher than lower ID config."
                    );
                    break;
                }
                if (i == 0) {
                    break;
                } else {
                    i--;
                }
            }
        }
        // make sure the current config staking amount is smaller than higher ids
        for (
            uint256 i = _poolLootBoxConfigurationId.add(1);
            i < pool.lootBoxConfigurationIdTracker.current();
            i++
        ) {
            PoolLootBoxConfiguration
                storage existingPoolLootBoxConfiguration = pool
                    .lootBoxConfigurations[i];
            if (existingPoolLootBoxConfiguration.enabled) {
                require(
                    _stakingAmountRequired <
                        existingPoolLootBoxConfiguration.stakingAmountRequired,
                    "Stake amount higher than higher ID config."
                );
                require(
                    _stakingBlockCountRequired >
                        existingPoolLootBoxConfiguration
                            .stakingBlockCountRequired,
                    "Block count lower than higher ID config."
                );
                break;
            }
        }
        // update value
        PoolLootBoxConfiguration storage poolLootBoxConfiguration = pool
            .lootBoxConfigurations[_poolLootBoxConfigurationId];
        poolLootBoxConfiguration.enabled = _enabled;
        poolLootBoxConfiguration.stakingAmountRequired = _stakingAmountRequired;
        poolLootBoxConfiguration
            .stakingBlockCountRequired = _stakingBlockCountRequired;
        emit PoolLootBoxConfigurationUpdated(
            _poolId,
            _poolLootBoxConfigurationId,
            _enabled,
            _stakingAmountRequired,
            _stakingBlockCountRequired
        );
    }

    // admin step 5: set duration
    // eg. use 15s as block time, 7 days = 7 * 24 * 60 * 60 / 15 = 40320
    function setPoolRewardsBlockCount(
        uint256 _poolId,
        uint256 _rewardsBlockCount
    ) external onlyOwner poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        // you need to finish one pool period before another one
        require(
            block.number >= pool.rewardsEndBlock,
            "Current pool end block not finished."
        );
        pool.rewardsBlockCount = _rewardsBlockCount;
        emit PoolRewardsBlockCountSet(_poolId, _rewardsBlockCount);
    }

    // admin step 6: set pool rewards distributor
    function setPoolRewardsDistributor(
        uint256 _poolId,
        address _rewardsDistributor
    ) external onlyOwner poolExists(_poolId) {
        require(_rewardsDistributor != address(0), "Invalid Input.");
        Pool storage pool = pools[_poolId];
        pool.rewardsDistributor = _rewardsDistributor;
        emit PoolRewardsDistributorSet(_poolId, _rewardsDistributor);
    }

    // admin step 7: supply reward (can only call by pool rewards distributor)
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

    // user stake
    function stake(uint256 _poolId, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
    {
        require(_amount > 0, "Invalid input for amount.");

        updatePoolRewardInfo(_poolId, msg.sender);

        _claimReward(_poolId);

        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount.add(_amount)
            );
        if (poolLootBoxConfiguration.enabled) {
            // update the user count when he reaches the required amount for configuration
            if (
                poolUser.stakingAmount <
                poolLootBoxConfiguration.stakingAmountRequired
            ) {
                poolUser.lootBoxStakingStartBlock = block.number;
            }
        } else {
            // no fitting configuration
            poolUser.lootBoxStakingStartBlock = 0;
        }
        pool.stakingAmount = pool.stakingAmount.add(_amount);
        poolUser.stakingAmount = poolUser.stakingAmount.add(_amount);
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit PoolUserStaked(_poolId, msg.sender, _amount);
    }

    function exit(uint256 _poolId) external nonReentrant poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        _withdraw(_poolId, poolUser.stakingAmount);
    }

    function withdraw(uint256 _poolId, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
    {
        _withdraw(_poolId, _amount);
    }

    // user withdraw
    function _withdraw(uint256 _poolId, uint256 _amount) private {
        require(_amount > 0, "Invalid input for amount.");

        updatePoolRewardInfo(_poolId, msg.sender);

        _claimReward(_poolId);

        // loot box part
        _claimLootBox(_poolId);
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        pool.stakingAmount = pool.stakingAmount.sub(_amount);
        poolUser.stakingAmount = poolUser.stakingAmount.sub(_amount);
        // update with new staking amount
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );
        if (!poolLootBoxConfiguration.enabled) {
            // no fitting configuration
            poolUser.lootBoxStakingStartBlock = 0;
        }
        pool.stakingToken.safeTransfer(msg.sender, _amount);
        emit PoolUserWithdrawn(_poolId, msg.sender, _amount);
    }

    // user withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        uint256 amount = poolUser.stakingAmount;
        require(amount > 0, "No staking amount");
        pool.stakingAmount = pool.stakingAmount.sub(amount);
        poolUser.stakingAmount = 0;
        poolUser.lootBoxStakingStartBlock = 0;
        pool.stakingToken.safeTransfer(msg.sender, amount);
        emit PoolUserWithdrawnEmergency(_poolId, msg.sender, amount);
    }

    function claimLootBox(uint256 _poolId)
        external
        nonReentrant
        poolExists(_poolId)
    {
        require(isLootBoxClaimable(_poolId, msg.sender), "Can not claim");
        updatePoolRewardInfo(_poolId, msg.sender);
        _claimLootBox(_poolId);
    }

    // claim loot box private
    function _claimLootBox(uint256 _poolId) private poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[msg.sender];
        if (isLootBoxClaimable(_poolId, msg.sender)) {
            uint256 lootBoxClaimableCount = getLootBoxClaimableCount(
                _poolId,
                msg.sender
            );
            for (uint256 i = 0; i < lootBoxClaimableCount; i++) {
                pool.goldenCatLootBox.mint(
                    msg.sender,
                    address(pool.stakingToken)
                );
            }
            poolUser.lootBoxStakingStartBlock = block.number;
            emit PoolUserLootBoxClaimedV2(
                _poolId,
                msg.sender,
                lootBoxClaimableCount
            );
        }
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );
        if (!poolLootBoxConfiguration.enabled) {
            // no fitting configuration
            poolUser.lootBoxStakingStartBlock = 0;
        }
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
            .rewardsAccumulatedPerStakingToken = getUpdatedRewardPerStakingTokenAccumulated(
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
                    poolUser
                        .stakingAmount
                        .mul(
                            pool.rewardsAccumulatedPerStakingToken.sub(
                                poolUser.rewardsAmountPerStakingTokenPaid
                            )
                        )
                        .div(DENOMINATOR)
                );
            // as user rewardsAmountWithdrawable is updated, we need to reduct the current rewardsAccumulatedPerStakingToken
            poolUser.rewardsAmountPerStakingTokenPaid = pool
                .rewardsAccumulatedPerStakingToken;

            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingToken,
                _userAddress,
                poolUser.rewardsAmountWithdrawable,
                poolUser.rewardsAmountPerStakingTokenPaid
            );
        } else {
            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingToken,
                _userAddress,
                0,
                0
            );
        }
    }

    /* ========== VIEW METHODS ========== */

    function getPoolUserLootBoxConfiguration(
        uint256 _poolId,
        uint256 _stakingAmount
    ) public view returns (PoolLootBoxConfiguration memory configuration) {
        Pool storage pool = pools[_poolId];
        if (pool.lootBoxConfigurationIdTracker.current() > 0) {
            uint256 i = pool.lootBoxConfigurationIdTracker.current().sub(1);
            while (i >= 0) {
                PoolLootBoxConfiguration storage poolLootBoxConfiguration = pool
                    .lootBoxConfigurations[i];
                if (
                    poolLootBoxConfiguration.enabled &&
                    _stakingAmount >=
                    poolLootBoxConfiguration.stakingAmountRequired
                ) {
                    return poolLootBoxConfiguration;
                }
                if (i == 0) {
                    break;
                } else {
                    i--;
                }
            }
        }
        return PoolLootBoxConfiguration(false, 0, 0);
    }

    function isLootBoxStaking(uint256 _poolId, address _user)
        public
        view
        returns (bool)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );
        return (poolLootBoxConfiguration.enabled &&
            poolLootBoxConfiguration.stakingAmountRequired != 0 &&
            poolLootBoxConfiguration.stakingBlockCountRequired != 0 &&
            poolUser.lootBoxStakingStartBlock != 0);
    }

    function isLootBoxClaimable(uint256 _poolId, address _user)
        public
        view
        returns (bool)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );

        return (isLootBoxStaking(_poolId, _user) &&
            block.number.sub(poolUser.lootBoxStakingStartBlock) >=
            poolLootBoxConfiguration.stakingBlockCountRequired);
    }

    function getLootBoxClaimableCount(uint256 _poolId, address _user)
        public
        view
        returns (uint256)
    {
        if (!isLootBoxClaimable(_poolId, _user)) {
            return 0;
        }
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );

        return
            (block.number - poolUser.lootBoxStakingStartBlock) /
            poolLootBoxConfiguration.stakingBlockCountRequired;
    }

    function getLootBoxStakingRemainingBlock(uint256 _poolId, address _user)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_user];
        PoolLootBoxConfiguration
            memory poolLootBoxConfiguration = getPoolUserLootBoxConfiguration(
                _poolId,
                poolUser.stakingAmount
            );
        if (isLootBoxStaking(_poolId, _user)) {
            if (isLootBoxClaimable(_poolId, _user)) {
                return 0;
            }
            return (poolUser.lootBoxStakingStartBlock +
                poolLootBoxConfiguration.stakingBlockCountRequired -
                block.number);
        }
        return type(uint256).max;
    }

    // get updated reward per token
    // rewardsAccumulatedPerStakingToken + new changes from time = rewardsLastCalculationBlock
    function getUpdatedRewardPerStakingTokenAccumulated(uint256 _poolId)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        // no one is staking, just return
        if (pool.stakingAmount == 0) {
            return pool.rewardsAccumulatedPerStakingToken;
        }
        // check if the current reward peroid is ended
        if (block.number < pool.rewardsEndBlock) {
            // if the pool is ongoing
            // reward per token
            // = rewardsAccumulatedPerStakingToken + new changes
            // = rewardsAccumulatedPerStakingToken + ((now - last update) * rewards per block / staking amount)
            return
                pool.rewardsAccumulatedPerStakingToken.add(
                    block
                        .number
                        .sub(pool.rewardsLastCalculationBlock)
                        .mul(pool.rewardsPerBlock)
                        .mul(DENOMINATOR)
                        .div(pool.stakingAmount)
                );
        }
        // if pool reward period is ended
        // reward per token
        // = rewardsAccumulatedPerStakingToken + new changes
        // = rewardsAccumulatedPerStakingToken + ((end time - last update) * rewards per block / staking amount)
        return
            pool.rewardsAccumulatedPerStakingToken.add(
                pool
                    .rewardsEndBlock
                    .sub(pool.rewardsLastCalculationBlock)
                    .mul(pool.rewardsPerBlock)
                    .mul(DENOMINATOR)
                    .div(pool.stakingAmount)
            );
    }

    function getPoolUserEarned(uint256 _poolId, address _userAddress)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_userAddress];
        return
            poolUser.rewardsAmountWithdrawable.add(
                poolUser
                    .stakingAmount
                    .mul(
                        pool.rewardsAccumulatedPerStakingToken.sub(
                            poolUser.rewardsAmountPerStakingTokenPaid
                        )
                    )
                    .div(DENOMINATOR)
            );
    }

    function getPoolUser(uint256 _poolId, address _userAddress)
        public
        view
        returns (PoolUser memory user)
    {
        Pool storage pool = pools[_poolId];
        user = pool.users[_userAddress];
    }

    function getPoolLootBoxConfiguration(uint256 _poolId, uint256 _confId)
        public
        view
        returns (PoolLootBoxConfiguration memory lootBoxConfiguration)
    {
        Pool storage pool = pools[_poolId];
        return pool.lootBoxConfigurations[_confId];
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
        address stakingToken,
        address rewardToken,
        address rewardDistributor
    );
    event PoolLootBoxConfigurationCreated(
        uint256 poolId,
        uint256 poolLootBoxConfigurationId,
        bool enabled,
        uint256 stakingAmountRequired,
        uint256 stakingBlockCountRequired
    );
    event PoolLootBoxConfigurationUpdated(
        uint256 poolId,
        uint256 poolLootBoxConfigurationId,
        bool enabled,
        uint256 stakingAmountRequired,
        uint256 stakingBlockCountRequired
    );
    event PoolRewardsBlockCountSet(uint256 poolId, uint256 rewardsBlockCount);
    event PoolRewardsDistributorSet(uint256 poolId, address rewardsDistributor);
    event PoolRewardSupplied(uint256 poolId, uint256 rewardsTokenAmount);

    event PoolUserStaked(uint256 poolId, address indexed user, uint256 amount);
    event PoolUserWithdrawn(
        uint256 poolId,
        address indexed user,
        uint256 amount
    );
    event PoolUserWithdrawnEmergency(
        uint256 poolId,
        address indexed user,
        uint256 amount
    );

    event PoolUserLootBoxClaimed(uint256 poolId, address indexed user);
    event PoolUserLootBoxClaimedV2(
        uint256 poolId,
        address indexed user,
        uint256 count
    );
    event PoolUserRewardClaimed(
        uint256 poolId,
        address indexed user,
        uint256 reward
    );

    event PoolRewardInfoUpdated(
        uint256 poolId,
        uint256 poolRewardsLastCalculationBlock,
        uint256 poolRewardsAccumulatedPerStakingToken,
        address poolUserAddress,
        uint256 poolUserRewardsAmountWithdrawable,
        uint256 poolUserRewardsAmountPerStakingTokenPaid
    );
}
