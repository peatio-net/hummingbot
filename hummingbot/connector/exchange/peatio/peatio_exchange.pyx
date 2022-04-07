import re
import time
import asyncio
import aiohttp
import copy
import json
import logging
import pandas as pd
import traceback
from decimal import Decimal
from libc.stdint cimport int64_t
from threading import Lock
from async_timeout import timeout
from typing import Optional, List, Dict, Any, AsyncIterable, Tuple

from hummingbot.logger import HummingbotLogger
from hummingbot.client.config.fee_overrides_config_map import fee_overrides_config_map
from hummingbot.client.config.global_config_map import global_config_map
from hummingbot.core.clock cimport Clock
from hummingbot.core.data_type.order_book cimport OrderBook
from hummingbot.core.data_type.order_book_tracker import OrderBookTrackerDataSourceType
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.data_type.trade_fee import AddedToCostTradeFee
from hummingbot.core.data_type.transaction_tracker import TransactionTracker
from hummingbot.core.data_type.cancellation_result import CancellationResult
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.core.utils.tracking_nonce import get_tracking_nonce
from hummingbot.core.utils.async_utils import safe_ensure_future, safe_gather

from hummingbot.core.event.events import (
    MarketEvent,
#    TradeFee,
    OrderType,
    OrderFilledEvent,
    TradeType,
    BuyOrderCompletedEvent,
    SellOrderCompletedEvent, OrderCancelledEvent, MarketTransactionFailureEvent,
    MarketOrderFailureEvent, SellOrderCreatedEvent, BuyOrderCreatedEvent
)

from hummingbot.connector.exchange_base cimport ExchangeBase
from hummingbot.connector.exchange_base import s_decimal_NaN
from hummingbot.connector.exchange.peatio.peatio_auth import PeatioAuth
from hummingbot.connector.exchange.peatio.peatio_constants import Constants
from hummingbot.connector.exchange.peatio.peatio_in_flight_order import PeatioInFlightOrder
from hummingbot.connector.exchange.peatio.peatio_order_book_tracker import PeatioOrderBookTracker
from hummingbot.connector.exchange.peatio.peatio_user_stream_tracker import PeatioUserStreamTracker
from hummingbot.connector.exchange.peatio.peatio_api_order_book_data_source import PeatioAPIOrderBookDataSource
from hummingbot.connector.exchange.peatio.peatio_utils import convert_from_exchange_trading_pair, convert_to_exchange_trading_pair, split_trading_pair
from hummingbot.connector.trading_rule cimport TradingRule

bm_logger = None
s_decimal_0 = Decimal(0)


class PeatioAPIException(IOError):
    def __init__(self, message, status_code = 0, malformed=False, body = None):
        super().__init__(message)
        self.status_code = status_code
        self.malformed = malformed
        self.body = body


cdef class PeatioExchangeTransactionTracker(TransactionTracker):
    cdef:
        PeatioExchange _owner

    def __init__(self, owner: PeatioExchange):
        super().__init__()
        self._owner = owner

    cdef c_did_timeout_tx(self, str tx_id):
        TransactionTracker.c_did_timeout_tx(self, tx_id)
        self._owner.c_did_timeout_tx(tx_id)

