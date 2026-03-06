"""
Backtest framework for UsaTec M5 data.
Tests multiple strategy families: ORB, EMA trend, momentum, VWAP deviation.
Server time appears UTC+3 (NY open = 9:30 AM EDT = 16:30 server).
"""

import pandas as pd
import numpy as np
from itertools import product
from dataclasses import dataclass, field
from typing import List, Optional

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_data(path: str) -> pd.DataFrame:
    with open(path, 'r', encoding='utf-16') as f:
        content = f.read()

    rows = []
    for line in content.strip().split('\n'):
        parts = line.strip().split(',')
        if len(parts) >= 6:
            rows.append(parts[:6])

    df = pd.DataFrame(rows, columns=['datetime', 'open', 'high', 'low', 'close', 'volume'])
    df['datetime'] = pd.to_datetime(df['datetime'].str.strip())
    for col in ['open', 'high', 'low', 'close']:
        df[col] = df[col].astype(float)
    df['volume'] = df['volume'].astype(int)
    df['date']   = df['datetime'].dt.date
    df['hour']   = df['datetime'].dt.hour
    df['minute'] = df['datetime'].dt.minute
    df['hm']     = df['hour'] * 60 + df['minute']
    df = df.sort_values('datetime').reset_index(drop=True)
    return df


# ---------------------------------------------------------------------------
# Trade result
# ---------------------------------------------------------------------------

@dataclass
class Trade:
    entry_dt:  pd.Timestamp
    exit_dt:   pd.Timestamp
    direction: str          # 'long' or 'short'
    entry:     float
    exit_price: float
    sl:        float
    tp:        float
    pts:       float        # positive = profit
    exit_reason: str        # 'tp', 'sl', 'eod'


# ---------------------------------------------------------------------------
# Backtest engine
# ---------------------------------------------------------------------------

def simulate_trade(bars: pd.DataFrame, direction: str,
                   entry: float, sl: float, tp: float,
                   eod_hm: int) -> Optional[Trade]:
    """
    Given a series of M5 bars AFTER entry, simulate trade outcome.
    Returns None if no bars available.
    """
    if bars.empty:
        return None

    entry_dt = bars.iloc[0]['datetime']

    for _, bar in bars.iterrows():
        hm = bar['hm']
        if direction == 'long':
            # Check SL first (worst case)
            if bar['low'] <= sl:
                pts = sl - entry
                return Trade(entry_dt, bar['datetime'], direction,
                             entry, sl, sl, tp, pts, 'sl')
            if bar['high'] >= tp:
                pts = tp - entry
                return Trade(entry_dt, bar['datetime'], direction,
                             entry, tp, sl, tp, pts, 'tp')
        else:  # short
            if bar['high'] >= sl:
                pts = entry - sl
                return Trade(entry_dt, bar['datetime'], direction,
                             entry, sl, sl, tp, pts, 'sl')
            if bar['low'] <= tp:
                pts = entry - tp
                return Trade(entry_dt, bar['datetime'], direction,
                             entry, tp, sl, tp, pts, 'tp')

        # End of day forced close
        if hm >= eod_hm:
            close_price = bar['close']
            pts = (close_price - entry) if direction == 'long' else (entry - close_price)
            return Trade(entry_dt, bar['datetime'], direction,
                         entry, close_price, sl, tp, pts, 'eod')

    # Final bar
    last = bars.iloc[-1]
    close_price = last['close']
    pts = (close_price - entry) if direction == 'long' else (entry - close_price)
    return Trade(entry_dt, last['datetime'], direction,
                 entry, close_price, sl, tp, pts, 'eod')


def stats(trades: List[Trade], label: str = '') -> dict:
    if not trades:
        return {}
    pts = [t.pts for t in trades]
    wins = [p for p in pts if p > 0]
    losses = [p for p in pts if p <= 0]
    gross_profit = sum(wins)
    gross_loss   = abs(sum(losses))
    net          = sum(pts)
    pf           = gross_profit / gross_loss if gross_loss > 0 else float('inf')
    wr           = len(wins) / len(pts) * 100
    # Max drawdown (running cumsum)
    cum = np.cumsum(pts)
    peak = np.maximum.accumulate(cum)
    dd   = cum - peak
    max_dd = dd.min()
    avg_win  = np.mean(wins)  if wins   else 0
    avg_loss = np.mean(losses) if losses else 0
    return {
        'label':    label,
        'n':        len(trades),
        'net':      round(net, 1),
        'pf':       round(pf, 3),
        'wr':       round(wr, 1),
        'max_dd':   round(max_dd, 1),
        'avg_win':  round(avg_win, 1),
        'avg_loss': round(avg_loss, 1),
        'sharpe':   round(net / (np.std(pts) * np.sqrt(len(pts))) if np.std(pts) > 0 else 0, 3),
    }


