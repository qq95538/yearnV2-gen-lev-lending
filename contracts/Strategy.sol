// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy} from "@yearn/yearn-vaults/contracts/BaseStrategy.sol";

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/uniswap/IUni.sol";

import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IVariableDebtToken.sol";
import "../interfaces/aave/ILendingPool.sol";

import "../interfaces/geist/IGeistIncentivesController.sol";
import "../interfaces/geist/IMultiFeeDistribution.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // AAVE protocol address
    IProtocolDataProvider private constant protocolDataProvider =
        IProtocolDataProvider(0xf3B0611e2E4D2cd6aB4bb3e01aDe211c3f42A8C3);
    IGeistIncentivesController private constant incentivesController =
        IGeistIncentivesController(0x297FddC5c33Ef988dd03bd13e162aE084ea1fE57);
    ILendingPool private constant lendingPool =
        ILendingPool(0x9FAD24f572045c7869117160A571B2e50b10d068);

    // Token addresses
    address private constant geist = 0xd8321AA83Fb0a4ECd6348D4577431310A6E0814d;
    address private constant weth = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    // SWAP routers
    IUni private constant SPOOKY_V2_ROUTER =
        IUni(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    IUni private constant SPIRIT_V2_ROUTER =
        IUni(0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52);

    // OPS State Variables
    uint256 private constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the aave protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint8 public maxIterations;
    bool public withdrawCheck;

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public minRewardToSell;

    enum SwapRouter {
        Spooky,
        Spirit
    }
    SwapRouter public swapRouter = SwapRouter.Spooky;

    bool private alreadyAdjusted; // Signal whether a position adjust was done in prepareReturn

    uint16 private constant referral = 7; // Yearn's aave referral code

    uint256 private constant MAX_BPS = 1e4;
    uint256 private constant BPS_WAD_RATIO = 1e14;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private constant PESSIMISM_FACTOR = 1000;
    uint256 private DECIMALS;

    constructor(address _vault) public BaseStrategy(_vault) {
        _initializeThis();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeThis();
    }

    function _initializeThis() internal {
        require(address(aToken) == address(0));

        // initialize operational state
        maxIterations = 10;
        withdrawCheck = false;

        // mins
        minWant = 100;
        minRatio = 0.005 ether;
        minRewardToSell = 1e15;

        // reward params
        swapRouter = SwapRouter.Spooky;

        alreadyAdjusted = false;

        // Set aave tokens
        (address _aToken, , address _debtToken) = protocolDataProvider
            .getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        // Let collateral targets
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios(
            address(want)
        );
        targetCollatRatio = ltv.sub(DEFAULT_COLLAT_TARGET_MARGIN);
        maxCollatRatio = liquidationThreshold.sub(DEFAULT_COLLAT_MAX_MARGIN);
        maxBorrowCollatRatio = ltv.sub(DEFAULT_COLLAT_MAX_MARGIN);

        DECIMALS = 10**vault.decimals();

        // approve spend aave spend
        approveMaxSpend(address(want), address(lendingPool));
        approveMaxSpend(address(aToken), address(lendingPool));

        // approve swap router spend
        approveMaxSpend(geist, address(SPOOKY_V2_ROUTER));
        approveMaxSpend(geist, address(SPIRIT_V2_ROUTER));
    }

    // SETTERS
    function setCollateralTargets(
        uint256 _targetCollatRatio,
        uint256 _maxCollatRatio,
        uint256 _maxBorrowCollatRatio
    ) external onlyVaultManagers {
        (uint256 ltv, uint256 liquidationThreshold) = getProtocolCollatRatios(
            address(want)
        );
        require(_targetCollatRatio < liquidationThreshold);
        require(_maxCollatRatio < liquidationThreshold);
        require(_targetCollatRatio < _maxCollatRatio);
        require(_maxBorrowCollatRatio < ltv);

        targetCollatRatio = _targetCollatRatio;
        maxCollatRatio = _maxCollatRatio;
        maxBorrowCollatRatio = _maxBorrowCollatRatio;
    }

    function setWithdrawCheck(bool _withdrawCheck) external onlyVaultManagers {
        withdrawCheck = _withdrawCheck;
    }

    function setMinsAndMaxs(
        uint256 _minWant,
        uint256 _minRatio,
        uint8 _maxIterations
    ) external onlyVaultManagers {
        require(_minRatio < maxBorrowCollatRatio);
        require(_maxIterations > 0 && _maxIterations < 16);
        minWant = _minWant;
        minRatio = _minRatio;
        maxIterations = _maxIterations;
    }

    function setRewardBehavior(SwapRouter _swapRouter, uint256 _minRewardToSell)
        external
        onlyVaultManagers
    {
        require(
            _swapRouter == SwapRouter.Spooky || _swapRouter == SwapRouter.Spirit
        );
        swapRouter = _swapRouter;
        minRewardToSell = _minRewardToSell;
    }

    function name() external view override returns (string memory) {
        return "StrategyGenLevGeist";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 balanceExcludingRewards = balanceOfWant().add(
            getCurrentSupply()
        );

        // if we don't have a position, don't worry about rewards
        if (balanceExcludingRewards < minWant) {
            return balanceExcludingRewards;
        }

        uint256 rewards = estimatedRewardsInWant()
            .mul(MAX_BPS.sub(PESSIMISM_FACTOR))
            .div(MAX_BPS);
        return balanceExcludingRewards.add(rewards);
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        uint256 rewardBalance = 0;

        uint256[] memory rewards = incentivesController.claimableReward(
            address(this),
            getAaveAssets()
        );
        for (uint8 i = 0; i < rewards.length; i++) {
            rewardBalance += rewards[i];
        }

        rewardBalance = rewardBalance.mul(5000).div(MAX_BPS);
        rewardBalance += balanceOfReward();

        return tokenToWant(geist, rewardBalance);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // claim & sell rewards
        _claimAndSellRewards();

        // account for profit / losses
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Assets immediately convertable to want only
        uint256 supply = getCurrentSupply();
        uint256 totalAssets = balanceOfWant().add(supply);

        if (totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _profit = totalAssets.sub(totalDebt);
        }

        // free funds to repay debt + profit to the strategy
        uint256 amountAvailable = balanceOfWant();
        uint256 amountRequired = _debtOutstanding.add(_profit);

        if (amountRequired > amountAvailable) {
            // we need to free funds
            // we dismiss losses here, they cannot be generated from withdrawal
            // but it is possible for the strategy to unwind full position
            (amountAvailable, ) = liquidatePosition(amountRequired);

            // Don't do a redundant adjustment in adjustPosition
            alreadyAdjusted = true;

            if (amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
                // profit remains unchanged unless there is not enough to pay it
                if (amountRequired.sub(_debtPayment) < _profit) {
                    _profit = amountRequired.sub(_debtPayment);
                }
            } else {
                // we were not able to free enough funds
                if (amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // we dont report losses here as the strategy might not be able to return in this harvest
                    // but it will still be there for the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable.sub(_debtPayment);
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if (amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (alreadyAdjusted) {
            alreadyAdjusted = false; // reset for next time
            return;
        }

        uint256 wantBalance = balanceOfWant();
        // deposit available want as collateral
        if (
            wantBalance > _debtOutstanding &&
            wantBalance.sub(_debtOutstanding) > minWant
        ) {
            _depositCollateral(wantBalance.sub(_debtOutstanding));
            // we update the value
            wantBalance = balanceOfWant();
        }
        // check current position
        uint256 currentCollatRatio = getCurrentCollatRatio();

        // Either we need to free some funds OR we want to be max levered
        if (_debtOutstanding > wantBalance) {
            // we should free funds
            uint256 amountRequired = _debtOutstanding.sub(wantBalance);

            // NOTE: vault will take free funds during the next harvest
            _freeFunds(amountRequired);
        } else if (currentCollatRatio < targetCollatRatio) {
            // we should lever up
            if (targetCollatRatio.sub(currentCollatRatio) > minRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (currentCollatRatio > targetCollatRatio) {
            if (currentCollatRatio.sub(targetCollatRatio) > minRatio) {
                (uint256 deposits, uint256 borrows) = getCurrentPosition();
                uint256 newBorrow = getBorrowFromSupply(
                    deposits.sub(borrows),
                    targetCollatRatio
                );
                _leverDownTo(newBorrow, borrows);
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        _freeFunds(amountRequired);

        uint256 freeAssets = balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            uint256 diff = _amountNeeded.sub(_liquidatedAmount);
            if (diff <= minWant) {
                _loss = diff;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }

        if (withdrawCheck) {
            require(_amountNeeded == _liquidatedAmount.add(_loss)); // dev: withdraw safety check
        }
    }

    function tendTrigger(uint256 gasCost) public view override returns (bool) {
        if (harvestTrigger(gasCost)) {
            //harvest takes priority
            return false;
        }
        // pull the liquidation liquidationThreshold from aave to be extra safu
        (, uint256 liquidationThreshold) = getProtocolCollatRatios(
            address(want)
        );

        uint256 currentCollatRatio = getCurrentCollatRatio();

        if (currentCollatRatio >= liquidationThreshold) {
            return true;
        }

        return (liquidationThreshold.sub(currentCollatRatio) <=
            LIQUIDATION_WARNING_THRESHOLD);
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    function prepareMigration(address _newStrategy) internal override {
        require(getCurrentSupply() < minWant);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    //emergency function that we can use to deleverage manually if something is broken
    function manualDeleverage(uint256 amount) external onlyVaultManagers {
        _withdrawCollateral(amount);
        _repayWant(amount);
    }

    //emergency function that we can use to deleverage manually if something is broken
    function manualReleaseWant(uint256 amount) external onlyVaultManagers {
        _withdrawCollateral(amount);
    }

    // emergency function that we can use to sell rewards if something is broken
    function manualClaimAndSellRewards() external onlyVaultManagers {
        _claimAndSellRewards();
    }

    // INTERNAL ACTIONS

    function _claimAndSellRewards() internal returns (uint256) {
        IGeistIncentivesController _incentivesController = incentivesController;

        _incentivesController.claim(address(this), getAaveAssets());

        // Exit with 50% penalty
        IMultiFeeDistribution(_incentivesController.rewardMinter()).exit();

        // sell AAVE for want
        uint256 rewardBalance = balanceOfReward();
        if (rewardBalance >= minRewardToSell) {
            _sellRewardForWant(rewardBalance, 0);
        }
    }

    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if (amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 realAssets = deposits.sub(borrows);
        uint256 amountRequired = Math.min(amountToFree, realAssets);
        uint256 newSupply = realAssets.sub(amountRequired);
        uint256 newBorrow = getBorrowFromSupply(newSupply, targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return balanceOfWant();
    }

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        // NOTE: decimals should cancel out
        uint256 realSupply = deposits.sub(borrows);
        uint256 newBorrow = getBorrowFromSupply(realSupply, targetCollatRatio);
        uint256 totalAmountToBorrow = newBorrow.sub(borrows);

        for (
            uint8 i = 0;
            i < maxIterations && totalAmountToBorrow > minWant;
            i++
        ) {
            totalAmountToBorrow = totalAmountToBorrow.sub(
                _leverUpStep(totalAmountToBorrow)
            );
        }
    }

    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 wantBalance = balanceOfWant();

        // calculate how much borrow can I take
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 canBorrow = getBorrowFromDeposit(
            deposits.add(wantBalance),
            maxBorrowCollatRatio
        );

        if (canBorrow <= borrows) {
            return 0;
        }
        canBorrow = canBorrow.sub(borrows);

        if (canBorrow < amount) {
            amount = canBorrow;
        }

        // deposit available want as collateral
        _depositCollateral(wantBalance);

        // borrow available amount
        _borrowWant(amount);

        return amount;
    }

    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed)
        internal
    {
        if (currentBorrowed > newAmountBorrowed) {
            uint256 totalRepayAmount = currentBorrowed.sub(newAmountBorrowed);

            uint256 _maxCollatRatio = maxCollatRatio;

            for (
                uint8 i = 0;
                i < maxIterations && totalRepayAmount > minWant;
                i++
            ) {
                _withdrawExcessCollateral(_maxCollatRatio);
                uint256 toRepay = totalRepayAmount;
                uint256 wantBalance = balanceOfWant();
                if (toRepay > wantBalance) {
                    toRepay = wantBalance;
                }
                uint256 repaid = _repayWant(toRepay);
                totalRepayAmount = totalRepayAmount.sub(repaid);
            }
        }

        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 targetDeposit = getDepositFromBorrow(
            borrows,
            _targetCollatRatio
        );
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit.sub(deposits);
            if (toDeposit > minWant) {
                _depositCollateral(Math.min(toDeposit, balanceOfWant()));
            }
        } else {
            _withdrawExcessCollateral(_targetCollatRatio);
        }
    }

    function _withdrawExcessCollateral(uint256 collatRatio)
        internal
        returns (uint256 amount)
    {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 theoDeposits = getDepositFromBorrow(borrows, collatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits.sub(theoDeposits);
            return _withdrawCollateral(toWithdraw);
        }
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.deposit(address(want), amount, address(this), referral);
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.withdraw(address(want), amount, address(this));
        return amount;
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return lendingPool.repay(address(want), amount, 2, address(this));
    }

    function _borrowWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.borrow(address(want), amount, 2, referral, address(this));
        return amount;
    }

    // INTERNAL VIEWS
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAToken() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function balanceOfDebtToken() internal view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    function balanceOfReward() internal view returns (uint256) {
        return IERC20(geist).balanceOf(address(this));
    }

    function getCurrentPosition()
        public
        view
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = balanceOfAToken();
        borrows = balanceOfDebtToken();
    }

    function getCurrentCollatRatio()
        public
        view
        returns (uint256 currentCollatRatio)
    {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        if (deposits > 0) {
            currentCollatRatio = borrows.mul(COLLATERAL_RATIO_PRECISION).div(
                deposits
            );
        }
    }

    function getCurrentSupply() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits.sub(borrows);
    }

    // conversions
    function tokenToWant(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0 || address(want) == token) {
            return amount;
        }

        // KISS: just use a v2 router for quotes which aren't used in critical logic
        IUni router = swapRouter == SwapRouter.Spooky
            ? SPOOKY_V2_ROUTER
            : SPIRIT_V2_ROUTER;
        uint256[] memory amounts = router.getAmountsOut(
            amount,
            getTokenOutPathV2(token, address(want))
        );

        return amounts[amounts.length - 1];
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return tokenToWant(weth, _amtInWei);
    }

    function getTokenOutPathV2(address _token_in, address _token_out)
        internal
        pure
        returns (address[] memory _path)
    {
        bool is_weth = _token_in == address(weth) ||
            _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function _sellRewardForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }
        IUni router = swapRouter == SwapRouter.Spooky
            ? SPOOKY_V2_ROUTER
            : SPIRIT_V2_ROUTER;
        router.swapExactTokensForTokens(
            amountIn,
            minOut,
            getTokenOutPathV2(address(geist), address(want)),
            address(this),
            now
        );
    }

    function getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
    }

    function getProtocolCollatRatios(address token)
        internal
        view
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        (, ltv, liquidationThreshold, , , , , , , ) = protocolDataProvider
            .getReserveConfigurationData(token);
        // convert bps to wad
        ltv = ltv.mul(BPS_WAD_RATIO);
        liquidationThreshold = liquidationThreshold.mul(BPS_WAD_RATIO);
    }

    function getBorrowFromDeposit(uint256 deposit, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return deposit.mul(collatRatio).div(COLLATERAL_RATIO_PRECISION);
    }

    function getDepositFromBorrow(uint256 borrow, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return borrow.mul(COLLATERAL_RATIO_PRECISION).div(collatRatio);
    }

    function getBorrowFromSupply(uint256 supply, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return
            supply.mul(collatRatio).div(
                COLLATERAL_RATIO_PRECISION.sub(collatRatio)
            );
    }

    function approveMaxSpend(address token, address spender) internal {
        IERC20(token).safeApprove(spender, type(uint256).max);
    }
}
