#include <Trade\Trade.mqh>

input int             nPeriod    = 45;
input double          lotSize    = 1.0;
input ENUM_TIMEFRAMES tradingTF  = PERIOD_M5;
input int             emaPeriod  = 20;
input int             startHour  = 9;
input int             startMin   = 0;
input int             endHour    = 17;
input int             endMin     = 30;
input datetime        startDate  = D'2024.01.01 00:00';

CTrade trade;

datetime lastDay      = 0;
double   lastEMA      = 0;
double   g_dev        = 0;
double   g_open       = 0;
double   g_devMinus1  = 0;
double   g_devPlus1   = 0;
double   g_devMinus2  = 0;
double   g_devPlus2   = 0;

#define MAX_CACHE 5000
datetime cached_dates[MAX_CACHE];
double   cached_devs[MAX_CACHE];
double   cached_opens[MAX_CACHE];
int      cache_count = 0;

double RoundToNearestHalf(double value) {
   return MathRound(value * 2.0) / 2.0;
}

bool GetDailyStats(datetime day, double &dev, double &open) {
   for (int i = 0; i < cache_count; i++) {
      if (cached_dates[i] == day) {
         dev  = cached_devs[i];
         open = cached_opens[i];
         return true;
      }
   }

   int shift = iBarShift(_Symbol, PERIOD_D1, day);
   if (shift < 0 || shift + nPeriod >= Bars(_Symbol, PERIOD_D1)) return false;

   double sum = 0, var = 0;
   for (int j = 1; j <= nPeriod; j++) {
      double h = iHigh(_Symbol, PERIOD_D1, shift + j);
      double l = iLow(_Symbol, PERIOD_D1, shift + j);
      sum += (h - l);
   }
   double avg = sum / nPeriod;
   for (int j = 1; j <= nPeriod; j++) {
      double h = iHigh(_Symbol, PERIOD_D1, shift + j);
      double l = iLow(_Symbol, PERIOD_D1, shift + j);
      var += MathPow((h - l) - avg, 2);
   }

   dev  = MathSqrt(var / nPeriod);
   open = iOpen(_Symbol, PERIOD_D1, shift);

   if (cache_count < MAX_CACHE) {
      cached_dates[cache_count] = day;
      cached_devs[cache_count]  = dev;
      cached_opens[cache_count] = open;
      cache_count++;
   }

   return true;
}

double GetEMA() {
   int handle = iMA(_Symbol, tradingTF, emaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if (handle == INVALID_HANDLE) return 0;
   double buf[1];
   if (CopyBuffer(handle, 0, 0, 1, buf) < 1) return 0;
   IndicatorRelease(handle);
   return buf[0];
}

bool IsWithinTradingHours() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins   = dt.hour * 60 + dt.min;
   int startMins = startHour * 60 + startMin;
   int endMins   = endHour * 60 + endMin;
   return (nowMins >= startMins && nowMins < endMins);
}

bool IsAfterEndTime() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = dt.hour * 60 + dt.min;
   int endMins = endHour * 60 + endMin;
   return (nowMins >= endMins);
}

void CloseAll() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (ticket > 0 && PositionSelectByTicket(ticket)) {
         if (PositionGetInteger(POSITION_MAGIC) == 123456) {
            if (!trade.PositionClose(ticket))
               Print("Error closing position ", ticket, ": ", GetLastError());
         }
      }
   }
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (OrderSelect(ticket) && OrderGetInteger(ORDER_MAGIC) == 123456) {
         if (!trade.OrderDelete(ticket))
            Print("Error deleting order ", ticket, ": ", GetLastError());
      }
   }
}

void ProcessNewDay() {
   datetime day = iTime(_Symbol, PERIOD_D1, 0);
   Print("New day: ", TimeToString(day));

   // Skip if already have an open position
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (ticket > 0 && PositionSelectByTicket(ticket)) {
         if (PositionGetInteger(POSITION_MAGIC) == 123456) {
            Print("Position already open, skipping new day orders");
            return;
         }
      }
   }

   // Cancel any leftover pending orders
   CloseAll();

   double dev, o;
   if (!GetDailyStats(day, dev, o)) {
      Print("GetDailyStats failed for ", TimeToString(day));
      return;
   }

   g_dev      = dev;
   g_open     = o;
   g_devMinus1 = RoundToNearestHalf(o - dev);
   g_devPlus1  = RoundToNearestHalf(o + dev);
   g_devMinus2 = RoundToNearestHalf(o - 2 * dev);
   g_devPlus2  = RoundToNearestHalf(o + 2 * dev);

   double ema = GetEMA();
   Print("Open=", o, " Dev=", dev, " EMA=", ema,
         " BuyLimit=", g_devMinus1, " SellLimit=", g_devPlus1);

   if (ema > g_devMinus1) {
      if (trade.BuyLimit(lotSize, g_devMinus1, _Symbol, g_devMinus2, ema, ORDER_TIME_DAY))
         Print("BuyLimit placed at ", g_devMinus1, " SL=", g_devMinus2, " TP=", ema);
      else
         Print("BuyLimit failed: ", GetLastError());
   } else {
      Print("BuyLimit skipped: EMA (", ema, ") <= devMinus1 (", g_devMinus1, ")");
   }

   if (ema < g_devPlus1) {
      if (trade.SellLimit(lotSize, g_devPlus1, _Symbol, g_devPlus2, ema, ORDER_TIME_DAY))
         Print("SellLimit placed at ", g_devPlus1, " SL=", g_devPlus2, " TP=", ema);
      else
         Print("SellLimit failed: ", GetLastError());
   } else {
      Print("SellLimit skipped: EMA (", ema, ") >= devPlus1 (", g_devPlus1, ")");
   }
}

