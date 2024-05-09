import os
import time
from typing import Dict, List, Optional, Set

from pydantic import Field

from hummingbot.client.hummingbot_application import HummingbotApplication
from hummingbot.connector.connector_base import ConnectorBase
from hummingbot.core.clock import Clock
from hummingbot.data_feed.candles_feed.candles_factory import CandlesConfig
from hummingbot.smart_components.models.base import SmartComponentStatus
from hummingbot.smart_components.models.executor_actions import CreateExecutorAction, StopExecutorAction
from hummingbot.strategy.strategy_v2_base import StrategyV2Base, StrategyV2ConfigBase


class GenericV2StrategyWithCashOutConfig(StrategyV2ConfigBase):
    script_file_name: str = Field(default_factory=lambda: os.path.basename(__file__))
    candles_config: List[CandlesConfig] = []
    markets: Dict[str, Set[str]] = {}
    time_to_cash_out: Optional[int] = None


class GenericV2StrategyWithCashOut(StrategyV2Base):
    """
    This script runs a generic strategy with cash out feature. Will also check if the controllers configs have been
    updated and apply the new settings.
    The cash out of the script can be set by the time_to_cash_out parameter in the config file. If set, the script will
    stop the controllers after the specified time has passed, and wait until the active executors finalize their
    execution.
    The controllers will also have a parameter to manually cash out. In that scenario, the main strategy will stop the
    specific controller and wait until the active executors finalize their execution. The rest of the executors will
    wait until the main strategy stops them.
    """
    def __init__(self, connectors: Dict[str, ConnectorBase], config: GenericV2StrategyWithCashOutConfig):
        super().__init__(connectors, config)
        self.config = config
        self.cashing_out = False
        self.closed_executors_buffer: int = 20
        if self.config.time_to_cash_out:
            self.cash_out_time = self.config.time_to_cash_out + time.time()
        else:
            self.cash_out_time = None

    def start(self, clock: Clock, timestamp: float) -> None:
        """
        Start the strategy.
        :param clock: Clock to use.
        :param timestamp: Current time.
        """
        self._last_timestamp = timestamp
        self.apply_initial_setting()

    def on_tick(self):
        super().on_tick()
        self.control_cash_out()

    def control_cash_out(self):
        self.evaluate_cash_out_time()
        if self.cashing_out:
            self.check_executors_status()
        else:
            self.check_manual_cash_out()

    def evaluate_cash_out_time(self):
        if self.cash_out_time and self.current_timestamp >= self.cash_out_time and not self.cashing_out:
            self.logger().info("Cash out time reached. Stopping the controllers.")
            for controller_id, controller in self.controllers.items():
                if controller.status == SmartComponentStatus.RUNNING:
                    self.logger().info(f"Cash out for controller {controller_id}.")
                    controller.stop()
            self.cashing_out = True

    def check_manual_cash_out(self):
        for controller_id, controller in self.controllers.items():
            if controller.config.manual_kill_switch and controller.status == SmartComponentStatus.RUNNING:
                self.logger().info(f"Manual cash out for controller {controller_id}.")
                controller.stop()
                executors_to_stop = self.get_executors_by_controller(controller_id)
                self.executor_orchestrator.execute_actions(
                    [StopExecutorAction(executor_id=executor.id,
                                        controller_id=executor.controller_id) for executor in executors_to_stop])
            if not controller.config.manual_kill_switch and controller.status == SmartComponentStatus.TERMINATED:
                self.logger().info(f"Restarting controller {controller_id}.")
                controller.start()

    def check_executors_status(self):
        active_executors = self.filter_executors(
            executors=self.get_all_executors(),
            filter_func=lambda executor: executor.status == SmartComponentStatus.RUNNING
        )
        if not active_executors:
            self.logger().info("All executors have finalized their execution. Stopping the strategy.")
            HummingbotApplication.main_application().stop()
        else:
            non_trading_executors = self.filter_executors(
                executors=active_executors,
                filter_func=lambda executor: not executor.is_trading
            )
            self.executor_orchestrator.execute_actions(
                [StopExecutorAction(executor_id=executor.id,
                                    controller_id=executor.controller_id) for executor in non_trading_executors])

    def create_actions_proposal(self) -> List[CreateExecutorAction]:
        return []

    def stop_actions_proposal(self) -> List[StopExecutorAction]:
        return []

    def apply_initial_setting(self):
        for controller_id, controller in self.controllers.items():
            config_dict = controller.config.dict()
            if "connector_name" in config_dict:
                if self.is_perpetual(config_dict["connector_name"]):
                    if "position_mode" in config_dict:
                        self.connectors[config_dict["connector_name"]].set_position_mode(config_dict["position_mode"])
                    if "leverage" in config_dict:
                        self.connectors[config_dict["connector_name"]].set_leverage(leverage=config_dict["leverage"],
                                                                                    trading_pair=config_dict["trading_pair"])