cdef class PeatioExchange(ExchangeBase):
    MARKET_RECEIVED_ASSET_EVENT_TAG = MarketEvent.ReceivedAsset.value
    MARKET_BUY_ORDER_COMPLETED_EVENT_TAG = MarketEvent.BuyOrderCompleted.value
    MARKET_SELL_ORDER_COMPLETED_EVENT_TAG = MarketEvent.SellOrderCompleted.value
    MARKET_WITHDRAW_ASSET_EVENT_TAG = MarketEvent.WithdrawAsset.value
    MARKET_ORDER_CANCELLED_EVENT_TAG = MarketEvent.OrderCancelled.value
    MARKET_TRANSACTION_FAILURE_EVENT_TAG = MarketEvent.TransactionFailure.value
    MARKET_ORDER_FAILURE_EVENT_TAG = MarketEvent.OrderFailure.value
    MARKET_ORDER_FILLED_EVENT_TAG = MarketEvent.OrderFilled.value
    MARKET_BUY_ORDER_CREATED_EVENT_TAG = MarketEvent.BuyOrderCreated.value
    MARKET_SELL_ORDER_CREATED_EVENT_TAG = MarketEvent.SellOrderCreated.value

    UPDATE_ORDERS_INTERVAL = 10.0
    ORDER_NOT_EXIST_WAIT_TIME = 10.0

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global bm_logger
        if bm_logger is None:
            bm_logger = logging.getLogger(__name__)
        return bm_logger

    def __init__(self,
                 peatio_api_key: str,
                 peatio_api_secret: str,
                 poll_interval: float = 5.0,
                 trading_pairs: Optional[List[str]] = None,
                 trading_required: bool = True):

        super().__init__()

        self._real_time_balance_update = True
        self._account_available_balances = {}
        self._account_balances = {}
        self._peatio_auth = PeatioAuth(peatio_api_key, peatio_api_secret)

        self._peatio_base_rest_url = Constants.REST_URL
        self._peatio_base_wss_url = Constants.WS_URL

        self.logger().info(f"Loading {Constants.EXCHANGE_NAME} Exchange Connector:")
        self.logger().info(f"REST URL={self._peatio_base_rest_url}")
        self.logger().info(f"WSS URL={self._peatio_base_wss_url}")

        if trading_pairs != None:
            if len(trading_pairs) == 1:
                self._market = trading_pairs[0]
                self.logger().info(f"Single Traded Market for this Strategy={self._market}")

        self._ev_loop = asyncio.get_event_loop()
        self._in_flight_orders = {}
        self._last_poll_timestamp = 0
        self._last_timestamp = 0
        self._order_book_tracker = PeatioOrderBookTracker(trading_pairs=trading_pairs)
        self._order_not_found_records = {}
        self._poll_notifier = asyncio.Event()
        self._poll_interval = poll_interval
        self._shared_client = None
        self._status_polling_task = None
        self._trading_required = trading_required
        self._trading_rules = {}
        self._trading_rules_polling_task = None
        self._tx_tracker = PeatioExchangeTransactionTracker(self)
        self._user_stream_event_listener_task = None
        self._user_stream_tracker = PeatioUserStreamTracker(peatio_auth=self._peatio_auth, trading_pairs=trading_pairs)
        self._user_stream_tracker_task = None
        self._check_network_interval = 60.0
    

    @staticmethod
    def split_trading_pair(trading_pair: str) -> Optional[Tuple[str, str]]:
        return split_trading_pair(trading_pair)

    @staticmethod
    def convert_from_exchange_trading_pair(exchange_trading_pair: str) -> Optional[str]:
        return convert_from_exchange_trading_pair(exchange_trading_pair)

    @staticmethod
    def convert_to_exchange_trading_pair(hb_trading_pair: str) -> str:
        return convert_to_exchange_trading_pair(hb_trading_pair)

    @property
    def name(self) -> str:
        return Constants.EXCHANGE_NAME

    @property
    def order_books(self) -> Dict[str, OrderBook]:
        return self._order_book_tracker.order_books

    @property
    def peatio_auth(self) -> PeatioAuth:
        return self._peatio_auth

    @property
    def status_dict(self) -> Dict[str, bool]:
        return {
            "order_book_initialized": self._order_book_tracker.ready,
            "account_balance": len(self._account_balances) > 0 if self._trading_required else True,
            "trading_rule_initialized": len(self._trading_rules) > 0 if self._trading_required else True
        }

    @property
    def ready(self) -> bool:
        return all(self.status_dict.values())

    @property
    def limit_orders(self) -> List[LimitOrder]:
        return [
            in_flight_order.to_limit_order()
            for in_flight_order in self._in_flight_orders.values()
        ]

    @property
    def tracking_states(self) -> Dict[str, any]:
        return {
            key: value.to_json()
            for key, value in self._in_flight_orders.items()
        }

    def restore_tracking_states(self, saved_states: Dict[str, any]):
        self._in_flight_orders.update({
            key: PeatioInFlightOrder.from_json(value)
            for key, value in saved_states.items()
        })

    async def get_active_exchange_markets(self) -> pd.DataFrame:
        return await PeatioAPIOrderBookDataSource.get_active_exchange_markets()

    cdef c_start(self, Clock clock, double timestamp):
        self._tx_tracker.c_start(clock, timestamp)
        ExchangeBase.c_start(self, clock, timestamp)

    cdef c_tick(self, double timestamp):
        cdef:
            int64_t last_tick = <int64_t> (self._last_timestamp / self._poll_interval)
            int64_t current_tick = <int64_t> (timestamp / self._poll_interval)

        ExchangeBase.c_tick(self, timestamp)

        self._tx_tracker.c_tick(timestamp)

        if current_tick > last_tick:
            if not self._poll_notifier.is_set():
                self._poll_notifier.set()
        self._last_timestamp = timestamp

    cdef object c_get_fee(self,
                          str base_currency,
                          str quote_currency,
                          object order_type,
                          object order_side,
                          object amount,
                          object price, 
                          object is_maker = None):
        # Fee info from https://www.coinharbour.com.au/api/v2/peatio/public/trading_fees

        cdef:
            object maker_fee = Decimal(0.002)
            object taker_fee = Decimal(0.002)
        
#        if order_type is OrderType.LIMIT and fee_overrides_config_map["peatio_maker_fee"].value is not None:
#                return AddedToCostTradeFee(percent=fee_overrides_config_map["peatio_maker_fee"].value)
#        if order_type is OrderType.MARKET and fee_overrides_config_map["peatio_taker_fee"].value is not None:
#                return AddedToCostTradeFee(percent=fee_overrides_config_map["peatio_taker_fee"].value)

#        return AddedToCostTradeFee(percent=maker_fee if order_type is OrderType.LIMIT else taker_fee)
        return AddedToCostTradeFee(Decimal(0.0))

    async def _update_balances(self):
        cdef:
            dict account_info
            list balances
            str asset_name
            set local_asset_names = set(self._account_balances.keys())
            set remote_asset_names = set()
            set asset_names_to_remove

#        path_url = "/account/balances"
#       GET_BALANCES = "/account/balances"
        path_url = Constants.GET_BALANCES

#        account_balances = await self._api_request("GET", path_url=path_url)

        account_balances = await self._api_request("GET", path_url=path_url)

        for balance_entry in account_balances:
            asset_name = balance_entry["currency"].upper()
            available_balance = Decimal(balance_entry["balance"])
            total_balance = available_balance + Decimal(balance_entry["locked"])
            self._account_available_balances[asset_name] = available_balance
            self._account_balances[asset_name] = total_balance
            remote_asset_names.add(asset_name)

        asset_names_to_remove = local_asset_names.difference(remote_asset_names)

        for asset_name in asset_names_to_remove:
            del self._account_available_balances[asset_name]
            del self._account_balances[asset_name]
    
    def _format_trading_rules(self, exchange_info_dict: Dict[str, Any]) -> List[TradingRule]:
        """
        Example:
        [{
            id: "l1str004usdc",
            name: "L1STR004/USDC",
            base_unit: "l1str004",
            quote_unit: "usdc",
            min_price: "0.01",
            max_price: "1000000.0",
            min_amount: "0.001",
            amount_precision: 3,
            price_precision: 2,
            state: "enabled",

#cdef class TradingRule:
#    cdef:
#        public str trading_pair
#        public object min_order_size                   # Calculated min base asset size based on last trade price
#        public object max_order_size                   # Calculated max base asset size
#        public object min_price_increment              # Min tick size difference accepted (e.g. 0.1)
#        public object min_base_amount_increment        # Min step size of base asset amount (e.g. 0.01)
#        public object min_quote_amount_increment       # Min step size of quote asset amount (e.g. 0.01)
#        public object max_price_significant_digits     # Max # of significant digits in a price
#        public object min_notional_size                # Notional value = price * quantity, min accepted (e.g. 3.001)
#        public object min_order_value                  # Calculated min base asset value based on the minimum accepted trade value (e.g. 0.078LTC is ~50,000 Satoshis)
#        public bint supports_limit_orders              # if limit order is allowed for this trading pair
#        public bint supports_market_orders             # if market order is allowed for this trading pair
#        public object buy_order_collateral_token       # Indicates the collateral token used for buy orders
#        public object sell_order_collateral_token      # Indicates the collateral token used for sell orders
        }]
        """
        cdef:
            list trading_pair_rules = exchange_info_dict
            list retval = []
        for rule in trading_pair_rules:
            try:
                trading_pair = rule.get("id")
                hb_trading_pair = convert_from_exchange_trading_pair(trading_pair)

                base_unit = rule.get("base_unit")
                quote_unit = rule.get("quote_unit")

