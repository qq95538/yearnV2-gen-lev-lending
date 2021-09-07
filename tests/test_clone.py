from utils import actions


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
    # send strategy to steady state
    actions.first_deposit_and_harvest(
        vault, strategy, token, user, gov, amount, RELATIVE_APPROX
    )

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
