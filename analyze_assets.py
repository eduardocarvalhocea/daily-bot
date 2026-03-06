"""
Parameter optimization for Bra50 (WIN mini) and MinDol (WDO mini).
Both CSVs use UTC server time. B3 opens 13:00 UTC, US opens 13:30 UTC.

Usage:
    python analyze_assets.py
"""

import re
import sys
import numpy as np
import pandas as pd
from itertools import product

sys.path.insert(0, '.')
from backtest import load_data, backtest_orb, stats


# ---------------------------------------------------------------------------
# Grid config (UTC times, hm = h*60 + m)
# ---------------------------------------------------------------------------

RANGE_CONFIGS = [
    (13*60,      13*60+30,  "B3-open  13:00-13:30"),
    (13*60,      14*60,     "B3+US    13:00-14:00"),
    (13*60+30,   14*60,     "US-open  13:30-14:00"),
    (13*60,      13*60+15,  "Pre-US   13:00-13:15"),
    (14*60,      14*60+30,  "Mid      14:00-14:30"),
]

RRS     = [2.0, 3.0, 4.0, 5.0]
EOD_HMS = [21*60, 22*60, 23*60]


# ---------------------------------------------------------------------------
# Grid search
# ---------------------------------------------------------------------------

def grid_search(df: pd.DataFrame, asset: str, min_trades: int = 20) -> list:
    results = []
    for (rs, re, rlabel), rr, eod in product(RANGE_CONFIGS, RRS, EOD_HMS):
        trades = backtest_orb(df, range_start_hm=rs, range_end_hm=re,
                              rr=rr, eod_hm=eod, direction_filter='both')
        if len(trades) < min_trades:
            continue
        label = f"{rlabel} rr={rr:.1f} eod={eod//60}h"
        s = stats(trades, label)
        s['_trades'] = trades
        s['_rs'] = rs
        s['_re'] = re
        s['_rr'] = rr
        s['_eod'] = eod
        results.append(s)
    return results


def print_top(results: list, n: int = 10) -> None:
    ranked = sorted(results, key=lambda x: (x.get('sharpe', -99), x.get('net', -99)),
                    reverse=True)
    print(f"{'Label':<48} {'N':>5} {'Net':>9} {'PF':>6} {'WR%':>6} {'MaxDD':>9} {'Sharpe':>7}")
    print("-" * 95)
    for r in ranked[:n]:
        print(f"{r['label']:<48} {r['n']:>5} {r['net']:>9.1f} {r['pf']:>6.3f} "
              f"{r['wr']:>6.1f} {r['max_dd']:>9.1f} {r['sharpe']:>7.3f}")
    return ranked


# ---------------------------------------------------------------------------
# Deep analysis
# ---------------------------------------------------------------------------

def deep_analysis(trades: list, label: str) -> None:
    from backtest import stats as _stats
    s = _stats(trades, label)
    print(f"\n{'='*60}")
    print(f"Deep Analysis: {label}")
    print(f"{'='*60}")
    print(f"Trades={s['n']}  Net={s['net']}  PF={s['pf']}  "
          f"WR={s['wr']}%  MaxDD={s['max_dd']}  Sharpe={s['sharpe']}")

    df_t = pd.DataFrame([{
        'month':     t.entry_dt.strftime('%Y-%m'),
        'pts':       t.pts,
        'reason':    t.exit_reason,
        'direction': t.direction,
    } for t in trades])

    print("\nMonthly PnL (pts):")
    monthly = df_t.groupby('month')['pts'].agg(['sum', 'count', 'mean']).round(1)
    monthly.columns = ['sum', 'n', 'avg']
    print(monthly.to_string())

    print("\nBy direction:")
    print(df_t.groupby('direction')['pts'].agg(['count', 'sum', 'mean']).round(1).to_string())

    print("\nBy exit reason:")
    print(df_t.groupby('reason')['pts'].agg(['count', 'sum', 'mean']).round(1).to_string())

    pts = [t.pts for t in trades]
    streak = max_streak = 0
    for p in pts:
        if p <= 0:
            streak += 1
            max_streak = max(max_streak, streak)
        else:
            streak = 0
    print(f"\nMax consecutive losses: {max_streak}")
    print(f"Avg pts/trade: {np.mean(pts):.2f}")


# ---------------------------------------------------------------------------
# Recommendation printer
# ---------------------------------------------------------------------------

def print_recommendation(asset: str, best: dict) -> None:
    rs  = best['_rs']
    re  = best['_re']
    rr  = best['_rr']
    eod = best['_eod']

    def fmt_hm(hm):
        return f"{hm // 60:02d}:{hm % 60:02d}"

    print(f"\n{'='*60}")
    print(f"bot.mq5 parameters for {asset}  (UTC server time)")
    print(f"{'='*60}")
    print(f"  RangeStart     = {rs}      // {fmt_hm(rs)} UTC")
    print(f"  RangeEnd       = {re}      // {fmt_hm(re)} UTC")
    print(f"  RR             = {rr}")
    print(f"  EOD_HM         = {eod}     // {fmt_hm(eod)} UTC")
    print(f"  PointValue     = ???       // Set from broker contract specs")
    print(f"  // Note: verify pointValue from broker tick value for {asset}")


# ---------------------------------------------------------------------------
# Per-asset analysis
# ---------------------------------------------------------------------------

def analyze(asset: str, csv_path: str, min_trades: int = 20) -> None:
    print(f"\n{'#'*70}")
    print(f"  {asset}")
    print(f"{'#'*70}")

    print(f"Loading {csv_path} ...")
    df = load_data(csv_path)
    print(f"Loaded {len(df):,} bars | "
          f"{df['datetime'].min()} -> {df['datetime'].max()} | "
          f"{df['date'].nunique()} trading days")

    if df['date'].nunique() < 60:
        print("  WARNING: < 60 trading days — results are directional only, "
              "not statistically robust.")

    print(f"\nRunning ORB grid search ({len(RANGE_CONFIGS)} windows x "
          f"{len(RRS)} RRs x {len(EOD_HMS)} EODs = "
          f"{len(RANGE_CONFIGS)*len(RRS)*len(EOD_HMS)} combos) ...")

    results = grid_search(df, asset, min_trades=min_trades)

    if not results:
        print("No configs met the minimum trade threshold. "
              "Try reducing min_trades or checking timestamps.")
        return

    print(f"\nTop 10 configs by Sharpe (then net pts):")
    ranked = print_top(results, n=10)

    best = ranked[0]
    deep_analysis(best['_trades'], best['label'])
    print_recommendation(asset, best)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    BASE = '/Users/eduardocarvalho/wsp/projects/daily-bot/dataset'

    analyze(
        asset     = 'Bra50',
        csv_path  = f'{BASE}/Bra50Apr26M5.csv',
        min_trades= 30,   # 3 years of data — require more
    )

    analyze(
        asset     = 'MinDol',
        csv_path  = f'{BASE}/MinDolApr26M5.csv',
        min_trades= 20,   # ~85 days — lower threshold
    )
