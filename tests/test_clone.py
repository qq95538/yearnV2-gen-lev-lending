import pytest
from utils import actions, utils

def test_clone(
    vault,
    strategy,
    token,
    amount,
    strategist,
    rewards,
    keeper,
    gov,
    user,
    RELATIVE_APPROX,
):
    user_balance_before = token.balanceOf(user)
    actions.user_deposit(user, vault, token, amount)

    # harvest
    utils.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    cloned_strategy = strategy.clone(
        vault, strategist, rewards, keeper, {"from": strategist}
    )

    # free funds from old strategy
    vault.revokeStrategy(strategy, {"from": gov})
    strategy.harvest({"from": gov})
    assert strategy.estimatedTotalAssets() == 0

    # take funds to new strategy
    cloned_strategy.harvest({"from": gov})
    assert cloned_strategy.estimatedTotalAssets() >= amount
