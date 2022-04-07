#   25-July-2021
#   Peter Cooney (PMC) - created this file for configuration of individual Peatio exchanges.
#   This file is a single source of truth for constant variables related to the exchange.
#   In most cases, just need to update EXCHANGE_NAME, REST_URL and WS_URL


import collections

# REST API Public Endpoints

class Constants:
    EXCHANGE_NAME = "peatio"

    DOMAIN_NAME ="www.coinharbour.com.au"

    REST_API_VERSION = "v2"
#   Eg. REST_URL = f"http://www.change.me/api/{REST_API_VERSION}/peatio"
#   Note: must use https, not http, to POST data
    REST_URL = f"https://{DOMAIN_NAME}/api/{REST_API_VERSION}/peatio"

#    REST_URL_AUTH = "/api/2"

    REST_URL_PRIVATE = f"{REST_URL}/private"
    REST_URL_PUBLIC = f"{REST_URL}/public"

    WS_API_VERSION = "v2"
#   Eg. WS_URL = f"wss://www.change.me/api/{WS_API_VERSION}/ranger"
    WS_URL = f"wss://{DOMAIN_NAME}/api/{WS_API_VERSION}/ranger"
    WS_URL_PRIVATE = f"{WS_URL}/private"
    WS_URL_PUBLIC = f"{WS_URL}/public"

#   /api/v2/peatio/public/timestamp
    TIME_URL = f"{REST_URL_PUBLIC}/timestamp"

    MARKETS_URL = f"{REST_URL}/market"

#   /api/v2/peatio/public/markets/tickers
#    EXCHANGE_INFO_URL = f"{REST_URL_PUBLIC}/markets"
#    TICKER_PRICE_CHANGE_URL = f"{REST_URL_PUBLIC}/markets/tickers"
#    SINGLE_MARKET_DEPTH_URL = f"{REST_URL_PUBLIC}"+"/markets/{}/depth"
#    EXCHANGE_INFO_URL = "/markets"
#    TICKER_PRICE_CHANGE_URL = "/markets/tickers"
#    SINGLE_MARKET_DEPTH_URL = "/markets/{}/depth"
    EXCHANGE_INFO_URL = "/public/markets"
    #TICKER_PRICE_CHANGE_URL = "/public/markets/{}/tickers"
    TICKER_PRICE_CHANGE_URL = "/public/markets/tickers"
    TICKER_PRICE_CHANGE_SINGLE_URL = "/public/markets/{market}/tickers"
    SINGLE_MARKET_DEPTH_URL = "/public/markets/{market}/depth"

#https://www.coinharbour.com.au/api/v2/peatio/public/markets/btcaud/tickers
    # REST API Public Endpoints
    GET_TRADING_PAIRS = "/Public/GetPairs"
    GET_TRADING_PAIRS_STATS = "/Public/GetPairStats"
    GET_MARKET = "/public/markets"
    GET_ORDER_BOOK = "/Public/GetOrderBook"
    GET_PUBLIC_TRADE_HISTORY = "/Public/GetTradeHistory"

    #DIFF_STREAM_URL = f"{WS_URL_PUBLIC}"

    WSS_MY_TRADES = "SubscribeMyTrades"
    WSS_ORDER_BOOK = "SubscribeOrderBook"
    WSS_TRADES = "SubscribeTrades"
    WSS_LOGIN = "Login"

    OrderBookRow = collections.namedtuple("Book", ["price", "amount"])

    ENDPOINT = {
        # Public Endpoints
        "TICKER": "public/ticker",
        "TICKER_SINGLE": "public/ticker/{trading_pair}",
        "SYMBOL": "public/symbol",
        "ORDER_BOOK": "public/orderbook",
        "ORDER_CREATE": "order",
        "ORDER_DELETE": "order/{id}",
        "ORDER_STATUS": "order/{id}",
        "USER_ORDERS": "order",
        "USER_BALANCES": "trading/balance",
    }