# ---------------------------------------------------------------------------
# Strategy 1: Opening Range Breakout (ORB)
# ---------------------------------------------------------------------------

def backtest_orb(df: pd.DataFrame,
                 range_start_hm: int = 16*60+30,   # 16:30 server
                 range_end_hm:   int = 17*60+0,    # 17:00 server
                 rr:             float = 2.0,       # TP = rr * range
                 sl_mult:        float = 1.0,       # SL = sl_mult * range
                 eod_hm:         int   = 22*60,     # force close at 22:00
                 direction_filter: str = 'both',    # 'long', 'short', 'both'
                 ) -> List[Trade]:
    """
    Opening Range Breakout:
    - Defines range as [low, high] of bars within [range_start, range_end)
    - Trades breakout above high (long) or below low (short)
    - SL = opposite side of range (or sl_mult * range from entry)
    - TP = rr * range_size from entry
    - One trade per day
    """
    trades = []

    for date, day_bars in df.groupby('date'):
        range_bars = day_bars[(day_bars['hm'] >= range_start_hm) &
                              (day_bars['hm'] <  range_end_hm)]
        if len(range_bars) < 2:
            continue

        or_high = range_bars['high'].max()
        or_low  = range_bars['low'].min()
        or_size = or_high - or_low
        if or_size < 5:   # skip tiny ranges
            continue

        sl_dist = or_size * sl_mult
        tp_dist = or_size * rr

        # Bars after range ends
        post_bars = day_bars[day_bars['hm'] >= range_end_hm].copy()
        if post_bars.empty:
            continue

        traded = False
        for idx, bar in post_bars.iterrows():
            if traded:
                break
            if bar['hm'] >= eod_hm:
                break

            # Long breakout
            if direction_filter in ('long', 'both') and bar['high'] > or_high:
                entry = or_high
                sl    = entry - sl_dist
                tp    = entry + tp_dist
                future = post_bars[post_bars.index >= idx]
                t = simulate_trade(future, 'long', entry, sl, tp, eod_hm)
                if t:
                    trades.append(t)
                    traded = True

            # Short breakout
            elif direction_filter in ('short', 'both') and bar['low'] < or_low:
                entry = or_low
                sl    = entry + sl_dist
                tp    = entry - tp_dist
                future = post_bars[post_bars.index >= idx]
                t = simulate_trade(future, 'short', entry, sl, tp, eod_hm)
                if t:
                    trades.append(t)
                    traded = True

    return trades


# ---------------------------------------------------------------------------
# Strategy 2: EMA Trend Following (intraday)
# ---------------------------------------------------------------------------

def backtest_ema_trend(df: pd.DataFrame,
                       fast_ema:   int   = 9,
                       slow_ema:   int   = 21,
                       atr_period: int   = 14,
                       sl_atr:     float = 1.5,
                       rr:         float = 2.0,
                       session_start_hm: int = 15*60,
                       session_end_hm:   int = 22*60,
                       ) -> List[Trade]:
    """
    EMA crossover trend following.
    - Buy when fast EMA crosses above slow EMA (within session hours)
    - SL = ATR * sl_atr below entry (for long)
    - TP = RR * SL distance
    - One trade per day (first signal)
    """
    # Compute EMAs on full dataframe
    df = df.copy()
    df['ema_fast'] = df['close'].ewm(span=fast_ema, adjust=False).mean()
    df['ema_slow'] = df['close'].ewm(span=slow_ema, adjust=False).mean()
    df['atr_raw']  = df[['high','low','close']].apply(
        lambda r: r['high'] - r['low'], axis=1)
    df['atr']      = df['atr_raw'].ewm(span=atr_period, adjust=False).mean()
    df['cross_up']   = (df['ema_fast'] > df['ema_slow']) & (df['ema_fast'].shift(1) <= df['ema_slow'].shift(1))
    df['cross_down'] = (df['ema_fast'] < df['ema_slow']) & (df['ema_fast'].shift(1) >= df['ema_slow'].shift(1))

    trades = []
    for date, day_bars in df.groupby('date'):
        session = day_bars[(day_bars['hm'] >= session_start_hm) &
                           (day_bars['hm'] <  session_end_hm)]
        if session.empty:
            continue

        traded = False
        for idx, bar in session.iterrows():
            if traded:
                break
            atr = bar['atr']
            if atr == 0:
                continue

            if bar['cross_up']:
                entry = bar['close']
                sl    = entry - sl_atr * atr
                tp    = entry + rr * sl_atr * atr
                future = day_bars[day_bars.index >= idx]
                t = simulate_trade(future, 'long', entry, sl, tp, session_end_hm)
                if t:
                    trades.append(t)
                    traded = True

            elif bar['cross_down']:
                entry = bar['close']
                sl    = entry + sl_atr * atr
                tp    = entry - rr * sl_atr * atr
                future = day_bars[day_bars.index >= idx]
                t = simulate_trade(future, 'short', entry, sl, tp, session_end_hm)
                if t:
                    trades.append(t)
                    traded = True

    return trades


