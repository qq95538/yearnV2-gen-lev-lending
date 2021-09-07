import pytest
from brownie import accounts, chain, interface, Contract
import utils

# This file is reserved for standard actions like deposits
def user_deposit(user, vault, token, amount):
    if token.allowance(user, vault) < amount:
        token.approve(vault, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount


def generate_profit(strategy, token_whale, amount):
    lp = interface.ILendingPool(
        interface.ILendingPoolAddressesProvider(
            interface.IProtocolDataProvider(
                "0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d"
            ).ADDRESSES_PROVIDER()
        ).getLendingPool()
    )
    token = Contract(strategy.want())
    token.approve(lp, 2 ** 256 - 1, {"from": token_whale})
    lp.deposit(strategy.want(), amount, strategy, 0, {"from": token_whale})
    return


def generate_loss(strategy, amount):
    strategy_account = accounts.at(strategy, force=True)
    interface.IERC20(strategy.aToken()).transfer(
        strategy.aToken(), amount, {"from": strategy_account}
    )
    return


def first_deposit_and_harvest(
    vault, strategy, token, user, gov, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    utils.sleep()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
