#include <Trade\Trade.mqh>

//────────────────────────────────────────────────────────────────────────────
// Opening Range Breakout (ORB)
//
// Server = CET. NY open = 09:30 ET = 15:30 CET (constant, summer & winter).
//
// Logic:
//   1. Track High/Low between rangeStartHour:Min and rangeEndHour:Min.
//   2. After range end, place BUY_STOP above high and SELL_STOP below low.
//      Entry is offset by entryOffsetPoints to filter false breakouts.
//   3. SL = range_size from entry. TP = range_size × rrMultiplier.
//   4. When one executes, cancel the other.
//   5. At eodHour:eodMin, force-close all and cancel pending orders.
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
input int    entryOffsetPts = 0;        // Extra offset on entry (pts, 0 = off) — filters false breakouts

input group "═══ Breakeven & Trail ═══"
input bool   useBreakeven   = true;     // Move SL to entry when profit reaches 1R
input int    beBufPoints    = 5;        // Breakeven buffer: SL = entry ± this (pts)
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
bool     g_ordersPlaced = false;
bool     g_traded       = false;
bool     g_eodDone      = false;
bool     g_beApplied    = false;    // Breakeven already set today

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

void CancelOrderType(ENUM_ORDER_TYPE otype) {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if (OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == magicNumber)
         if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == otype) {
            trade.OrderDelete(t);
            Print("Cancelled ", EnumToString(otype));
         }
   }
}

bool HasOrderType(ENUM_ORDER_TYPE otype) {
   for (int i = 0; i < OrdersTotal(); i++) {
      ulong t = OrderGetTicket(i);
      if (OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == magicNumber)
         if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == otype)
            return true;
   }
   return false;
}

//────────────────────────────────────────────────────────────────────────────
void PlaceBreakoutOrders() {
   double rangeSize = g_orHigh - g_orLow;

   if (rangeSize <= 0) {
      Print("Invalid range, skipping");
      return;
   }
   if (minRangePoints > 0 && rangeSize < minRangePoints) {
      Print("Range too small (", DoubleToString(rangeSize,1), " < ", minRangePoints, ")");
      return;
   }
   if (maxRangePoints > 0 && rangeSize > maxRangePoints) {
      Print("Range too large (", DoubleToString(rangeSize,1), " > ", maxRangePoints, ")");
      return;
   }

   double tp_dist = rangeSize * rrMultiplier;
   double sl_dist = rangeSize;
   double lot     = CalcLot(rangeSize);

   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if (stopLevel < 10 * _Point) stopLevel = 10 * _Point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("OR: H=", DoubleToString(g_orHigh,1),
         " L=", DoubleToString(g_orLow,1),
         " Range=", DoubleToString(rangeSize,1),
         " Lot=", DoubleToString(lot,2),
         " (Equity=", DoubleToString(equity,2), ")");

   double offset = entryOffsetPts * _Point;

   // BUY_STOP above range high (+ optional offset)
   double buy_entry = g_orHigh + offset;
   double buy_sl    = buy_entry - sl_dist;
   double buy_tp    = buy_entry + tp_dist;

   if (buy_entry > ask + stopLevel) {
      if (trade.BuyStop(lot, buy_entry, _Symbol, buy_sl, buy_tp, ORDER_TIME_GTC))
         Print("BuyStop placed: entry=", DoubleToString(buy_entry,1),
               " SL=", DoubleToString(buy_sl,1),
               " TP=", DoubleToString(buy_tp,1));
      else
         Print("BuyStop FAILED: ", GetLastError());
   } else {
      Print("BuyStop skipped: price already above range high");
   }

   // SELL_STOP below range low (- optional offset)
   double sell_entry = g_orLow - offset;
   double sell_sl    = sell_entry + sl_dist;
   double sell_tp    = sell_entry - tp_dist;

   if (sell_entry < bid - stopLevel) {
      if (trade.SellStop(lot, sell_entry, _Symbol, sell_sl, sell_tp, ORDER_TIME_GTC))
         Print("SellStop placed: entry=", DoubleToString(sell_entry,1),
               " SL=", DoubleToString(sell_sl,1),
               " TP=", DoubleToString(sell_tp,1));
      else
         Print("SellStop FAILED: ", GetLastError());
   } else {
      Print("SellStop skipped: price already below range low");
   }

   g_ordersPlaced = true;
}

