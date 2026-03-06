#include <Trade\Trade.mqh>

//────────────────────────────────────────────────────────────────────────────
// Opening Range Breakout (ORB)
//
// Server = CET. NY open = 09:30 ET = 15:30 CET (constant, summer & winter).
//
// Logic:
//   1. Track High/Low between rangeStartHour:Min and rangeEndHour:Min.
//   2. After range end, wait for an M5 candle to CLOSE beyond the range
//      boundary (+ optional entryOffsetPts). Enter at market on that bar.
//      Candle-close confirmation eliminates same-candle false breakouts.
//   3. SL = range_size from entry. TP = range_size × rrMultiplier.
//   4. At eodHour:eodMin, force-close all.
//
// Breakeven & Trail:
//   - useBreakeven: when profit reaches 1R (range size), SL moves to
//     entry + beBufPoints (risk-free). Does not limit gain.
//   - useTrail: after breakeven, SL trails price by trailRangeMult×range.
//     Only moves SL in favorable direction, never back.
//
// Position sizing (fixed fractional):
//   lot = (AccountEquity × riskPct) / (range_size × pointValue)
//   This compounds naturally as equity grows.
//
// NY session defaults : range 15:00–15:30 CET, EOD 21:00 CET
// London session use  : range 09:00–09:30 CET, EOD 15:00 CET
//────────────────────────────────────────────────────────────────────────────

input group "═══ Session ═══"
input int    rangeStartHour = 15;       // Range start hour (CET)
input int    rangeStartMin  = 0;        // Range start minute
input int    rangeEndHour   = 15;       // Range end hour (CET)
input int    rangeEndMin    = 30;       // Range end minute
input int    eodHour        = 21;       // Force-close hour (CET)
input int    eodMin         = 0;        // Force-close minute

input group "═══ Trade ═══"
input double rrMultiplier   = 3.0;      // TP = range × rrMultiplier (use 3.0)
input int    minRangePoints = 0;        // Min range to trade (0 = off)
input int    maxRangePoints = 0;        // Max range to trade (0 = off)
input int    entryOffsetPts = 0;        // Candle-close threshold offset (ticks above/below range, 0 = off)

input group "═══ Breakeven & Trail ═══"
input bool   useBreakeven   = true;     // Move SL to entry when profit reaches 1R
input int    beBufTicks     = 2;        // Breakeven buffer in ticks (SL = entry ± N ticks)
input bool   useTrail       = false;    // Trail SL after breakeven (false = hold SL at BE)
input double trailRangeMult = 1.5;      // Trail distance = range × this (only when useTrail)

input group "═══ Position Sizing ═══"
input bool   useDynamicLot  = true;     // true = fixed fractional, false = fixed lot
input double riskPct        = 0.015;    // Risk per trade as fraction of equity (e.g. 0.015 = 1.5%)
input double pointValue     = 5.0;      // $ per point per lot — check symbol spec (UsaTec=5)
input double fixedLot       = 1.0;      // Used when useDynamicLot = false
input double minLot         = 0.01;     // Minimum lot size
input double maxLot         = 100.0;    // Maximum lot size (safety cap)

input group "═══ General ═══"
input int      magicNumber  = 789012;
input datetime startDate    = D'2024.01.01 00:00';

CTrade trade;

// Daily state
datetime g_lastDay      = 0;
double   g_orHigh       = 0;
double   g_orLow        = DBL_MAX;
bool     g_rangeReady   = false;
bool     g_traded       = false;
bool     g_eodDone      = false;
bool     g_beApplied    = false;    // Breakeven already set today
datetime g_lastBarTime  = 0;        // Last M5 bar open time (for candle-close detection)

//────────────────────────────────────────────────────────────────────────────
// Normalize price to instrument tick size.
double NormPrice(double price) {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tick <= 0) tick = _Point;
   return MathRound(price / tick) * tick;
}

//────────────────────────────────────────────────────────────────────────────
int HM(int h, int m) { return h * 60 + m; }

int NowHM() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
}

datetime TodayDate() {
   return iTime(_Symbol, PERIOD_D1, 0);
}

double CalcLot(double rangeSize) {
   if (!useDynamicLot)
      return fixedLot;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if (equity <= 0 || rangeSize <= 0 || pointValue <= 0)
      return fixedLot;

   double risk_money = equity * riskPct;
   double lot = risk_money / (rangeSize * pointValue);

   // Round to broker step
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step > 0) lot = MathFloor(lot / step) * step;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//────────────────────────────────────────────────────────────────────────────
void CloseAll() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t > 0 && PositionSelectByTicket(t))
         if (PositionGetInteger(POSITION_MAGIC) == magicNumber)
            trade.PositionClose(t);
   }
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if (OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == magicNumber)
         trade.OrderDelete(t);
   }
}