#                self.logger().info(f"_format_trading_rules line 300 trading_pair={trading_pair}, base_unit={base_unit}, quote_unit={quote_unit}, min_order_size={min_order_size}, tick_size={tick_size}, step_size={step_size}, min_notional={min_notional}.")
#                self.logger().info(f"_format_trading_rules line 301 {hb_trading_pair}=convert_from_exchange_trading_pair({trading_pair})")

                min_amount = Decimal(rule["min_amount"])
                min_notional = min(Decimal(rule["min_price"]) * min_amount, Decimal("0.00000001"))
                min_notional_size=min_notional,

                retval.append(TradingRule(
                    hb_trading_pair,
                    min_order_size=Decimal(rule['min_amount']),
#                    min_order_size=0.1, # this format works ok

                    min_order_value=Decimal(rule['min_amount']) * Decimal(rule['min_price']),
#                    min_order_value=1, # this format works
                    
                    min_price_increment=f"1e-{rule['price_precision']}",
                    #min_price_increment="0.01",

                    min_quote_amount_increment=str(f"1e-{rule['amount_precision']}"),
#                    min_quote_amount_increment="0.01",

                    min_base_amount_increment=str(f"1e-{rule['amount_precision']}"),
#                    min_base_amount_increment="1",

                    min_notional_size=str(min_notional_size),
                    supports_limit_orders=True,
                    supports_market_orders=True
                            ))
                #self.logger().error(f"line 326 TradingRule={TradingRule}")

            except Exception:
                self.logger().error(f"Error parsing the trading pair rule {rule}. Skipping.", exc_info=True)
        return retval


    @property
    def in_flight_orders(self) -> Dict[str, PeatioInFlightOrder]:
        return self._in_flight_orders

    def supported_order_types(self):
        return [OrderType.LIMIT, OrderType.MARKET]

    async def get_order(self, client_order_id: str) -> Dict[str, Any]:
        # Used to retrieve a single order by client_order_id
        path_url = f"/market/orders/{client_order_id}"

        return await self._api_request("GET", path_url=path_url)

    def issue_creation_event(self, exchange_order_id, tracked_order):
        if tracked_order.exchange_order_id is not None:
            # We've already issued this creation event
            return
        tracked_order.update_exchange_order_id(str(exchange_order_id))
        tracked_order.last_state = "PENDING"
        if tracked_order.trade_type is TradeType.SELL:
            cls = SellOrderCreatedEvent
            tag = self.MARKET_SELL_ORDER_CREATED_EVENT_TAG
        else:
            cls = BuyOrderCreatedEvent
            tag = self.MARKET_BUY_ORDER_CREATED_EVENT_TAG

        self.c_trigger_event(tag, cls(
                            self._current_timestamp,
                            tracked_order.order_type,
                            tracked_order.trading_pair,
                            tracked_order.amount,
                            tracked_order.price,
                            tracked_order.client_order_id,
                            tracked_order.creation_timestamp))

        self.logger().info(f"Created {Constants.EXCHANGE_NAME} Order: {tracked_order.exchange_order_id} - {tracked_order.order_type} {tracked_order.trade_type} {tracked_order.client_order_id} for "
                           f"{tracked_order.amount} {tracked_order.trading_pair}.")

    async def _update_order_status(self):
        cdef:
            # This is intended to be a backup measure to close straggler orders, in case Peatio's user stream events
            # are not capturing the updates as intended. Also handles filled events that are not captured by
            # _user_stream_event_listener
            # The poll interval for order status is 10 seconds.
            int64_t last_tick = <int64_t>(self._last_poll_timestamp / self.UPDATE_ORDERS_INTERVAL)
            int64_t current_tick = <int64_t>(self._current_timestamp / self.UPDATE_ORDERS_INTERVAL)

        try:
            if current_tick > last_tick and len(self._in_flight_orders) > 0:
                tracked_orders = list(self._in_flight_orders.values())
                for tracked_order in tracked_orders:
                    client_order_id = tracked_order.client_order_id
                    if tracked_order.last_state == "NEW" and tracked_order.created_at >= (int(time.time()) - self.ORDER_NOT_EXIST_WAIT_TIME):
                        continue  # Don't query for orders that are waiting for a response from the API unless they are older then ORDER_NOT_EXIST_WAIT_TIME
                    try:

                        order = await self.get_order(tracked_order.exchange_order_id)

                    except PeatioAPIException as e:
                        if e.status_code == 404:
                            if (not e.malformed and e.body == 'record.not_found' and
                                    tracked_order.created_at < (int(time.time()) - self.ORDER_NOT_EXIST_WAIT_TIME)):
                                # This was an indeterminate order that may or may not have been live on the exchange
                                # The exchange has informed us that this never became live on the exchange
                                self.c_trigger_event(
                                    self.MARKET_ORDER_FAILURE_EVENT_TAG,
                                    MarketOrderFailureEvent(self._current_timestamp,
                                                            client_order_id,
                                                            tracked_order.order_type)
                                )
                                self.logger().warning(
                                    f"Error fetching status update for the order {client_order_id}: "
                                    f"{tracked_order}. Marking as failed current_timestamp={self._current_timestamp} created_at:{tracked_order.created_at}"
                                )
                                self.c_stop_tracking_order(client_order_id)
                                continue
                        else:
                            self.logger().warning(
                                f"Error fetching status update for the order {client_order_id}:"
                                f" HTTP status: {e.status_code} {'malformed: ' + str(e.malformed) if e.malformed else e.body}. Will try again."
                            )
                            continue

                    if tracked_order.exchange_order_id is None:
                        # This was an indeterminate order that has not yet had a creation event issued
                        self.issue_creation_event(order["id"], tracked_order)

                    order_state = order["state"]
                    order_type = "LIMIT" if tracked_order.order_type is OrderType.LIMIT else "MARKET"
                    trade_type = "BUY" if tracked_order.trade_type is TradeType.BUY else "SELL"

                    order_type_description = tracked_order.order_type
                    executed_amount_diff = s_decimal_0
                    avg_price = Decimal(order["avg_price"])
                    new_confirmed_amount = Decimal(order["executed_volume"])
                    executed_amount_base_diff = new_confirmed_amount - tracked_order.executed_amount_base
                    if executed_amount_base_diff > s_decimal_0:
                        self.logger().info(f"Updated order status with fill from polling _update_order_status: {json.dumps(order)}")
                        new_confirmed_quote_amount = new_confirmed_amount * avg_price
                        executed_amount_quote_diff = new_confirmed_quote_amount - tracked_order.executed_amount_quote
                        executed_price = executed_amount_quote_diff / executed_amount_base_diff

                        tracked_order.executed_amount_base = new_confirmed_amount
                        tracked_order.executed_amount_quote = new_confirmed_quote_amount
                        self.logger().info(f"Filled {executed_amount_base_diff} out of {tracked_order.amount} of the "
                                           f"{order_type} order {tracked_order.client_order_id}.")
                        self.c_trigger_event(self.MARKET_ORDER_FILLED_EVENT_TAG,
                                             OrderFilledEvent(
                                                 self._current_timestamp,
                                                 tracked_order.client_order_id,
                                                 tracked_order.trading_pair,
                                                 tracked_order.trade_type,
                                                 tracked_order.order_type,
                                                 executed_price,
                                                 executed_amount_base_diff,
                                                 self.c_get_fee(
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.order_type,
                                                     tracked_order.trade_type,
                                                     executed_price,
                                                     executed_amount_base_diff
                                                 )
                                             ))

                    if order_state == "done":
                        tracked_order.last_state = "done"
                        self.logger().info(f"The {order_type}-{trade_type} "
                                           f"{client_order_id} has completed according to {Constants.EXCHANGE_NAME} order status API.")

                        if tracked_order.trade_type is TradeType.BUY:
                            self.c_trigger_event(self.MARKET_BUY_ORDER_COMPLETED_EVENT_TAG,
                                                 BuyOrderCompletedEvent(
                                                     self._current_timestamp,
                                                     tracked_order.client_order_id,
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.fee_asset or tracked_order.base_asset,
                                                     tracked_order.executed_amount_base,
                                                     tracked_order.executed_amount_quote,
                                                     tracked_order.fee_paid,
                                                     tracked_order.order_type))
                        elif tracked_order.trade_type is TradeType.SELL:
                            self.c_trigger_event(self.MARKET_SELL_ORDER_COMPLETED_EVENT_TAG,
                                                 SellOrderCompletedEvent(
                                                     self._current_timestamp,
                                                     tracked_order.client_order_id,
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.fee_asset or tracked_order.base_asset,
                                                     tracked_order.executed_amount_base,
                                                     tracked_order.executed_amount_quote,
                                                     tracked_order.fee_paid,
                                                     tracked_order.order_type))
                        else:
                            raise ValueError("Invalid trade_type for {client_order_id}: {tracked_order.trade_type}")
                        self.c_stop_tracking_order(client_order_id)

                    if order_state == "cancel":
                        tracked_order.last_state = "cancel"
                        self.logger().info(f"The {tracked_order.order_type}-{tracked_order.trade_type} "
                                           f"{client_order_id} has been cancelled according to {Constants.EXCHANGE_NAME} order status API.")
                        self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                             OrderCancelledEvent(
                                                 self._current_timestamp,
                                                 client_order_id
                                             ))
                        self.c_stop_tracking_order(client_order_id)

                    if order_state == 'reject':
                        tracked_order.last_state = order_state
                        self.c_trigger_event(
                            self.MARKET_ORDER_FAILURE_EVENT_TAG,
                            MarketOrderFailureEvent(self._current_timestamp,
                                                    client_order_id,
                                                    tracked_order.order_type)
                        )
                        self.logger().info(f"The {tracked_order.order_type}-{tracked_order.trade_type} "
                                           f"{client_order_id} has been rejected according to {Constants.EXCHANGE_NAME} order status API.")
                        self.c_stop_tracking_order(client_order_id)

        except Exception as e:
            self.logger().error("Update Order Status Error: " + str(e) + " " + str(e.__cause__))

    async def _iter_user_stream_queue(self) -> AsyncIterable[Dict[str, Any]]:
        while True:
            try:
                yield await self._user_stream_tracker.user_stream.get()
            except asyncio.CancelledError:
                raise
            except Exception:
                self.logger().error("Unknown error. Retrying after 1 second.", exc_info=True)
                await asyncio.sleep(1.0)

    async def _user_stream_event_listener(self):
        async for stream_message in self._iter_user_stream_queue():
            try:
                if 'balance' in stream_message:  # Updates balances
                    balance_updates = stream_message['balance']
                    for update in balance_updates:
                        available_balance: Decimal = Decimal(update['balance'])
                        total_balance: Decimal = available_balance + Decimal(update['locked'])
                        asset_name = update["currency"].upper()
                        self._account_available_balances[asset_name] = available_balance
                        self._account_balances[asset_name] = total_balance

                elif 'order' in stream_message:  # Updates tracked orders
                    order = stream_message.get('order')
                    order_status = order["state"]
                    order_id = order["id"]

                    in_flight_orders = self._in_flight_orders.copy()
                    tracked_order = in_flight_orders.get(order_id)

                    if tracked_order is None:
                        self.logger().debug(f"Unrecognized order ID from user stream: {order_id}.")
                        continue

                    if tracked_order.exchange_order_id is None:
                        # This was an indeterminate order that has not yet had a creation event issued
                        self.issue_creation_event(order["id"], tracked_order)

                    order_type = tracked_order.order_type
                    executed_amount_diff = s_decimal_0
                    avg_price = Decimal(order["avg_price"])
                    new_confirmed_amount = Decimal(order["executed_volume"])
                    executed_amount_base_diff = new_confirmed_amount - tracked_order.executed_amount_base
                    if executed_amount_base_diff > s_decimal_0:
                        new_confirmed_quote_amount = new_confirmed_amount * avg_price
                        executed_amount_quote_diff = new_confirmed_quote_amount - tracked_order.executed_amount_quote
                        executed_price = executed_amount_quote_diff / executed_amount_base_diff

                        tracked_order.executed_amount_base = new_confirmed_amount
                        tracked_order.executed_amount_quote = new_confirmed_quote_amount
                        tracked_order.last_state = order_status
                        self.logger().info(f"Filled {executed_amount_base_diff} out of {tracked_order.amount} of the "
                                           f"{order_type} order {tracked_order.client_order_id}.")
                        self.c_trigger_event(self.MARKET_ORDER_FILLED_EVENT_TAG,
                                             OrderFilledEvent(
                                                 self._current_timestamp,
                                                 tracked_order.client_order_id,
                                                 tracked_order.trading_pair,
                                                 tracked_order.trade_type,
                                                 tracked_order.order_type,
                                                 executed_price,
                                                 executed_amount_base_diff,
                                                 self.c_get_fee(
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.order_type,
                                                     tracked_order.trade_type,
                                                     executed_price,
                                                     executed_amount_base_diff
                                                 )
                                             ))

                    if order_status == "done":  # FILL(COMPLETE)
                        self.logger().info(f"The order "
                                           f"{tracked_order.client_order_id} has completed according to {Constants.EXCHANGE_NAME} User stream.")
                        tracked_order.last_state = "done"
                        if tracked_order.trade_type is TradeType.BUY:
                            self.logger().info(f"The LIMIT_BUY order {tracked_order.client_order_id} has completed "
                                               f"according to {Constants.EXCHANGE_NAME} websocket API.")
                            self.c_trigger_event(self.MARKET_BUY_ORDER_COMPLETED_EVENT_TAG,
                                                 BuyOrderCompletedEvent(
                                                     self._current_timestamp,
                                                     tracked_order.client_order_id,
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.fee_asset or tracked_order.quote_asset,
                                                     tracked_order.executed_amount_base,
                                                     tracked_order.executed_amount_quote,
                                                     tracked_order.fee_paid,
                                                     tracked_order.order_type
                                                 ))
                        elif tracked_order.trade_type is TradeType.SELL:
                            self.logger().info(f"The LIMIT_SELL order {tracked_order.client_order_id} has completed "
                                               f"according to {Constants.EXCHANGE_NAME} WebSocket API.")
                            self.c_trigger_event(self.MARKET_SELL_ORDER_COMPLETED_EVENT_TAG,
                                                 SellOrderCompletedEvent(
                                                     self._current_timestamp,
                                                     tracked_order.client_order_id,
                                                     tracked_order.base_asset,
                                                     tracked_order.quote_asset,
                                                     tracked_order.fee_asset or tracked_order.quote_asset,
                                                     tracked_order.executed_amount_base,
                                                     tracked_order.executed_amount_quote,
                                                     tracked_order.fee_paid,
                                                     tracked_order.order_type
                                                 ))
                        else:
                            raise ValueError("Invalid trade_type for {tracked_order.client_order_id}: {tracked_order.trade_type}")
                        self.c_stop_tracking_order(tracked_order.client_order_id)
                        continue

                    if order_status == "cancel":  # CANCEL

                        self.logger().info(f"{Constants.EXCHANGE_NAME} order {tracked_order.client_order_id} has been cancelled "
                                           f"according to {Constants.EXCHANGE_NAME} WebSocket API.")
                        tracked_order.last_state = "cancel"
                        self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG,
                                             OrderCancelledEvent(self._current_timestamp,
                                                                 tracked_order.client_order_id))
                        self.c_stop_tracking_order(tracked_order.client_order_id)

                    if order_status == 'reject':
                        tracked_order.last_state = order_status
                        self.c_trigger_event(
                            self.MARKET_ORDER_FAILURE_EVENT_TAG,
                            MarketOrderFailureEvent(self._current_timestamp,
                                                    tracked_order.client_order_id,
                                                    tracked_order.order_type)
                        )
                        self.logger().info(f"{Constants.EXCHANGE_NAME} order {tracked_order.client_order_id} has been rejected "
                                           f"according to {Constants.EXCHANGE_NAME} WebSocket API.")
                        self.c_stop_tracking_order(tracked_order.client_order_id)

                else:
                    # Ignores all other user stream message types
                    continue

            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.logger().error("Unexpected error in {Constants.EXCHANGE_NAME} user stream listener loop. {e}", exc_info=True)
                await asyncio.sleep(5.0)

    async def _status_polling_loop(self):
        while True:
            try:
                self._poll_notifier = asyncio.Event()
                await self._poll_notifier.wait()

                await safe_gather(
                    self._update_balances(),
                    self._update_order_status(),
                )
                self._last_poll_timestamp = self._current_timestamp
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.logger().warning(f"Unexpected error while polling {Constants.EXCHANGE_NAME} updates. {e}", exc_info=True)
                await asyncio.sleep(5.0)

    async def _trading_rules_polling_loop(self):
        while True:
            try:
                await self._update_trading_rules()
                await asyncio.sleep(60 * 5)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.logger().warning(f"Unexpected error while fetching {Constants.EXCHANGE_NAME} trading rule updates. {e}", exc_info=True)
                await asyncio.sleep(0.5)

    async def _update_trading_rules(self):
        cdef:
            # The poll interval for withdraw rules is 60 seconds.
            int64_t last_tick = <int64_t>(self._last_timestamp / 60.0)
            int64_t current_tick = <int64_t>(self._current_timestamp / 60.0)
            
        if current_tick > last_tick or len(self._trading_rules) < 1:
            #exchange_info = await self.query_api(self._openware_client.get_markets)
            #exchange_info = self._openware_client.get_markets()
            #return self._get('/public/markets')
            path_url = Constants.EXCHANGE_INFO_URL
            exchange_info = await self._api_request("GET", path_url=path_url)

            trading_rules_list = self._format_trading_rules(exchange_info)
            self._trading_rules.clear()
            for trading_rule in trading_rules_list:
                self._trading_rules[trading_rule.trading_pair] = trading_rule

    cdef OrderBook c_get_order_book(self, str trading_pair):
        cdef:
            dict order_books = self._order_book_tracker.order_books

        if trading_pair not in order_books:
            raise ValueError(f"No {Constants.EXCHANGE_NAME} order book exists for '{trading_pair}'.")
        return order_books[trading_pair]

    cdef c_start_tracking_order(self,
                                str order_id,
                                str exchange_order_id,
                                str trading_pair,
                                object order_type,
                                object trade_type,
                                object price,
                                object amount):
        self._in_flight_orders[order_id] = PeatioInFlightOrder(
            order_id,
            exchange_order_id,
            trading_pair,
            order_type,
            trade_type,
            price,
            amount,
            int(time.time())
        )

    cdef c_stop_tracking_order(self, str order_id):
        if order_id in self._in_flight_orders:
            del self._in_flight_orders[order_id]

    cdef c_did_timeout_tx(self, str tracking_id):
        self.c_trigger_event(self.MARKET_TRANSACTION_FAILURE_EVENT_TAG, MarketTransactionFailureEvent(self._current_timestamp, tracking_id))

    cdef object c_get_order_price_quantum(self, str trading_pair, object price):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            
        return Decimal(trading_rule.min_price_increment)

    cdef object c_get_order_size_quantum(self, str trading_pair, object order_size):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]

        return Decimal(trading_rule.min_base_amount_increment)

    cdef object c_quantize_order_amount(self, str trading_pair, object amount, object price=0.0):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]

            object quantized_amount = ExchangeBase.c_quantize_order_amount(self, trading_pair, amount)

        global s_decimal_0
        if quantized_amount < trading_rule.min_order_size:
            return s_decimal_0

        if quantized_amount < trading_rule.min_order_value:
            return s_decimal_0

        return quantized_amount

    async def place_order(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          is_buy: bool,
                          order_type: OrderType,
                          price: Decimal) -> Dict[str, Any]:
        path_url = Constants.GET_ORDERS

        market_str = convert_to_exchange_trading_pair(trading_pair)

        if amount.is_nan() : amount = Decimal("0")
        amount_str = f"{amount:f}"

        if price.is_nan() : price = Decimal("0")
        price_str = f"{price:f}"

        side_str = "buy" if is_buy else "sell"

        params = {}
        if order_type is OrderType.LIMIT:  # Peatio supports CEILING_LIMIT
            params = {
                "market": f"{market_str}",
                "side": f"{side_str}",
                "volume": f"{amount_str}",
                "ord_type": "limit",
                "price": f"{price_str}"
            }
        elif order_type is OrderType.MARKET:
            params = {
                "market": f"{market_str}",
                "side": f"{side_str}",
                "volume": f"{amount_str}",
                "ord_type": "market"
            }

        self.logger().info(f"Request {Constants.EXCHANGE_NAME} order placement for {side_str} {amount_str} {market_str} {order_id} at {self._current_timestamp}")

        api_response = await self._api_request("POST", path_url=path_url, params=params)

        return api_response

    async def execute_buy(self,
                          order_id: str,
                          trading_pair: str,
                          amount: Decimal,
                          order_type: OrderType,
                          price: Optional[Decimal] = s_decimal_0):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            double quote_amount
            object decimal_amount
            object decimal_price
            str exchange_order_id
            object tracked_order

        decimal_amount = self.c_quantize_order_amount(trading_pair, amount)
        decimal_price = (self.c_quantize_order_price(trading_pair, price)
                         if order_type is OrderType.LIMIT
                         else s_decimal_0)

        self.logger().info(f"execute_buy -  amount={amount:.4f}, price={price:.4f}, quote_amount={quote_amount:.4f}, decimal_amount={decimal_amount:.4f}, decimal_price={decimal_price:.4f}")
        #INFO - execute_buy -  amount=1.0000, price=4390.0000, quote_amount=0.0000, decimal_amount=1.0000, decimal_price=4390.0000

        if decimal_amount < Decimal(trading_rule.min_order_size):
            raise ValueError(f"Buy order amount {decimal_amount} is lower than the minimum order size {trading_rule.min_order_size}.")

        try:
            order_result = None
            self.c_start_tracking_order(
                order_id,
                None,
                trading_pair,
                order_type,
                TradeType.BUY,
                decimal_price,
                decimal_amount,
            )

            if order_type is OrderType.LIMIT:
                order_result = await self.place_order(order_id,
                                                      trading_pair,
                                                      decimal_amount,
                                                      True,
                                                      order_type,
                                                      decimal_price)
            elif order_type is OrderType.MARKET:
                decimal_price = self.c_get_price(trading_pair, True)
                order_result = await self.place_order(order_id,
                                                      trading_pair,
                                                      decimal_amount,
                                                      True,
                                                      order_type,
                                                      decimal_price)

            else:
                raise ValueError(f"Invalid {Constants.EXCHANGE_NAME} OrderType {order_type}. Aborting.")

