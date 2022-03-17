import pytest
from brownie import config, Contract, network
import requests

# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


@pytest.fixture(scope="session")
def gov(accounts):
    yield accounts.at("0xC0E2830724C946a6748dDFE09753613cd38f6767", force=True)


@pytest.fixture(scope="session")
def strat_ms(accounts):
    yield accounts.at("0x72a34AbafAB09b15E7191822A679f28E067C4a16", force=True)


@pytest.fixture(scope="session")
def user(accounts):
    yield accounts[0]


@pytest.fixture(scope="session")
def rewards(accounts):
    yield accounts[1]


@pytest.fixture(scope="session")
def guardian(accounts):
    yield accounts[2]


@pytest.fixture(scope="session")
def management(strat_ms):
    yield strat_ms  # accounts[3]


@pytest.fixture(scope="session")
def strategist(accounts):
    yield accounts[4]


@pytest.fixture(scope="session")
def keeper(accounts):
    yield accounts[5]


token_addresses = {
    "BTC": "0x321162Cd933E2Be498Cd2267a90534A804051b11",  # WBTC
    "ETH": "0x74b23882a30290451A17c44f4F05243b6b58C76d",  # WETH
    "DAI": "0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E",  # DAI
    "USDC": "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75",  # USDC
    "WFTM": "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83",  # WFTM
    "MIM": "0x82f0B8B456c1A451378467398982d4834b6829c1",  # MIM
}

# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        # "BTC",   # WBTC
        # "ETH",   # ETH
        # "DAI",   # DAI
        # "USDC",  # USDC
        "WFTM",  # WFTM
        # "MIM",   # MIM
    ],
    scope="session",
    autouse=True,
)
def token(request):
    yield Contract(token_addresses[request.param])


whale_addresses = {
    "BTC": "0x4565DC3Ef685E4775cdF920129111DdF43B9d882",
    "ETH": "0xC772BA6C2c28859B7a0542FAa162a56115dDCE25",
    "DAI": "0x8CFA87aD11e69E071c40D58d2d1a01F862aE01a8",
    "USDC": "0x2dd7C9371965472E5A5fD28fbE165007c61439E1",
    "WFTM": "0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d",
    "MIM": "0x2dd7C9371965472E5A5fD28fbE165007c61439E1",
}


@pytest.fixture(scope="session", autouse=True)
def token_whale(token):
    yield whale_addresses[token.symbol()]


token_prices = {
    "BTC": 40_000,
    "ETH": 3_500,
    "YFI": 30_000,
    "DAI": 1,
    "USDC": 1,
    "WFTM": 2,
    "MIM": 1,
}


@pytest.fixture(autouse=True, scope="function")
def amount(token, token_whale, user):
    # this will get the number of tokens (around $1m worth of token)
    base_amount = round(1_000_000 / token_prices[token.symbol()])
    amount = base_amount * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate a whale address
    if amount > token.balanceOf(token_whale):
        amount = token.balanceOf(token_whale)
    token.transfer(user, amount, {"from": token_whale})
    yield amount


@pytest.fixture(scope="function")
def big_amount(token, token_whale, user):
    # this will get the number of tokens (around $9m worth of token)
    ten_minus_one_million = round(9_000_000 / token_prices[token.symbol()])
    amount = ten_minus_one_million * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate a whale address
    if amount > token.balanceOf(token_whale):
        amount = token.balanceOf(token_whale)
    token.transfer(user, amount, {"from": token_whale})
    yield token.balanceOf(user)


@pytest.fixture
def wftm():
    yield Contract("0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83")


@pytest.fixture
def weth(wftm):
    yield wftm
    # token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    # yield Contract(token_address)


@pytest.fixture
def weth_amount(user, weth):
    weth_amount = 10 ** weth.decimals()
    weth.transfer(
        user, weth_amount, {"from": "0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d"}
    )
    yield weth_amount


@pytest.fixture(scope="function", autouse=True)
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture(scope="function")
def factory(strategist, vault, LevGeistFactory):
    yield strategist.deploy(LevGeistFactory, vault)


@pytest.fixture(scope="function")
def strategy(chain, keeper, vault, factory, gov, strategist, Strategy):
    strategy = Strategy.at(factory.original())
    strategy.setKeeper(keeper, {"from": strategist})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    chain.sleep(1)
    chain.mine()
    yield strategy


@pytest.fixture()
def enable_healthcheck(strategy, gov):
    strategy.setHealthCheck("0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0", {"from": gov})
    strategy.setDoHealthCheck(True, {"from": gov})
    yield True


@pytest.fixture(scope="session", autouse=True)
def RELATIVE_APPROX():
    yield 1e-5