# ---------------------------------------------------------------------------
# Strategy 3: ORB with trend filter (daily bias via EMA of closes)
# ---------------------------------------------------------------------------

def backtest_orb_trend(df: pd.DataFrame,
                       range_start_hm: int   = 16*60+30,
                       range_end_hm:   int   = 17*60,
                       rr:             float = 2.0,
                       eod_hm:         int   = 22*60,
                       trend_ema_bars: int   = 20,   # bars of daily H1 closes
                       ) -> List[Trade]:
    """
    ORB with daily EMA trend filter.
    Only trade in direction of H1 EMA.
    Long if price > H1-EMA, short if price < H1-EMA.
    """
    # Build daily closing bias from hourly data
    df = df.copy()
    # Use M5 close EMA as trend proxy
    df['trend_ema'] = df['close'].ewm(span=trend_ema_bars * 12, adjust=False).mean()  # *12 to get ~daily
    df['trend_ema_h'] = df['close'].ewm(span=trend_ema_bars, adjust=False).mean()     # shorter

    trades = []
    for date, day_bars in df.groupby('date'):
        range_bars = day_bars[(day_bars['hm'] >= range_start_hm) &
                              (day_bars['hm'] <  range_end_hm)]
        if len(range_bars) < 2:
            continue

        or_high = range_bars['high'].max()
        or_low  = range_bars['low'].min()
        or_size = or_high - or_low
        if or_size < 5:
            continue

        tp_dist = or_size * rr
        sl_dist = or_size

        post_bars = day_bars[day_bars['hm'] >= range_end_hm].copy()
        if post_bars.empty:
            continue

        traded = False
        for idx, bar in post_bars.iterrows():
            if traded or bar['hm'] >= eod_hm:
                break

            trend_up   = bar['close'] > bar['trend_ema_h']
            trend_down = bar['close'] < bar['trend_ema_h']

            if trend_up and bar['high'] > or_high:
                entry  = or_high
                sl     = entry - sl_dist
                tp     = entry + tp_dist
                future = post_bars[post_bars.index >= idx]
                t = simulate_trade(future, 'long', entry, sl, tp, eod_hm)
                if t:
                    trades.append(t)
                    traded = True

            elif trend_down and bar['low'] < or_low:
                entry  = or_low
                sl     = entry + sl_dist
                tp     = entry - tp_dist
                future = post_bars[post_bars.index >= idx]
                t = simulate_trade(future, 'short', entry, sl, tp, eod_hm)
                if t:
                    trades.append(t)
                    traded = True

    return trades


# ---------------------------------------------------------------------------
# Strategy 4: First-hour momentum / gap-and-go
# ---------------------------------------------------------------------------

