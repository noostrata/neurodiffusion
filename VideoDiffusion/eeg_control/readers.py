#!/usr/bin/env python3
"""EEG readers for mock, BrainFlow, and optional LSL input."""

from __future__ import annotations

import argparse
import math
import platform
import time
from collections import deque
from dataclasses import dataclass
from typing import Protocol

import numpy as np


class EegReader(Protocol):
    sampling_rate: float
    channel_count: int

    def start(self) -> None:
        ...

    def stop(self) -> None:
        ...

    def get_window(self, sample_count: int) -> np.ndarray | None:
        ...


class ReaderContext:
    def __init__(self, reader: EegReader):
        self.reader = reader

    def __enter__(self) -> EegReader:
        self.reader.start()
        return self.reader

    def __exit__(self, exc_type, exc, tb) -> None:
        self.reader.stop()


@dataclass
class MockEegReader:
    scenario: str = "alternating"
    sampling_rate: float = 250.0
    channel_count: int = 4
    seed: int = 7

    def __post_init__(self) -> None:
        self._started_at = 0.0
        self._rng = np.random.default_rng(self.seed)

    def start(self) -> None:
        self._started_at = time.monotonic()

    def stop(self) -> None:
        pass

    def _mode_for_elapsed(self, elapsed_s: float) -> str:
        if self.scenario != "alternating":
            return self.scenario
        phase = elapsed_s % 24.0
        if phase < 8.0:
            return "calm"
        if phase < 16.0:
            return "active"
        return "switch"

    def get_window(self, sample_count: int) -> np.ndarray | None:
        elapsed = max(0.0, time.monotonic() - self._started_at)
        mode = self._mode_for_elapsed(elapsed)
        start_t = max(0.0, elapsed - (sample_count / self.sampling_rate))
        t = start_t + (np.arange(sample_count, dtype=float) / self.sampling_rate)

        noise = self._rng.normal(0.0, 4.0, size=(self.channel_count, sample_count))
        data = noise

        if mode == "calm":
            alpha = 30.0 * np.sin(2.0 * math.pi * 10.0 * t)
            beta = 5.0 * np.sin(2.0 * math.pi * 20.0 * t)
            data += alpha[None, :] + beta[None, :]
        elif mode == "active":
            alpha = 6.0 * np.sin(2.0 * math.pi * 10.0 * t)
            beta = 24.0 * np.sin(2.0 * math.pi * 22.0 * t)
            data += alpha[None, :] + beta[None, :]
        elif mode in {"switch", "blink", "clench"}:
            alpha = 10.0 * np.sin(2.0 * math.pi * 9.0 * t)
            burst_center = t[-1] - 0.25
            burst = 160.0 * np.exp(-((t - burst_center) ** 2) / 0.015)
            data += alpha[None, :] + burst[None, :]
        else:
            data += 10.0 * np.sin(2.0 * math.pi * 12.0 * t)[None, :]

        return data