# Order Status Defintions
    ORDER_STATUS = [
    'New',
    'Partially Filled',
    'Filled',
    'Expired',
    'Cancelled',
    'Canceling',
    'Processing',
    'No Balance',
    'No Fill'
    ]

    WS_SUB = {
        "TRADES": "Trades",
        "ORDERS": "Orderbook",
        "USER_ORDERS_TRADES": "Reports",
    }

    WS_METHODS = {
        "ORDERS_SNAPSHOT": "snapshotOrderbook",
        "ORDERS_UPDATE": "updateOrderbook",
        "TRADES_SNAPSHOT": "snapshotTrades",
        "TRADES_UPDATE": "updateTrades",
        "USER_BALANCE": "getTradingBalance",
        "USER_ORDERS": "activeOrders",
        "USER_TRADES": "report",
    }

    # Timeouts
    MESSAGE_TIMEOUT = 30.0
    PING_TIMEOUT = 10.0
    API_CALL_TIMEOUT = 5.0
    API_MAX_RETRIES = 4

    # Intervals
    # Only used when nothing is received from WS
    SHORT_POLL_INTERVAL = 5.0

    # One minute should be fine since we get trades, orders and balances via WS
    LONG_POLL_INTERVAL = 60.0
#    UPDATE_ORDER_STATUS_INTERVAL = 60.0

    # 10 minute interval to update trading rules, these would likely never change whilst running.
    INTERVAL_TRADING_RULES = 600

#   Trading pair splitter regex
#   TRADING_PAIR_SPLITTER = re.compile(r"^(\w+)(AUD|aud|USD|usd|BNB|bnb|USDT|usdt|NZD|nzd|BTC|btc|ETH|eth|BRL|brl|PAX|pax)$")
    TRADING_PAIR_SPLITTER = "AUD|aud|USD|usd|BNB|bnb|USDT|usdt|NZD|nzd|BTC|btc|ETH|eth"


#   https://change.me/api/v2/peatio/account/balances
    GET_BALANCES = "/account/balances"

#    GET_ORDERS = f"{REST_API_VERSION}/Private/GetOrders"
    GET_ORDERS = "/market/orders"

    #GET_DETAILED_BALANCES = "/Private/GetDetailedBalances"
    #GET_OPEN_ORDERS = "/Private/GetOpenOrders"
    #GET_PRIVATE_TRADE_HISTORY = "/Private/GetTradeHistory"
    #PLACE_ORDER = "/Private/PlaceOrders"
    #MOVE_ORDER = "/Private/MoveOrders"
    #CANCEL_ORDER = "/Private/CancelOrder"
    #CANCEL_ALL_ORDERS = "/Private/CancelAllOrders"


#   Openware examples
#   From https://www.openware.com/sdk/2.6/api/peatio/trading-api.html

#   Public API End Points

#   https://change.me/api/v2/peatio/public/markets

#   /api/v2/admin/peatio/blockchains
#   /api/v2/admin/peatio/blockchains/clients
#   /api/v2/admin/peatio/blockchains/process_block
#   /api/v2/admin/peatio/blockchains/update
#   /api/v2/admin/peatio/blockchains/{id}/latest_block

#   /api/v2/peatio/public/health/alive
#   /api/v2/peatio/public/timestamp
#   /api/v2/peatio/public/trading_fees
#   /api/v2/peatio/public/version
#   /api/v2/peatio/public/webhooks/{event}
#   /api/v2/peatio/public/withdraw_limits

#   /api/v2/peatio/public/markets
#   /api/v2/peatio/public/markets/tickers
#   /api/v2/peatio/public/markets/{market}/depth

#   /api/v2/peatio/public/markets/{market}/tickers
#   /api/v2/peatio/public/markets/{market}/trades
#   /api/v2/peatio/public/markets/{market}/order-book

#   /api/v2/peatio/public/currencies
#   /api/v2/peatio/public/currencies/{id}

#   Private  API End Points

#   https://change.me/api/v2/peatio/account/balances
#   https://change.me/api/v2/peatio/market/orders
#   https://change.me/api/v2/peatio/market/trade

#   /api/v2/peatio/account/stats/pnl
#   /api/v2/peatio/account/transactions

#   /api/v2/peatio/market/orders
#   /api/v2/peatio/market/orders/{id}
#   /api/v2/peatio/market/orders/cancel

#   For testing:
#   http://www.coinharbour.com.au/api/v2/peatio/public/markets
#   http://www.coinharbour.com.au/api/v2/peatio/public/markets/tickers

#   http://www.coinharbour.com.au/api/v2/peatio/account/balances
#   http://www.coinharbour.com.au/api/v2/peatio/market/orders