//────────────────────────────────────────────────────────────────────────────
void ResetDayState() {
   g_orHigh       = 0;
   g_orLow        = DBL_MAX;
   g_rangeReady   = false;
   g_ordersPlaced = false;
   g_traded       = false;
   g_eodDone      = false;
   g_beApplied    = false;
}

//────────────────────────────────────────────────────────────────────────────
// Breakeven & trailing stop management — called every tick while in position.
//
// Breakeven (useBreakeven):
//   Triggers when floating profit >= 1R (range size).
//   Moves SL to entry ± beBufPoints so the trade becomes risk-free.
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

   for (int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double buf = beBufPoints * _Point;

      if (ptype == POSITION_TYPE_BUY) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPrice;

         // Breakeven
         if (useBreakeven && !g_beApplied && profit >= rangeSize) {
            double newSL = openPrice + buf;
            if (newSL > currentSL) {
               if (trade.PositionModify(ticket, newSL, currentTP)) {
                  g_beApplied = true;
                  Print("BE set BUY: SL -> ", DoubleToString(newSL, 1),
                        " (profit=", DoubleToString(profit, 1), " pts)");
               }
            }
         }

         // Trail (only after breakeven)
         if (useTrail && g_beApplied) {
            double trailSL  = bid - rangeSize * trailRangeMult;
            double minSL    = openPrice + buf;          // never trail below BE
            trailSL = MathMax(trailSL, minSL);
            if (trailSL > currentSL + _Point) {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
         }

      } else { // SELL
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPrice - ask;

         // Breakeven
         if (useBreakeven && !g_beApplied && profit >= rangeSize) {
            double newSL = openPrice - buf;
            if (newSL < currentSL) {
               if (trade.PositionModify(ticket, newSL, currentTP)) {
                  g_beApplied = true;
                  Print("BE set SELL: SL -> ", DoubleToString(newSL, 1),
                        " (profit=", DoubleToString(profit, 1), " pts)");
               }
            }
         }

         // Trail (only after breakeven)
         if (useTrail && g_beApplied) {
            double trailSL = ask + rangeSize * trailRangeMult;
            double maxSL   = openPrice - buf;           // never trail above BE
            trailSL = MathMin(trailSL, maxSL);
            if (trailSL < currentSL - _Point) {
               trade.PositionModify(ticket, trailSL, currentTP);
            }
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
         " | BE=", useBreakeven ? StringFormat("ON(buf=%dpts)", beBufPoints) : "OFF",
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

   // ── Phase 2: Place orders ──────────────────────────────────────────────
   if (!g_ordersPlaced && !g_traded) {
      PlaceBreakoutOrders();
   }

   // ── Phase 3: Cancel opposite when one executes ─────────────────────────
   if (HasPosition()) {
      g_traded = true;
      bool hasBuy  = false, hasSell = false;
      for (int i = 0; i < PositionsTotal(); i++) {
         ulong t = PositionGetTicket(i);
         if (t > 0 && PositionSelectByTicket(t) &&
             PositionGetInteger(POSITION_MAGIC) == magicNumber) {
            if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)  hasBuy  = true;
            if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) hasSell = true;
         }
      }
      if (hasBuy  && HasOrderType(ORDER_TYPE_SELL_STOP)) CancelOrderType(ORDER_TYPE_SELL_STOP);
      if (hasSell && HasOrderType(ORDER_TYPE_BUY_STOP))  CancelOrderType(ORDER_TYPE_BUY_STOP);

      // ── Phase 4: Breakeven & trail ──────────────────────────────────────
      ManagePosition();
   }
}

//────────────────────────────────────────────────────────────────────────────
void OnDeinit(const int reason) {
   Print("Bot stopped, reason=", reason);
}
