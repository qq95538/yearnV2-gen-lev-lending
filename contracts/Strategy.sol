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
import "../interfaces/compound/CEtherI.sol";
import "../interfaces/compound/CErc20I.sol";
import "../interfaces/compound/ComptrollerI.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // COMPOUND
    ComptrollerI private constant compound = ComptrollerI(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    address private constant comp = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    CErc20I public cToken;

    // SWAP
    address public constant uniswapRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // OPS State Variables
    uint256 public targetCollatRatio;

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public maxIterations;

    // TODO: review decimals
    uint256 private constant MAX_BPS = 1 ether;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "Strategy<ProtocolName><TokenType>";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return want.balanceOf(address(this));
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
        // we need to accrue interests in both sides
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssets = estimatedTotalAssets();

        if(totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _profit = totalAssets.sub(totalDebt);
        }

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
                // profit remains unchanged
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
                    _profit = amountRequired.sub(_debtPayment);
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();
        // deposit available want as collateral
        // TODO: create minWant state variable
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
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
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

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // INTERNAL ACTIONS
    function _claimAndSellRewards() internal returns (uint256) {

    }

    function claimRewards() internal returns (uint256) {

    }

    function handleRewards() internal returns (uint256) {

    }
    
    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if(amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();

        uint256 amountRequired = Math.min(amountToFree, deposits);
        uint256 newCollateral = deposits.sub(amountRequired);
        uint256 newBorrow = newCollateral.mul(targetCollatRatio).div(MAX_BPS);

        // repay required amount
        leverDownTo(newBorrow, borrows);

        // withdraw as collateral
        _withdrawCollateral(amountRequired);

        return balanceOfWant();
    }

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows, ) = getCurrentPosition();
        // NOTE: decimals should cancel out
        uint256 newBorrow = deposits.mul(targetCollatRatio).div(MAX_BPS.sub(targetCollatRatio));
        uint256 totalAmountToBorrow = newBorrow.sub(borrows);
        uint256 i = 0;
        // TODO: add/replace with flash loan
        while(totalAmountToBorrow > 0) {
            if(i >= maxIterations) break;
            totalAmountToBorrow = totalAmountToBorrow.sub(leverUpStep(totalAmountToBorrow));
            i = i + 1;
        }
    }

    function leverUpStep(uint256 amount) internal returns (uint256) {
        if(amount == 0) {
            return 0;
        }
        // deposit available collateral
        _depositCollateral(amount);
        // borrow available collateral
        _borrowWant(amount);

        return amount;
    }

    function leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed) internal returns (uint256) {
        if(newAmountBorrowed >= currentBorrowed) {
            // we don't need to repay
            return 0;
        }
        uint256 repayAmount = currentBorrowed.sub(newAmountBorrowed);
        // repay with available want
        // TODO: add/replace with flash loan
        uint256 i = 0;
        while(repayAmount > 0) {
            if(i >= maxIterations) break;
            uint256 repaid = _repayWant(repayAmount);
            repayAmount = repayAmount.sub(repaid);
            i = i + 1;
        }
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        require(cToken.mint(amount) == 0, "!mint");
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        cToken.redeemUnderlying(amount);
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        cToken.repayBorrow(amount);
    }

    function _borrowWant(uint256 amount) internal returns (uint256) {
        require(cToken.borrow(amount) == 0, "!borrow");
    }

    // INTERNAL VIEWS
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function getCurrentPosition() internal view returns (uint256 deposits, uint256 borrows, uint256 currentCollatRatio) {
        
    }

    function getUpdatedPosition() internal view returns (uint256 deposits, uint256 borrows, uint256 currentCollatRatio) {

    }

    // conversions

    function ethToWant(uint256 _amtInWei) public view override returns (uint256) {
        return _amtInWei;
    }
}
