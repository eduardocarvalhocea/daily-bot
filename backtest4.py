"""
New strategy research backtest — beyond ORB.
Tests: IBS mean reversion, ORB+VWAP filter, ORB+Volume filter,
       RSI mean reversion, multi-strategy portfolio.
Dataset: UsaTec M5, CET timezone.
"""

import pandas as pd
import numpy as np
from dataclasses import dataclass, field
from typing import List, Optional
import warnings
warnings.filterwarnings('ignore')

# ── data loading ─────────────────────────────────────────────────────────────
def load_data(path: str) -> pd.DataFrame:
    with open(path, 'r', encoding='utf-16') as f:
        content = f.read()
    rows = []
    for line in content.strip().split('\n'):
        parts = line.strip().split(',')
        if len(parts) >= 6:
            rows.append(parts[:6])
    df = pd.DataFrame(rows, columns=['datetime','open','high','low','close','volume'])
    df['datetime'] = pd.to_datetime(df['datetime'].str.strip())
    for c in ['open','high','low','close']:
        df[c] = df[c].astype(float)
    df['volume'] = df['volume'].astype(int)
    df['date']   = df['datetime'].dt.date
    df['hour']   = df['datetime'].dt.hour
    df['minute'] = df['datetime'].dt.minute
    df['hm']     = df['hour'] * 60 + df['minute']
    df['dow']    = df['datetime'].dt.dayofweek
    return df.sort_values('datetime').reset_index(drop=True)

# ── helper: daily bars from M5 ──────────────────────────────────────────────
def build_daily(df: pd.DataFrame) -> pd.DataFrame:
    daily = df.groupby('date').agg(
        open=('open', 'first'),
        high=('high', 'max'),
        low=('low', 'min'),
        close=('close', 'last'),
        volume=('volume', 'sum'),
    ).reset_index()
    daily['date'] = pd.to_datetime(daily['date'])
    daily['ibs'] = (daily['close'] - daily['low']) / (daily['high'] - daily['low'])
    daily['rsi'] = compute_rsi(daily['close'], 2)
    daily['rsi14'] = compute_rsi(daily['close'], 14)
    daily['prev_high'] = daily['high'].shift(1)
    daily['prev_low'] = daily['low'].shift(1)
    daily['prev_close'] = daily['close'].shift(1)
    daily['atr14'] = compute_atr(daily, 14)
    daily['ema5'] = daily['close'].ewm(span=5, adjust=False).mean()
    daily['ema10'] = daily['close'].ewm(span=10, adjust=False).mean()
    daily['ema20'] = daily['close'].ewm(span=20, adjust=False).mean()
    daily['sma200'] = daily['close'].rolling(200).mean()
    daily['dow'] = daily['date'].dt.dayofweek
    return daily

def compute_rsi(series, period):
    delta = series.diff()
    gain = delta.where(delta > 0, 0.0)
    loss = -delta.where(delta < 0, 0.0)
    avg_gain = gain.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss
    return 100 - (100 / (1 + rs))

def compute_atr(daily, period):
    tr = pd.DataFrame({
        'hl': daily['high'] - daily['low'],
        'hc': abs(daily['high'] - daily['close'].shift(1)),
        'lc': abs(daily['low'] - daily['close'].shift(1)),
    }).max(axis=1)
    return tr.rolling(period).mean()

# ── VWAP calculation for intraday ────────────────────────────────────────────
def add_vwap(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df['typical'] = (df['high'] + df['low'] + df['close']) / 3
    df['tp_vol'] = df['typical'] * df['volume']
    df['cum_tp_vol'] = df.groupby('date')['tp_vol'].cumsum()
    df['cum_vol'] = df.groupby('date')['volume'].cumsum()
    df['vwap'] = df['cum_tp_vol'] / df['cum_vol'].replace(0, np.nan)
    return df

# ── stats ────────────────────────────────────────────────────────────────────
@dataclass
class Trade:
    entry_dt: object
    exit_dt: object
    direction: str
    entry: float
    exit_price: float
    sl: float
    tp: float
    pts: float
    exit_reason: str
    range_size: float = 0
    dow: int = 0

def calc_stats(trades, label=''):
    if not trades:
        return None
    pts = [t.pts for t in trades]
    wins = [p for p in pts if p > 0]
    losses = [p for p in pts if p <= 0]
    gp = sum(wins); gl = abs(sum(losses))
    net = sum(pts); pf = gp/gl if gl else float('inf')
    wr = len(wins)/len(pts)*100
    cum = np.cumsum(pts)
    dd = (cum - np.maximum.accumulate(cum)).min()
    sh = net / (np.std(pts) * np.sqrt(len(pts))) if np.std(pts) > 0 else 0
    avg_w = np.mean(wins) if wins else 0
    avg_l = np.mean(losses) if losses else 0
    return dict(label=label, n=len(trades), net=round(net,1), pf=round(pf,3),
                wr=round(wr,1), max_dd=round(dd,1), sharpe=round(sh,3),
                avg_win=round(avg_w,1), avg_loss=round(avg_l,1))

def hdr():
    return f"{'Label':<55} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8} {'Sharpe':>7}"

def row(s):
    if not s: return ""
    return (f"{s['label']:<55} {s['n']:>5} {s['net']:>8.1f} {s['pf']:>6.3f} "
            f"{s['wr']:>6.1f}% {s['max_dd']:>8.1f} {s['sharpe']:>7.3f}")

def compound_equity(trades, risk_pct=0.015, point_value=5.0, initial=10000):
    equity = initial
    curve = [equity]
    for t in trades:
        if t.range_size > 0:
            risk_usd = equity * risk_pct
            lot = risk_usd / (t.range_size * point_value)
        else:
            lot = 1.0
        pnl = t.pts * lot * point_value
        equity += pnl
        curve.append(equity)
    return equity, curve

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 1: ORB Baseline (reference)
# ══════════════════════════════════════════════════════════════════════════════
def simulate_trade(bars, direction, entry, sl, tp, eod_hm):
    if bars.empty:
        return None
    entry_dt = bars.iloc[0]['datetime']
    dow = bars.iloc[0]['dow']
    for _, b in bars.iterrows():
        if direction == 'long':
            if b['low'] <= sl:
                return Trade(entry_dt, b['datetime'], direction, entry, sl, sl, tp, sl - entry, 'sl', dow=dow)
            if b['high'] >= tp:
                return Trade(entry_dt, b['datetime'], direction, entry, tp, sl, tp, tp - entry, 'tp', dow=dow)
        else:
            if b['high'] >= sl:
                return Trade(entry_dt, b['datetime'], direction, entry, sl, sl, tp, entry - sl, 'sl', dow=dow)
            if b['low'] <= tp:
                return Trade(entry_dt, b['datetime'], direction, entry, tp, sl, tp, entry - tp, 'tp', dow=dow)
        if b['hm'] >= eod_hm:
            cp = b['close']
            pts = (cp - entry) if direction == 'long' else (entry - cp)
            return Trade(entry_dt, b['datetime'], direction, entry, cp, sl, tp, pts, 'eod', dow=dow)
    last = bars.iloc[-1]
    cp = last['close']
    pts = (cp - entry) if direction == 'long' else (entry - cp)
    return Trade(entry_dt, last['datetime'], direction, entry, cp, sl, tp, pts, 'eod', dow=dow)

def run_orb(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60,
            vwap_filter=False, vol_filter=False, vol_mult=1.5):
    trades = []
    if vwap_filter:
        df = add_vwap(df)

    for date, day_bars in df.groupby('date'):
        rbars = day_bars[(day_bars['hm'] >= rs) & (day_bars['hm'] < re)]
        if len(rbars) < 2:
            continue

        or_high = rbars['high'].max()
        or_low = rbars['low'].min()
        or_size = or_high - or_low
        if or_size <= 0:
            continue

        tp_dist = or_size * rr
        sl_dist = or_size
        post = day_bars[day_bars['hm'] >= re].copy()
        if post.empty:
            continue

        # VWAP filter: only trade in VWAP direction
        if vwap_filter:
            range_end_bar = rbars.iloc[-1]
            vwap_val = range_end_bar.get('vwap', None)
            if vwap_val is None or np.isnan(vwap_val):
                continue
            price_vs_vwap = range_end_bar['close'] - vwap_val
        else:
            price_vs_vwap = 0

        # Volume filter: require above-average volume during range
        if vol_filter:
            range_vol = rbars['volume'].sum()
            # compare to same-time average over last 20 days
            avg_vol = df[(df['hm'] >= rs) & (df['hm'] < re)]['volume'].mean() * len(rbars)
            if range_vol < avg_vol * vol_mult:
                continue

        traded = False
        for idx, b in post.iterrows():
            if traded or b['hm'] >= eod:
                break
            can_long = (not vwap_filter or price_vs_vwap > 0)
            can_short = (not vwap_filter or price_vs_vwap < 0)

            if can_long and b['high'] > or_high:
                entry = or_high
                t = simulate_trade(post[post.index >= idx], 'long',
                                   entry, entry - sl_dist, entry + tp_dist, eod)
                if t:
                    t.range_size = or_size
                    trades.append(t)
                    traded = True
            elif can_short and b['low'] < or_low:
                entry = or_low
                t = simulate_trade(post[post.index >= idx], 'short',
                                   entry, entry + sl_dist, entry - tp_dist, eod)
                if t:
                    t.range_size = or_size
                    trades.append(t)
                    traded = True
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 2: IBS Mean Reversion (Daily)
# Buy when IBS < threshold, exit on first close > prev day high
# ══════════════════════════════════════════════════════════════════════════════
def run_ibs(daily, ibs_low=0.2, ibs_high=0.8, use_rsi_filter=False,
            rsi_threshold=30, exit_mode='prev_high', max_hold=5,
            sl_atr_mult=1.5, label=''):
    trades = []
    i = 1
    while i < len(daily) - 1:
        row_today = daily.iloc[i]
        ibs = row_today['ibs']

        # BUY signal: low IBS
        if ibs < ibs_low:
            if use_rsi_filter and row_today['rsi'] > rsi_threshold:
                i += 1
                continue
            entry = row_today['close']
            entry_dt = row_today['date']
            sl = entry - row_today['atr14'] * sl_atr_mult if not np.isnan(row_today['atr14']) else entry - 200
            held = 0
            exited = False
            for j in range(i+1, min(i+1+max_hold, len(daily))):
                held += 1
                d = daily.iloc[j]
                # SL check
                if d['low'] <= sl:
                    pts = sl - entry
                    trades.append(Trade(entry_dt, d['date'], 'long', entry, sl, sl, 0, pts, 'sl'))
                    exited = True
                    i = j + 1
                    break
                # Exit: close > prev day high
                if exit_mode == 'prev_high' and d['close'] > row_today['high']:
                    pts = d['close'] - entry
                    trades.append(Trade(entry_dt, d['date'], 'long', entry, d['close'], sl, 0, pts, 'target'))
                    exited = True
                    i = j + 1
                    break
                # Exit: close > EMA5
                if exit_mode == 'ema5' and d['close'] > d['ema5']:
                    pts = d['close'] - entry
                    trades.append(Trade(entry_dt, d['date'], 'long', entry, d['close'], sl, 0, pts, 'ema5'))
                    exited = True
                    i = j + 1
                    break
            if not exited:
                d = daily.iloc[min(i+max_hold, len(daily)-1)]
                pts = d['close'] - entry
                trades.append(Trade(entry_dt, d['date'], 'long', entry, d['close'], sl, 0, pts, 'timeout'))
                i = min(i+max_hold, len(daily)-1) + 1
            continue

        # SELL signal: high IBS
        if ibs > ibs_high:
            if use_rsi_filter and row_today['rsi'] < (100 - rsi_threshold):
                i += 1
                continue
            entry = row_today['close']
            entry_dt = row_today['date']
            sl = entry + row_today['atr14'] * sl_atr_mult if not np.isnan(row_today['atr14']) else entry + 200
            held = 0
            exited = False
            for j in range(i+1, min(i+1+max_hold, len(daily))):
                held += 1
                d = daily.iloc[j]
                if d['high'] >= sl:
                    pts = entry - sl
                    trades.append(Trade(entry_dt, d['date'], 'short', entry, sl, sl, 0, pts, 'sl'))
                    exited = True
                    i = j + 1
                    break
                if exit_mode == 'prev_high' and d['close'] < row_today['low']:
                    pts = entry - d['close']
                    trades.append(Trade(entry_dt, d['date'], 'short', entry, d['close'], sl, 0, pts, 'target'))
                    exited = True
                    i = j + 1
                    break
                if exit_mode == 'ema5' and d['close'] < d['ema5']:
                    pts = entry - d['close']
                    trades.append(Trade(entry_dt, d['date'], 'short', entry, d['close'], sl, 0, pts, 'ema5'))
                    exited = True
                    i = j + 1
                    break
            if not exited:
                d = daily.iloc[min(i+max_hold, len(daily)-1)]
                pts = entry - d['close']
                trades.append(Trade(entry_dt, d['date'], 'short', entry, d['close'], sl, 0, pts, 'timeout'))
                i = min(i+max_hold, len(daily)-1) + 1
            continue
        i += 1
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 3: RSI(2) Mean Reversion
# Buy when RSI(2) < threshold, sell when RSI(2) > (100-threshold)
# ══════════════════════════════════════════════════════════════════════════════
def run_rsi2(daily, rsi_low=10, rsi_high=90, exit_mode='rsi_cross',
             max_hold=5, sl_atr_mult=1.5):
    trades = []
    i = 20  # skip warmup
    while i < len(daily) - 1:
        d = daily.iloc[i]
        rsi = d['rsi']

        if np.isnan(rsi) or np.isnan(d['atr14']):
            i += 1
            continue

        # BUY: RSI(2) oversold
        if rsi < rsi_low:
            entry = d['close']
            entry_dt = d['date']
            sl = entry - d['atr14'] * sl_atr_mult
            exited = False
            for j in range(i+1, min(i+1+max_hold, len(daily))):
                nxt = daily.iloc[j]
                if nxt['low'] <= sl:
                    trades.append(Trade(entry_dt, nxt['date'], 'long', entry, sl, sl, 0, sl-entry, 'sl'))
                    exited = True; i = j+1; break
                if exit_mode == 'rsi_cross' and nxt['rsi'] > 70:
                    pts = nxt['close'] - entry
                    trades.append(Trade(entry_dt, nxt['date'], 'long', entry, nxt['close'], sl, 0, pts, 'rsi_exit'))
                    exited = True; i = j+1; break
                if exit_mode == 'ema5' and nxt['close'] > nxt['ema5']:
                    pts = nxt['close'] - entry
                    trades.append(Trade(entry_dt, nxt['date'], 'long', entry, nxt['close'], sl, 0, pts, 'ema5'))
                    exited = True; i = j+1; break
            if not exited:
                nxt = daily.iloc[min(i+max_hold, len(daily)-1)]
                pts = nxt['close'] - entry
                trades.append(Trade(entry_dt, nxt['date'], 'long', entry, nxt['close'], sl, 0, pts, 'timeout'))
                i = min(i+max_hold, len(daily)-1)+1
            continue

        # SELL: RSI(2) overbought
        if rsi > rsi_high:
            entry = d['close']
            entry_dt = d['date']
            sl = entry + d['atr14'] * sl_atr_mult
            exited = False
            for j in range(i+1, min(i+1+max_hold, len(daily))):
                nxt = daily.iloc[j]
                if nxt['high'] >= sl:
                    trades.append(Trade(entry_dt, nxt['date'], 'short', entry, sl, sl, 0, entry-sl, 'sl'))
                    exited = True; i = j+1; break
                if exit_mode == 'rsi_cross' and nxt['rsi'] < 30:
                    pts = entry - nxt['close']
                    trades.append(Trade(entry_dt, nxt['date'], 'short', entry, nxt['close'], sl, 0, pts, 'rsi_exit'))
                    exited = True; i = j+1; break
                if exit_mode == 'ema5' and nxt['close'] < nxt['ema5']:
                    pts = entry - nxt['close']
                    trades.append(Trade(entry_dt, nxt['date'], 'short', entry, nxt['close'], sl, 0, pts, 'ema5'))
                    exited = True; i = j+1; break
            if not exited:
                nxt = daily.iloc[min(i+max_hold, len(daily)-1)]
                pts = entry - nxt['close']
                trades.append(Trade(entry_dt, nxt['date'], 'short', entry, nxt['close'], sl, 0, pts, 'timeout'))
                i = min(i+max_hold, len(daily)-1)+1
            continue
        i += 1
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 4: Gap Fade
# Fade opening gaps > threshold, target gap fill
# ══════════════════════════════════════════════════════════════════════════════
def run_gap_fade(daily, min_gap_pct=0.003, max_hold=3, sl_atr_mult=1.0):
    trades = []
    for i in range(20, len(daily)-1):
        d = daily.iloc[i]
        prev = daily.iloc[i-1]
        if np.isnan(d['atr14']):
            continue
        gap = d['open'] - prev['close']
        gap_pct = abs(gap) / prev['close']
        if gap_pct < min_gap_pct:
            continue

        entry = d['open']
        entry_dt = d['date']

        if gap > 0:  # gap up → short (fade)
            tp = prev['close']
            sl = entry + d['atr14'] * sl_atr_mult
            exited = False
            for j in range(i, min(i+max_hold, len(daily))):
                nxt = daily.iloc[j]
                if nxt['high'] >= sl:
                    trades.append(Trade(entry_dt, nxt['date'], 'short', entry, sl, sl, tp, entry-sl, 'sl'))
                    exited = True; break
                if nxt['low'] <= tp:
                    trades.append(Trade(entry_dt, nxt['date'], 'short', entry, tp, sl, tp, entry-tp, 'tp'))
                    exited = True; break
            if not exited:
                nxt = daily.iloc[min(i+max_hold-1, len(daily)-1)]
                pts = entry - nxt['close']
                trades.append(Trade(entry_dt, nxt['date'], 'short', entry, nxt['close'], sl, tp, pts, 'timeout'))
        else:  # gap down → long (fade)
            tp = prev['close']
            sl = entry - d['atr14'] * sl_atr_mult
            exited = False
            for j in range(i, min(i+max_hold, len(daily))):
                nxt = daily.iloc[j]
                if nxt['low'] <= sl:
                    trades.append(Trade(entry_dt, nxt['date'], 'long', entry, sl, sl, tp, sl-entry, 'sl'))
                    exited = True; break
                if nxt['high'] >= tp:
                    trades.append(Trade(entry_dt, nxt['date'], 'long', entry, tp, sl, tp, tp-entry, 'tp'))
                    exited = True; break
            if not exited:
                nxt = daily.iloc[min(i+max_hold-1, len(daily)-1)]
                pts = nxt['close'] - entry
                trades.append(Trade(entry_dt, nxt['date'], 'long', entry, nxt['close'], sl, tp, pts, 'timeout'))
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 5: First Candle Breakout (NY open)
# Trade breakout of the first M5 candle after NY open (15:30 CET)
# ══════════════════════════════════════════════════════════════════════════════
def run_first_candle(df, open_hm=15*60+30, rr=3.0, eod=21*60):
    trades = []
    for date, day_bars in df.groupby('date'):
        # First candle at NY open
        fc = day_bars[day_bars['hm'] == open_hm]
        if fc.empty:
            continue
        fc = fc.iloc[0]
        fc_high = fc['high']
        fc_low = fc['low']
        fc_size = fc_high - fc_low
        if fc_size <= 0:
            continue

        tp_dist = fc_size * rr
        sl_dist = fc_size
        post = day_bars[day_bars['hm'] > open_hm]
        if post.empty:
            continue

        traded = False
        for idx, b in post.iterrows():
            if traded or b['hm'] >= eod:
                break
            if b['high'] > fc_high:
                entry = fc_high
                t = simulate_trade(post[post.index >= idx], 'long',
                                   entry, entry - sl_dist, entry + tp_dist, eod)
                if t:
                    t.range_size = fc_size
                    trades.append(t)
                    traded = True
            elif b['low'] < fc_low:
                entry = fc_low
                t = simulate_trade(post[post.index >= idx], 'short',
                                   entry, entry + sl_dist, entry - tp_dist, eod)
                if t:
                    t.range_size = fc_size
                    trades.append(t)
                    traded = True
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# STRATEGY 6: Previous Day High/Low Breakout
# Trade breakout of previous day's high/low during NY session
# ══════════════════════════════════════════════════════════════════════════════
def run_prev_day_breakout(df, daily, rr=2.0, eod=21*60, session_start=15*60+30, sl_mult=0.5, fixed_tp=0):
    trades = []
    daily_dict = {}
    for _, d in daily.iterrows():
        daily_dict[d['date'].date() if hasattr(d['date'], 'date') else d['date']] = d

    for date, day_bars in df.groupby('date'):
        prev_date = pd.Timestamp(date) - pd.Timedelta(days=1)
        # Find previous trading day
        prev = None
        for offset in range(1, 5):
            candidate = (pd.Timestamp(date) - pd.Timedelta(days=offset))
            cdate = candidate.date() if hasattr(candidate, 'date') else candidate
            if cdate in daily_dict:
                prev = daily_dict[cdate]
                break
        if prev is None:
            continue

        prev_high = prev['high']
        prev_low = prev['low']
        range_size = prev_high - prev_low
        if range_size <= 0:
            continue

        tp_dist = fixed_tp if fixed_tp > 0 else range_size * rr
        sl_dist = range_size * sl_mult

        session = day_bars[day_bars['hm'] >= session_start]
        if session.empty:
            continue

        traded = False
        for idx, b in session.iterrows():
            if traded or b['hm'] >= eod:
                break
            if b['high'] > prev_high:
                entry = prev_high
                t = simulate_trade(session[session.index >= idx], 'long',
                                   entry, entry - sl_dist, entry + tp_dist, eod)
                if t:
                    t.range_size = range_size
                    trades.append(t)
                    traded = True
            elif b['low'] < prev_low:
                entry = prev_low
                t = simulate_trade(session[session.index >= idx], 'short',
                                   entry, entry + sl_dist, entry - tp_dist, eod)
                if t:
                    t.range_size = range_size
                    trades.append(t)
                    traded = True
    return trades

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == '__main__':
    print("Loading data...")
    df = load_data('/Users/eduardocarvalho/workspace/projects/daily-bot/UsaTecM5.csv')
    daily = build_daily(df)
    print(f"{len(df)} bars, {daily.shape[0]} trading days")

    print("\n" + "="*90)
    print("STRATEGY COMPARISON")
    print("="*90)
    print(hdr())

    # ── ORB variants ──────────────────────────────────────────────────────────
    results = []

    orb_base = run_orb(df)
    s = calc_stats(orb_base, "ORB 15:00-15:30 rr=3 eod=21h (baseline)")
    if s: print(row(s)); results.append(('orb_base', s, orb_base))

    orb_vwap = run_orb(df, vwap_filter=True)
    s = calc_stats(orb_vwap, "ORB + VWAP filter")
    if s: print(row(s)); results.append(('orb_vwap', s, orb_vwap))

    orb_vol = run_orb(df, vol_filter=True, vol_mult=1.0)
    s = calc_stats(orb_vol, "ORB + Volume filter (1.0x)")
    if s: print(row(s)); results.append(('orb_vol', s, orb_vol))

    orb_vol15 = run_orb(df, vol_filter=True, vol_mult=1.5)
    s = calc_stats(orb_vol15, "ORB + Volume filter (1.5x)")
    if s: print(row(s)); results.append(('orb_vol15', s, orb_vol15))

    orb_both = run_orb(df, vwap_filter=True, vol_filter=True, vol_mult=1.0)
    s = calc_stats(orb_both, "ORB + VWAP + Volume (1.0x)")
    if s: print(row(s)); results.append(('orb_both', s, orb_both))

    # ORB with different RR
    for rr in [2.0, 2.5, 4.0, 5.0]:
        t = run_orb(df, rr=rr)
        s = calc_stats(t, f"ORB rr={rr}")
        if s: print(row(s)); results.append((f'orb_rr{rr}', s, t))

    # First candle breakout
    for rr in [2.0, 3.0, 4.0]:
        t = run_first_candle(df, rr=rr)
        s = calc_stats(t, f"First Candle Breakout rr={rr}")
        if s: print(row(s)); results.append((f'fcb_rr{rr}', s, t))

    print("\n" + "-"*90)
    print("MEAN REVERSION STRATEGIES (daily timeframe)")
    print("-"*90)
    print(hdr())

    # ── IBS variants ──────────────────────────────────────────────────────────
    for ibs_low, ibs_high in [(0.1, 0.9), (0.15, 0.85), (0.2, 0.8), (0.25, 0.75)]:
        t = run_ibs(daily, ibs_low=ibs_low, ibs_high=ibs_high)
        s = calc_stats(t, f"IBS <{ibs_low} / >{ibs_high}")
        if s: print(row(s)); results.append((f'ibs_{ibs_low}', s, t))

    # IBS + RSI filter
    t = run_ibs(daily, ibs_low=0.2, ibs_high=0.8, use_rsi_filter=True, rsi_threshold=30)
    s = calc_stats(t, "IBS 0.2/0.8 + RSI(2)<30 filter")
    if s: print(row(s)); results.append(('ibs_rsi', s, t))

    # IBS with EMA5 exit
    t = run_ibs(daily, ibs_low=0.2, ibs_high=0.8, exit_mode='ema5')
    s = calc_stats(t, "IBS 0.2/0.8 exit=EMA5")
    if s: print(row(s)); results.append(('ibs_ema5', s, t))

    # IBS long-only (buy dips only)
    t = run_ibs(daily, ibs_low=0.2, ibs_high=999)
    s = calc_stats(t, "IBS <0.2 long-only")
    if s: print(row(s)); results.append(('ibs_long', s, t))

    # ── RSI(2) ────────────────────────────────────────────────────────────────
    for rsi_low, rsi_high in [(5, 95), (10, 90), (15, 85), (20, 80)]:
        t = run_rsi2(daily, rsi_low=rsi_low, rsi_high=rsi_high)
        s = calc_stats(t, f"RSI(2) <{rsi_low} / >{rsi_high}")
        if s: print(row(s)); results.append((f'rsi2_{rsi_low}', s, t))

    t = run_rsi2(daily, rsi_low=10, rsi_high=90, exit_mode='ema5')
    s = calc_stats(t, "RSI(2) 10/90 exit=EMA5")
    if s: print(row(s)); results.append(('rsi2_ema5', s, t))

    # ── Gap Fade ──────────────────────────────────────────────────────────────
    for gap_pct in [0.002, 0.003, 0.005, 0.008]:
        t = run_gap_fade(daily, min_gap_pct=gap_pct)
        s = calc_stats(t, f"Gap Fade >{gap_pct*100:.1f}%")
        if s: print(row(s)); results.append((f'gap_{gap_pct}', s, t))

    # ── Prev Day H/L Breakout ────────────────────────────────────────────────
    for rr in [1.5, 2.0, 3.0]:
        t = run_prev_day_breakout(df, daily, rr=rr)
        s = calc_stats(t, f"Prev Day H/L Breakout rr={rr}")
        if s: print(row(s)); results.append((f'pdhl_{rr}', s, t))

    # ══════════════════════════════════════════════════════════════════════════
    # PORTFOLIO: Combine best breakout + best mean reversion
    # ══════════════════════════════════════════════════════════════════════════
    print("\n" + "="*90)
    print("COMPOUNDING SIMULATION (1.5% risk, $10k start)")
    print("="*90)

    # Sort results by net pts
    sorted_results = sorted([r for r in results if r[1]], key=lambda x: x[1]['net'], reverse=True)

    print(f"\n{'Strategy':<55} {'Net Pts':>8} {'Final $':>10} {'CAGR':>8}")
    for name, s, trades in sorted_results[:10]:
        if trades:
            final_eq, _ = compound_equity(trades, risk_pct=0.015, point_value=5.0)
            months = 18  # approx dataset span
            cagr = ((final_eq / 10000) ** (12/months) - 1) * 100 if final_eq > 0 else 0
            print(f"{s['label']:<55} {s['net']:>8.1f} {final_eq:>10,.0f} {cagr:>7.1f}%")

    # ── Multi-strategy portfolio ─────────────────────────────────────────────
    print("\n" + "="*90)
    print("MULTI-STRATEGY PORTFOLIO (non-overlapping)")
    print("="*90)

    # Combine ORB (intraday) + IBS (daily) — they don't conflict
    orb_trades = run_orb(df)
    ibs_trades = run_ibs(daily, ibs_low=0.2, ibs_high=0.8)

    # Tag trades with strategy for identification
    all_trades = []
    for t in orb_trades:
        t2 = Trade(t.entry_dt, t.exit_dt, t.direction, t.entry, t.exit_price,
                   t.sl, t.tp, t.pts, t.exit_reason, t.range_size, t.dow)
        all_trades.append(t2)
    for t in ibs_trades:
        t2 = Trade(t.entry_dt, t.exit_dt, t.direction, t.entry, t.exit_price,
                   t.sl, t.tp, t.pts, t.exit_reason, t.range_size, t.dow)
        all_trades.append(t2)

    # Sort by entry date
    all_trades.sort(key=lambda t: str(t.entry_dt))

    s_orb = calc_stats(orb_trades, "ORB alone")
    s_ibs = calc_stats(ibs_trades, "IBS alone")
    s_combined = calc_stats(all_trades, "ORB + IBS combined")

    print(hdr())
    if s_orb: print(row(s_orb))
    if s_ibs: print(row(s_ibs))
    if s_combined: print(row(s_combined))

    if all_trades:
        final_eq, curve = compound_equity(all_trades, risk_pct=0.01, point_value=5.0)
        print(f"\nCombined portfolio (1% risk each): $10,000 → ${final_eq:,.0f}")

    # Also try ORB + RSI(2)
    rsi_trades = run_rsi2(daily, rsi_low=10, rsi_high=90)
    combo2 = sorted(orb_trades + rsi_trades, key=lambda t: str(t.entry_dt))
    s_combo2 = calc_stats(combo2, "ORB + RSI(2) combined")
    if s_combo2: print(row(s_combo2))

    print("\n" + "="*90)
    print("TOP 5 STRATEGIES BY NET POINTS")
    print("="*90)
    print(hdr())
    for name, s, trades in sorted_results[:5]:
        print(row(s))

    # ══════════════════════════════════════════════════════════════════════════
    # DEEP DIVE: Prev Day H/L Breakout (best strategy)
    # ══════════════════════════════════════════════════════════════════════════
    print("\n" + "="*90)
    print("DEEP DIVE: Previous Day H/L Breakout")
    print("="*90)

    # Different SL multipliers
    print("\nSL sensitivity (rr=3.0):")
    print(hdr())
    for sl_mult in [0.25, 0.33, 0.5, 0.75, 1.0]:
        t = run_prev_day_breakout(df, daily, rr=3.0, sl_mult=sl_mult)
        s = calc_stats(t, f"PrevDay rr=3.0 sl={sl_mult}x range")
        if s: print(row(s))

    # Different session starts
    print("\nSession start sensitivity (rr=3.0, sl=0.5x):")
    print(hdr())
    for start in [9*60, 10*60, 14*60, 15*60, 15*60+30, 16*60]:
        t = run_prev_day_breakout(df, daily, rr=3.0, session_start=start)
        s = calc_stats(t, f"PrevDay start={start//60}:{start%60:02d}")
        if s: print(row(s))

    # Compounding with ATR-based sizing for PrevDay
    print("\nCompounding with ATR-based sizing:")
    pdhl = run_prev_day_breakout(df, daily, rr=3.0)
    # Use SL distance as range_size for proper lot calc
    for t in pdhl:
        # SL is 0.5x of prev day range, so risk per point is half the range
        t.range_size = abs(t.entry - t.sl)

    final_eq, _ = compound_equity(pdhl, risk_pct=0.015, point_value=5.0)
    print(f"PrevDay H/L rr=3.0 (sizing by SL dist): $10,000 -> ${final_eq:,.0f}")

    final_eq2, _ = compound_equity(pdhl, risk_pct=0.02, point_value=5.0)
    print(f"PrevDay H/L rr=3.0 (2% risk):            $10,000 -> ${final_eq2:,.0f}")

    # Best combo: ORB rr=4 + PrevDay + IBS long-only
    print("\n" + "="*90)
    print("ULTIMATE PORTFOLIO: ORB rr=4 + PrevDay H/L rr=3 + IBS long-only")
    print("="*90)

    orb4 = run_orb(df, rr=4.0)
    pdhl3 = run_prev_day_breakout(df, daily, rr=3.0)
    ibs_long = run_ibs(daily, ibs_low=0.2, ibs_high=999)

    # Fix range_size for pdhl for proper compounding
    for t in pdhl3:
        t.range_size = abs(t.entry - t.sl)

    mega = sorted(orb4 + pdhl3 + ibs_long, key=lambda t: str(t.entry_dt))
    s_mega = calc_stats(mega, "ORB4 + PrevDay + IBS_long")
    print(hdr())
    if s_mega: print(row(s_mega))

    final_mega, _ = compound_equity(mega, risk_pct=0.01, point_value=5.0)
    print(f"\nCompounded (1% risk each): $10,000 -> ${final_mega:,.0f}")

    final_mega15, _ = compound_equity(mega, risk_pct=0.015, point_value=5.0)
    print(f"Compounded (1.5% risk each): $10,000 -> ${final_mega15:,.0f}")

    # ══════════════════════════════════════════════════════════════════════════
    # WALK-FORWARD VALIDATION of best strategies
    # ══════════════════════════════════════════════════════════════════════════
    print("\n" + "="*90)
    print("WALK-FORWARD VALIDATION (6-month train, 3-month test)")
    print("="*90)

    df_copy = df.copy()
    df_copy['ym'] = df_copy['datetime'].dt.to_period('M')
    months = sorted(df_copy['ym'].unique())

    daily_copy = daily.copy()
    daily_copy['ym'] = daily_copy['date'].dt.to_period('M')

    strategies_to_validate = [
        ("ORB rr=4.0", lambda d, dl: run_orb(d, rr=4.0)),
        ("PrevDay rr=3 start=15:30", lambda d, dl: run_prev_day_breakout(d, dl, rr=3.0, session_start=15*60+30)),
        ("PrevDay rr=3 start=16:00", lambda d, dl: run_prev_day_breakout(d, dl, rr=3.0, session_start=16*60)),
        ("IBS <0.2 long-only", lambda d, dl: run_ibs(dl, ibs_low=0.2, ibs_high=999)),
    ]

    window = 6; step = 3
    for strat_name, strat_fn in strategies_to_validate:
        print(f"\n--- {strat_name} ---")
        print(f"{'Period':<20} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6}")
        total_net = 0; total_n = 0
        i = window
        while i + step <= len(months):
            test_start = months[i]
            test_end = months[min(i + step - 1, len(months)-1)]
            test_df = df_copy[(df_copy['ym'] >= test_start) & (df_copy['ym'] <= test_end)]
            test_daily = daily_copy[(daily_copy['ym'] >= test_start) & (daily_copy['ym'] <= test_end)]
            trades = strat_fn(test_df, test_daily)
            if trades:
                s = calc_stats(trades)
                total_net += s['net']
                total_n += s['n']
                print(f"{str(test_start)+'–'+str(test_end):<20} {s['n']:>5} {s['net']:>8.1f} {s['pf']:>6.3f} {s['wr']:>5.1f}%")
            i += step
        print(f"{'TOTAL OOS':<20} {total_n:>5} {total_net:>8.1f}")

    # ══════════════════════════════════════════════════════════════════════════
    # MONTHLY BREAKDOWN of best strategy
    # ══════════════════════════════════════════════════════════════════════════
    print("\n" + "="*90)
    print("MONTHLY PnL: PrevDay H/L rr=3 start=16:00")
    print("="*90)
    pdhl_best = run_prev_day_breakout(df, daily, rr=3.0, session_start=16*60)
    df_t = pd.DataFrame([{'month': str(t.entry_dt)[:7], 'pts': t.pts, 'dir': t.direction} for t in pdhl_best])
    monthly = df_t.groupby('month')['pts'].agg(['sum','count','mean']).round(1)
    monthly['positive'] = monthly['sum'] > 0
    print(monthly.to_string())
    pos = monthly['positive'].sum()
    print(f"\nPositive months: {pos}/{len(monthly)} ({100*pos/len(monthly):.0f}%)")

    # Direction split
    print("\nDirection split:")
    print(df_t.groupby('dir')['pts'].agg(['count','sum','mean']).round(1).to_string())

    # ══════════════════════════════════════════════════════════════════════════
    # FIXED TP TEST
    # ══════════════════════════════════════════════════════════════════════════
    print("\n" + "="*90)
    print("FIXED TP TEST: PrevDay H/L start=16:00 sl=0.5x")
    print("="*90)
    print(hdr())
    for ftp in [5, 10, 15, 20, 30, 50, 75, 100, 150, 200]:
        t = run_prev_day_breakout(df, daily, rr=3.0, session_start=16*60, fixed_tp=ftp)
        s = calc_stats(t, f"FixedTP={ftp} pts")
        if s: print(row(s))