class BrainFlowReader:
    def __init__(
        self,
        board: str,
        *,
        serial_port: str = "",
        mac_address: str = "",
        serial_number: str = "",
        ip_address: str = "",
        ip_port: int = 0,
        timeout: int = 0,
        other_info: str = "",
        streamer_params: str = "",
        buffer_size: int = 450000,
    ):
        self.board = board
        self.serial_port = serial_port
        self.mac_address = mac_address
        self.serial_number = serial_number
        self.ip_address = ip_address
        self.ip_port = ip_port
        self.timeout = timeout
        self.other_info = other_info
        self.streamer_params = streamer_params
        self.buffer_size = buffer_size
        self._board_shim = None
        self._eeg_channels: list[int] = []
        self.sampling_rate = 0.0
        self.channel_count = 0

    def _brainflow_board_id(self):
        from brainflow.board_shim import BoardIds

        mapping = {
            "synthetic": BoardIds.SYNTHETIC_BOARD,
            "cyton": BoardIds.CYTON_BOARD,
            "cyton-daisy": BoardIds.CYTON_DAISY_BOARD,
            "ganglion": BoardIds.GANGLION_NATIVE_BOARD,
            "ganglion-wifi": BoardIds.GANGLION_WIFI_BOARD,
            "cyton-wifi": BoardIds.CYTON_WIFI_BOARD,
            "cyton-daisy-wifi": BoardIds.CYTON_DAISY_WIFI_BOARD,
        }
        if self.board not in mapping:
            raise ValueError(f"Unsupported BrainFlow board: {self.board}")
        board_id = mapping[self.board]
        return int(board_id.value if hasattr(board_id, "value") else board_id)

    def _validate_params(self) -> None:
        serial_boards = {"cyton", "cyton-daisy"}
        if self.board in serial_boards and not self.serial_port:
            raise ValueError(f"{self.board} requires --serial-port")
        if (
            platform.system() == "Darwin"
            and self.board in serial_boards
            and self.serial_port.startswith("/dev/tty.")
        ):
            raise ValueError("On macOS, BrainFlow/OpenBCI requires the /dev/cu.* port, not /dev/tty.*")
        wifi_boards = {"ganglion-wifi", "cyton-wifi", "cyton-daisy-wifi"}
        if self.board in wifi_boards and not self.ip_port:
            raise ValueError(f"{self.board} requires --ip-port; --ip-address is optional for discovery")

    def start(self) -> None:
        from brainflow.board_shim import BoardShim, BrainFlowInputParams

        self._validate_params()
        board_id = self._brainflow_board_id()
        params = BrainFlowInputParams()
        params.serial_port = self.serial_port
        params.mac_address = self.mac_address
        params.serial_number = self.serial_number
        params.ip_address = self.ip_address
        params.ip_port = int(self.ip_port)
        params.timeout = int(self.timeout)
        params.other_info = self.other_info

        board = BoardShim(board_id, params)
        try:
            board.prepare_session()
            if self.streamer_params:
                board.start_stream(int(self.buffer_size), self.streamer_params)
            else:
                board.start_stream(int(self.buffer_size))
        except Exception:
            if board.is_prepared():
                board.release_session()
            raise
        self._board_shim = board
        actual_board_id = int(board.get_board_id())
        self._eeg_channels = list(BoardShim.get_eeg_channels(actual_board_id))
        try:
            self.sampling_rate = float(board.get_board_sampling_rate())
        except Exception:
            self.sampling_rate = float(BoardShim.get_sampling_rate(actual_board_id))
        self.channel_count = len(self._eeg_channels)

    def stop(self) -> None:
        board = self._board_shim
        if board is None:
            return
        try:
            if board.is_prepared():
                board.stop_stream()
                board.release_session()
        finally:
            self._board_shim = None

    def get_window(self, sample_count: int) -> np.ndarray | None:
        if self._board_shim is None:
            raise RuntimeError("BrainFlowReader is not started")
        data = self._board_shim.get_current_board_data(sample_count)
        if data.shape[1] < sample_count:
            return None
        return np.asarray(data[self._eeg_channels, :], dtype=float)


