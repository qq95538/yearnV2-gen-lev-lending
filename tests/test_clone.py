import pytest
from utils import actions, utils


def test_clone(
    vault,
    strategy,
    token,
    amount,
    weth,
    strategist,
    rewards,
    keeper,
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

    cloned_strategy = strategy.clone(
        vault, strategist, rewards, keeper, {"from": strategist}
    ).return_value
    cloned_strategy = Strategy.at(cloned_strategy)

    # free funds from old strategy
    vault.revokeStrategy(strategy, {"from": gov})
    utils.sleep(1)
    strategy.harvest({"from": gov})
    assert strategy.estimatedTotalAssets() < strategy.minWant()

    # take funds to new strategy
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    weth.transfer(
        cloned_strategy, 1e6, {"from": "0xba12222222228d8ba445958a75a0704d566bf2c8"}
    )
    utils.sleep(1)
    cloned_strategy.harvest({"from": gov})
    assert (
        pytest.approx(cloned_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )


@pytest.mark.skip()
def test_non_clone(
    vault,
    strategy,
    token,
    amount,
    weth,
    strategist,
    rewards,
    keeper,
    gov,
    user,
    RELATIVE_APPROX,
    FlashLoanLib,
    Strategy,
):
    user_balance_before = token.balanceOf(user)
    actions.user_deposit(user, vault, token, amount)

    # harvest
    utils.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    non_cloned_strategy = Strategy.deploy(vault, {"from": strategist})

    # free funds from old strategy
    vault.revokeStrategy(strategy, {"from": gov})
    utils.sleep(1)
    strategy.harvest({"from": gov})
    assert strategy.estimatedTotalAssets() < strategy.minWant()

    # take funds to new strategy
    vault.addStrategy(
        non_cloned_strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov}
    )
    weth.transfer(
        non_cloned_strategy, 1e6, {"from": "0xba12222222228d8ba445958a75a0704d566bf2c8"}
    )
    utils.sleep(1)
    non_cloned_strategy.harvest({"from": gov})
    assert (
        pytest.approx(non_cloned_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == amount
    )
