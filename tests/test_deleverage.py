import brownie
from brownie import Contract
import pytest
from utils import actions, checks, utils


def test_deleverage_to_zero(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)
    utils.sleep(1)
    strategy.harvest({"from": strategist})

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    utils.sleep(7 * 24 * 3600)

    utils.strategy_status(vault, strategy)

    vault.revokeStrategy(strategy.address, {"from": gov})
    n = 0
    while vault.debtOutstanding(strategy) > 0 and n < 5:
        utils.sleep(1)
        strategy.harvest({"from": strategist})
        utils.strategy_status(vault, strategy)
        n += 1

    utils.sleep()
    utils.strategy_status(vault, strategy)
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == 0
        or strategy.estimatedTotalAssets() <= strategy.minWant()
    )
    assert (
        pytest.approx(
            vault.strategies(strategy).dict()["totalLoss"], rel=RELATIVE_APPROX
        )
        == 0
    )


def test_deleverage_parameter_change(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)
    utils.sleep(1)
    strategy.harvest({"from": strategist})

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    utils.sleep(7 * 24 * 3600)

    strategy.setCollateralTargets(
        strategy.targetCollatRatio() / 2,
        strategy.maxCollatRatio(),
        strategy.maxBorrowCollatRatio(),
        {"from": gov},
    )

    utils.strategy_status(vault, strategy)

    n = 0
    while (
        not pytest.approx(strategy.getCurrentCollatRatio(), rel=RELATIVE_APPROX)
        == strategy.targetCollatRatio()
    ):
        utils.sleep(1)
        strategy.harvest({"from": strategist})
        utils.strategy_status(vault, strategy)
        n += 1

    assert (
        pytest.approx(strategy.getCurrentCollatRatio(), rel=RELATIVE_APPROX)
        == strategy.targetCollatRatio()
    )
    utils.sleep()
    utils.strategy_status(vault, strategy)
    assert (
        pytest.approx(
            vault.strategies(strategy).dict()["totalLoss"], rel=RELATIVE_APPROX
        )
        == 0
    )


def test_manual_deleverage_to_zero(
    chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)
    utils.sleep(1)
    strategy.harvest({"from": strategist})

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    chain.sleep(6 * 3600)

    utils.strategy_status(vault, strategy)

    n = 0
    while strategy.getCurrentSupply() > strategy.minWant():
        utils.sleep(1)

        (deposit, borrow) = strategy.getCurrentPosition()
        theo_min_deposit = borrow / (strategy.maxCollatRatio() / 1e18)
        step_size = min(int(deposit - theo_min_deposit), borrow)

        strategy.manualDeleverage(step_size, {"from": gov})

        n += 1

        if strategy.getCurrentPosition().dict()["borrows"] == 0:
            break

    utils.strategy_status(vault, strategy)
    print(f"manualDeleverage calls: {n} iterations")

    utils.sleep(1)
    deposits = strategy.getCurrentPosition().dict()["deposits"]
    while deposits > strategy.minWant():
        strategy.manualReleaseWant(deposits, {"from": gov})
        deposits = strategy.getCurrentPosition().dict()["deposits"]
    assert strategy.getCurrentSupply() <= strategy.minWant()

    strategy.setRewardBehavior(0, 1e6, {"from": gov})
    if strategy.estimatedRewardsInWant() >= strategy.minRewardToSell():
        strategy.manualClaimAndSellRewards({"from": gov})

    utils.sleep()
    utils.strategy_status(vault, strategy)
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    ) or strategy.estimatedTotalAssets() > amount

    vault.revokeStrategy(strategy.address, {"from": gov})
    strategy.harvest({"from": strategist})
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == 0
        or strategy.estimatedTotalAssets() <= strategy.minWant()
    )
    assert (
        pytest.approx(
            vault.strategies(strategy).dict()["totalLoss"], rel=RELATIVE_APPROX
        )
        == 0
    )
