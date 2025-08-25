import math
import os
from dataclasses import dataclass
from typing import List, Tuple, Optional

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter


# ============================ Inputs (match EA defaults) ============================ #
SYMBOL = "ETHUSD"
ATR_PERIOD = 14
ATR_MULTIPLIER = 1.5
LOOKBACK_MAX_BARS = 10
DOJI_MAX_BODY_PCT_OF_RANGE = 10.0
REQUIRE_DOJI_BODY_GREATER_PREV_WICKLESS = True
SEED = 42

# Animation
NUM_BARS = 900  # ~ 15 hours of 1-minute bars
WINDOW = 150    # bars shown in the viewport
FPS = 20
OUTFILE = "strategy_animation.gif"


# ============================ Data Structures ============================ #
@dataclass
class Candle:
    time: pd.Timestamp
    open: float
    high: float
    low: float
    close: float
    volume: float


# ============================ Synthetic Data Generation ============================ #
def generate_synthetic_ohlcv(num_bars: int, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    # Base random walk with intraday volatility patterns
    base_price = 3000.0
    returns = rng.normal(loc=0.0, scale=0.0008, size=num_bars)
    # Add a midday trend and open/close sessions volatility
    trend = np.linspace(-0.0002, 0.0002, num_bars)
    returns += trend
    prices = base_price * np.exp(np.cumsum(returns))

    # Construct OHLC with random spreads around the close
    o = prices * (1 + rng.normal(0, 0.0002, size=num_bars))
    c = prices
    h = np.maximum(o, c) * (1 + np.abs(rng.normal(0, 0.0006, size=num_bars)))
    l = np.minimum(o, c) * (1 - np.abs(rng.normal(0, 0.0006, size=num_bars)))

    # Tick volume proxy
    v = np.abs(np.diff(np.insert(c, 0, c[0])))
    v = (v / (np.max(v) + 1e-9)) * 1000 + 50

    idx = pd.date_range("2025-01-01 07:00", periods=num_bars, freq="T")
    df = pd.DataFrame({"open": o, "high": h, "low": l, "close": c, "volume": v}, index=idx)
    return df


# ============================ Indicators ============================ #
def heikin_ashi(df: pd.DataFrame) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    ha_close = (df["open"].values + df["high"].values + df["low"].values + df["close"].values) / 4.0
    ha_open = np.zeros_like(ha_close)
    ha_high = np.zeros_like(ha_close)
    ha_low = np.zeros_like(ha_close)

    # Initialize with first bar
    ha_open[0] = (df["open"].values[0] + df["close"].values[0]) / 2.0
    ha_high[0] = max(df["high"].values[0], ha_open[0], ha_close[0])
    ha_low[0]  = min(df["low"].values[0],  ha_open[0], ha_close[0])

    for i in range(1, len(df)):
        ha_open[i] = (ha_open[i - 1] + ha_close[i - 1]) / 2.0
        ha_high[i] = max(df["high"].values[i], ha_open[i], ha_close[i])
        ha_low[i]  = min(df["low"].values[i],  ha_open[i], ha_close[i])

    return ha_open, ha_close, ha_high, ha_low


def atr(df: pd.DataFrame, period: int) -> np.ndarray:
    high = df["high"].values
    low = df["low"].values
    close = df["close"].values
    tr = np.zeros_like(close)
    tr[0] = high[0] - low[0]
    for i in range(1, len(close)):
        tr[i] = max(
            high[i] - low[i],
            abs(high[i] - close[i - 1]),
            abs(low[i] - close[i - 1])
        )
    # Wilder's smoothing
    atr_vals = np.zeros_like(close)
    atr_vals[period - 1] = np.mean(tr[:period])
    for i in range(period, len(close)):
        atr_vals[i] = (atr_vals[i - 1] * (period - 1) + tr[i]) / period
    return atr_vals


def vwap_intraday(df: pd.DataFrame, tz_offset_hours: int = 2) -> np.ndarray:
    # Anchor per session-day using typical price and tick volume proxy
    typical = (df["high"] + df["low"] + df["close"]) / 3.0
    vol = df["volume"].values
    vwap = np.zeros(len(df))

    # Reset at session day boundary in target tz
    session_dates = (df.index.tz_localize("UTC") + pd.to_timedelta(tz_offset_hours, unit="h")).date
    current_key = None
    cum_pv = 0.0
    cum_v = 0.0
    for i, key in enumerate(session_dates):
        if current_key != key:
            current_key = key
            cum_pv = 0.0
            cum_v = 0.0
        cum_pv += typical.iloc[i] * vol[i]
        cum_v += vol[i]
        vwap[i] = cum_pv / max(cum_v, 1e-9)
    return vwap


# ============================ Strategy Logic ============================ #
def is_bullish_ha(i: int, ha_o: np.ndarray, ha_c: np.ndarray) -> bool:
    return ha_c[i] > ha_o[i]


def is_bearish_ha(i: int, ha_o: np.ndarray, ha_c: np.ndarray) -> bool:
    return ha_c[i] < ha_o[i]


def is_bullish_wickless_ha(i: int, ha_o: np.ndarray, ha_c: np.ndarray, ha_l: np.ndarray) -> bool:
    low_pivot = min(ha_o[i], ha_c[i])
    return is_bullish_ha(i, ha_o, ha_c) and abs(ha_l[i] - low_pivot) <= 1e-8


def is_bearish_wickless_ha(i: int, ha_o: np.ndarray, ha_c: np.ndarray, ha_h: np.ndarray) -> bool:
    high_pivot = max(ha_o[i], ha_c[i])
    return is_bearish_ha(i, ha_o, ha_c) and abs(ha_h[i] - high_pivot) <= 1e-8


def has_consecutive_wickless_run(bearish: bool, lookback: int,
                                 ha_o: np.ndarray, ha_c: np.ndarray, ha_h: np.ndarray, ha_l: np.ndarray,
                                 current_index: int) -> bool:
    found = 0
    # Look back strictly before current bar
    for k in range(1, lookback + 1):
        i = current_index - k
        if i < 0:
            break
        if bearish:
            ok = is_bearish_wickless_ha(i, ha_o, ha_c, ha_h)
            opposite = is_bullish_ha(i, ha_o, ha_c)
        else:
            ok = is_bullish_wickless_ha(i, ha_o, ha_c, ha_l)
            opposite = is_bearish_ha(i, ha_o, ha_c)
        if ok:
            found += 1
            if found >= 2:
                return True
        elif opposite:
            found = 0
        else:
            found = 0
    return False


def is_doji(i: int, df: pd.DataFrame, ha_o: np.ndarray, ha_c: np.ndarray,
            prev_idx_1: int, prev_idx_2: int) -> bool:
    body = abs(df["close"].values[i] - df["open"].values[i])
    rng = max(df["high"].values[i] - df["low"].values[i], 1e-9)
    body_pct = (body / rng) * 100.0
    if body_pct > DOJI_MAX_BODY_PCT_OF_RANGE:
        return False
    if REQUIRE_DOJI_BODY_GREATER_PREV_WICKLESS:
        prev_body1 = abs(ha_c[prev_idx_1] - ha_o[prev_idx_1])
        prev_body2 = abs(ha_c[prev_idx_2] - ha_o[prev_idx_2])
        if not (body > prev_body1 and body > prev_body2):
            return False
    return True


@dataclass
class TradeState:
    active: bool = False
    direction: Optional[str] = None  # 'long' or 'short'
    entry_index: Optional[int] = None
    entry_price: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    partial_taken: bool = False


def evaluate_signal(i: int, df: pd.DataFrame, ha_o: np.ndarray, ha_c: np.ndarray, ha_h: np.ndarray, ha_l: np.ndarray,
                    vwap: np.ndarray, atr_vals: np.ndarray) -> Tuple[bool, Optional[str], float, float]:
    price = df["close"].values[i]
    doji_now = is_doji(i, df, ha_o, ha_c, i - 1 if i - 1 >= 0 else 0, i - 2 if i - 2 >= 0 else 0)
    if not doji_now:
        return False, None, 0.0, 0.0

    # Trend filter
    buy_ok = price > vwap[i]
    sell_ok = price < vwap[i]

    if buy_ok and has_consecutive_wickless_run(True, LOOKBACK_MAX_BARS, ha_o, ha_c, ha_h, ha_l, i):
        sl = df["low"].values[i] - atr_vals[i] * ATR_MULTIPLIER
        risk = abs(price - sl)
        tp = price + risk
        return True, "long", sl, tp
    if sell_ok and has_consecutive_wickless_run(False, LOOKBACK_MAX_BARS, ha_o, ha_c, ha_h, ha_l, i):
        sl = df["high"].values[i] + atr_vals[i] * ATR_MULTIPLIER
        risk = abs(sl - price)
        tp = price - risk
        return True, "short", sl, tp

    return False, None, 0.0, 0.0


# ============================ Animation ============================ #
class StrategyAnimator:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.ha_o, self.ha_c, self.ha_h, self.ha_l = heikin_ashi(df)
        self.atr_vals = atr(df, ATR_PERIOD)
        self.vwap = vwap_intraday(df)
        self.trade = TradeState()

        self.fig, self.ax = plt.subplots(figsize=(12, 6))
        self.line_vwap, = self.ax.plot([], [], color="#2ca02c", lw=1.5, label="VWAP")
        self.text_info = self.ax.text(0.01, 0.97, "", transform=self.ax.transAxes, va="top", fontsize=9,
                                      bbox=dict(boxstyle="round,pad=0.3", fc="white", alpha=0.7))
        self.sl_line = None
        self.tp_line = None
        self.bars_cache = []  # list of (hl_line, body_rect)

        self.ax.set_title(f"{SYMBOL} M1 Strategy Animation")
        self.ax.grid(True, alpha=0.2)
        self.ax.legend(loc="upper left")

    def _draw_candle(self, i: int):
        o = self.df["open"].values[i]
        h = self.df["high"].values[i]
        l = self.df["low"].values[i]
        c = self.df["close"].values[i]
        color = "#2ca02c" if c >= o else "#d62728"
        x = i
        # Wick
        hl, = self.ax.plot([x, x], [l, h], color=color, lw=1.0, alpha=0.9)
        # Body
        body_bottom = min(o, c)
        body_top = max(o, c)
        width = 0.6
        rect = plt.Rectangle((x - width / 2.0, body_bottom), width, max(body_top - body_bottom, 1e-8),
                             edgecolor=color, facecolor=color, alpha=0.7)
        self.ax.add_patch(rect)
        return hl, rect

    def _clear_bars(self):
        for hl, rect in self.bars_cache:
            try:
                hl.remove()
            except Exception:
                pass
            try:
                rect.remove()
            except Exception:
                pass
        self.bars_cache.clear()

    def _update_trade(self, i: int):
        price_high = self.df["high"].values[i]
        price_low = self.df["low"].values[i]
        price_close = self.df["close"].values[i]

        if self.trade.active:
            # Partial TP at 1R
            if not self.trade.partial_taken:
                reached = (self.trade.direction == "long" and price_high >= self.trade.tp) or 
                          (self.trade.direction == "short" and price_low <= self.trade.tp)
                if reached:
                    self.trade.partial_taken = True

            # Trailing after partial
            if self.trade.partial_taken:
                trail_sl = (price_close - self.atr_vals[i] * ATR_MULTIPLIER) if self.trade.direction == "long" \
                    else (price_close + self.atr_vals[i] * ATR_MULTIPLIER)
                if self.trade.direction == "long" and trail_sl > self.trade.sl:
                    self.trade.sl = trail_sl
                elif self.trade.direction == "short" and trail_sl < self.trade.sl:
                    self.trade.sl = trail_sl

            # Exit if SL is hit
            stopped = (self.trade.direction == "long" and price_low <= self.trade.sl) or \
                      (self.trade.direction == "short" and price_high >= self.trade.sl)
            if stopped:
                self.trade = TradeState()  # reset

        else:
            # Look for new signal
            if i >= max(ATR_PERIOD + 2, LOOKBACK_MAX_BARS + 2):
                has, direction, sl, tp = evaluate_signal(i, self.df, self.ha_o, self.ha_c, self.ha_h, self.ha_l,
                                                         self.vwap, self.atr_vals)
                if has:
                    self.trade.active = True
                    self.trade.direction = direction
                    self.trade.entry_index = i
                    self.trade.entry_price = self.df["close"].values[i]
                    self.trade.sl = sl
                    self.trade.tp = tp
                    self.trade.partial_taken = False

    def _draw_levels(self, i: int):
        # Remove previous lines
        if self.sl_line is not None:
            try:
                self.sl_line.remove()
            except Exception:
                pass
            self.sl_line = None
        if self.tp_line is not None:
            try:
                self.tp_line.remove()
            except Exception:
                pass
            self.tp_line = None

        if self.trade.active:
            color = "#1f77b4" if self.trade.direction == "long" else "#ff7f0e"
            self.sl_line = self.ax.axhline(self.trade.sl, color=color, lw=1.2, ls="--", alpha=0.9, label="SL")
            self.tp_line = self.ax.axhline(self.trade.tp, color=color, lw=1.2, ls=":", alpha=0.9, label="TP")

    def init(self):
        self.ax.set_xlim(0, WINDOW)
        y = self.df["close"].values[:WINDOW]
        self.ax.set_ylim(y.min() * 0.995, y.max() * 1.005)
        return []

    def update(self, frame: int):
        i = frame
        left = max(0, i - WINDOW + 1)
        right = i + 1

        self._clear_bars()

        # Draw candles in window
        for idx in range(left, right):
            hl, rect = self._draw_candle(idx - left)
            self.bars_cache.append((hl, rect))

        # Update axes limits
        y = self.df["close"].values[left:right]
        yl, yh = y.min(), y.max()
        pad = (yh - yl) * 0.1 + 1e-6
        self.ax.set_xlim(0, min(WINDOW, right - left))
        self.ax.set_ylim(yl - pad, yh + pad)

        # VWAP in window
        x_v = np.arange(right - left)
        y_v = self.vwap[left:right]
        self.line_vwap.set_data(x_v, y_v)

        # Update trade state and draw SL/TP
        self._update_trade(i)
        self._draw_levels(i)

        # Info text
        trend = "BUY-ONLY" if self.df["close"].values[i] > self.vwap[i] else ("SELL-ONLY" if self.df["close"].values[i] < self.vwap[i] else "NEUTRAL")
        info = [
            f"Frame: {i+1}/{len(self.df)}",
            f"Trend: {trend}",
        ]
        if self.trade.active:
            info.append(f"Trade: {self.trade.direction} | SL={self.trade.sl:.2f} TP={self.trade.tp:.2f} Partial={'Y' if self.trade.partial_taken else 'N'}")
        self.text_info.set_text("\n".join(info))

        return []


def main():
    df = generate_synthetic_ohlcv(NUM_BARS, SEED)
    anim = StrategyAnimator(df)

    fig = anim.fig
    animation = FuncAnimation(fig, anim.update, frames=np.arange(NUM_BARS), init_func=anim.init,
                              interval=1000 // FPS, blit=False, repeat=False)

    out_path = os.path.join(os.path.dirname(__file__), OUTFILE)
    print(f"Writing GIF to {out_path} ...")
    writer = PillowWriter(fps=FPS)
    animation.save(out_path, writer=writer)
    print("Done.")


if __name__ == "__main__":
    main()