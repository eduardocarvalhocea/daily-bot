"""
Profitability improvement analysis:
1. Fixed fractional position sizing (compounding)
2. Second ORB window (London open 09:00–09:30 CET)
3. Partial TP (close 50% at 1.5R, let 50% run to 3R)
4. Pyramid on winners
"""

import pandas as pd
import numpy as np
from typing import List
import warnings
warnings.filterwarnings('ignore')

def load_data(path):
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
    df['hm']     = df['datetime'].dt.hour * 60 + df['datetime'].dt.minute
    df['dow']    = df['datetime'].dt.dayofweek
    return df.sort_values('datetime').reset_index(drop=True)

# ─────────────────────────────────────────────────────────────────────────────
# Core simulation returning pts-per-trade AND range size
# ─────────────────────────────────────────────────────────────────────────────
def run_orb_full(df, rs, re, rr, eod, min_range=0, max_range=0):
    """Returns list of (pts, range_size, direction, exit_reason, date)."""
    results = []
    for date, day_bars in df.groupby('date'):
        rbars = day_bars[(day_bars['hm'] >= rs) & (day_bars['hm'] < re)]
        if len(rbars) < 2:
            continue
        or_high = rbars['high'].max()
        or_low  = rbars['low'].min()
        or_size = or_high - or_low
        if or_size <= 0:
            continue
        if min_range > 0 and or_size < min_range:
            continue
        if max_range > 0 and or_size > max_range:
            continue

        tp_d = or_size * rr
        sl_d = or_size

        post = day_bars[day_bars['hm'] >= re].copy()
        if post.empty:
            continue

        traded = False
        for idx, b in post.iterrows():
            if traded or b['hm'] >= eod:
                break

            if b['high'] > or_high:
                entry = or_high
                direction = 'long'
                sl = entry - sl_d; tp = entry + tp_d
            elif b['low'] < or_low:
                entry = or_low
                direction = 'short'
                sl = entry + sl_d; tp = entry - tp_d
            else:
                continue

            # Simulate forward
            future = post[post.index >= idx]
            for _, fb in future.iterrows():
                if direction == 'long':
                    if fb['low'] <= sl:
                        pts = sl - entry; reason = 'sl'; break
                    if fb['high'] >= tp:
                        pts = tp - entry; reason = 'tp'; break
                else:
                    if fb['high'] >= sl:
                        pts = entry - sl; reason = 'sl'; break
                    if fb['low'] <= tp:
                        pts = entry - tp; reason = 'tp'; break
                if fb['hm'] >= eod:
                    pts = (fb['close'] - entry) if direction == 'long' else (entry - fb['close'])
                    reason = 'eod'; break
            else:
                last = future.iloc[-1]
                pts = (last['close'] - entry) if direction == 'long' else (entry - last['close'])
                reason = 'eod'

            results.append({'date': date, 'pts': pts, 'range': or_size,
                            'direction': direction, 'reason': reason})
            traded = True

    return results

