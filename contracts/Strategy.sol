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
import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IVariableDebtToken.sol";

import "./FlashLoanLib.sol";
import "../interfaces/dydx/ICallee.sol";

contract Strategy is BaseStrategy, ICallee {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // AAVE
    IProtocolDataProvider private constant aaveDP = IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    address private constant aave = 0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9;
    address private constant stkAave = 0x4da27a545c0c5B758a6BA100e3a049001de870f5;
    IAToken public aToken;
    IVariableDebtToken public variableDebtToken;

    // SWAP
    address public constant uniswapRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // OPS State Variables
    uint256 private constant COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 public targetCollatRatio;
    uint256 public maxCollatRatio;

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public minCompToSell;
    uint256 public maxIterations;

    uint256 private a = 0;

    bool public isDyDxActive = true;

    // TODO: review decimals
    uint256 private constant MAX_BPS = 1 ether;
    uint256 private immutable DECIMALS;

    constructor(address _vault) public BaseStrategy(_vault) {
        (aToken,,variableDebtToken) = aaveDP.getReserveTokensAddresses(want);
        ( , , uint256 liquidationThreshold,,,,,,,) = aaveDP.getReserveConfigurationData(want);
        targetCollatRatio = (liquidationThreshold * 10**14) - COLLAT_TARGET_MARGIN;
        maxCollatRatio = (liquidationThreshold * 10**14) - COLLAT_MAX_MARGIN;
        DECIMALS = 10 ** vault.decimals();
        IERC20(aave).safeApprove(uniswapRouter, type(uint256).max);
        want.safeApprove(address(_aToken), type(uint256).max);
        IERC20(address(weth)).safeApprove(FlashLoanLib.SOLO, type(uint256).max);
    }

    receive() external payable {}

    // SETTERS
    // TODO: add setters for thesholds
    function setTargetCollatRatio(uint256 _targetCollatRatio) external onlyVaultManagers {
        targetCollatRatio = _targetCollatRatio;
    }

    function setMinWant(uint256 _minWant) external onlyVaultManagers {
        minWant = _minWant;
    }

    function setMinRatio(uint256 _minRatio) external onlyVaultManagers {
        minRatio = _minRatio;
    }

    function setMinCompToSell(uint256 _minCompToSell) external onlyVaultManagers {
        minCompToSell = _minCompToSell;
    }

    function setMaxIterations(uint256 _maxIterations) external onlyVaultManagers {
        maxIterations = _maxIterations;
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
        uint256 rewards = estimatedRewardsInWant();

        return balanceOfWant().add(netAssets).add(rewards);
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        // NOTE: assuming 13s between blocks
        // NOTE: no problem in using block.timestamp. no decisions are taken using this
        uint256 lastReport = vault.strategies(address(this)).lastReport;
        if(lastReport >= block.timestamp) {
            return 0;
        }
        uint256 blocksSinceLastReport = block.timestamp.sub(lastReport).div(13);

        // Amount of COMP that suppliers AND borrowers receive
        uint256 compSpeed = compound.compSpeeds(address(cToken));

        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        // NOTE: using 1e18 because exchangeRate has 18 decimals
        // TODO: check that exchangeRate always has 18 decimals
        uint256 totalDeposits = cToken.totalSupply().mul(cToken.exchangeRateStored()).div(1e18);
        uint256 totalBorrows = cToken.totalBorrows();
        // Shortcut if no deposits / (== no borrows)
        if(totalDeposits == 0 || deposits == 0) {
            return 0;
        }
        // NOTE: compSpeed is the same for borrows and deposits
        uint256 supplyShare = deposits.mul(DECIMALS).div(totalDeposits);
        uint256 supplyRewards = supplyShare.mul(compSpeed).mul(blocksSinceLastReport).div(DECIMALS);
        // Shortcut if no borrows
        if (totalBorrows == 0 || borrows == 0) {
            return compToWant(supplyRewards);
        }

        uint256 borrowShare = borrows.mul(DECIMALS).div(totalBorrows);
        uint256 borrowRewards = borrowShare.mul(compSpeed).mul(blocksSinceLastReport).div(DECIMALS);

        return compToWant(supplyRewards.add(borrowRewards));
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
        // account for profit / losses
        // we need to accrue interests in both sides
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        // update position
        getUpdatedPosition();
        
        uint256 totalAssets = estimatedTotalAssets();
        if(totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _profit = totalAssets.sub(totalDebt);
        }

        // claim & sell rewards
        _claimAndSellRewards();

        // free funds to repay debt + profit to the strategy
        uint256 wantBalance = balanceOfWant();
        uint256 amountRequired = _debtOutstanding.add(_profit);

        if(amountRequired > wantBalance) {
            // we need to free funds
            // we dismiss losses here, they cannot be generated from withdrawal
            // but it is possible for the strategy to unwind full position
            (uint256 amountAvailable, ) = liquidatePosition(amountRequired);
            if(amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
                if(amountRequired.sub(_debtPayment) < _profit) {
                    _profit = amountRequired.sub(_debtPayment);
                }
            } else {
                // we were not able to free enough funds
                if(amountAvailable < _debtOutstanding) {
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
            if(amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();
        // deposit available want as collateral
        if(wantBalance > _debtOutstanding && wantBalance.sub(_debtOutstanding) > minWant) {
            // we need to keep collateral uninvested
            _depositCollateral(wantBalance.sub(_debtOutstanding));
            // we update the value
            wantBalance = balanceOfWant();
        }
        // check current position
        (, , uint256 currentCollatRatio) = getCurrentPosition();

        // Either we need to free some funds OR we want to be max levered
        if(_debtOutstanding > wantBalance) {
            // we should free funds
            uint256 amountRequired = _debtOutstanding.sub(wantBalance);

            // NOTE: vault will take free funds during the next harvest
            _freeFunds(amountRequired);

        } else if (currentCollatRatio < targetCollatRatio) {
            // we should lever up
            // TODO: create minRatio state variable
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
        if(wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        _freeFunds(amountRequired);

        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {

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
        // TODO: add other paths for handling rewards (ySwap? Unstaking in AAVE?)
        uint256 _comp = _claimRewards();
        uint256[] memory amounts;
        if (_comp > minCompToSell) {
            address[] memory path = new address[](3);
            path[0] = comp;
            path[1] = weth;
            path[2] = address(want);

            amounts = IUni(uniswapRouter).swapExactTokensForTokens(_comp, uint256(0), path, address(this), block.timestamp);
            return amounts[amounts.length - 1];
        }
    }

    function _claimRewards() internal returns (uint256) {
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = cToken;

        compound.claimComp(address(this), tokens);

        return IERC20(comp).balanceOf(address(this));
    }

    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if(amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        // NOTE: we cannot 
        uint256 realAssets = deposits.sub(borrows);
        uint256 amountRequired = Math.min(amountToFree, realAssets);
        uint256 newSupply = realAssets.sub(amountRequired);
        uint256 newBorrow = newSupply.mul(targetCollatRatio).div(MAX_BPS.sub(targetCollatRatio));

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return balanceOfWant();
    }

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        // NOTE: decimals should cancel out
        uint256 realSupply = deposits.sub(borrows);
        uint256 newBorrow = realSupply.mul(targetCollatRatio).div(MAX_BPS.sub(targetCollatRatio));

        uint256 totalAmountToBorrow = newBorrow.sub(borrows);
        uint256 i = 0;

        // implement flash loan
        while(totalAmountToBorrow > minWant) {
            if(i >= maxIterations) break;

            // The best approach is to lever up using regular method, then finish with flash loan
            if(i >= 1 && isDyDxActive) {
                totalAmountToBorrow = totalAmountToBorrow.sub(_leverUpFlashLoan(totalAmountToBorrow));
            }

            uint256 borrowed = _leverUpStep(totalAmountToBorrow);
            totalAmountToBorrow = totalAmountToBorrow.sub(borrowed);
            i = i + 1;
        }
    }

    function _leverUpFlashLoan(uint256 amount) internal returns (uint256) {
        return FlashLoanLib.doDyDxFlashLoan(false, amount);
    }

    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if(amount == 0) {
            return 0;
        }

        uint256 wantBalance = balanceOfWant(); 
        // deposit available want as collateral
        _depositCollateral(wantBalance);

        // calculate how much borrow can I take
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 canBorrow = deposits.mul(targetCollatRatio).div(MAX_BPS).sub(borrows);
        if(canBorrow < amount) {
            amount = canBorrow;
        }
        // borrow available collateral
        _borrowWant(amount);

        return amount;
    }

    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed) internal returns (uint256) {
        if(newAmountBorrowed >= currentBorrowed) {
            // we don't need to repay
            return 0;
        }
        uint256 totalRepayAmount = currentBorrowed.sub(newAmountBorrowed);
        // repay with available want
        totalRepayAmount = totalRepayAmount.sub(_leverDownFlashLoan(totalRepayAmount));
        uint256 i = 0;
        while(totalRepayAmount > minWant) {
            if(i >= maxIterations) break;
            uint256 toRepay = totalRepayAmount;
            uint256 wantBalance = balanceOfWant();
            if(toRepay > wantBalance) {
                toRepay = wantBalance;
            }
            uint256 repaid = _repayWant(toRepay);
            totalRepayAmount = totalRepayAmount.sub(repaid);
            // withdraw collateral
            (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
            uint256 theoDeposits = borrows.mul(1e18).div(maxCollatRatio);
            if(deposits > theoDeposits) {
                uint256 toWithdraw = deposits.sub(theoDeposits);
                _withdrawCollateral(toWithdraw);
            }
            i = i + 1;
        }

        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        uint256 toDeposit = targetCollatRatio > 0 ? borrows.mul(1e18).div(targetCollatRatio).sub(deposits) : 0;
        _depositCollateral(toDeposit);
    }

    function _leverDownFlashLoan(uint256 amount) internal returns (uint256) {
        if(amount <= minWant) return 0;
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        if(amount > borrows) {
            amount = borrows;
        }
        uint256 repaid = FlashLoanLib.doDyDxFlashLoan(true, amount);
        // withdraw collateral
        (deposits, borrows, ) = getCurrentPosition();
        uint256 theoDeposits = borrows.mul(1e18).div(maxCollatRatio);
        if(deposits > theoDeposits) {
            uint256 toWithdraw = deposits.sub(theoDeposits);
            _withdrawCollateral(toWithdraw);
        }
        return repaid;
    }
                                                
    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if(amount == 0) return 0;
        require(cToken.mint(amount) == 0, "!mint");
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if(amount == 0) return 0;
        require(cToken.redeemUnderlying(amount) == 0, "!redeem");
        return amount;
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        if(amount == 0) return 0;
        require(cToken.repayBorrow(amount) == 0, "!repay");
        return amount;
    }

    function _borrowWant(uint256 amount) internal returns (uint256) {
        if(amount == 0) return 0;
        require(cToken.borrow(amount) == 0, "!borrow");
        return amount;
    }

    // INTERNAL VIEWS
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data
    ) public override {
        (bool deficit, uint256 amount) = abi.decode(data, (bool, uint256));
        require(msg.sender == FlashLoanLib.SOLO);
        require(sender == address(this));

        FlashLoanLib.loanLogic(deficit, amount, cToken);
    }

    function getCurrentPosition() internal view returns (uint256 deposits, uint256 borrows, uint256 currentCollatRatio) {
        (, uint256 cTokenBalance, uint256 borrowBalance, uint256 exchangeRate) = cToken.getAccountSnapshot(address(this));
        borrows = borrowBalance;
        // NOTE: we use 1e18 because exchangeRate has 18 decimals
        deposits = cTokenBalance.mul(exchangeRate).div(1e18);
        if(deposits > 0) {
            currentCollatRatio = borrows.mul(1e18).div(deposits);
        }
    }

    function getUpdatedPosition() internal returns (uint256 deposits, uint256 borrows, uint256 currentCollatRatio) {
        deposits = cToken.balanceOfUnderlying(address(this));
        borrows = cToken.borrowBalanceCurrent(address(this));
        if(deposits > 0) {
            currentCollatRatio = borrows.mul(1e18).div(deposits);
        }
    }

    // conversions
    function compToWant(uint256 amount) internal view returns (uint256) {
        if(amount == 0) return 0;

        address[] memory path;
        if(address(want) == weth) {
            path = new address[](2);
            path[0] = comp;
            path[1] = address(want);
        } else {
            path = new address[](3);
            path[0] = comp;
            path[1] = weth;
            path[2] = address(want);
        }
        uint256[] memory amounts = IUni(uniswapRouter).getAmountsOut(amount, path);

        return amounts[amounts.length - 1];
    }

    function ethToWant(uint256 _amtInWei) public view override returns (uint256) {
        if(_amtInWei == 0 || address(want) == weth) {
            return _amtInWei;
        }

        address[] memory path;
        path = new address[](2);
        path[0] = weth;
        path[1] = address(want);

        uint256[] memory amounts = IUni(uniswapRouter).getAmountsOut(_amtInWei, path);

        return amounts[amounts.length - 1];
    }
}
