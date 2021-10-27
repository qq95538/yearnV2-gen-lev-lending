import pytest
from brownie import config, Contract, network

# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


# @pytest.fixture(
#     params=[
#         1000,
#         3000,
#         10000,
#     ],
#     scope="session",
#     autouse=True,
# )
# def stksave_fee(request):
#     yield request.param