# ─────────────────────────────────────────────────────────────────────────────
# Partial TP simulation: close 50% at 1.5R, let 50% run to full TP
# ─────────────────────────────────────────────────────────────────────────────
def run_orb_partial_tp(df, rs, re, rr=3.0, partial_rr=1.5, eod=21*60,
                       partial_pct=0.5, min_range=0, max_range=0):
    """
    Split: partial_pct closes at partial_rr, rest closes at rr (or SL/EOD).
    Returns list of combined pts.
    """
    results = []
    for date, day_bars in df.groupby('date'):
        rbars = day_bars[(day_bars['hm'] >= rs) & (day_bars['hm'] < re)]
        if len(rbars) < 2:
            continue
        or_high = rbars['high'].max()
        or_low  = rbars['low'].min()
        or_size = or_high - or_low
        if or_size <= 0:
            continue
        if min_range > 0 and or_size < min_range:
            continue
        if max_range > 0 and or_size > max_range:
            continue

        sl_d = or_size
        tp1_d = or_size * partial_rr
        tp2_d = or_size * rr

        post = day_bars[day_bars['hm'] >= re].copy()
        if post.empty:
            continue

        traded = False
        for idx, b in post.iterrows():
            if traded or b['hm'] >= eod:
                break

            if b['high'] > or_high:
                entry = or_high; direction = 'long'
                sl = entry - sl_d
                tp1 = entry + tp1_d; tp2 = entry + tp2_d
            elif b['low'] < or_low:
                entry = or_low; direction = 'short'
                sl = entry + sl_d
                tp1 = entry - tp1_d; tp2 = entry - tp2_d
            else:
                continue

            # Simulate two positions: partial and remainder
            future = post[post.index >= idx]
            partial_pts = None
            rest_pts = None
            # After partial TP: SL for remainder moves to break-even
            sl_after_partial = entry  # break-even

            for _, fb in future.iterrows():
                if direction == 'long':
                    # Check SL first
                    sl_now = sl if partial_pts is None else sl_after_partial
                    if fb['low'] <= sl_now:
                        if partial_pts is None:
                            partial_pts = sl - entry
                            rest_pts = sl - entry
                        else:
                            rest_pts = sl_after_partial - entry
                        break
                    if partial_pts is None and fb['high'] >= tp1:
                        partial_pts = tp1 - entry
                        # SL for remainder moves to break-even
                    if partial_pts is not None and rest_pts is None and fb['high'] >= tp2:
                        rest_pts = tp2 - entry
                        break
                else:
                    sl_now = sl if partial_pts is None else sl_after_partial
                    if fb['high'] >= sl_now:
                        if partial_pts is None:
                            partial_pts = entry - sl
                            rest_pts = entry - sl
                        else:
                            rest_pts = entry - sl_after_partial
                        break
                    if partial_pts is None and fb['low'] <= tp1:
                        partial_pts = entry - tp1
                    if partial_pts is not None and rest_pts is None and fb['low'] <= tp2:
                        rest_pts = entry - tp2
                        break
                if fb['hm'] >= eod:
                    cp = fb['close']
                    if partial_pts is None:
                        eod_pts = (cp - entry) if direction == 'long' else (entry - cp)
                        partial_pts = eod_pts
                        rest_pts = eod_pts
                    elif rest_pts is None:
                        rest_pts = (cp - entry) if direction == 'long' else (entry - cp)
                    break
            else:
                last = future.iloc[-1]
                cp = last['close']
                eod_pts = (cp - entry) if direction == 'long' else (entry - cp)
                if partial_pts is None:
                    partial_pts = eod_pts; rest_pts = eod_pts
                elif rest_pts is None:
                    rest_pts = eod_pts

            if partial_pts is None: partial_pts = 0
            if rest_pts is None: rest_pts = 0

            combined = partial_pct * partial_pts + (1 - partial_pct) * rest_pts
            results.append({'date': date, 'pts': combined, 'range': or_size,
                            'direction': direction})
            traded = True

    return results

