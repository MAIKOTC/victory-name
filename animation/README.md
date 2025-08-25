# Strategy Animation (VWAP + Heikin Ashi + Doji + ATR)

This script generates an animated GIF showing how the EA logic works on synthetic M1 data:
- VWAP as trend filter
- Heikin Ashi wickless runs (used to qualify reversals)
- Doji trigger candle
- ATR(14) x 1.5 for SL/TP
- Partial take profit at 1R and ATR trailing stop thereafter

## Quick start

1. Create a virtual environment (recommended) and install dependencies:
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

2. Run the script:
```bash
python animate_strategy.py
```

3. Output:
- A GIF `strategy_animation.gif` will be written in the same directory.

## Customize
- Edit constants at the top of `animate_strategy.py` to match the EA’s inputs:
  - ATR_PERIOD, ATR_MULTIPLIER, LOOKBACK_MAX_BARS
  - DOJI_MAX_BODY_PCT_OF_RANGE, REQUIRE_DOJI_BODY_GREATER_PREV_WICKLESS
  - NUM_BARS, WINDOW, FPS

This visualization is for understanding; the trading logic in MetaTrader is implemented in the EA files.