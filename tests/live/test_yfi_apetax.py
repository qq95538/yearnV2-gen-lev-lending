import brownie
from brownie import Contract
import pytest
from utils import actions, checks, utils


@pytest.mark.skip()
def test_operation(chain, accounts, RELATIVE_APPROX):
    strategy = Contract("0xcdE892be1dD7aB55F68Ca13bC0c35928819A6eE6")
    vault = Contract(strategy.vault())
    strategist = accounts.at(strategy.strategist(), force=True)

    before_pps = vault.pricePerShare()
    utils.strategy_status(vault, strategy)

    # harvest
    strategy.harvest({"from": strategist})

    utils.strategy_status(vault, strategy)

    chain.sleep(3600 * 6)
    chain.mine()
    after_pps = vault.pricePerShare()
    assert after_pps > before_pps
    print(f"PPS: {before_pps/1e18:.18f} before, {after_pps/1e18:.18f} after")
    utils.strategy_status(vault, strategy)