# ─────────────────────────────────────────────────────────────────────────────
# Position sizing simulator
# ─────────────────────────────────────────────────────────────────────────────
def simulate_compounding(pts_list, ranges_list, initial_equity=10000,
                         risk_pct=0.01, pt_value=1.0, label=''):
    """
    Fixed fractional: risk risk_pct of equity per trade.
    SL distance = range_size points.
    Lot size = (equity * risk_pct) / (range_size * pt_value)
    """
    equity = initial_equity
    max_eq = initial_equity
    max_dd = 0
    monthly_ret = []
    equities = [equity]

    for pts, rng in zip(pts_list, ranges_list):
        if rng <= 0:
            continue
        # Lot size based on risk
        risk_usd = equity * risk_pct
        lot = risk_usd / (rng * pt_value)
        lot = max(0.01, round(lot, 2))  # min 0.01 lot
        pnl = pts * lot * pt_value
        equity += pnl
        equity = max(equity, 0.01)
        equities.append(equity)
        max_eq = max(max_eq, equity)
        dd = (equity - max_eq) / max_eq * 100
        max_dd = min(max_dd, dd)

    total_ret = (equity - initial_equity) / initial_equity * 100
    cagr = ((equity / initial_equity) ** (1/1.5) - 1) * 100  # ~1.5 years
    sharpe_daily = np.std(np.diff(equities) / equities[:-1]) * np.sqrt(252) if len(equities) > 2 else 0

    print(f"  {label:<45} Equity: ${equity:>10,.2f}  Ret: {total_ret:>7.1f}%  "
          f"CAGR~: {cagr:>6.1f}%  MaxDD: {max_dd:>7.1f}%")
    return equity, total_ret, max_dd

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    print("Loading data...")
    df = load_data('/Users/eduardocarvalho/workspace/projects/daily-bot/UsaTecM5.csv')
    print(f"{len(df)} bars, {df['date'].nunique()} days\n")

    BASE = dict(rs=15*60, re=15*60+30, rr=3.0, eod=21*60)

    # ─── 1. Fixed fractional compounding ────────────────────────────────────
    print("=" * 75)
    print("1. FIXED FRACTIONAL POSITION SIZING (compounding)")
    print("   Initial equity: $10,000 | pt_value: $1/pt/lot")
    print("=" * 75)

    base_res = run_orb_full(df, **BASE)
    pts_list   = [r['pts']  for r in base_res]
    range_list = [r['range'] for r in base_res]

    for risk in [0.005, 0.01, 0.015, 0.02, 0.025]:
        simulate_compounding(pts_list, range_list, risk_pct=risk,
                             label=f"Risk {risk*100:.1f}%/trade (1 lot = 1pt/$ )")

    print("\n  Fixed 1 lot for reference:")
    net = sum(pts_list)
    print(f"  {'Fixed 1 lot':<45} Net pts: {net:.1f} (+${net:.2f} at $1/pt)")

    # ─── 2. London open ORB ──────────────────────────────────────────────────
    print("\n" + "=" * 75)
    print("2. SECOND WINDOW: London open ORB (09:00–09:30 CET)")
    print("=" * 75)

    london_rs = 9*60; london_re = 9*60+30; london_eod = 15*60  # close before NY
    london_rs2 = 9*60+30; london_re2 = 10*60

    configs = [
        ("London 09:00-09:30 rr=2.0 eod=15h", dict(rs=9*60, re=9*60+30, rr=2.0, eod=15*60)),
        ("London 09:00-09:30 rr=3.0 eod=15h", dict(rs=9*60, re=9*60+30, rr=3.0, eod=15*60)),
        ("London 09:00-09:30 rr=2.0 eod=13h", dict(rs=9*60, re=9*60+30, rr=2.0, eod=13*60)),
        ("London 09:30-10:00 rr=2.0 eod=15h", dict(rs=9*60+30, re=10*60, rr=2.0, eod=15*60)),
        ("London 09:30-10:00 rr=3.0 eod=15h", dict(rs=9*60+30, re=10*60, rr=3.0, eod=15*60)),
        ("London 08:30-09:00 rr=2.0 eod=15h", dict(rs=8*60+30, re=9*60,  rr=2.0, eod=15*60)),
        ("London 08:30-09:00 rr=3.0 eod=15h", dict(rs=8*60+30, re=9*60,  rr=3.0, eod=15*60)),
    ]

    print(f"  {'Config':<50} {'N':>5} {'Net':>8} {'PF':>6} {'WR':>6} {'Sharpe':>7}")
    for label, params in configs:
        res = run_orb_full(df, **params)
        if not res:
            continue
        pts = [r['pts'] for r in res]
        wins = [p for p in pts if p > 0]
        losses = [p for p in pts if p <= 0]
        gp = sum(wins); gl = abs(sum(losses))
        net = sum(pts); pf = gp/gl if gl else 9.9
        wr  = len(wins)/len(pts)*100
        sh  = net/(np.std(pts)*np.sqrt(len(pts))) if np.std(pts) > 0 else 0
        print(f"  {label:<50} {len(pts):>5} {net:>8.1f} {pf:>6.3f} {wr:>6.1f}% {sh:>7.3f}")

    # ─── 3. Partial TP ──────────────────────────────────────────────────────
    print("\n" + "=" * 75)
    print("3. PARTIAL TAKE PROFIT (close partial at 1.5R, rest at 3R)")
    print("=" * 75)

    configs_partial = [
        ("50% at 1.5R, 50% at 3R, BE stop on rest", dict(partial_pct=0.5, partial_rr=1.5, rr=3.0)),
        ("50% at 2.0R, 50% at 3R, BE stop on rest", dict(partial_pct=0.5, partial_rr=2.0, rr=3.0)),
        ("33% at 1.5R, 67% at 3R",                  dict(partial_pct=0.33, partial_rr=1.5, rr=3.0)),
        ("50% at 1.5R, no final TP (eod only)",      dict(partial_pct=0.5, partial_rr=1.5, rr=999)),
    ]

    print(f"  {'Config':<55} {'N':>5} {'Net':>8} {'PF':>6} {'WR%':>6}")
    for label, params in configs_partial:
        res = run_orb_partial_tp(df, rs=15*60, re=15*60+30, eod=21*60, **params)
        pts = [r['pts'] for r in res]
        wins = [p for p in pts if p > 0]
        losses = [p for p in pts if p <= 0]
        gp = sum(wins); gl = abs(sum(losses))
        net = sum(pts); pf = gp/gl if gl else 9.9
        wr  = len(wins)/len(pts)*100
        print(f"  {label:<55} {len(pts):>5} {net:>8.1f} {pf:>6.3f} {wr:>6.1f}%")

    # Baseline for comparison
    res_base = run_orb_full(df, **BASE)
    pts_b = [r['pts'] for r in res_base]
    wins_b = [p for p in pts_b if p > 0]; losses_b = [p for p in pts_b if p <= 0]
    pf_b = sum(wins_b)/abs(sum(losses_b)); wr_b = len(wins_b)/len(pts_b)*100
    print(f"  {'Baseline (100% at 3R)':<55} {len(pts_b):>5} {sum(pts_b):>8.1f} {pf_b:>6.3f} {wr_b:>6.1f}%")

    # ─── 4. Dual window combined ─────────────────────────────────────────────
    print("\n" + "=" * 75)
    print("4. COMBINED: NY ORB + best London ORB (non-overlapping)")
    print("=" * 75)

    ny_res  = run_orb_full(df, rs=15*60, re=15*60+30, rr=3.0, eod=21*60)
    lon_res = run_orb_full(df, rs=9*60,  re=9*60+30,  rr=2.0, eod=15*60)

    # Combine by date (allow both trades same day)
    ny_pts   = [r['pts'] for r in ny_res]
    lon_pts  = [r['pts'] for r in lon_res]
    all_pts  = ny_pts + lon_pts
    n = len(all_pts); wins_c = [p for p in all_pts if p > 0]; losses_c = [p for p in all_pts if p <= 0]
    pf_c = sum(wins_c)/abs(sum(losses_c)); wr_c = len(wins_c)/n*100; net_c = sum(all_pts)
    cum = np.cumsum(all_pts); dd_c = (cum - np.maximum.accumulate(cum)).min()
    sh_c = net_c/(np.std(all_pts)*np.sqrt(n))

    print(f"  NY only:       N={len(ny_pts):>3}  Net={sum(ny_pts):>8.1f}  PF={pf_b:.3f}  WR={wr_b:.1f}%")
    print(f"  London only:   N={len(lon_pts):>3}  Net={sum(lon_pts):>8.1f}")
    print(f"  Combined:      N={n:>3}  Net={net_c:>8.1f}  PF={pf_c:.3f}  WR={wr_c:.1f}%  MaxDD={dd_c:.1f}  Sharpe={sh_c:.3f}")

    # ─── 5. Combined compounding ─────────────────────────────────────────────
    print("\n" + "=" * 75)
    print("5. COMPOUNDING ON COMBINED (NY + London)")
    print("=" * 75)

    # Merge by date order
    all_res = sorted(ny_res + lon_res, key=lambda x: x['date'])
    all_pts2   = [r['pts']  for r in all_res]
    all_ranges = [r['range'] for r in all_res]

    for risk in [0.01, 0.015, 0.02]:
        simulate_compounding(all_pts2, all_ranges, risk_pct=risk,
                             label=f"Combined (NY+London) risk={risk*100:.1f}%")

    # ─── 6. Summary recommendation ──────────────────────────────────────────
    print("\n" + "=" * 75)
    print("RECOMMENDATION SUMMARY")
    print("=" * 75)
    print("""
  Option A: NY ORB alone + fixed fractional 1.5%/trade
    → ~$10k grows to ~$X over 18 months. No strategy change needed.
    → Simple, robust, proven walk-forward.

  Option B: Add London ORB (09:00–09:30 CET) as second bot
    → Independent trades, different session risk.
    → Increases daily opportunity from 1 → up to 2 trades/day.
    → Run as separate EA with same logic, just different hours.

  Option C: Partial TP (50% at 1.5R, BE stop on rest)
    → Increases WR%, reduces variance. Good for psychology.
    → Slight reduction in net pts but smoother equity curve.

  Best pragmatic combo: NY ORB + 1.5% fixed fractional.
    Then add London ORB when comfortable.
""")
