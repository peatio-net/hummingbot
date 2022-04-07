import re

from typing import Optional, Tuple
from typing_extensions import Self

from hummingbot.connector.exchange.peatio.peatio_constants import Constants
from hummingbot.client.config.config_var import ConfigVar
from hummingbot.client.config.config_methods import using_exchange

CENTRALIZED = True

#EXAMPLE_PAIR = "BTC-ETH"

#DEFAULT_FEES = [0.35, 0.45]  # The actual fees

KEYS = {
    "peatio_api_key":
        ConfigVar(key="peatio_api_key",
                  prompt="Enter your Peatio API key >>> ",
                  required_if=using_exchange("peatio"),
                  is_secure=True,
                  is_connect_key=True),
    "peatio_api_secret":
        ConfigVar(key="peatio_api_secret",
                  prompt="Enter your Peatio API secret >>> ",
                  required_if=using_exchange("peatio"),
                  is_secure=True,
                  is_connect_key=True),
#    "peatio_currencies":
#        ConfigVar(key="peatio_currencies",
#                  prompt="Enter your Peatio quote currencies Eg: 'USD|ETH|BTC' >>> ",
#                  required_if=using_exchange("peatio"),
#                  is_secure=False,
#                  is_connect_key=True),
#    "peatio_base_rest_url":
#        ConfigVar(key="peatio_base_rest_url",
#                  prompt="Enter your Peatio HTTP REST API URL Eg. 'https://www.fixex.io/api/v2/peatio' >>> ",
#                  required_if=using_exchange("peatio"),
#                  is_secure=False,
#                  is_connect_key=True),
#    "peatio_base_wss_url":
#        ConfigVar(key="peatio_base_wss_url",
#                  prompt="Enter your Peatio WSS API URL Eg. 'wss://www.fixex.io/api/v2/ranger' >>> ",
#                  required_if=using_exchange("peatio"),
#                  is_secure=False,
#                  is_connect_key=True)

}

#pmc

#TRADING_PAIR_SPLITTER = re.compile("{Constants.TRADING_PAIR_SPLITTER}")
#TRADING_PAIR_SPLITTER = re.compile("^\({Constants.TRADING_PAIR_SPLITTER}\)$")
TRADING_PAIR_SPLITTER = re.compile(r"^(\w+)(USDT|usdt|ETH|eth|AUD|aud|USD|usd)$")

def split_trading_pair(trading_pair: str) -> Optional[Tuple[str, str]]:
    try:
 #       Self.logger().info(f"PMC - split_trading_pair - line 58 \n\ntrading_pair = {trading_pair}, \n\nTRADING_PAIR_SPLITTER = {TRADING_PAIR_SPLITTER}")

        if ('/' in trading_pair):
 #           Self.logger().info(f"PMC - split_trading_pair - line 61")
            m = trading_pair.split('/')
            return m[0], m[1]
        else:
 #           Self.logger().info(f"PMC - split_trading_pair - line 65")
            m = TRADING_PAIR_SPLITTER.match(trading_pair)
            return m.group(1), m.group(2)
    # Exceptions are now logged as warnings in trading pair fetcher
    except Exception:
        return None


def convert_from_exchange_trading_pair(exchange_trading_pair: str) -> Optional[str]:

    if split_trading_pair(exchange_trading_pair) is None:
        return None

    # Peatio does not split BASEQUOTE (fthusd)
    base_asset, quote_asset = split_trading_pair(exchange_trading_pair)

    return f"{base_asset}-{quote_asset}".upper()


def convert_to_exchange_trading_pair(hb_trading_pair: str) -> str:
    return hb_trading_pair.lower().replace("-", "")

