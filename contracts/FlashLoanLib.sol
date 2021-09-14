pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/dydx/DydxFlashLoanBase.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/aave/IProtocolDataProvider.sol";
import "../interfaces/aave/IAaveIncentivesController.sol";
import "../interfaces/aave/IStakedAave.sol";
import "../interfaces/aave/IAToken.sol";
import "../interfaces/aave/IVariableDebtToken.sol";
import "../interfaces/aave/IPriceOracle.sol";
import "../interfaces/aave/ILendingPool.sol";

interface IOptionalERC20 {
    function decimals() external view returns (uint8);
}

library FlashLoanLib {
    using SafeMath for uint256;
    event Leverage(
        uint256 amountRequested,
        uint256 amountGiven,
        bool deficit,
        address flashLoan
    );

    address public constant SOLO = 0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e;
    uint256 private constant collatRatioETH = 0.79 ether;
    uint256 private constant COLLAT_RATIO_PRECISION = 1 ether;
    address private constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IAToken public constant aWeth =
        IAToken(0x030bA81f1c18d280636F32af80b9AAd02Cf0854e);
    IProtocolDataProvider private constant protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    ILendingPool private constant lendingPool =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    // Aave's referral code
    uint16 private constant referral = 0;

    function doDyDxFlashLoan(
        bool deficit,
        uint256 amountDesired,
        address token
    ) public returns (uint256 amount) {
        if (amountDesired == 0) {
            return 0;
        }
        amount = amountDesired;
        ISoloMargin solo = ISoloMargin(SOLO);

        // calculate amount of ETH we need
        uint256 requiredETH;
        {
            requiredETH = _toETH(amount, token).mul(COLLAT_RATIO_PRECISION).div(
                collatRatioETH
            );

            uint256 dxdyLiquidity = IERC20(weth).balanceOf(address(solo));
            if (requiredETH > dxdyLiquidity) {
                requiredETH = dxdyLiquidity;
                // NOTE: if we cap amountETH, we reduce amountToken we are taking too
                amount = _fromETH(requiredETH, token).mul(collatRatioETH).div(
                    1 ether
                );
            }
        }

        // Array of actions to be done during FlashLoan
        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

        // 1. Take FlashLoan
        operations[0] = _getWithdrawAction(0, requiredETH); // hardcoded market ID to 0 (ETH)

        // 2. Encode arguments of functions and create action for calling it
        bytes memory data = abi.encode(deficit, amount);
        // This call will:
        // supply ETH to Aave
        // borrow desired Token from Aave
        // do stuff with Token
        // repay desired Token to Aave
        // withdraw ETH from Aave
        operations[1] = _getCallAction(data);

        // 3. Repay FlashLoan
        operations[2] = _getDepositAction(0, requiredETH.add(2));

        // Create Account Info
        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);

        emit Leverage(amountDesired, requiredETH, deficit, address(solo));

        return amount; // we need to return the amount of Token we have changed our position in
    }

    function loanLogic(
        bool deficit,
        uint256 amount,
        address want
    ) public {
        uint256 wethBal = IERC20(weth).balanceOf(address(this));
        ILendingPool lp = lendingPool;

        // 1. Deposit WETH in Aave as collateral
        lp.deposit(weth, wethBal, address(this), referral);

        if (deficit) {
            // 2a. if in deficit withdraw amount and repay it
            lp.withdraw(want, amount, address(this));
            lp.repay(want, amount, 2, address(this));
        } else {
            // 2b. if levering up borrow and deposit
            lp.borrow(want, amount, 2, 0, address(this));
            lp.deposit(
                want,
                IERC20(want).balanceOf(address(this)),
                address(this),
                referral
            );
        }
        // 3. Withdraw WETH
        lp.withdraw(weth, wethBal, address(this));
    }

    function _getAccountInfo() internal view returns (Account.Info memory) {
        return Account.Info({owner: address(this), number: 1});
    }

    function _getWithdrawAction(uint256 marketId, uint256 amount)
        internal
        view
        returns (Actions.ActionArgs memory)
    {
        return
            Actions.ActionArgs({
                actionType: Actions.ActionType.Withdraw,
                accountId: 0,
                amount: Types.AssetAmount({
                    sign: false,
                    denomination: Types.AssetDenomination.Wei,
                    ref: Types.AssetReference.Delta,
                    value: amount
                }),
                primaryMarketId: marketId,
                secondaryMarketId: 0,
                otherAddress: address(this),
                otherAccountId: 0,
                data: ""
            });
    }

    function _getCallAction(bytes memory data)
        internal
        view
        returns (Actions.ActionArgs memory)
    {
        return
            Actions.ActionArgs({
                actionType: Actions.ActionType.Call,
                accountId: 0,
                amount: Types.AssetAmount({
                    sign: false,
                    denomination: Types.AssetDenomination.Wei,
                    ref: Types.AssetReference.Delta,
                    value: 0
                }),
                primaryMarketId: 0,
                secondaryMarketId: 0,
                otherAddress: address(this),
                otherAccountId: 0,
                data: data
            });
    }

    function _getDepositAction(uint256 marketId, uint256 amount)
        internal
        view
        returns (Actions.ActionArgs memory)
    {
        return
            Actions.ActionArgs({
                actionType: Actions.ActionType.Deposit,
                accountId: 0,
                amount: Types.AssetAmount({
                    sign: true,
                    denomination: Types.AssetDenomination.Wei,
                    ref: Types.AssetReference.Delta,
                    value: amount
                }),
                primaryMarketId: marketId,
                secondaryMarketId: 0,
                otherAddress: address(this),
                otherAccountId: 0,
                data: ""
            });
    }

    function _priceOracle() internal view returns (IPriceOracle) {
        return
            IPriceOracle(
                protocolDataProvider.ADDRESSES_PROVIDER().getPriceOracle()
            );
    }

    function _toETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(weth) // 1:1 change
        ) {
            return _amount;
        }

        return
            _amount.mul(_priceOracle().getAssetPrice(asset)).div(
                uint256(10)**uint256(IOptionalERC20(asset).decimals())
            );
    }

    function _fromETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(weth) // 1:1 change
        ) {
            return _amount;
        }

        return
            _amount
                .mul(uint256(10)**uint256(IOptionalERC20(asset).decimals()))
                .div(_priceOracle().getAssetPrice(asset));
    }
}
