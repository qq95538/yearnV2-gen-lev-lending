// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/uniswap/IUni.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";

import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IVariableDebtToken.sol";
import "../interfaces/aave/IPriceOracle.sol";
import "../interfaces/aave/ILendingPool.sol";

import "./FlashLoanLib.sol";
import "../interfaces/dydx/ICallee.sol";

contract Strategy is BaseStrategy, ICallee {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // AAVE
    IProtocolDataProvider private constant protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    IAaveIncentivesController private constant incentivesController =
        IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    address private constant aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    IStakedAave private constant stkAave =
        IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    bool public isSupplyIncentivised;
    bool public isBorrowIncentivised;

    // SWAP
    IUni public constant V2ROUTER =
        IUni(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    ISwapRouter public constant V3ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    address private constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // OPS State Variables
    uint256 private constant DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 public maxBorrowCollatRatio; // The maximum the aave protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk

    uint256 public minWant = 100;
    uint256 public minRatio = 0.005 ether;
    uint256 public minRewardToSell = 1e15;
    uint8 public maxIterations = 6;
    uint256 public maxStkAavePriceImpactBps = 500;
    uint256 public pessimismFactor = 1000;
    bool public sellStkAave = true;
    bool public useUniV3 = false;
    bool public isDyDxActive = true;

    // Aave's referral code
    uint16 internal referral = 0;

    // TODO: review decimals
    uint256 private constant MAX_BPS = 1e4;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private DECIMALS;

    constructor(address _vault) public BaseStrategy(_vault) {
        _initializeThis();
    }

    function _initializeThis() internal {
        (address _aToken, , address _debtToken) =
            protocolDataProvider.getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);
        (, uint256 ltv, uint256 liquidationThreshold, , , , , , , ) =
            protocolDataProvider.getReserveConfigurationData(address(want));
        maxBorrowCollatRatio = ltv * 10**14 - DEFAULT_COLLAT_MAX_MARGIN;
        liquidationThreshold = liquidationThreshold * 10**14; // convert bps to wad
        targetCollatRatio = _getTargetLTV(liquidationThreshold);
        maxCollatRatio = _getWarningLTV(liquidationThreshold);
        DECIMALS = 10**vault.decimals();
        IERC20(address(stkAave)).safeApprove(
            address(V3ROUTER),
            type(uint256).max
        );
        want.safeApprove(_aToken, type(uint256).max);
        IERC20(address(weth)).safeApprove(FlashLoanLib.SOLO, type(uint256).max);
        IERC20(address(weth)).safeApprove(
            address(_lendingPool()),
            type(uint256).max
        );
    }

    // SETTERS
    // TODO: add setters for thesholds
    function setTargetCollatRatio(uint256 _targetCollatRatio)
        external
        onlyVaultManagers
    {
        targetCollatRatio = _targetCollatRatio;
    }

    function setMinWant(uint256 _minWant) external onlyVaultManagers {
        minWant = _minWant;
    }

    function setMinRatio(uint256 _minRatio) external onlyVaultManagers {
        minRatio = _minRatio;
    }

    function setMinRewardToSell(uint256 _minRewardToSell)
        external
        onlyVaultManagers
    {
        minRewardToSell = _minRewardToSell;
    }

    function setMaxIterations(uint8 _maxIterations) external onlyVaultManagers {
        maxIterations = _maxIterations;
    }

    function setSellStkAave(bool _sellStkAave) external onlyVaultManagers {
        sellStkAave = _sellStkAave;
    }

    function setIsDyDxActive(bool _isDyDxActive) external onlyVaultManagers {
        isDyDxActive = _isDyDxActive;
    }

    function name() external view override returns (string memory) {
        return "StrategyGenLevAAVE";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 netAssets = deposits.sub(borrows);
        uint256 rewards =
            estimatedRewardsInWant().mul(MAX_BPS - pessimismFactor).div(
                MAX_BPS
            );

        return balanceOfWant().add(netAssets).add(rewards);
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        uint256 aaveBalance = IERC20(aave).balanceOf(address(this));
        uint256 stkAaveBalance =
            IERC20(address(stkAave)).balanceOf(address(this));

        uint256 combinedBalance =
            aaveBalance.add(
                stkAaveBalance.mul(MAX_BPS - maxStkAavePriceImpactBps).div(
                    MAX_BPS
                )
            );

        uint256 lastReport = vault.strategies(address(this)).lastReport;
        if (lastReport >= block.timestamp) {
            return 0;
        }
        uint256 secondsSinceLastReport = block.timestamp.sub(lastReport);

        (, uint256 supplyAavePerSecond, ) =
            incentivesController.getAssetData(address(aToken));
        (, uint256 borrowAavePerSecond, ) =
            incentivesController.getAssetData(address(debtToken));

        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        uint256 totalDeposits = aToken.totalSupply();
        uint256 totalBorrows = debtToken.totalSupply();

        if (deposits == 0 || totalDeposits == 0) {
            return tokenToWant(aave, combinedBalance);
        }

        uint256 supplyShare = deposits.mul(DECIMALS).div(totalDeposits);
        uint256 supplyRewards =
            supplyShare
                .mul(supplyAavePerSecond)
                .mul(secondsSinceLastReport)
                .div(DECIMALS);
        // Shortcut if no borrows
        if (borrows == 0 || totalBorrows == 0) {
            return tokenToWant(aave, supplyRewards.add(combinedBalance));
        }

        uint256 borrowShare = borrows.mul(DECIMALS).div(totalBorrows);
        uint256 borrowRewards =
            borrowShare
                .mul(borrowAavePerSecond)
                .mul(secondsSinceLastReport)
                .div(DECIMALS);

        return
            tokenToWant(
                aave,
                supplyRewards.add(borrowRewards).add(combinedBalance)
            );
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
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 totalAssets = balanceOfWant().add(deposits).sub(borrows);

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
            if (_debtOutstanding >= amountAvailable) {
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
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if (amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
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
        (, , uint256 currentCollatRatio) = getCurrentPosition();

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
            _loss = _amountNeeded.sub(freeAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(type(uint256).max);
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // INTERNAL ACTIONS

    function _claimAndSellRewards() internal returns (uint256) {
        uint256 stkAaveBalance = balanceOfStkAave();
        if (_checkCooldown() && stkAaveBalance > 0) {
            // redeem AAVE from stkAave
            stkAave.claimRewards(address(this), type(uint256).max);
            stkAave.redeem(address(this), stkAaveBalance);
        }

        address[] memory assets;
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);

        incentivesController.claimRewards(
            assets,
            type(uint256).max,
            address(this)
        );

        // request start of cooldown period
        uint256 cooldownStartTimestamp =
            stkAave.stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = stkAave.COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = stkAave.UNSTAKE_WINDOW();
        if (
            stkAaveBalance > 0 &&
            (// cooldown not started
            (cooldownStartTimestamp == 0) ||
                // cooldown window is passed
                (cooldownStartTimestamp > 0 &&
                    block.timestamp >
                    cooldownStartTimestamp.add(COOLDOWN_SECONDS).add(
                        UNSTAKE_WINDOW
                    )))
        ) {
            stkAave.cooldown();
        }

        // Always keep 1 wei to get around cooldown clear
        stkAaveBalance = balanceOfStkAave();
        if (stkAaveBalance >= minRewardToSell.add(1)) {
            uint256 minAAVEOut = stkAaveBalance.mul(0.95 ether).div(1 ether);
            _sellSTKAAVEToAAVE(stkAaveBalance.sub(1), minAAVEOut);
        }

        // sell AAVE for want
        // a minimum balance of 0.01 AAVE is required
        uint256 aaveBalance = balanceOfAave();
        if (aaveBalance >= minRewardToSell) {
            _sellAAVEForWant(aaveBalance, 0);
        }
    }

    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if (amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        // NOTE: we cannot
        uint256 realAssets = deposits.sub(borrows);
        uint256 amountRequired = Math.min(amountToFree, realAssets);
        uint256 newSupply = realAssets.sub(amountRequired);
        uint256 newBorrow =
            newSupply.mul(targetCollatRatio).div(
                COLLATERAL_RATIO_PRECISION.sub(targetCollatRatio)
            );

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return balanceOfWant();
    }

    event Debug(uint256 deposits, uint256 borrows, string msg);

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        // NOTE: decimals should cancel out
        uint256 realSupply = deposits.sub(borrows);
        uint256 newBorrow =
            realSupply.mul(targetCollatRatio).div(
                COLLATERAL_RATIO_PRECISION.sub(targetCollatRatio)
            );

        uint256 totalAmountToBorrow = newBorrow.sub(borrows);

        if (isDyDxActive) {
            // The best approach is to lever up using regular method, then finish with flash loan
            totalAmountToBorrow = totalAmountToBorrow.sub(
                _leverUpStep(totalAmountToBorrow)
            );

            if (totalAmountToBorrow > minWant) {
                totalAmountToBorrow = totalAmountToBorrow.sub(
                    _leverUpFlashLoan(totalAmountToBorrow)
                );
            }
        } else {
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
    }

    function _leverUpFlashLoan(uint256 amount) internal returns (uint256) {
        return FlashLoanLib.doDyDxFlashLoan(false, amount, address(want));
    }

    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 wantBalance = balanceOfWant();

        // calculate how much borrow can I take
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 canBorrow =
            deposits.add(wantBalance).mul(maxBorrowCollatRatio).div(
                COLLATERAL_RATIO_PRECISION
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

        // borrow available collateral
        _borrowWant(amount);

        return amount;
    }

    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed)
        internal
        returns (uint256)
    {
        if (newAmountBorrowed >= currentBorrowed) {
            // we don't need to repay
            return 0;
        }
        uint256 totalRepayAmount = currentBorrowed.sub(newAmountBorrowed);
        if (isDyDxActive) {
            totalRepayAmount = totalRepayAmount.sub(
                _leverDownFlashLoan(totalRepayAmount)
            );
        }

        for (
            uint8 i = 15;
            i < maxIterations && totalRepayAmount > minWant;
            i++
        ) {
            uint256 toRepay = totalRepayAmount;
            uint256 wantBalance = balanceOfWant();
            if (toRepay > wantBalance) {
                toRepay = wantBalance;
            }
            uint256 repaid = _repayWant(toRepay);
            totalRepayAmount = totalRepayAmount.sub(repaid);
            // withdraw collateral
            _withdrawExcessCollateral();
        }

        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 toDeposit =
            targetCollatRatio > 0
                ? borrows.mul(1e18).div(targetCollatRatio).sub(deposits)
                : 0;
        if (toDeposit > minWant) {
            _depositCollateral(toDeposit);
        }
    }

    function _leverDownFlashLoan(uint256 amount) internal returns (uint256) {
        if (amount <= minWant) return 0;
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        if (amount > borrows) {
            amount = borrows;
        }
        uint256 repaid =
            FlashLoanLib.doDyDxFlashLoan(true, amount, address(want));
        // withdraw collateral
        _withdrawExcessCollateral();
        return repaid;
    }

    function _withdrawExcessCollateral() internal returns (uint256 amount) {
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 theoDeposits = borrows.mul(1e18).div(maxCollatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits.sub(theoDeposits);
            return _withdrawCollateral(toWithdraw);
        }
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), address(want), amount);
        lp.deposit(address(want), amount, address(this), referral);
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), address(aToken), amount);
        lp.withdraw(address(want), amount, address(this));
        return amount;
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), address(want), amount);
        return lp.repay(address(want), amount, 2, address(this));
    }

    function _borrowWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool().borrow(
            address(want),
            amount,
            2,
            referral,
            address(this)
        );
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

    function balanceOfAave() internal view returns (uint256) {
        return IERC20(aave).balanceOf(address(this));
    }

    function balanceOfStkAave() internal view returns (uint256) {
        return IERC20(address(stkAave)).balanceOf(address(this));
    }

    // Flashloan callback function
    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data
    ) public override {
        (bool deficit, uint256 amount, address token) =
            abi.decode(data, (bool, uint256, address));
        require(msg.sender == FlashLoanLib.SOLO);
        require(sender == address(this));
        require(token == address(want));

        FlashLoanLib.loanLogic(deficit, amount, token);
    }

    function getCurrentPosition()
        public
        view
        returns (
            uint256 deposits,
            uint256 borrows,
            uint256 currentCollatRatio
        )
    {
        deposits = balanceOfAToken();
        borrows = balanceOfDebtToken();
        if (deposits > 0) {
            currentCollatRatio = borrows.mul(COLLATERAL_RATIO_PRECISION).div(
                deposits
            );
        }
    }

    // conversions
    function tokenToWant(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;

        address[] memory path;
        if (address(want) == weth) {
            path = new address[](2);
            path[0] = token;
            path[1] = address(want);
        } else {
            path = new address[](3);
            path[0] = token;
            path[1] = weth;
            path[2] = address(want);
        }
        uint256[] memory amounts = IUni(V2ROUTER).getAmountsOut(amount, path);

        return amounts[amounts.length - 1];
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        if (_amtInWei == 0 || address(want) == weth) {
            return _amtInWei;
        }

        address[] memory path;
        path = new address[](2);
        path[0] = weth;
        path[1] = address(want);

        uint256[] memory amounts =
            IUni(V2ROUTER).getAmountsOut(_amtInWei, path);

        return amounts[amounts.length - 1];
    }

    function _lendingPool() internal view returns (ILendingPool) {
        return
            ILendingPool(
                protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool()
            );
    }

    function _checkCooldown() internal view returns (bool) {
        uint256 cooldownStartTimestamp =
            IStakedAave(stkAave).stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = IStakedAave(stkAave).COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = IStakedAave(stkAave).UNSTAKE_WINDOW();
        return
            cooldownStartTimestamp != 0 &&
            block.timestamp > cooldownStartTimestamp.add(COOLDOWN_SECONDS) &&
            block.timestamp <=
            cooldownStartTimestamp.add(COOLDOWN_SECONDS).add(UNSTAKE_WINDOW);
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    function _getAaveUserAccountData()
        internal
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return _lendingPool().getUserAccountData(address(this));
    }

    function _getTargetLTV(uint256 liquidationThreshold)
        internal
        pure
        returns (uint256)
    {
        return liquidationThreshold.sub(DEFAULT_COLLAT_TARGET_MARGIN);
    }

    function _getWarningLTV(uint256 liquidationThreshold)
        internal
        pure
        returns (uint256)
    {
        return liquidationThreshold.sub(DEFAULT_COLLAT_MAX_MARGIN);
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        pure
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function _sellAAVEForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }
        if (!useUniV3) {
            _checkAllowance(address(V2ROUTER), address(aave), amountIn);
            V2ROUTER.swapExactTokensForTokens(
                amountIn,
                minOut,
                getTokenOutPath(address(aave), address(want)),
                address(this),
                now
            );
        } else {
            _checkAllowance(address(V3ROUTER), address(aave), amountIn);
            bytes memory path =
                abi.encodePacked(
                    address(aave),
                    uint24(10000),
                    address(weth),
                    uint24(10000),
                    address(want)
                );

            ISwapRouter.ExactInputParams memory fromAAVETowBTCParams =
                ISwapRouter.ExactInputParams(
                    path,
                    address(this),
                    now,
                    amountIn,
                    minOut
                );
            V3ROUTER.exactInput(fromAAVETowBTCParams);
        }
    }

    function _sellSTKAAVEToAAVE(uint256 amountIn, uint256 minOut) internal {
        // Swap Rewards in UNIV3
        // NOTE: Unoptimized, can be frontrun and most importantly this pool is low liquidity
        ISwapRouter.ExactInputSingleParams memory fromRewardToAAVEParams =
            ISwapRouter.ExactInputSingleParams(
                address(stkAave),
                address(aave),
                10000,
                address(this),
                now,
                amountIn, // wei
                minOut,
                0
            );
        V3ROUTER.exactInputSingle(fromRewardToAAVEParams);
    }

    function _sellAAVEForWantV3(uint256 amountIn, uint256 minOut) internal {
        // We now have AAVE tokens, let's get want
    }
}
