import pytest
from brownie import config, Contract, network

# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def strat_ms(accounts):
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture(autouse=True)
def FlashLoanLibrary(FlashLoanLib, gov):
    yield gov.deploy(FlashLoanLib)


token_addresses = {
    "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",  # WBTC
    "YFI": "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e",  # YFI
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",  # LINK
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",  # USDT
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",  # DAI
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
}

# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        "WBTC",  # WBTC
        "YFI",  # YFI
        # "WETH",  # WETH
        # 'LINK', # LINK
        # 'USDT', # USDT
        # "DAI", # DAI
        # "USDC",  # USDC
    ],
    scope="session",
    autouse=True,
)
def token(request):
    yield Contract(token_addresses[request.param])


whale_addresses = {
    "WBTC": "0x28c6c06298d514db089934071355e5743bf21d60",
    "WETH": "0x28c6c06298d514db089934071355e5743bf21d60",
    "LINK": "0x28c6c06298d514db089934071355e5743bf21d60",
    "YFI": "0x28c6c06298d514db089934071355e5743bf21d60",
    "USDT": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "USDC": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "DAI": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
}


@pytest.fixture(scope="session", autouse=True)
def token_whale(token):
    yield whale_addresses[token.symbol()]


token_prices = {
    "WBTC": 45_000,
    "WETH": 3_500,
    "LINK": 20,
    "YFI": 30_000,
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
}


@pytest.fixture(autouse=True)
def amount(token, token_whale, user):
    # this will get the number of tokens (around $1m worth of token)
    amillion = round(1_000_000 / token_prices[token.symbol()])
    amount = amillion * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate a whale address
    if amount > token.balanceOf(token_whale):
        amount = token.balanceOf(token_whale)
    token.transfer(user, amount, {"from": token_whale})
    yield amount


@pytest.fixture()
def big_amount(token, token_whale, user):
    # this will get the number of tokens (around $49m worth of token)
    fifty_minus_one_million = round(49_000_000 / token_prices[token.symbol()])
    amount = fifty_minus_one_million * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate a whale address
    if amount > token.balanceOf(token_whale):
        amount = token.balanceOf(token_whale)
    token.transfer(user, amount, {"from": token_whale})
    yield token.balanceOf(user)


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amount(user, weth):
    weth_amount = 10 ** weth.decimals()
    user.transfer(weth, weth_amount)
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


@pytest.fixture(scope="session")
def registry():
    yield Contract("0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804")


@pytest.fixture(scope="session")
def live_vault(registry, token):
    yield registry.latestVault(token)


@pytest.fixture(scope="function")
def strategy(chain, strategist, keeper, vault, Strategy, gov, weth, dyDxActive):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    strategy.setIsDyDxActive(dyDxActive, {"from": gov})

    # send WETH to repay 2 wei+ each flashloan
    weth.transfer(strategy, 1e6, {"from": "0xBA12222222228d8Ba445958a75a0704d566BF2C8"})
    chain.sleep(1)
    chain.mine()
    yield strategy


@pytest.fixture()
def enable_healthcheck(strategy, gov):
    strategy.setHealthCheck("0xDDCea799fF1699e98EDF118e0629A974Df7DF012", {"from": gov})
    strategy.setDoHealthCheck(True, {"from": gov})
    yield True


@pytest.fixture(
    params=[
        True,
        # False,
    ],
    scope="session",
    autouse=True,
)
def dyDxActive(request):
    isActive = request.param
    yield isActive


@pytest.fixture(scope="session", autouse=True)
def RELATIVE_APPROX():
    yield 1e-5