def backtest_momentum(df: pd.DataFrame,
                      session_open_hm: int   = 15*60,   # session start
                      signal_hm:       int   = 16*60,   # signal bar (after 1h)
                      rr:              float = 2.0,
                      sl_pct:          float = 0.004,    # SL = 0.4% from entry
                      eod_hm:          int   = 22*60,
                      min_move_pct:    float = 0.002,    # minimum 0.2% move to trigger
                      ) -> List[Trade]:
    """
    First-hour momentum:
    - Measure move from session open close to signal_hm bar
    - If strong up move: go long breakout
    - If strong down move: go short
    """
    trades = []
    for date, day_bars in df.groupby('date'):
        open_bar = day_bars[day_bars['hm'] >= session_open_hm]
        if open_bar.empty:
            continue
        session_open_price = open_bar.iloc[0]['open']

        signal_bars = day_bars[day_bars['hm'] >= signal_hm]
        if signal_bars.empty:
            continue
        signal_bar = signal_bars.iloc[0]
        signal_close = signal_bar['close']
        move = (signal_close - session_open_price) / session_open_price

        if abs(move) < min_move_pct:
            continue

        post_bars = day_bars[day_bars['hm'] >= signal_hm].copy()
        if post_bars.empty:
            continue

        if move > 0:  # bullish momentum
            entry = signal_close
            sl    = entry * (1 - sl_pct)
            tp    = entry + rr * (entry - sl)
            t = simulate_trade(post_bars, 'long', entry, sl, tp, eod_hm)
        else:         # bearish momentum
            entry = signal_close
            sl    = entry * (1 + sl_pct)
            tp    = entry - rr * (sl - entry)
            t = simulate_trade(post_bars, 'short', entry, sl, tp, eod_hm)

        if t:
            trades.append(t)

    return trades


# ---------------------------------------------------------------------------
# Grid search helpers
# ---------------------------------------------------------------------------

def grid_orb(df):
    print("=== ORB Grid Search ===")
    results = []

    # Server = CET. NY open = 9:30 ET = 15:30 CET (constant, summer+winter).
    # NY close = 22:00 ET = 22:00 CET.
    range_configs = [
        (15*60,    15*60+15,  "15:00-15:15"),  # pre-open 15min
        (15*60,    15*60+30,  "15:00-15:30"),  # pre-open 30min
        (15*60+30, 16*60,     "15:30-16:00"),  # NY open first 30min
        (15*60+30, 16*60+30,  "15:30-16:30"),  # NY open first 60min
        (15*60,    16*60,     "15:00-16:00"),  # pre+open 60min
        (15*60+30, 17*60,     "15:30-17:00"),  # NY open first 90min
        (16*60,    16*60+30,  "16:00-16:30"),  # post-open 30min
    ]
    rrs = [1.5, 2.0, 2.5, 3.0]
    eods = [21*60, 22*60]  # NY close = 22:00 CET

    for (rs, re, rlabel), rr, eod in product(range_configs, rrs, eods):
        trades = backtest_orb(df, range_start_hm=rs, range_end_hm=re,
                              rr=rr, eod_hm=eod)
        if len(trades) < 30:
            continue
        s = stats(trades, f"ORB {rlabel} rr={rr} eod={eod//60}h")
        results.append(s)

    results.sort(key=lambda x: x.get('net', -9999), reverse=True)
    print(f"{'Label':<45} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8} {'Sharpe':>7}")
    for r in results[:20]:
        print(f"{r['label']:<45} {r['n']:>5} {r['net']:>8.1f} {r['pf']:>6.3f} "
              f"{r['wr']:>6.1f}% {r['max_dd']:>8.1f} {r['sharpe']:>7.3f}")
    return results


def grid_ema(df):
    print("\n=== EMA Crossover Grid Search ===")
    results = []

    params = [
        (5, 13), (5, 20), (9, 21), (9, 50), (13, 34), (20, 50)
    ]
    sl_atrs = [1.0, 1.5, 2.0]
    rrs = [1.5, 2.0, 2.5]

    for (fast, slow), sl_atr, rr in product(params, sl_atrs, rrs):
        trades = backtest_ema_trend(df, fast_ema=fast, slow_ema=slow,
                                    sl_atr=sl_atr, rr=rr)
        if len(trades) < 20:
            continue
        s = stats(trades, f"EMA {fast}/{slow} sl={sl_atr}atr rr={rr}")
        results.append(s)

    results.sort(key=lambda x: x.get('net', -9999), reverse=True)
    print(f"{'Label':<40} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8} {'Sharpe':>7}")
    for r in results[:15]:
        print(f"{r['label']:<40} {r['n']:>5} {r['net']:>8.1f} {r['pf']:>6.3f} "
              f"{r['wr']:>6.1f}% {r['max_dd']:>8.1f} {r['sharpe']:>7.3f}")
    return results


