// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./Exponential.sol";
import "./library/SafeERC20.sol";
import "./library/EthAddressLib.sol";
import "./interfaces/lending/IInterestRateModel.sol";
import "./interfaces/lending/IBankController.sol";
import "./interfaces/lending/IERC20.sol";
import "./interfaces/lending/IFToken.sol";
import "./interfaces/IVaultConfig.sol";
import "./interfaces/lending/IFlashLoanReceiver.sol";
// import "./library/SafeMathLib.sol";

import "hardhat/console.sol";

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

interface IFarm {
    function stake(uint256 _poolId, address sender, uint256 _amount) external;
    function withdraw(uint256 _poolId, address sender, uint256 _amount) external;
    function transfer(uint256 _poolId, address sender, address receiver, uint256 _amount) external;
    function users(address sender) external returns(PoolUser memory);
    function getPoolUser(uint256 _poolId, address _userAddress) external view returns (PoolUser memory user);
}

contract FToken is Exponential, OwnableUpgradeSafe {
    using SafeERC20 for IERC20Interface;

    uint256 public totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => mapping(address => uint256)) internal transferAllowances;

    // address public admin;
    uint256 public initialExchangeRate;
    uint256 public totalBorrows;
    uint256 public totalReserves;

    IVaultConfig public config;

    // The Reserve Factor in Compound is the parameter that controls
    // how much of the interest for a given asset is routed to that asset's Reserve Pool.
    // The Reserve Pool protects lenders against borrower default and liquidation malfunction.
    // For example, a 5% Reserve Factor means that 5% of the interest that borrowers pay for
    // that asset would be routed to the Reserve Pool instead of to lenders.
    uint256 public reserveFactor;
    uint256 public securityFactor;
    uint256 public borrowIndex;
    uint256 internal constant borrowRateMax = 0.0005e16;
    uint256 public accrualBlockNumber;
    IInterestRateModel public interestRateModel;
    address public underlying;
    IBankController public controller;
    uint256 public borrowSafeRatio;
    bool internal _notEntered;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => uint256) public accountTokens;
    mapping(address => BorrowSnapshot) public accountBorrows;
    uint256 public totalCash;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed account, uint256 value);
    event Borrow(address indexed account, uint256 value);

    function initialize(
        uint256 _initialExchangeRate,
        address _controller,
        address _initialInterestRateModel,
        uint256 _borrowSafeRatio,
        address _underlying,
        string memory _name,
        string memory _symbol,
        IVaultConfig _config
    ) public initializer {
        __Ownable_init();
        initialExchangeRate = _initialExchangeRate;
        controller = IBankController(_controller);
        interestRateModel = IInterestRateModel(_initialInterestRateModel);
        underlying = _underlying;
        borrowSafeRatio = _borrowSafeRatio;
        accrualBlockNumber = getBlockNumber();
        borrowIndex = 1e18;
        name = _name;
        symbol = _symbol;
        decimals = 18;
        _notEntered = true;
        securityFactor = 100;
        config = _config;
    }

    modifier onlyController {
        require(msg.sender == address(controller), "require controller");
        _;
    }

    modifier onlyComponent {
        require(
            msg.sender == address(controller) ||
            msg.sender == address(this) ||
            controller.marketsContains(msg.sender),
            "only internal component"
        );
        _;
    }

    modifier whenUnpaused {
        require(!IBankController(controller).paused(), "System paused");
        _;
    }

    // function setController(address _controller) external onlyOwner {
    //     controller = IBankController(_controller);
    // }

    function setReserveAndSecurityAndBorrowSafe(uint256 _reserveFactor, uint256 _borrowSafeRatio, uint256 _securityFactor)
        external
        onlyOwner
    {
        accrueInterest();
        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        reserveFactor = _reserveFactor;
        borrowSafeRatio = _borrowSafeRatio;
        securityFactor = _securityFactor;
    }

    function tokenCash(address token, address account)
        public view returns (uint256)
    {
        return token != EthAddressLib.ethAddress()
                ? IERC20Interface(token).balanceOf(account)
                : address(account).balance;
    }

    function transferToUser(
        address _underlying,
        address payable account,
        uint256 amount
    ) public onlyComponent {
        require(_underlying == underlying, "TransferToUser not allowed");
        transferToUserInternal(underlying, account, amount);
    }

    function transferToUserInternal(
        address _underlying,
        address payable account,
        uint256 amount
    ) internal {
        if (underlying != EthAddressLib.ethAddress()) {
            IERC20Interface(underlying).safeTransfer(account, amount);
        } else {
            (bool result, ) = account.call{
                value: amount,
                gas: controller.transferEthGasCost()
            }("");
            require(result, "Transfer of ETH failed");
        }
    }

    function transferIn(address account, address _underlying, uint256 amount)
        public onlyComponent payable
    {
	    require(controller.marketsContains(msg.sender) || msg.sender == account, "auth failed");
        require(_underlying == underlying, "TransferToUser not allowed");
        if (_underlying != EthAddressLib.ethAddress()) {
            require(msg.value == 0, "ERC20 do not accecpt ETH.");
            uint256 balanceBefore = IERC20Interface(_underlying).balanceOf(address(this));
            IERC20Interface(_underlying).safeTransferFrom(account, address(this), amount);
            uint256 balanceAfter = IERC20Interface(_underlying).balanceOf(address(this));
            require(balanceAfter - balanceBefore == amount, "TransferIn amount not valid");
            // erc20 => transferFrom
        } else {
            // Receive eth transfer, which has been transferred through payable
            require(msg.value >= amount, "Eth value is not enough");
            if (msg.value > amount) {
                // send back excess ETH
                uint256 excessAmount = msg.value.sub(amount);
                //solium-disable-next-line
                (bool result, ) = account.call{
                    value: excessAmount,
                    gas: controller.transferEthGasCost()
                }("");
                require(result, "Transfer of ETH failed");
            }
        }
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     */
    function transfer(address dst, uint256 amount) external nonReentrant {
        // spender - src - dst
        transferTokens(msg.sender, msg.sender, dst, amount);
        emit Transfer(msg.sender, dst, amount);
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     */
    function transferFrom(address src, address dst, uint256 amount) external nonReentrant returns (bool) {
        // spender - src - dst
        transferTokens(msg.sender, src, dst, amount);

        // TransferLogStruct memory tls = TransferLogStruct(
        //     src,
        //     underlying,
        //     address(this),
        //     amount,
        //     balanceOf(src),
        //     dst,
        //     balanceOf(dst),
        //     tokenCash(underlying, address(this))
        // );

        // emit MonitorEvent("TransferFrom", abi.encode(tls));

        return true;
    }

    function transferTokens(
        address spender,
        address src,
        address dst,
        uint256 tokens
    ) internal whenUnpaused returns (bool) {
        controller.transferCheck(address(this), src, dst, mulScalarTruncate(tokens, borrowSafeRatio));

        require(src != dst, "Cannot transfer to self");

        uint256 startingAllowance = 0;
        if (spender == src) {
            startingAllowance = uint256(-1);
        } else {
            startingAllowance = transferAllowances[src][spender];
        }

        uint256 allowanceNew = startingAllowance.sub(tokens);

        accountTokens[src] = accountTokens[src].sub(tokens);
        accountTokens[dst] = accountTokens[dst].add(tokens);

        if (startingAllowance != uint256(-1)) {
            transferAllowances[src][spender] = allowanceNew;
        }

        (address farm, uint256 poolId) = config.getFarmConfig(address(this));
        IFarm(farm).transfer(poolId, src, dst, tokens);
        emit Transfer(src, dst, tokens);
        return true;
    }

    function approve(address spender, uint256 amount) external {
        // address src = msg.sender;
        transferAllowances[msg.sender][spender] = amount;
        // emit Approval(src, spender, amount);
    }

    function allowance(address owner, address spender)
        external
        view
        returns (uint256)
    {
        return transferAllowances[owner][spender];
    }

    struct MintLocals {
        uint256 exchangeRate;
        uint256 mintTokens;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
        uint256 actualMintAmount;
    }

    function mint(address user, uint256 amount) internal nonReentrant {
        accrueInterest();
        mintInternal(user, amount);
    }

    function mintInternal(address user, uint256 amount) internal {
        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        MintLocals memory tmp;
        controller.mintCheck(underlying, user, amount);
        tmp.exchangeRate = exchangeRateStored();
        tmp.mintTokens = divScalarByExpTruncate(amount, tmp.exchangeRate);
        tmp.totalSupplyNew = addExp(totalSupply, tmp.mintTokens);
        tmp.accountTokensNew = addExp(accountTokens[user], tmp.mintTokens);
        totalSupply = tmp.totalSupplyNew;
        accountTokens[user] = tmp.accountTokensNew;

        emit Transfer(address(0), user, tmp.mintTokens);
    }

    function deposit(uint256 amount) external payable whenUnpaused {
        mint(msg.sender, amount);
        this.transferIn{value: msg.value}(msg.sender, underlying, amount);
        this.addTotalCash(amount);

        (address farm, uint256 poolId) = config.getFarmConfig(address(this));
        IFarm(farm).stake(poolId, msg.sender, amount);

        emit Deposit(msg.sender, amount);
    }

    struct BorrowLocals {
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
    }

    function borrow(uint256 borrowAmount) external nonReentrant whenUnpaused {
        accrueInterest();
        borrowInternal(msg.sender, borrowAmount);
    }

    function borrowInternal(address payable borrower, uint256 borrowAmount) internal {
        controller.borrowCheck(
            borrower,
            underlying,
            address(this),
            mulScalarTruncate(borrowAmount, borrowSafeRatio)
        );

        require(
            controller.getCashPrior(underlying) >= borrowAmount,
            "Insufficient balance"
        );

        BorrowLocals memory tmp;
        // uint256 lastPrincipal = accountBorrows[borrower].principal;
        tmp.accountBorrows = borrowBalanceStoredInternal(borrower);
        tmp.accountBorrowsNew = addExp(tmp.accountBorrows, borrowAmount);
        tmp.totalBorrowsNew = addExp(totalBorrows, borrowAmount);

        accountBorrows[borrower].principal = tmp.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = tmp.totalBorrowsNew;

        transferToUserInternal(underlying, borrower, borrowAmount);
        this.subTotalCash(borrowAmount);

        emit Borrow(borrower, borrowAmount);
    }

    function borrowInternalForLeverage(address payable borrower, uint256 borrowAmount) external payable {
        require(controller.vaultContains(msg.sender), "only permit vault");
        controller.borrowCheckForLeverage(
            borrower,
            underlying,
            address(this),
            mulScalarTruncate(borrowAmount, borrowSafeRatio)
        );

        require(
            controller.getCashPrior(underlying) >= borrowAmount,
            "Insufficient balance"
        );
        // This is for the same borrower, the original principal plus the interest plus the amount of money borrowed this time
        // BorrowLocals memory tmp;
        // uint256 lastPrincipal = accountBorrows[borrower].principal;
        // tmp.accountBorrows = lastPrincipal;
        // tmp.accountBorrowsNew = addExp(tmp.accountBorrows, borrowAmount);
        // tmp.totalBorrowsNew = addExp(totalBorrows, borrowAmount);

        accountBorrows[borrower].principal = addExp(accountBorrows[borrower].principal, borrowAmount);
        accountBorrows[borrower].interestIndex = 1e18;
        totalBorrows = addExp(totalBorrows, borrowAmount);

        transferToUserInternal(underlying, msg.sender, borrowAmount);
        this.subTotalCash(borrowAmount);
    }

    struct RepayLocals {
        uint256 repayAmount;
        uint256 borrowerIndex;
        uint256 accountBorrows;
        uint256 accountBorrowsNew;
        uint256 totalBorrowsNew;
        uint256 actualRepayAmount;
    }

    function exchangeRateStored() public view returns (uint256 exchangeRate) {
        return calcExchangeRate(totalBorrows, totalReserves);
    }

    function calcExchangeRate(uint256 _totalBorrows, uint256 _totalReserves)
        public
        view
        returns (uint256 exchangeRate)
    {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return initialExchangeRate;
        } else {
            /*
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint256 totalCash = controller.getCashPrior(underlying);
            uint256 cashPlusBorrowsMinusReserves = subExp(
                addExp(totalCash, _totalBorrows),
                _totalReserves
            );
            exchangeRate = getDiv(cashPlusBorrowsMinusReserves, _totalSupply);
        }
    }

    function exchangeRateAfter(uint256 transferInAmout)
        public view returns (uint256 exchangeRate)
    {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // If the market is initialized, then return to the initial exchange rate
            return initialExchangeRate;
        } else {
            /*
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint256 totalCash = controller.getCashAfter(
                underlying,
                transferInAmout
            );
            uint256 cashPlusBorrowsMinusReserves = subExp(
                addExp(totalCash, totalBorrows),
                totalReserves
            );
            exchangeRate = getDiv(cashPlusBorrowsMinusReserves, _totalSupply);
        }
    }

    // function balanceOfUnderlying(address owner) external returns (uint256) {
    //     uint256 exchangeRate = exchangeRateCurrent();
    //     uint256 balance = mulScalarTruncate(exchangeRate, accountTokens[owner]);
    //     return balance;
    // }

    // function calcBalanceOfUnderlying(address owner)
    //     public
    //     view
    //     returns (uint256)
    // {
    //     (, , uint256 _totalBorrows, uint256 _trotalReserves) = peekInterest();

    //     uint256 _exchangeRate = calcExchangeRate(
    //         _totalBorrows,
    //         _trotalReserves
    //     );
    //     uint256 balance = mulScalarTruncate(
    //         _exchangeRate,
    //         accountTokens[owner]
    //     );
    //     return balance;
    // }

    // function exchangeRateCurrent() public nonReentrant returns (uint256) {
    //     accrueInterest();
    //     return exchangeRateStored();
    // }

    function getAccountState(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 fTokenBalance = accountTokens[account];
        uint256 borrowBalance = borrowBalanceStoredInternal(account);
        uint256 exchangeRate = exchangeRateStored();

        return (fTokenBalance, borrowBalance, exchangeRate);
    }

    struct WithdrawLocals {
        uint256 exchangeRate;
        uint256 withdrawTokens;
        uint256 withdrawAmount;
        uint256 totalSupplyNew;
        uint256 accountTokensNew;
    }

    function withdrawTokens(uint256 withdrawTokensIn)
        public
        whenUnpaused
        nonReentrant
        returns (uint256)
    {
        accrueInterest();
        return withdrawInternal(msg.sender, withdrawTokensIn, 0);
    }

    // function withdrawUnderlying(uint256 withdrawAmount)
    //     public
    //     whenUnpaused
    //     nonReentrant
    //     returns (uint256, bytes memory)
    // {
    //     accrueInterest();
    //     return withdrawInternal(msg.sender, 0, withdrawAmount);
    // }

    function withdrawInternal(
        address payable withdrawer,
        uint256 withdrawTokensIn,
        uint256 withdrawAmountIn
    ) internal returns (uint256) {
        require(
            withdrawTokensIn == 0 || withdrawAmountIn == 0,
            "withdraw parameter not valid"
        );
        WithdrawLocals memory tmp;

        tmp.exchangeRate = exchangeRateStored();

        if (withdrawTokensIn > 0) {
            tmp.withdrawTokens = withdrawTokensIn;
            tmp.withdrawAmount = mulScalarTruncate(
                tmp.exchangeRate,
                withdrawTokensIn
            );
        } else {
            tmp.withdrawTokens = divScalarByExpTruncate(
                withdrawAmountIn,
                tmp.exchangeRate
            );
            tmp.withdrawAmount = withdrawAmountIn;
        }

        controller.withdrawCheck(address(this), withdrawer, tmp.withdrawTokens);

        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

        tmp.totalSupplyNew = totalSupply.sub(tmp.withdrawTokens);
        tmp.accountTokensNew = accountTokens[withdrawer].sub(
            tmp.withdrawTokens
        );

        require(
            controller.getCashPrior(underlying) >= tmp.withdrawAmount,
            "Insufficient money"
        );

        transferToUserInternal(underlying, withdrawer, tmp.withdrawAmount);
        this.subTotalCash(tmp.withdrawAmount);

        totalSupply = tmp.totalSupplyNew;
        accountTokens[withdrawer] = tmp.accountTokensNew;

        (address farm, uint256 poolId) = config.getFarmConfig(address(this));
        IFarm(farm).withdraw(poolId, msg.sender, tmp.withdrawTokens);

        emit Transfer(withdrawer, address(0), tmp.withdrawTokens);

        return tmp.withdrawAmount;
    }

    // function strikeWithdrawInternal(
    //     address withdrawer,
    //     uint256 withdrawTokensIn,
    //     uint256 withdrawAmountIn
    // ) internal returns (uint256, bytes memory) {
    //     require(
    //         withdrawTokensIn == 0 || withdrawAmountIn == 0,
    //         "withdraw parameter not valid"
    //     );
    //     WithdrawLocals memory tmp;

    //     tmp.exchangeRate = exchangeRateStored();

    //     if (withdrawTokensIn > 0) {
    //         tmp.withdrawTokens = withdrawTokensIn;
    //         tmp.withdrawAmount = mulScalarTruncate(
    //             tmp.exchangeRate,
    //             withdrawTokensIn
    //         );
    //     } else {
    //         tmp.withdrawTokens = divScalarByExpTruncate(
    //             withdrawAmountIn,
    //             tmp.exchangeRate
    //         );
    //         tmp.withdrawAmount = withdrawAmountIn;
    //     }

    //     require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

    //     tmp.totalSupplyNew = totalSupply.sub(tmp.withdrawTokens);
    //     tmp.accountTokensNew = accountTokens[withdrawer].sub(
    //         tmp.withdrawTokens
    //     );

    //     totalSupply = tmp.totalSupplyNew;
    //     accountTokens[withdrawer] = tmp.accountTokensNew;

    //     uint256 preCalcTokenCash = tokenCash(underlying, address(this))
    //         .add(tmp.withdrawAmount);

    //     WithdrawLogStruct memory wls = WithdrawLogStruct(
    //         withdrawer,
    //         underlying,
    //         address(this),
    //         tmp.withdrawTokens,
    //         tmp.withdrawAmount,
    //         exchangeRateStored(),
    //         interestRateModel.getBorrowRate(
    //             preCalcTokenCash,
    //             totalBorrows,
    //             totalReserves
    //         ),
    //         tokenCash(address(this), withdrawer),
    //         preCalcTokenCash
    //     );

    //     emit Transfer(withdrawer, address(0), tmp.withdrawTokens);

    //     return (tmp.withdrawAmount, abi.encode(wls));
    // }

    function accrueInterest() public {
        uint256 currentBlockNumber = getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return;
        }

        uint256 cashPrior = controller.getCashPrior(underlying);
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        uint256 borrowRate = interestRateModel.getBorrowRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        require(borrowRate <= borrowRateMax, "borrow rate is too high");

        uint256 blockDelta = currentBlockNumber.sub(accrualBlockNumberPrior);

        /*
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */

        uint256 simpleInterestFactor;
        uint256 interestAccumulated;
        uint256 totalBorrowsNew;
        uint256 totalReservesNew;
        uint256 borrowIndexNew;

        simpleInterestFactor = mulScalar(borrowRate, blockDelta);

        interestAccumulated = divExp(
            mulExp(simpleInterestFactor, borrowsPrior),
            expScale
        );

        totalBorrowsNew = addExp(interestAccumulated, borrowsPrior);

        totalReservesNew = addExp(
            divExp(mulExp(reserveFactor, interestAccumulated), expScale),
            reservesPrior
        );

        borrowIndexNew = addExp(
            divExp(mulExp(simpleInterestFactor, borrowIndexPrior), expScale),
            borrowIndexPrior
        );

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        borrowRate = interestRateModel.getBorrowRate(
            cashPrior,
            totalBorrows,
            totalReserves
        );
        require(borrowRate <= borrowRateMax, "borrow rate is too high");
    }

    function peekInterest()
        public view
        returns (
            uint256 _accrualBlockNumber,
            uint256 _borrowIndex,
            uint256 _totalBorrows,
            uint256 _totalReserves
        )
    {
        _accrualBlockNumber = getBlockNumber();
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == _accrualBlockNumber) {
            return (
                accrualBlockNumber,
                borrowIndex,
                totalBorrows,
                totalReserves
            );
        }

        uint256 cashPrior = controller.getCashPrior(underlying);
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        uint256 borrowRate = interestRateModel.getBorrowRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        require(borrowRate <= borrowRateMax, "borrow rate is too high");

        uint256 blockDelta = _accrualBlockNumber.sub(accrualBlockNumberPrior);

        /*
         *  simpleInterestFactor = borrowRate * blockDelta
         *  interestAccumulated = simpleInterestFactor * totalBorrows
         *  totalBorrowsNew = interestAccumulated + totalBorrows
         *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
         *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
         */

        uint256 simpleInterestFactor;
        uint256 interestAccumulated;
        uint256 totalBorrowsNew;
        uint256 totalReservesNew;
        uint256 borrowIndexNew;

        simpleInterestFactor = mulScalar(borrowRate, blockDelta);

        interestAccumulated = divExp(
            mulExp(simpleInterestFactor, borrowsPrior),
            expScale
        );

        totalBorrowsNew = addExp(interestAccumulated, borrowsPrior);

        totalReservesNew = addExp(
            divExp(mulExp(reserveFactor, interestAccumulated), expScale),
            reservesPrior
        );

        borrowIndexNew = addExp(
            divExp(mulExp(simpleInterestFactor, borrowIndexPrior), expScale),
            borrowIndexPrior
        );

        _borrowIndex = borrowIndexNew;
        _totalBorrows = totalBorrowsNew;
        _totalReserves = totalReservesNew;

        borrowRate = interestRateModel.getBorrowRate(
            cashPrior,
            totalBorrows,
            totalReserves
        );
        require(borrowRate <= borrowRateMax, "borrow rate is too high");
    }

    function borrowBalanceCurrent(address account)
        external
        nonReentrant
        returns (uint256)
    {
        accrueInterest();
        BorrowSnapshot memory borrowSnapshot = accountBorrows[account];
        require(borrowSnapshot.interestIndex <= borrowIndex, "borrowIndex error");

        return borrowBalanceStoredInternal(account);
    }

    function borrowBalanceStoredInternal(address user)
        internal view
        returns (uint256 result)
    {
        BorrowSnapshot memory borrowSnapshot = accountBorrows[user];

        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        result = mulExp(borrowSnapshot.principal, divExp(borrowIndex, borrowSnapshot.interestIndex));
    }

    // function _setInterestRateModel(IInterestRateModel newInterestRateModel)
    //     public
    //     onlyAdmin
    // {
    //     address oldIRM = address(interestRateModel);
    //     uint256 oldUR = utilizationRate();
    //     uint256 oldAPR = APR();
    //     uint256 oldAPY = APY();

    //     uint256 exRate1 = exchangeRateStored();
    //     accrueInterest();
    //     uint256 exRate2 = exchangeRateStored();

    //     require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

    //     interestRateModel = newInterestRateModel;
    //     uint256 newUR = utilizationRate();
    //     uint256 newAPR = APR();
    //     uint256 newAPY = APY();

    //     emit NewInterestRateModel(oldIRM, oldUR, oldAPR, oldAPY, exRate1, address(newInterestRateModel), newUR, newAPR, newAPY, exRate2);

    //     // ReserveDepositLogStruct memory rds = ReserveDepositLogStruct(
    //     //     underlying,
    //     //     0,
    //     //     exchangeRateStored(),
    //     //     getBorrowRate(),
    //     //     tokenCash(underlying, address(this))
    //     // );

    //     // emit MonitorEvent(
    //     //     "ReserveDeposit",
    //     //     abi.encode(rds)
    //     // );
    // }

    // function setInitialExchangeRate(uint256 _initialExchangeRate) external onlyOwner {
    //     uint256 oldInitialExchangeRate = initialExchangeRate;

    //     uint256 oldUR = utilizationRate();
    //     uint256 oldAPR = APR();
    //     uint256 oldAPY = APY();

    //     uint256 exRate1 = exchangeRateStored();
    //     accrueInterest();
    //     uint256 exRate2 = exchangeRateStored();

    //     require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

    //     initialExchangeRate = _initialExchangeRate;
    //     uint256 newUR = utilizationRate();
    //     uint256 newAPR = APR();
    //     uint256 newAPY = APY();

    //     // emit NewInitialExchangeRate(oldInitialExchangeRate, oldUR, oldAPR, oldAPY, exRate1, initialExchangeRate, newUR, newAPR, newAPY, exRate2);

    //     // ReserveDepositLogStruct memory rds = ReserveDepositLogStruct(
    //     //     underlying,
    //     //     0,
    //     //     exchangeRateStored(),
    //     //     getBorrowRate(),
    //     //     tokenCash(underlying, address(this))
    //     // );

    //     // emit MonitorEvent(
    //     //     "ReserveDeposit",
    //     //     abi.encode(rds)
    //     // );
    // }

    function getBlockNumber() internal view returns (uint256) {
        return block.number;
    }

    function repay(uint256 repayAmount)
        external payable whenUnpaused nonReentrant
    {
        accrueInterest();

        uint256 actualRepayAmount = repayInternal(msg.sender, repayAmount);

        this.transferIn{value: msg.value}(
            msg.sender,
            underlying,
            actualRepayAmount
        );
        this.addTotalCash(actualRepayAmount);
        // return (actualRepayAmount, flog);
    }

    function repayInternal(address borrower, uint256 repayAmount)
        internal
        returns (uint256)
    {
        controller.repayCheck(underlying);
        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

        RepayLocals memory tmp;
        // uint256 lastPrincipal = accountBorrows[borrower].principal;
        tmp.borrowerIndex = accountBorrows[borrower].interestIndex;
        tmp.accountBorrows = borrowBalanceStoredInternal(borrower);

        // -1 Means the repay all
        if (repayAmount == uint256(-1)) {
            tmp.repayAmount = tmp.accountBorrows;
        } else {
            tmp.repayAmount = repayAmount;
        }

        tmp.accountBorrowsNew = tmp.accountBorrows.sub(tmp.repayAmount);
        if (totalBorrows < tmp.repayAmount) {
            tmp.totalBorrowsNew = 0;
        } else {
            tmp.totalBorrowsNew = totalBorrows.sub(tmp.repayAmount);
        }

        accountBorrows[borrower].principal = tmp.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = tmp.totalBorrowsNew;

        return tmp.repayAmount;
    }

    function repayInternalForLeverage(address borrower, uint256 repayAmount)
        external payable
    {
        require(controller.vaultContains(msg.sender), "vault not permitted");
        accrueInterest();
        controller.repayCheck(underlying);
        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");

        RepayLocals memory tmp;
        uint256 lastPrincipal = accountBorrows[borrower].principal;
        tmp.accountBorrows = lastPrincipal;
        tmp.borrowerIndex = 1e18;

        // -1 Means the repay all
        if (repayAmount == uint256(-1)) {
            tmp.repayAmount = tmp.accountBorrows;
        } else {
            tmp.repayAmount = repayAmount;
        }

        tmp.accountBorrowsNew = SafeMathLib.sub(tmp.accountBorrows, tmp.repayAmount, "tmp.accountBorrowsNew sub");
        if (totalBorrows < tmp.repayAmount) {
            tmp.totalBorrowsNew = 0;
        } else {
            tmp.totalBorrowsNew = SafeMathLib.sub(totalBorrows, tmp.repayAmount, "tmp.totalBorrowsNew sub");
        }

        accountBorrows[borrower].principal = tmp.accountBorrowsNew;
        accountBorrows[borrower].interestIndex = tmp.borrowerIndex;
        totalBorrows = tmp.totalBorrowsNew;

        this.transferIn{value: msg.value}(
            msg.sender,
            underlying,
            tmp.repayAmount
        );
        this.addTotalCash(tmp.repayAmount);
    }

    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalanceStoredInternal(account);
    }

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        address underlyingCollateral
    ) public payable whenUnpaused nonReentrant
    {
        require(msg.sender != borrower, "Liquidator cannot be borrower");
        require(repayAmount > 0, "Liquidate amount not valid");
        require(!config.isWorker(borrower), "Cannot liquidate worker debt");

        FToken fTokenCollateral = FToken(
            controller.getFTokeAddress(underlyingCollateral)
        );

        _liquidateBorrow(msg.sender, borrower, repayAmount, fTokenCollateral);

        this.transferIn{value: msg.value}(
            msg.sender,
            underlying,
            repayAmount
        );

        this.addTotalCash(repayAmount);
    }

    function _liquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        FToken fTokenCollateral
    ) internal {
        require(
            controller.isFTokenValid(address(this)) &&
                controller.isFTokenValid(address(fTokenCollateral)),
            "Market not listed"
        );
        accrueInterest();
        fTokenCollateral.accrueInterest();
        // uint256 lastPrincipal = accountBorrows[borrower].principal;
        // uint256 newPrincipal = borrowBalanceStoredInternal(borrower);

        controller.liquidateBorrowCheck(
            address(this),
            address(fTokenCollateral),
            borrower,
            liquidator,
            repayAmount
        );

        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        require(
            fTokenCollateral.accrualBlockNumber() == getBlockNumber(),
            "Blocknumber fails"
        );

        uint256 actualRepayAmount = repayInternal(borrower, repayAmount);

        uint256 seizeTokens = controller.liquidateTokens(
            address(this),
            address(fTokenCollateral),
            actualRepayAmount
        );
        require(
            fTokenCollateral.balanceOf(borrower) >= seizeTokens,
            "Seize too much"
        );

        if (address(fTokenCollateral) == address(this)) {
            seizeInternal(address(this), liquidator, borrower, seizeTokens);
        } else {
            fTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }
    }

    function seize(
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external nonReentrant {
        return seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
    }

    // function cancellingOut() public whenUnpaused nonReentrant {
    //     (bool strikeOk, bytes memory strikeLog) = _cancellingOut(
    //         msg.sender
    //     );
    //     if (strikeOk) {
    //         emit MonitorEvent("CancellingOut", strikeLog);
    //     }
    // }

    // function _cancellingOut(address striker)
    //     internal
    //     nonReentrant
    //     returns (bool strikeOk, bytes memory strikeLog)
    // {
    //     if (
    //         borrowBalanceStoredInternal(striker) > 0 && balanceOf(striker) > 0
    //     ) {
    //         accrueInterest();
    //         uint256 lastPrincipal = accountBorrows[striker].principal;
    //         uint256 curBorrowBalance = borrowBalanceStoredInternal(striker);
    //         uint256 userSupplyBalance = calcBalanceOfUnderlying(striker);
    //         uint256 lastFtokenBalance = balanceOf(striker);
    //         uint256 actualRepayAmount;
    //         bytes memory repayLog;
    //         uint256 withdrawAmount;
    //         bytes memory withdrawLog;
    //         if (curBorrowBalance > 0 && userSupplyBalance > 0) {
    //             if (userSupplyBalance > curBorrowBalance) {
    //                 (withdrawAmount, withdrawLog) = strikeWithdrawInternal(
    //                     striker,
    //                     0,
    //                     curBorrowBalance
    //                 );
    //             } else {
    //                 (withdrawAmount, withdrawLog) = strikeWithdrawInternal(
    //                     striker,
    //                     balanceOf(striker),
    //                     0
    //                 );
    //             }
    //             (actualRepayAmount, repayLog) = repayInternal(
    //                 striker,
    //                 withdrawAmount
    //             );
    //             CallingOutLogStruct memory cols;
    //             cols.user_address = striker;
    //             cols.token_address = underlying;
    //             cols.cheque_token_address = address(this);
    //             cols.amount_wiped_out = SafeMathLib.abs(
    //                 lastFtokenBalance,
    //                 balanceOf(striker)
    //             );
    //             cols.debt_cancelled_out = actualRepayAmount;
    //             cols.interest_accrued = SafeMathLib.abs(
    //                 curBorrowBalance,
    //                 lastPrincipal
    //             );
    //             cols.cheque_token_value = exchangeRateStored();
    //             cols.loan_interest_rate = interestRateModel.getBorrowRate(
    //                 tokenCash(underlying, address(this)),
    //                 totalBorrows,
    //                 totalReserves
    //             );
    //             cols.account_balance = tokenCash(address(this), striker);
    //             cols.account_debt = accountBorrows[striker].principal;
    //             cols.global_token_reserved = tokenCash(
    //                 underlying,
    //                 address(this)
    //             );
    //             strikeLog = abi.encode(cols);
    //             strikeOk = true;
    //         }
    //     }
    // }

    // function transferFlashloanAsset(
    //     address underlying,
    //     address payable account,
    //     uint256 amount
    // ) public onlySelf {
    //     transferToUserInternal(underlying, account, amount);
    // }

    // function currentBalanceForUnderlying(address token) public view returns (uint256) {
    //     if (token == EthAddressLib.ethAddress()) {
    //         return address(this).balance;
    //     }
    //     return IERC20Interface(token).balanceOf(address(this));
    // }

    // function flashloan(
    //     address receiver,
    //     uint256 amount,
    //     bytes memory params
    // ) public whenUnpaused nonReentrant {
    //     uint256 balanceBefore = currentBalanceForUnderlying(underlying);
    //     require(amount > 0 && amount <= balanceBefore, "insufficient flashloan liquidity");

    //     uint256 fee = amount.mul(controller.flashloanFeeBips()).div(10000);
    //     address payable _receiver = address(uint160(receiver));

    //     this.transferFlashloanAsset(underlying, _receiver, amount);
    //     IFlashLoanReceiver(_receiver).executeOperation(underlying, amount, fee, params);

    //     uint256 balanceAfter = currentBalanceForUnderlying(underlying);
    //     require(balanceAfter >= balanceBefore.add(fee), "invalid flashloan payback amount");
    //     address payable vault = address(uint160(controller.flashloanVault()));
    //     transferFlashloanAsset(underlying, vault, fee);
    //     emit FlashLoan(receiver, underlying, amount, fee);
    // }

    function balanceOf(address owner) public view returns (uint256) {
        return accountTokens[owner];
    }

    function seizeInternal(
        address seizerToken,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) internal {
        require(borrower != liquidator, "Liquidator cannot be borrower");
        controller.seizeCheck(address(this), seizerToken);

        accountTokens[borrower] = accountTokens[borrower].sub(seizeTokens);
        address mulsig = controller.mulsig();
        uint256 securityFund = seizeTokens.mul(securityFactor).div(10000);
        uint256 prize = seizeTokens.sub(securityFund);
        accountTokens[mulsig] = accountTokens[mulsig].add(securityFund);
        accountTokens[liquidator] = accountTokens[liquidator].add(prize);

        (address farm, uint256 poolId) = config.getFarmConfig(address(this));
        IFarm(farm).transfer(poolId, borrower, liquidator, prize);
        IFarm(farm).transfer(poolId, borrower, mulsig, securityFund);
        emit Transfer(borrower, liquidator, prize);
        emit Transfer(borrower, mulsig, securityFund);
    }

    function _reduceReserves(uint256 _reduceAmount) external onlyController {
        accrueInterest();

        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        require(
            controller.getCashPrior(underlying) >= _reduceAmount,
            "Insufficient cash"
        );
        require(totalReserves >= _reduceAmount, "Insufficient reserves");

        totalReserves = SafeMathLib.sub(
            totalReserves,
            _reduceAmount,
            "reduce reserves underflow"
        );
    }

    function _addReservesFresh(uint256 _addAmount) external onlyController {
        accrueInterest();

        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        totalReserves = SafeMathLib.add(totalReserves, _addAmount);
    }

    function addReservesForLeverage(uint256 _addAmount) external payable {
        require(controller.vaultContains(msg.sender), "vault not permitted");
        accrueInterest();

        require(accrualBlockNumber == getBlockNumber(), "Blocknumber fails");
        this.transferIn{value: msg.value}(
            msg.sender,
            underlying,
            _addAmount
        );
        totalReserves = SafeMathLib.add(totalReserves, _addAmount);
    }

    function addTotalCash(uint256 _addAmount) public onlyComponent {
        totalCash = totalCash.add(_addAmount);
    }

    function subTotalCash(uint256 _subAmount) public onlyComponent {
        totalCash = totalCash.sub(_subAmount);
    }

    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true;
    }

    // function APR() public view returns (uint256) {
    //     uint256 cash = tokenCash(underlying, address(this));
    //     return interestRateModel.APR(cash, totalBorrows, totalReserves);
    // }

    // function APY() public view returns (uint256) {
    //     uint256 cash = tokenCash(underlying, address(this));
    //     return
    //         interestRateModel.APY(
    //             cash,
    //             totalBorrows,
    //             totalReserves,
    //             reserveFactor
    //         );
    // }

    function utilizationRate() public view returns (uint256) {
        uint256 cash = tokenCash(underlying, address(this));
        return interestRateModel.utilizationRate(cash, totalBorrows, totalReserves);
    }

    function getBorrowRate() public view returns (uint256) {
        uint256 cash = tokenCash(underlying, address(this));
        return interestRateModel.getBorrowRate(cash, totalBorrows, totalReserves);
    }

    // function getSupplyRate() public view returns (uint256) {
    //     uint256 cash = tokenCash(underlying, address(this));
    //     return
    //         interestRateModel.getSupplyRate(
    //             cash,
    //             totalBorrows,
    //             totalReserves,
    //             reserveFactor
    //         );
    // }
}