int OnInit() {
   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
      Print("Automated trading not enabled");
      return INIT_FAILED;
   }

   lastDay = iTime(_Symbol, PERIOD_D1, 0);
   return INIT_SUCCEEDED;
}

void OnTick() {
   if (TimeCurrent() < startDate) return;

   // Close all and stop after endTime
   if (IsAfterEndTime()) {
      static datetime lastCloseDay = 0;
      datetime today = iTime(_Symbol, PERIOD_D1, 0);
      if (lastCloseDay != today) {
         Print("End time reached, closing all");
         CloseAll();
         lastCloseDay = today;
      }
      return;
   }

   // Wait until startTime
   if (!IsWithinTradingHours()) return;

   // Detect new day
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if (currentDay != lastDay) {
      lastDay = currentDay;
      lastEMA = 0;
      ProcessNewDay();
      return;
   }

   // Detect newly executed orders: cancel opposite pending, set SL/TP
   static int lastPendingCount = -1;
   int pendingCount = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (OrderSelect(ticket) && OrderGetInteger(ORDER_MAGIC) == 123456)
         pendingCount++;
   }

   bool hasBuy  = false;
   bool hasSell = false;
   ulong buyTicket  = 0;
   ulong sellTicket = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (ticket > 0 && PositionSelectByTicket(ticket)) {
         if (PositionGetInteger(POSITION_MAGIC) == 123456) {
            if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               hasBuy     = true;
               buyTicket  = ticket;
            } else {
               hasSell    = true;
               sellTicket = ticket;
            }
         }
      }
   }

   // When a new position appears and pending orders still exist, cancel opposite
   if (lastPendingCount > pendingCount && (hasBuy || hasSell)) {
      double ema = GetEMA();
      if (hasBuy) {
         // Cancel any remaining sell limit
         for (int i = OrdersTotal() - 1; i >= 0; i--) {
            ulong t = OrderGetTicket(i);
            if (OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == 123456 &&
                OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_LIMIT) {
               trade.OrderDelete(t);
               Print("Cancelled SellLimit after BUY execution");
            }
         }
         if (ema > 0) {
            trade.PositionModify(buyTicket, g_devMinus2, ema);
            Print("BUY executed: SL=", g_devMinus2, " TP=", ema);
         }
      }
      if (hasSell) {
         // Cancel any remaining buy limit
         for (int i = OrdersTotal() - 1; i >= 0; i--) {
            ulong t = OrderGetTicket(i);
            if (OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == 123456 &&
                OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT) {
               trade.OrderDelete(t);
               Print("Cancelled BuyLimit after SELL execution");
            }
         }
         if (ema > 0) {
            trade.PositionModify(sellTicket, g_devPlus2, ema);
            Print("SELL executed: SL=", g_devPlus2, " TP=", ema);
         }
      }
   }
   lastPendingCount = pendingCount;

   // Track EMA in real-time and update TP
   if (hasBuy || hasSell) {
      double ema = GetEMA();
      if (ema > 0 && MathAbs(ema - lastEMA) > _Point) {
         if (hasBuy) {
            double sl = PositionSelectByTicket(buyTicket) ? PositionGetDouble(POSITION_SL) : g_devMinus2;
            trade.PositionModify(buyTicket, sl, ema);
         }
         if (hasSell) {
            double sl = PositionSelectByTicket(sellTicket) ? PositionGetDouble(POSITION_SL) : g_devPlus2;
            trade.PositionModify(sellTicket, sl, ema);
         }
         lastEMA = ema;
      }
   }
}

void OnDeinit(const int reason) {
   Print("Bot stopped, reason=", reason);
}