def grid_momentum(df):
    print("\n=== Momentum Grid Search ===")
    results = []

    # CET: NY open=15:30, NY close=22:00
    session_opens = [15*60, 15*60+30]
    signal_delays = [30, 60, 90, 120]  # minutes after session open
    rrs = [1.5, 2.0, 2.5]
    min_moves = [0.001, 0.002, 0.003]

    for so, delay, rr, mm in product(session_opens, signal_delays, rrs, min_moves):
        signal_hm = so + delay
        trades = backtest_momentum(df, session_open_hm=so, signal_hm=signal_hm,
                                   rr=rr, min_move_pct=mm)
        if len(trades) < 20:
            continue
        s = stats(trades, f"MOM open={so//60}:{so%60:02d} +{delay}m rr={rr} mm={mm:.3f}")
        results.append(s)

    results.sort(key=lambda x: x.get('net', -9999), reverse=True)
    print(f"{'Label':<55} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8}")
    for r in results[:15]:
        print(f"{r['label']:<55} {r['n']:>5} {r['net']:>8.1f} {r['pf']:>6.3f} "
              f"{r['wr']:>6.1f}% {r['max_dd']:>8.1f}")
    return results


def deep_orb_analysis(df, best_rs, best_re, best_rr, best_eod):
    """Detailed analysis of the best ORB config."""
    print(f"\n=== Deep ORB Analysis ===")
    trades = backtest_orb(df, range_start_hm=best_rs, range_end_hm=best_re,
                          rr=best_rr, eod_hm=best_eod)

    s = stats(trades)
    print(f"Trades: {s['n']}, Net: {s['net']}, PF: {s['pf']}, WR: {s['wr']}%, "
          f"MaxDD: {s['max_dd']}, Sharpe: {s['sharpe']}")

    pts = [t.pts for t in trades]
    cum = np.cumsum(pts)

    # By year/month
    df_trades = pd.DataFrame([{
        'date': t.entry_dt.date(),
        'month': t.entry_dt.strftime('%Y-%m'),
        'pts': t.pts,
        'reason': t.exit_reason,
        'direction': t.direction,
    } for t in trades])

    print("\nMonthly PnL:")
    monthly = df_trades.groupby('month')['pts'].agg(['sum','count','mean']).round(1)
    print(monthly.to_string())

    print("\nBy exit reason:")
    print(df_trades.groupby('reason')['pts'].agg(['count','sum','mean']).round(1).to_string())

    print("\nBy direction:")
    print(df_trades.groupby('direction')['pts'].agg(['count','sum','mean']).round(1).to_string())

    # Consecutive losses
    streak = 0
    max_streak = 0
    for p in pts:
        if p <= 0:
            streak += 1
            max_streak = max(max_streak, streak)
        else:
            streak = 0
    print(f"\nMax consecutive losses: {max_streak}")
    print(f"Avg pts/trade: {np.mean(pts):.2f}")

    return trades


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    print("Loading data...")
    df = load_data('/Users/eduardocarvalho/workspace/projects/daily-bot/UsaTecM5.csv')
    print(f"Loaded {len(df)} bars from {df['datetime'].min()} to {df['datetime'].max()}")
    print(f"Trading days: {df['date'].nunique()}")
    print()

    # Run grid searches
    orb_results = grid_orb(df)
    ema_results = grid_ema(df)
    mom_results = grid_momentum(df)

    # Deep analysis on best ORB
    if orb_results:
        best = orb_results[0]
        print(f"\nBest ORB: {best['label']}")
        # Parse params from label (simple approach)
        # Re-run top configs manually based on grid output
        # Default deep dive on best range: 15:30-16:00, rr=2.0
        best_rs  = 15*60+30
        best_re  = 16*60
        best_rr  = 2.0
        best_eod = 22*60

        # Find actual best from results
        label = best['label']
        # Try to parse
        import re
        m = re.search(r'(\d+:\d+)-(\d+:\d+)', label)
        if m:
            def hm(s):
                h, mi = map(int, s.split(':'))
                return h * 60 + mi
            best_rs = hm(m.group(1))
            best_re = hm(m.group(2))
        m2 = re.search(r'rr=([\d.]+)', label)
        if m2:
            best_rr = float(m2.group(1))
        m3 = re.search(r'eod=(\d+)h', label)
        if m3:
            best_eod = int(m3.group(1)) * 60

        deep_orb_analysis(df, best_rs, best_re, best_rr, best_eod)