bool HasPosition() {
   for (int i = 0; i < PositionsTotal(); i++) {
      ulong t = PositionGetTicket(i);
      if (t > 0 && PositionSelectByTicket(t))
         if (PositionGetInteger(POSITION_MAGIC) == magicNumber)
            return true;
   }
   return false;
}

//────────────────────────────────────────────────────────────────────────────
// Enter at market in direction dir (ORDER_TYPE_BUY or ORDER_TYPE_SELL).
// SL = rangeSize from entry, TP = rangeSize × rrMultiplier.
void EnterMarket(ENUM_ORDER_TYPE dir) {
   double rangeSize = g_orHigh - g_orLow;
   if (rangeSize <= 0) { Print("Invalid range, skipping"); return; }

   if (minRangePoints > 0 && rangeSize < minRangePoints) {
      Print("Range too small (", DoubleToString(rangeSize,1), " < ", minRangePoints, ") — skipping");
      g_traded = true;
      return;
   }
   if (maxRangePoints > 0 && rangeSize > maxRangePoints) {
      Print("Range too large (", DoubleToString(rangeSize,1), " > ", maxRangePoints, ") — skipping");
      g_traded = true;
      return;
   }

   double lot = CalcLot(rangeSize);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("OR: H=", DoubleToString(g_orHigh,1),
         " L=", DoubleToString(g_orLow,1),
         " Range=", DoubleToString(rangeSize,1),
         " Lot=", DoubleToString(lot,2),
         " Dir=", EnumToString(dir),
         " (Equity=", DoubleToString(equity,2), ")");

   double tp_dist = rangeSize * rrMultiplier;

   if (dir == ORDER_TYPE_BUY) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormPrice(ask - rangeSize);
      double tp  = NormPrice(ask + tp_dist);
      if (trade.Buy(lot, _Symbol, ask, sl, tp))
         Print("Buy entered: ask=", DoubleToString(ask,1),
               " SL=", DoubleToString(sl,1), " TP=", DoubleToString(tp,1));
      else
         Print("Buy FAILED: ", GetLastError());
   } else {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormPrice(bid + rangeSize);
      double tp  = NormPrice(bid - tp_dist);
      if (trade.Sell(lot, _Symbol, bid, sl, tp))
         Print("Sell entered: bid=", DoubleToString(bid,1),
               " SL=", DoubleToString(sl,1), " TP=", DoubleToString(tp,1));
      else
         Print("Sell FAILED: ", GetLastError());
   }

   g_traded = true;
}

//────────────────────────────────────────────────────────────────────────────
void ResetDayState() {
   g_orHigh      = 0;
   g_orLow       = DBL_MAX;
   g_rangeReady  = false;
   g_traded      = false;
   g_eodDone     = false;
   g_beApplied   = false;
   g_lastBarTime = 0;
}

//────────────────────────────────────────────────────────────────────────────
// Breakeven & trailing stop management — called every tick while in position.
//
// Breakeven (useBreakeven):
//   Triggers when floating profit >= 1R (range size).
//   Moves SL to entry ± beBufTicks (ticks) so the trade is nearly risk-free.
//   SL is clamped to broker's SYMBOL_TRADE_STOPS_LEVEL and normalized to
//   tick size to avoid "Invalid stops" rejections.
//   Fires once per trade; does NOT limit gain (TP unchanged).
//
// Trailing stop (useTrail, only after breakeven):
//   Trails SL at (price - trailRangeMult × range) for buys,
//   and (price + trailRangeMult × range) for sells.
//   SL only moves in favorable direction, never back toward entry.
//────────────────────────────────────────────────────────────────────────────
void ManagePosition() {
   if (!useBreakeven && !useTrail) return;

   double rangeSize = g_orHigh - g_orLow;
   if (rangeSize <= 0) return;

   double tick      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tick <= 0) tick = _Point;
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if (stopLevel < tick) stopLevel = tick;
   double buf       = beBufTicks * tick;

   for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if (ptype == POSITION_TYPE_BUY) {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;

         // Breakeven: trigger at 1R, set SL at entry + buf
         // Clamped to max valid distance from current bid (broker stopLevel)
         if (useBreakeven && !g_beApplied && profit >= rangeSize) {
            double idealSL = openPrice + buf;
            double maxSL   = bid - stopLevel - tick;   // broker minimum distance
            double newSL   = NormPrice(MathMin(idealSL, maxSL));
            if (newSL > currentSL + tick) {
               if (trade.PositionModify(ticket, newSL, currentTP)) {
                  g_beApplied = true;
                  Print("BE set BUY: SL -> ", DoubleToString(newSL, 1),
                        " (profit=", DoubleToString(profit, 1), ")");
               }
            }
         }

         // Trail (only after breakeven)
         if (useTrail && g_beApplied) {
            double trailSL = bid - rangeSize * trailRangeMult;
            double maxSL   = bid - stopLevel - tick;
            trailSL = MathMin(trailSL, maxSL);
            trailSL = MathMax(trailSL, openPrice + buf);   // never below BE
            trailSL = NormPrice(trailSL);
            if (trailSL > currentSL + tick)
               trade.PositionModify(ticket, trailSL, currentTP);
         }

      } else { // SELL
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;

         // Breakeven: trigger at 1R, set SL at entry - buf
         // Clamped to min valid distance from current ask (broker stopLevel)
         if (useBreakeven && !g_beApplied && profit >= rangeSize) {
            double idealSL = openPrice - buf;
            double minSL   = ask + stopLevel + tick;   // broker minimum distance
            double newSL   = NormPrice(MathMax(idealSL, minSL));
            if (newSL < currentSL - tick) {
               if (trade.PositionModify(ticket, newSL, currentTP)) {
                  g_beApplied = true;
                  Print("BE set SELL: SL -> ", DoubleToString(newSL, 1),
                        " (profit=", DoubleToString(profit, 1), ")");
               }
            }
         }

         // Trail (only after breakeven)
         if (useTrail && g_beApplied) {
            double trailSL = ask + rangeSize * trailRangeMult;
            double minSL   = ask + stopLevel + tick;
            trailSL = MathMax(trailSL, minSL);
            trailSL = MathMin(trailSL, openPrice - buf);   // never above BE
            trailSL = NormPrice(trailSL);
            if (trailSL < currentSL - tick)
               trade.PositionModify(ticket, trailSL, currentTP);
         }
      }
   }
}