#           PMC This is the number of the new Order created in Peatio
            exchange_order_id = str(order_result.get("id"))

            tracked_order = self._in_flight_orders.get(order_id)

            if tracked_order is not None and exchange_order_id is not None:
                self.issue_creation_event(exchange_order_id, tracked_order)
            else:
                self.logger().error(f"Unable to issue {Constants.EXCHANGE_NAME} creation event for {order_id}: {tracked_order} {exchange_order_id}")
        except asyncio.TimeoutError:
            self.logger().error(f"Network timout while submitting order {order_id} to {Constants.EXCHANGE_NAME}. Order will be recovered.")
        except Exception:
            self.logger().error(
                f"Error submitting {order_id}: buy {order_type} order to {Constants.EXCHANGE_NAME} for "
                f"{decimal_amount} {trading_pair} "
                f"{decimal_price if order_type.is_limit_type() else ''}.",
                exc_info=True
            )
            tracked_order = self._in_flight_orders.get(order_id)
            tracked_order.last_state = "FAILURE"
            tracked_order.update_exchange_order_id("0")  # prevents deadlock on get_exchange_order_id()

            self.c_stop_tracking_order(order_id)
            
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG, MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_buy(self,
                   str trading_pair,
                   object amount,
                   object order_type=OrderType.LIMIT,
                   object price=s_decimal_NaN,
                   dict kwargs={}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
#            self.logger().info(f"Line 917 - c_buy -  trading_pair={trading_pair}, amount={amount:.4f}, price={price:.4f}")

            str order_id = str(f"buy-{trading_pair}-{tracking_nonce}")

        safe_ensure_future(self.execute_buy(order_id, trading_pair, amount, order_type, price))

        return order_id

    async def execute_sell(self,
                           order_id: str,
                           trading_pair: str,
                           amount: Decimal,
                           order_type: OrderType = OrderType.LIMIT,
                           price: Optional[Decimal] = s_decimal_NaN):
        cdef:
            TradingRule trading_rule = self._trading_rules[trading_pair]
            double quote_amount
            object decimal_amount
            object decimal_price
            str exchange_order_id
            object tracked_order

        decimal_amount = self.c_quantize_order_amount(trading_pair, amount)
        decimal_price = (self.c_quantize_order_price(trading_pair, price)
                         if order_type is OrderType.LIMIT
                         else s_decimal_0)

        if decimal_amount < Decimal(trading_rule.min_order_size):
            raise ValueError(f"Sell order amount {decimal_amount} is lower than the {Constants.EXCHANGE_NAME} minimum order size {trading_rule.min_order_size}")

        try:
            order_result = None

            self.c_start_tracking_order(
                order_id,
                None,
                trading_pair,
                order_type,
                TradeType.SELL,
                decimal_price,
                decimal_amount,
            )

            if order_type is OrderType.LIMIT:
                order_result = await self.place_order(order_id,
                                                      trading_pair,
                                                      decimal_amount,
                                                      False,
                                                      order_type,
                                                      decimal_price)
            elif order_type is OrderType.MARKET:
                decimal_price = self.c_get_price(trading_pair, False)
                order_result = await self.place_order(order_id,
                                                      trading_pair,
                                                      decimal_amount,
                                                      False,
                                                      order_type,
                                                      decimal_price)
            else:
                raise ValueError(f"Invalid OrderType {order_type}. Aborting.")

            exchange_order_id = str(order_result.get("id"))
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is not None and exchange_order_id is not None:
                self.issue_creation_event(exchange_order_id, tracked_order)
            else:
                self.logger().error(f"Unable to issue creation event for {order_id}: {tracked_order} {exchange_order_id}")
        except asyncio.TimeoutError:
            self.logger().error(f"Network timout while submitting order {order_id} to {Constants.EXCHANGE_NAME}. Order will be recovered.")
        except Exception:
            self.logger().error(
                f"Error submitting {order_id}: sell {order_type} order to {Constants.EXCHANGE_NAME} for "
                f"{decimal_amount} {trading_pair} "
                f"{decimal_price if order_type.is_limit_type() else ''}.",
                exc_info=True,
            )
            tracked_order = self._in_flight_orders.get(order_id)
            tracked_order.last_state = "FAILURE"
            tracked_order.update_exchange_order_id("0")  # prevents deadlock on get_exchange_order_id()
            self.c_stop_tracking_order(order_id)
            self.c_trigger_event(self.MARKET_ORDER_FAILURE_EVENT_TAG, MarketOrderFailureEvent(self._current_timestamp, order_id, order_type))

    cdef str c_sell(self,
                    str trading_pair,
                    object amount,
                    object order_type=OrderType.MARKET,
                    object price=0.0,
                    dict kwargs={}):
        cdef:
            int64_t tracking_nonce = <int64_t> get_tracking_nonce()
            str order_id = str(f"sell-{trading_pair}-{tracking_nonce}")

        safe_ensure_future(self.execute_sell(order_id, trading_pair, amount, order_type, price))
        return order_id

    async def execute_cancel(self, trading_pair: str, order_id: str):
        try:
            tracked_order = self._in_flight_orders.get(order_id)
            if tracked_order is None:
                self.logger().error(f"The order {order_id} is not tracked. ")
                raise ValueError

            path_url = f"{Constants.GET_ORDERS}/{tracked_order.exchange_order_id}/cancel"

#            self.logger().info(f"execute_cancel path_url = {path_url}, order_id = {order_id}, tracked_order.exchange_order_id = {tracked_order.exchange_order_id} ")
            self.logger().info(f"Peatio execute_cancel order_id = {order_id}, tracked_order.exchange_order_id = {tracked_order.exchange_order_id} ")

            cancel_result = await self._api_request("POST", path_url=path_url)

            # TODO: this cancel result looks like:
            # {"id":4699083,"uuid":"2421ceb6-a8b7-445b-9ca9-0f7f1a05e285","side":"buy","ord_type":"limit","price":"0.02","avg_price":"0.0","state":"cancel","market":"ethbtc","created_at":"2020-09-09T18:53:56+02:00","updated_at":"2020-09-09T18:56:41+02:00","origin_volume":"1.0","remaining_volume":"1.0","executed_volume":"0.0","trades_count":0}
            # and should be used as an order status update

            return order_id
        except asyncio.CancelledError:
            raise
        except Exception as err:
            if ("record.not_found" in str(err) and tracked_order is not None and
                    tracked_order.created_at < (int(time.time()) - self.ORDER_NOT_EXIST_WAIT_TIME)):
                # The order doesn't exist
                self.logger().info(f"The order {order_id} does not exist on {Constants.EXCHANGE_NAME}. Marking as cancelled.")
                self.c_stop_tracking_order(order_id)
                self.c_trigger_event(self.MARKET_ORDER_CANCELLED_EVENT_TAG, OrderCancelledEvent(self._current_timestamp, order_id))
                return order_id

            self.logger().error(
                f"Failed to cancel {Constants.EXCHANGE_NAME} order {order_id}: {str(err)}.", exc_info=True
            )
        return None

    cdef c_cancel(self, str trading_pair, str order_id):
        safe_ensure_future(self.execute_cancel(trading_pair, order_id))
        return order_id

    def cancel(self, trading_pair: str, client_order_id: str):
        return self.c_cancel(trading_pair, client_order_id)

    async def cancel_all(self, timeout_seconds: float) -> List[CancellationResult]:
        incomplete_orders = [order for order in self._in_flight_orders.values() if not order.is_done]
        tasks = [self.execute_cancel(o.trading_pair, o.client_order_id) for o in incomplete_orders]
        order_id_set = set([o.client_order_id for o in incomplete_orders])
        successful_cancellation = []

        try:
            async with timeout(timeout_seconds):
                api_responses = await safe_gather(*tasks, return_exceptions=True)
                for res in api_responses:
                    order_id_set.remove(res)
                    successful_cancellation.append(CancellationResult(res, True))
        except Exception as e:
            self.logger().error(
                f"Unexpected error cancelling orders. {e}"
            )

        failed_cancellation = [CancellationResult(oid, False) for oid in order_id_set]
        return successful_cancellation + failed_cancellation

    async def _http_client(self) -> aiohttp.ClientSession:
        if self._shared_client is None:
            self._shared_client = aiohttp.ClientSession()
        return self._shared_client

    async def _api_request(self,
                           http_method: str,
                           path_url: str = None,
                           params: Dict[str, any] = None,
                           body: Dict[str, any] = None,
                           subaccount_id: str = '') -> Dict[str, Any]:
        assert path_url is not None

        url = f"{Constants.REST_URL}{path_url}"

        content_type = "application/json" if http_method == "post" else "application/x-www-form-urlencoded"
        headers = {"Content-Type": content_type}
        headers = self.peatio_auth.generate_auth_dict()

        client = await self._http_client()
        async with client.request(http_method,
                                  url=url,
                                  headers=headers,
                                  params=params,
                                  data=body,
                                  timeout=Constants.API_CALL_TIMEOUT) as response:

            try:

                data = await response.json(content_type=None)

                #self.logger().info(f"Line 1075 _api_request await url={url}, url response.json data={data}")

            except Exception as e:
                raise PeatioAPIException(f"Malformed response. Expected JSON got: {await response.text()}", status_code=response.status, malformed=True)

            if response.status not in [200, 201]:  # HTTP Response code of 20X generally means it is successful
                try:
                    error_msg = data['errors'][0]
                except Exception:
                    error_msg = await response.text()
                raise PeatioAPIException(f"Error fetching response from {http_method}-{url}. HTTP Status Code {response.status}: ", status_code=response.status, body=error_msg)

            return data

    async def check_network(self) -> NetworkStatus:
        try:
            await self._api_request("GET", path_url="/public/health/alive")
        except asyncio.CancelledError:
            raise
        except Exception:
            return NetworkStatus.NOT_CONNECTED
        return NetworkStatus.CONNECTED

    def _stop_network(self):
        self._order_book_tracker.stop()
        if self._status_polling_task is not None:
            self._status_polling_task.cancel()
        if self._user_stream_tracker_task is not None:
            self._user_stream_tracker_task.cancel()
        if self._user_stream_event_listener_task is not None:
            self._user_stream_event_listener_task.cancel()
        self._status_polling_task = self._user_stream_tracker_task = \
            self._user_stream_event_listener_task = None

    async def stop_network(self):
        self._stop_network()

    async def start_network(self):
        self._stop_network()
        self._order_book_tracker.start()
        self._trading_rules_polling_task = safe_ensure_future(self._trading_rules_polling_loop())
        if self._trading_required:
            self._status_polling_task = safe_ensure_future(self._status_polling_loop())
            self._user_stream_tracker_task = safe_ensure_future(self._user_stream_tracker.start())
            self._user_stream_event_listener_task = safe_ensure_future(self._user_stream_event_listener())

    def get_order_book(self, trading_pair: str) -> OrderBook:
        return self.c_get_order_book(trading_pair)

    def get_price(self, trading_pair: str, is_buy: bool) -> Decimal:
        return self.c_get_price(trading_pair, is_buy)

    def buy(self, trading_pair: str, amount: Decimal, order_type=OrderType.MARKET,
            price: Decimal = s_decimal_NaN, **kwargs) -> str:
        return self.c_buy(trading_pair, amount, order_type, price, kwargs)

    def sell(self, trading_pair: str, amount: Decimal, order_type=OrderType.MARKET,
             price: Decimal = s_decimal_NaN, **kwargs) -> str:
        return self.c_sell(trading_pair, amount, order_type, price, kwargs)

    def cancel(self, trading_pair: str, client_order_id: str):
        return self.c_cancel(trading_pair, client_order_id)

    def get_fee(self,
                base_currency: str,
                quote_currency: str,
                order_type: OrderType,
                order_side: TradeType,
                amount: Decimal,
                price: Decimal = s_decimal_NaN) -> AddedToCostTradeFee:
#        return self.c_get_fee(base_currency, quote_currency, order_type, order_side, amount, price)
        return Decimal(0)


