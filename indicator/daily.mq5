#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots   9

#property indicator_color1 Orange
#property indicator_color2 Orange
#property indicator_color3 Orange
#property indicator_color4 Orange
#property indicator_color5 Orange
#property indicator_color6 Orange
#property indicator_color7 Orange
#property indicator_color8 Orange
#property indicator_color9 Purple

input int nPeriod = 45;
input datetime startDate = D'2024.01.01 00:00';

// Buffers
double point1[], point2[], point3[], point4[];
double point5[], point6[], point7[], point8[];
double open_buffer[];

// Cache manual
#define MAX_CACHE 5000
datetime cached_dates[MAX_CACHE];
double cached_devs[MAX_CACHE];
double cached_opens[MAX_CACHE];
int cache_count = 0;

// Arredonda para múltiplos de 0.5
double RoundToNearestHalf(double value)
{
   return MathRound(value * 2.0) / 2.0;
}

int OnInit()
{
   SetIndexBuffer(0, point1);   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(0, PLOT_LABEL, "Dev +1");
   SetIndexBuffer(1, point2);   PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(1, PLOT_LABEL, "Dev +2");
   SetIndexBuffer(2, point3);   PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(2, PLOT_LABEL, "Dev +3");
   SetIndexBuffer(3, point4);   PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(3, PLOT_LABEL, "Dev +4");
   SetIndexBuffer(4, point5);   PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(4, PLOT_LABEL, "Dev -1");
   SetIndexBuffer(5, point6);   PlotIndexSetInteger(5, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(5, PLOT_LABEL, "Dev -2");
   SetIndexBuffer(6, point7);   PlotIndexSetInteger(6, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(6, PLOT_LABEL, "Dev -3");
   SetIndexBuffer(7, point8);   PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_LINE);  PlotIndexSetString(7, PLOT_LABEL, "Dev -4");
   SetIndexBuffer(8, open_buffer); PlotIndexSetInteger(8, PLOT_DRAW_TYPE, DRAW_LINE); PlotIndexSetString(8, PLOT_LABEL, "Abertura");

   return(INIT_SUCCEEDED);
}

bool GetDailyStats(datetime day, double &dev, double &open)
{
   for (int i = 0; i < cache_count; i++)
   {
      if (cached_dates[i] == day)
      {
         dev = cached_devs[i];
         open = cached_opens[i];
         return true;
      }
   }

   int shift = iBarShift(_Symbol, PERIOD_D1, day);
   if(shift < 0 || shift + nPeriod >= Bars(_Symbol, PERIOD_D1)) return false;

   double sum = 0, var = 0, h, l;
   for(int j = 1; j <= nPeriod; j++)
   {
      h = iHigh(_Symbol, PERIOD_D1, shift + j);
      l = iLow(_Symbol, PERIOD_D1, shift + j);
      sum += (h - l);
   }
   double avg = sum / nPeriod;
   for(int j = 1; j <= nPeriod; j++)
   {
      h = iHigh(_Symbol, PERIOD_D1, shift + j);
      l = iLow(_Symbol, PERIOD_D1, shift + j);
      var += MathPow((h - l) - avg, 2);
   }
   dev = MathSqrt(var / nPeriod);
   open = iOpen(_Symbol, PERIOD_D1, shift);

   if (cache_count < MAX_CACHE)
   {
      cached_dates[cache_count] = day;
      cached_devs[cache_count] = dev;
      cached_opens[cache_count] = open;
      cache_count++;
   }

   return true;
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   int start = MathMax(prev_calculated - 1, 0);

   for(int i = start; i < rates_total; i++)
   {
      if(time[i] < startDate) continue;

      MqlDateTime t1, t2;
      TimeToStruct(time[i], t1);
      TimeToStruct(time[i > 0 ? i - 1 : 0], t2);
      bool isNewDay = (i == 0 || t1.day != t2.day || t1.mon != t2.mon || t1.year != t2.year);

      if (isNewDay)
      {
         datetime currentDay = time[i];
         double dev, o;
         if(!GetDailyStats(currentDay, dev, o)) continue;

         point1[i] = RoundToNearestHalf(o + dev);
         point2[i] = RoundToNearestHalf(o + 2 * dev);
         point3[i] = RoundToNearestHalf(o + 3 * dev);
         point4[i] = RoundToNearestHalf(o + 4 * dev);

         point5[i] = RoundToNearestHalf(o - dev);
         point6[i] = RoundToNearestHalf(o - 2 * dev);
         point7[i] = RoundToNearestHalf(o - 3 * dev);
         point8[i] = RoundToNearestHalf(o - 4 * dev);

         open_buffer[i] = RoundToNearestHalf(o);
      }
      else
      {
         point1[i] = point1[i - 1];
         point2[i] = point2[i - 1];
         point3[i] = point3[i - 1];
         point4[i] = point4[i - 1];

         point5[i] = point5[i - 1];
         point6[i] = point6[i - 1];
         point7[i] = point7[i - 1];
         point8[i] = point8[i - 1];

         open_buffer[i] = open_buffer[i - 1];
      }
   }

   // Exibir últimos valores como texto no gráfico
   if (rates_total > 0)
   {
      int last = rates_total - 1;
      string name;
      for (int j = 0; j < 9; j++)
      {
         double val = 0;
         if      (j == 0) val = point1[last];
         else if (j == 1) val = point2[last];
         else if (j == 2) val = point3[last];
         else if (j == 3) val = point4[last];
         else if (j == 4) val = point5[last];
         else if (j == 5) val = point6[last];
         else if (j == 6) val = point7[last];
         else if (j == 7) val = point8[last];
         else if (j == 8) val = open_buffer[last];

         name = "text_label_" + (string)j;
         ObjectDelete(0, name);
         ObjectCreate(0, name, OBJ_TEXT, 0, time[last], val);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlack);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
         ObjectSetString(0, name, OBJPROP_TEXT, DoubleToString(val, 1));
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