class LslEegReader:
    def __init__(
        self,
        *,
        stream_type: str = "EEG",
        stream_name: str = "",
        nominal_srate: float = 250.0,
        timeout_s: float = 10.0,
    ):
        self.stream_type = stream_type
        self.stream_name = stream_name
        self.nominal_srate = nominal_srate
        self.timeout_s = timeout_s
        self._inlet = None
        self._buffer: deque[list[float]] = deque()
        self.sampling_rate = 0.0
        self.channel_count = 0

    def start(self) -> None:
        from pylsl import StreamInlet, resolve_byprop

        prop = "name" if self.stream_name else "type"
        value = self.stream_name or self.stream_type
        streams = resolve_byprop(prop, value, timeout=self.timeout_s)
        if not streams:
            raise RuntimeError(f"No LSL stream found for {prop}={value!r}")
        info = streams[0]
        self._inlet = StreamInlet(info, max_buflen=5)
        self.sampling_rate = float(info.nominal_srate() or self.nominal_srate)
        self.channel_count = int(info.channel_count())

    def stop(self) -> None:
        self._inlet = None
        self._buffer.clear()

    def get_window(self, sample_count: int) -> np.ndarray | None:
        if self._inlet is None:
            raise RuntimeError("LslEegReader is not started")
        deadline = time.monotonic() + 1.0
        while len(self._buffer) < sample_count and time.monotonic() < deadline:
            samples, _timestamps = self._inlet.pull_chunk(timeout=0.2, max_samples=sample_count)
            for sample in samples:
                self._buffer.append(list(sample))
            while len(self._buffer) > sample_count * 2:
                self._buffer.popleft()
        if len(self._buffer) < sample_count:
            return None
        rows = list(self._buffer)[-sample_count:]
        return np.asarray(rows, dtype=float).T


def add_reader_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--board",
        default="mock",
        choices=(
            "mock",
            "synthetic",
            "cyton",
            "cyton-daisy",
            "ganglion",
            "ganglion-wifi",
            "cyton-wifi",
            "cyton-daisy-wifi",
            "lsl",
        ),
        help="EEG source. mock is dependency-free; synthetic/cyton/etc use BrainFlow; lsl uses pylsl.",
    )
    parser.add_argument("--mock-scenario", default="alternating", help="mock scenario: calm, active, switch, alternating")
    parser.add_argument("--mock-sampling-rate", type=float, default=250.0)
    parser.add_argument("--mock-channels", type=int, default=4)
    parser.add_argument("--serial-port", default="", help="BrainFlow serial port, e.g. /dev/cu.usbserial-* on macOS")
    parser.add_argument("--mac-address", default="", help="BrainFlow Bluetooth MAC address when required")
    parser.add_argument("--serial-number", default="", help="BrainFlow serial number/device name when required")
    parser.add_argument("--ip-address", default="", help="BrainFlow IP address when required")
    parser.add_argument("--ip-port", type=int, default=0, help="BrainFlow IP port when required")
    parser.add_argument("--timeout", type=int, default=0, help="BrainFlow discovery/connect timeout")
    parser.add_argument("--other-info", default="", help="BrainFlow board-specific extra info, e.g. Ganglion fw:2")
    parser.add_argument("--streamer-params", default="", help="BrainFlow streamer params, e.g. file://raw.csv:w or streaming_board://224.0.0.1:6677")
    parser.add_argument("--stream-buffer-packages", type=int, default=450000, help="BrainFlow internal ring-buffer package count")
    parser.add_argument("--lsl-type", default="EEG", help="LSL stream type to resolve")
    parser.add_argument("--lsl-name", default="", help="Optional LSL stream name to resolve instead of type")
    parser.add_argument("--lsl-srate", type=float, default=250.0, help="Fallback LSL sampling rate if nominal rate is absent")


def create_reader_from_args(args: argparse.Namespace) -> EegReader:
    if args.board == "mock":
        return MockEegReader(
            scenario=args.mock_scenario,
            sampling_rate=args.mock_sampling_rate,
            channel_count=args.mock_channels,
        )
    if args.board == "lsl":
        return LslEegReader(
            stream_type=args.lsl_type,
            stream_name=args.lsl_name,
            nominal_srate=args.lsl_srate,
        )
    return BrainFlowReader(
        args.board,
        serial_port=args.serial_port,
        mac_address=args.mac_address,
        serial_number=args.serial_number,
        ip_address=args.ip_address,
        ip_port=args.ip_port,
        timeout=args.timeout,
        other_info=args.other_info,
        streamer_params=args.streamer_params,
        buffer_size=args.stream_buffer_packages,
    )
