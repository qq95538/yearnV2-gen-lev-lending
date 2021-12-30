import pytest
from utils import actions, utils


def test_clone(
    vault,
    strategy,
    factory,
    token,
    amount,
    weth,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    Strategy,
):
    user_balance_before = token.balanceOf(user)
    actions.user_deposit(user, vault, token, amount)

    # harvest
    utils.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    cloned_strategy = factory.cloneLevAave(vault, {"from": strategist}).return_value
    cloned_strategy = Strategy.at(cloned_strategy)

    # free funds from old strategy
    vault.revokeStrategy(strategy, {"from": gov})
    utils.sleep(1)
    strategy.harvest({"from": gov})
    assert strategy.estimatedTotalAssets() < strategy.minWant()

    # take funds to new strategy
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    utils.sleep(1)
    cloned_strategy.harvest({"from": gov})
    assert (
        pytest.approx(cloned_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )
