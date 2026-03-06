"""
Deep analysis and optimization of ORB strategy.
Best base config: range 15:00-15:30 CET, RR=3.0, EOD=21:00 CET.
Server = CET. NY open = 15:30 CET.
"""

import pandas as pd
import numpy as np
from dataclasses import dataclass
from typing import List, Optional
import warnings
warnings.filterwarnings('ignore')

# ── data loading ───────────────────────────────────────────────────────────
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
    df['dow']    = df['datetime'].dt.dayofweek  # 0=Mon, 4=Fri
    return df.sort_values('datetime').reset_index(drop=True)

# ── trade simulation ────────────────────────────────────────────────────────
@dataclass
class Trade:
    entry_dt: pd.Timestamp
    exit_dt:  pd.Timestamp
    direction: str
    entry: float
    exit_price: float
    sl: float
    tp: float
    pts: float
    exit_reason: str
    range_size: float
    dow: int

def simulate(bars: pd.DataFrame, direction: str, entry: float,
             sl: float, tp: float, eod_hm: int) -> Optional[Trade]:
    if bars.empty:
        return None
    entry_dt = bars.iloc[0]['datetime']
    dow = bars.iloc[0]['dow']
    for _, b in bars.iterrows():
        if direction == 'long':
            if b['low'] <= sl:
                return Trade(entry_dt, b['datetime'], direction, entry, sl,
                             sl, tp, sl - entry, 'sl', abs(tp - sl) / 3, dow)
            if b['high'] >= tp:
                return Trade(entry_dt, b['datetime'], direction, entry, tp,
                             sl, tp, tp - entry, 'tp', abs(tp - sl) / 3, dow)
        else:
            if b['high'] >= sl:
                return Trade(entry_dt, b['datetime'], direction, entry, sl,
                             sl, tp, entry - sl, 'sl', abs(tp - sl) / 3, dow)
            if b['low'] <= tp:
                return Trade(entry_dt, b['datetime'], direction, entry, tp,
                             sl, tp, entry - tp, 'tp', abs(tp - sl) / 3, dow)
        if b['hm'] >= eod_hm:
            cp = b['close']
            pts = (cp - entry) if direction == 'long' else (entry - cp)
            return Trade(entry_dt, b['datetime'], direction, entry, cp,
                         sl, tp, pts, 'eod', abs(tp - sl) / 3, dow)
    last = bars.iloc[-1]
    cp = last['close']
    pts = (cp - entry) if direction == 'long' else (entry - cp)
    return Trade(entry_dt, last['datetime'], direction, entry, cp,
                 sl, tp, pts, 'eod', abs(tp - sl) / 3, dow)

def run_orb(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60,
            min_range=0, max_range=99999,
            long_only=False, short_only=False,
            trend_filter_period=0,   # 0 = disabled
            avoid_monday=False, avoid_friday=False) -> List[Trade]:
    trades = []
    # Compute trend EMA if needed
    if trend_filter_period > 0:
        df = df.copy()
        df['trend_ema'] = df['close'].ewm(span=trend_filter_period, adjust=False).mean()

    for date, day_bars in df.groupby('date'):
        dow = day_bars.iloc[0]['dow']
        if avoid_monday and dow == 0:
            continue
        if avoid_friday and dow == 4:
            continue

        rbars = day_bars[(day_bars['hm'] >= rs) & (day_bars['hm'] < re)]
        if len(rbars) < 2:
            continue

        or_high = rbars['high'].max()
        or_low  = rbars['low'].min()
        or_size = or_high - or_low
        if or_size < min_range or or_size > max_range:
            continue

        tp_dist = or_size * rr
        sl_dist = or_size

        post = day_bars[day_bars['hm'] >= re].copy()
        if post.empty:
            continue

        # Trend at range end
        if trend_filter_period > 0:
            trend_bar = day_bars[day_bars['hm'] < re].iloc[-1]
            price_vs_ema = trend_bar['close'] - trend_bar['trend_ema']
        else:
            price_vs_ema = 0

        traded = False
        for idx, b in post.iterrows():
            if traded or b['hm'] >= eod:
                break
            # Trend filter: if period > 0, only trade in trend direction
            can_long  = not short_only and (trend_filter_period == 0 or price_vs_ema > 0)
            can_short = not long_only  and (trend_filter_period == 0 or price_vs_ema < 0)

            if can_long and b['high'] > or_high:
                entry = or_high
                t = simulate(post[post.index >= idx], 'long',
                             entry, entry - sl_dist, entry + tp_dist, eod)
                if t:
                    t.range_size = or_size
                    t.dow = dow
                    trades.append(t)
                    traded = True
            elif can_short and b['low'] < or_low:
                entry = or_low
                t = simulate(post[post.index >= idx], 'short',
                             entry, entry + sl_dist, entry - tp_dist, eod)
                if t:
                    t.range_size = or_size
                    t.dow = dow
                    trades.append(t)
                    traded = True
    return trades

def stats(trades, label=''):
    if not trades:
        return {}
    pts = [t.pts for t in trades]
    wins   = [p for p in pts if p > 0]
    losses = [p for p in pts if p <= 0]
    gp = sum(wins);  gl = abs(sum(losses))
    net = sum(pts);  pf = gp/gl if gl else float('inf')
    wr  = len(wins)/len(pts)*100
    cum = np.cumsum(pts)
    dd  = (cum - np.maximum.accumulate(cum)).min()
    sh  = net / (np.std(pts) * np.sqrt(len(pts))) if np.std(pts) > 0 else 0
    return dict(label=label, n=len(trades), net=round(net,1), pf=round(pf,3),
                wr=round(wr,1), max_dd=round(dd,1), sharpe=round(sh,3),
                avg_win=round(np.mean(wins) if wins else 0,1),
                avg_loss=round(np.mean(losses) if losses else 0,1))

def hdr():
    return f"{'Label':<55} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8} {'Sharpe':>7}"

def row(s):
    return (f"{s['label']:<55} {s['n']:>5} {s['net']:>8.1f} {s['pf']:>6.3f} "
            f"{s['wr']:>6.1f}% {s['max_dd']:>8.1f} {s['sharpe']:>7.3f}")

# ─────────────────────────────────────────────────────────────────────────────
# 1. Walk-forward validation
# ─────────────────────────────────────────────────────────────────────────────
def walk_forward(df, rs, re, rr, eod, window_months=6, step_months=3):
    """
    Walk-forward: train on window_months, test on next step_months.
    Shows out-of-sample performance.
    """
    df = df.copy()
    df['ym'] = df['datetime'].dt.to_period('M')
    months = sorted(df['ym'].unique())
    results = []

    i = window_months
    while i + step_months <= len(months):
        test_start = months[i]
        test_end   = months[min(i + step_months - 1, len(months)-1)]
        test_df = df[(df['ym'] >= test_start) & (df['ym'] <= test_end)]
        trades  = run_orb(test_df, rs=rs, re=re, rr=rr, eod=eod)
        if trades:
            s = stats(trades, f"{test_start}–{test_end}")
            results.append(s)
        i += step_months

    return results

# ─────────────────────────────────────────────────────────────────────────────
# 2. Filter experiments
# ─────────────────────────────────────────────────────────────────────────────
def filter_experiments(df):
    base = dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60)
    results = []

    configs = [
        ("Baseline",                    {}),
        ("Short only",                  dict(short_only=True)),
        ("Long only",                   dict(long_only=True)),
        ("No Monday",                   dict(avoid_monday=True)),
        ("No Friday",                   dict(avoid_friday=True)),
        ("No Mon+Fri",                  dict(avoid_monday=True, avoid_friday=True)),
        ("Min range 30",                dict(min_range=30)),
        ("Min range 50",                dict(min_range=50)),
        ("Max range 150",               dict(max_range=150)),
        ("Range 30-150",                dict(min_range=30, max_range=150)),
        ("Trend EMA50",                 dict(trend_filter_period=50*12)),
        ("Trend EMA20",                 dict(trend_filter_period=20*12)),
        ("Short only + no Mon",         dict(short_only=True, avoid_monday=True)),
        ("Short only + min_range=30",   dict(short_only=True, min_range=30)),
        ("Short only + range 30-200",   dict(short_only=True, min_range=30, max_range=200)),
    ]

    print("\n=== Filter Experiments (base: 15:00-15:30, rr=3.0, eod=21h) ===")
    print(hdr())
    for label, extra in configs:
        params = {**base, **extra}
        trades = run_orb(df, **params)
        s = stats(trades, label)
        if s:
            print(row(s))
            results.append(s)
    return results