//────────────────────────────────────────────────────────────────────────────
int OnInit() {
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
      Print("Automated trading not enabled");
      return INIT_FAILED;
   }

   Print("ORB bot started | Range: ", rangeStartHour, ":", StringFormat("%02d", rangeStartMin),
         "–", rangeEndHour, ":", StringFormat("%02d", rangeEndMin), " CET",
         " | RR=", rrMultiplier,
         " | EOD=", eodHour, "h CET",
         " | Sizing: ", useDynamicLot ? StringFormat("%.1f%% risk (pointVal=%.2f)", riskPct*100, pointValue)
                                      : StringFormat("%.2f lot fixed", fixedLot),
         " | EntryOffset=", entryOffsetPts, "pts",
         " | BE=", useBreakeven ? StringFormat("ON(buf=%dticks)", beBufTicks) : "OFF",
         " | Trail=", useTrail  ? StringFormat("ON(%.1fx)", trailRangeMult) : "OFF");
   return INIT_SUCCEEDED;
}

//────────────────────────────────────────────────────────────────────────────
void OnTick() {
   if (TimeCurrent() < startDate) return;

   int nowHM      = NowHM();
   int rangeStartHM = HM(rangeStartHour, rangeStartMin);
   int rangeEndHM   = HM(rangeEndHour,   rangeEndMin);
   int eodHM        = HM(eodHour, eodMin);

   // ── New day ────────────────────────────────────────────────────────────
   datetime today = TodayDate();
   if (today != g_lastDay) {
      g_lastDay = today;
      CloseAll();
      ResetDayState();
      Print("New day: ", TimeToString(today));
   }

   // ── EOD ────────────────────────────────────────────────────────────────
   if (nowHM >= eodHM) {
      if (!g_eodDone) {
         Print("EOD (", eodHour, "h CET) — closing all");
         CloseAll();
         g_eodDone = true;
      }
      return;
   }

   // ── Phase 1: Build opening range ───────────────────────────────────────
   if (!g_rangeReady) {
      if (nowHM >= rangeStartHM && nowHM < rangeEndHM) {
         double h = iHigh(_Symbol, PERIOD_M5, 0);
         double l = iLow(_Symbol,  PERIOD_M5, 0);
         if (h > g_orHigh) g_orHigh = h;
         if (l < g_orLow)  g_orLow  = l;
      } else if (nowHM >= rangeEndHM && g_orHigh > 0 && g_orLow < DBL_MAX) {
         g_rangeReady = true;
         Print("Range set: H=", DoubleToString(g_orHigh,1),
               " L=", DoubleToString(g_orLow,1),
               " Size=", DoubleToString(g_orHigh - g_orLow,1));
      }
      return;
   }

   // ── Phase 2: Candle-close confirmation ────────────────────────────────
   if (!g_traded) {
      datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
      if (barTime != g_lastBarTime) {
         g_lastBarTime = barTime;

         double tick   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if (tick <= 0) tick = _Point;
         double offset = entryOffsetPts * tick;

         double closePrice = iClose(_Symbol, PERIOD_M5, 1);
         if (closePrice > g_orHigh + offset)
            EnterMarket(ORDER_TYPE_BUY);
         else if (closePrice < g_orLow - offset)
            EnterMarket(ORDER_TYPE_SELL);
      }
   }

   // ── Phase 3: Breakeven & trail ─────────────────────────────────────────
   if (HasPosition())
      ManagePosition();
}

//────────────────────────────────────────────────────────────────────────────
void OnDeinit(const int reason) {
   Print("Bot stopped, reason=", reason);
}