# ─────────────────────────────────────────────────────────────────────────────
# 3. EOD time sensitivity
# ─────────────────────────────────────────────────────────────────────────────
def eod_sensitivity(df):
    print("\n=== EOD Time Sensitivity (base: 15:00-15:30, rr=3.0) ===")
    print(hdr())
    for eod_h in range(18, 24):
        trades = run_orb(df, rs=15*60, re=15*60+30, rr=3.0, eod=eod_h*60)
        s = stats(trades, f"EOD={eod_h}:00 CET")
        if s:
            print(row(s))

# ─────────────────────────────────────────────────────────────────────────────
# 4. Range size analysis
# ─────────────────────────────────────────────────────────────────────────────
def range_analysis(df):
    trades = run_orb(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60)
    df_t = pd.DataFrame([{
        'pts': t.pts, 'range': t.range_size, 'direction': t.direction,
        'reason': t.exit_reason, 'dow': t.dow,
    } for t in trades])

    print("\n=== Range Size Quantile Analysis ===")
    df_t['range_q'] = pd.qcut(df_t['range'], 4, labels=['Q1 small','Q2','Q3','Q4 large'])
    print(df_t.groupby('range_q')['pts'].agg(['count','sum','mean']).round(1).to_string())

    print("\n=== Day of Week ===")
    dow_names = {0:'Mon',1:'Tue',2:'Wed',3:'Thu',4:'Fri'}
    df_t['dow_name'] = df_t['dow'].map(dow_names)
    print(df_t.groupby('dow_name')['pts'].agg(['count','sum','mean']).round(1).to_string())

    print("\n=== Exit Reason ===")
    print(df_t.groupby('reason')['pts'].agg(['count','sum','mean']).round(1).to_string())

    print("\n=== Direction split ===")
    print(df_t.groupby('direction')['pts'].agg(['count','sum','mean']).round(1).to_string())

    return df_t

# ─────────────────────────────────────────────────────────────────────────────
# 5. Best combined config final stats + walk-forward
# ─────────────────────────────────────────────────────────────────────────────
def final_analysis(df):
    print("\n" + "="*70)
    print("FINAL STRATEGY SUMMARY")
    print("="*70)

    # Test a few promising variants
    candidates = [
        ("ORB 15:00-15:30 rr=3 eod=21h all",         dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60)),
        ("ORB 15:00-15:30 rr=3 eod=21h short-only",  dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60, short_only=True)),
        ("ORB 15:00-15:30 rr=3 eod=21h no-Mon",      dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60, avoid_monday=True)),
        ("ORB 15:00-15:30 rr=3 eod=21h min30",       dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60, min_range=30)),
        ("ORB 15:00-15:30 rr=2.5 eod=21h all",       dict(rs=15*60, re=15*60+30, rr=2.5, eod=21*60)),
        ("ORB 15:30-16:00 rr=3 eod=21h all",         dict(rs=15*60+30, re=16*60, rr=3.0, eod=21*60)),
    ]

    print("\nFull-sample performance:")
    print(hdr())
    for label, params in candidates:
        trades = run_orb(df, **params)
        s = stats(trades, label)
        if s:
            print(row(s))

    # Walk-forward for best config
    print("\nWalk-forward out-of-sample (6-month train, 3-month test windows):")
    print(f"{'Period':<20} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'MaxDD':>8}")
    wf = walk_forward(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60)
    total_net = 0
    for w in wf:
        total_net += w['net']
        print(f"{w['label']:<20} {w['n']:>5} {w['net']:>8.1f} {w['pf']:>6.3f} "
              f"{w['wr']:>6.1f}% {w['max_dd']:>8.1f}")
    print(f"{'Total OOS':<20} {'':>5} {total_net:>8.1f}")

    # Monthly consistency
    print("\n=== Monthly PnL (best config) ===")
    trades = run_orb(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60)
    df_t = pd.DataFrame([{'month': t.entry_dt.strftime('%Y-%m'), 'pts': t.pts} for t in trades])
    monthly = df_t.groupby('month')['pts'].agg(['sum','count','mean']).round(1)
    monthly['positive'] = monthly['sum'] > 0
    print(monthly.to_string())
    pos_months = monthly['positive'].sum()
    print(f"\nPositive months: {pos_months}/{len(monthly)} ({100*pos_months/len(monthly):.0f}%)")

if __name__ == '__main__':
    print("Loading data...")
    df = load_data('/Users/eduardocarvalho/workspace/projects/daily-bot/UsaTecM5.csv')
    print(f"{len(df)} bars, {df['date'].nunique()} trading days")

    filter_experiments(df)
    eod_sensitivity(df)
    range_analysis(df)
    final_analysis(df)
