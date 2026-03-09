//+------------------------------------------------------------------+
//|  UsaTec_SignalScore.mq5  —  v2.0                                 |
//|  Score composto: −1 (sell) a +1 (buy)                            |
//|  Aplicar no gráfico M5                                           |
//+------------------------------------------------------------------+
#property copyright   "UsaTec Strategy"
#property version     "2.00"
#property description "Histograma colorido: verde = compra | vermelho = venda"
#property description "Setas = setup completo com todos 7 criterios confirmados"

#property indicator_separate_window
#property indicator_minimum  -1.10
#property indicator_maximum   1.10
#property indicator_buffers   5
#property indicator_plots     3

//--- Plot 0: Histograma colorido
#property indicator_label1  "Score"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrCrimson,clrOrangeRed,clrGold,clrYellowGreen,clrLimeGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3

//--- Plot 1: Seta BUY
#property indicator_label2  "Buy"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_width2  3

//--- Plot 2: Seta SELL
#property indicator_label3  "Sell"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  3

//==================================================================
//  PARAMETROS
//==================================================================
input group "=== M5 Indicadores ==="
input int    InpEMA9       = 9;
input int    InpEMA21      = 21;
input int    InpRSIPer     = 14;
input int    InpATRPer     = 14;

input group "=== M30 Filtros ==="
input int    InpM30EMA21   = 21;
input int    InpM30EMA50   = 50;
input int    InpM30RSIPer  = 14;
input double InpRSILong    = 60.0;   // RSI M30 minimo para bull
input double InpRSIShort   = 40.0;   // RSI M30 maximo para bear

input group "=== RSI M5 Zonas ==="
input double InpRSILMin    = 40.0;   // Long min
input double InpRSILMax    = 72.0;   // Long max
input double InpRSISMin    = 28.0;   // Short min
input double InpRSISMax    = 60.0;   // Short max

input group "=== Pesos (soma = 1.0) ==="
input double W1 = 0.20;  // Tendencia M30
input double W2 = 0.25;  // RSI M30 momentum
input double W3 = 0.15;  // Pullback EMA21
input double W4 = 0.15;  // Confirmacao EMA21+EMA9
input double W5 = 0.10;  // VWAP
input double W6 = 0.10;  // RSI M5
input double W7 = 0.05;  // Candle direcional

input group "=== Visual ==="
input double InpThresh    = 0.70;   // Score minimo para seta de sinal
input bool   InpArrows    = true;   // Mostrar setas de sinal completo
input bool   InpPanel     = true;   // Mostrar painel de condicoes

//==================================================================
//  BUFFERS
//==================================================================
double Sc[];      // 0: valores do score
double ScClr[];   // 1: indice de cor (0=vermelho .. 4=verde)
double BuyArr[];  // 2: setas buy
double SellArr[]; // 3: setas sell
double VwapC[];   // 4: VWAP calculado (interno)

//==================================================================
//  HANDLES
//==================================================================
int hE9, hE21, hE50, hRSI, hATR;
int hM30E21, hM30E50, hM30RSI;

bool panelOk = false;
int  panelWin = -1;

string PFX = "UTSC_";

//==================================================================
//  INIT
//==================================================================
int OnInit()
{
   if(Period() != PERIOD_M5)
   { Alert("Aplicar no M5!"); return INIT_FAILED; }

   SetIndexBuffer(0, Sc,      INDICATOR_DATA);
   SetIndexBuffer(1, ScClr,   INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BuyArr,  INDICATOR_DATA);
   SetIndexBuffer(3, SellArr, INDICATOR_DATA);
   SetIndexBuffer(4, VwapC,   INDICATOR_CALCULATIONS);

   // Setas: codigos Wingdings
   PlotIndexSetInteger(1, PLOT_ARROW, 233); // cima
   PlotIndexSetInteger(2, PLOT_ARROW, 234); // baixo
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT,  10);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT, -10);
   PlotIndexSetDouble (1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble (2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ArrayInitialize(BuyArr,  EMPTY_VALUE);
   ArrayInitialize(SellArr, EMPTY_VALUE);

   // Handles
   string s = Symbol();
   hE9     = iMA(s, PERIOD_M5, InpEMA9, 0, MODE_EMA, PRICE_CLOSE);
   hE21    = iMA(s, PERIOD_M5, InpEMA21, 0, MODE_EMA, PRICE_CLOSE);
   hE50    = iMA(s, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   hRSI    = iRSI(s, PERIOD_M5, InpRSIPer, PRICE_CLOSE);
   hATR    = iATR(s, PERIOD_M5, InpATRPer);
   hM30E21 = iMA(s, PERIOD_M30, InpM30EMA21, 0, MODE_EMA, PRICE_CLOSE);
   hM30E50 = iMA(s, PERIOD_M30, InpM30EMA50, 0, MODE_EMA, PRICE_CLOSE);
   hM30RSI = iRSI(s, PERIOD_M30, InpM30RSIPer, PRICE_CLOSE);

   if(hE9==INVALID_HANDLE||hE21==INVALID_HANDLE||hRSI==INVALID_HANDLE||
      hATR==INVALID_HANDLE||hM30E21==INVALID_HANDLE||hM30E50==INVALID_HANDLE||
      hM30RSI==INVALID_HANDLE)
   { Alert("Erro handles! ", GetLastError()); return INIT_FAILED; }

   // Nome e niveis
   string sname = StringFormat("UsaTec Score [Thr:%.0f%%]", InpThresh*100);
   IndicatorSetString(INDICATOR_SHORTNAME, sname);
   IndicatorSetInteger(INDICATOR_LEVELS, 3);
   IndicatorSetDouble (INDICATOR_LEVELVALUE, 0,  InpThresh);
   IndicatorSetDouble (INDICATOR_LEVELVALUE, 1,  0.0);
   IndicatorSetDouble (INDICATOR_LEVELVALUE, 2, -InpThresh);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrLimeGreen);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrDimGray);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrCrimson);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_SOLID);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELWIDTH, 1, 2);

   return INIT_SUCCEEDED;
}

//==================================================================
//  DEINIT
//==================================================================
void OnDeinit(const int reason)
{
   int handles[] = { hE9,hE21,hE50,hRSI,hATR,hM30E21,hM30E50,hM30RSI };
   for(int k=0;k<8;k++) IndicatorRelease(handles[k]);
   ObjectsDeleteAll(0, PFX);
}

//==================================================================
//  CALCULATE
//==================================================================
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
   int minBars = 55;
   if(rates_total < minBars) return 0;

   // ── Tentar criar painel (so uma vez) ─────────────────────────
   if(InpPanel && !panelOk)
   {
      string sname = StringFormat("UsaTec Score [Thr:%.0f%%]", InpThresh*100);
      panelWin = ChartWindowFind(0, sname);
      if(panelWin >= 0) { CreatePanel(); panelOk = true; }
   }

   // ── Carregar M30 (pelo numero real de barras M30) ─────────────
   int m30n = iBars(Symbol(), PERIOD_M30);
   if(m30n < 30) return 0;

   double m30e21[], m30e50[], m30rsi[];
   ArraySetAsSeries(m30e21,  true);
   ArraySetAsSeries(m30e50,  true);
   ArraySetAsSeries(m30rsi,  true);
   if(CopyBuffer(hM30E21, 0, 0, m30n, m30e21)  != m30n) return prev_calculated;
   if(CopyBuffer(hM30E50, 0, 0, m30n, m30e50)  != m30n) return prev_calculated;
   if(CopyBuffer(hM30RSI, 0, 0, m30n, m30rsi)  != m30n) return prev_calculated;

   // ── Carregar M5 (como serie: indice 0 = mais recente) ─────────
   double ae9[], ae21[], ae50[], arsi[], aatr[];
   ArraySetAsSeries(ae9,  true); ArraySetAsSeries(ae21, true);
   ArraySetAsSeries(ae50, true); ArraySetAsSeries(arsi, true);
   ArraySetAsSeries(aatr, true);
   if(CopyBuffer(hE9,  0, 0, rates_total, ae9)  <= 0) return prev_calculated;
   if(CopyBuffer(hE21, 0, 0, rates_total, ae21) <= 0) return prev_calculated;
   if(CopyBuffer(hE50, 0, 0, rates_total, ae50) <= 0) return prev_calculated;
   if(CopyBuffer(hRSI, 0, 0, rates_total, arsi) <= 0) return prev_calculated;
   if(CopyBuffer(hATR, 0, 0, rates_total, aatr) <= 0) return prev_calculated;

   // ── VWAP: calcular da esquerda para a direita ─────────────────
   // time[], open[], high[], low[], close[] NAO sao series no OnCalculate
   // (indice 0 = barra mais antiga, rates_total-1 = barra mais recente)
   {
      double cumTP=0, cumVol=0;
      datetime dayS=0;
      for(int i=0; i<rates_total; i++)
      {
         MqlDateTime dt; TimeToStruct(time[i], dt);
         datetime d = (datetime)(time[i] - (datetime)(dt.hour*3600+dt.min*60+dt.sec));
         if(d != dayS) { dayS=d; cumTP=0; cumVol=0; }
         double v = (double)tick_volume[i];
         cumTP  += ((high[i]+low[i]+close[i])/3.0)*v;
         cumVol += v;
         VwapC[i] = (cumVol>0) ? cumTP/cumVol : close[i];
      }
   }

   // ── Loop principal ─────────────────────────────────────────────
   // IMPORTANTE: time[] nao eh serie (0=antigo), mas ae21[] eh serie (0=recente)
   // Para a barra no indice i de time[]:
   //   - No array serie: si = rates_total - 1 - i  (si=0 quando i=rates_total-1)
   //   - OHLC vem de open[i], close[i] etc. (nao serie)

   int start = (prev_calculated < minBars) ? minBars : prev_calculated - 1;
   double wTot = W1+W2+W3+W4+W5+W6+W7; if(wTot<0.001) wTot=1.0;

   // Variaveis para o painel (ultima barra calculada)
   double pMe21=0,pMe50=0,pMrsi=0,pE9=0,pE21=0,pCl=0,pOp=0,pRsi=0,pVwap=0,pNet=0;
   bool   pFL=false,pFS=false;

   for(int i=start; i<rates_total; i++)
   {
      // Indice no array serie para esta barra M5
      int si  = rates_total - 1 - i;   // si=0 = barra i=rates_total-1
      int si1 = si + 1;                 // barra anterior
      int si2 = si + 2;                 // penultima

      if(si2 >= rates_total) { Sc[i]=0; ScClr[i]=2; continue; }

      // Dados M5 (valores ja calculados para barra fechada i-1)
      // OHLC da barra anterior: indice i-1 no array nao-serie
      int  ip  = i-1;
      int  ip2 = i-2;
      if(ip < 0)  { Sc[i]=0; ScClr[i]=2; continue; }

      double cl  = close[ip];
      double op  = open [ip];
      double hi  = high [ip];
      double lo  = low  [ip];
      double cl2 = (ip2 >= 0) ? close[ip2] : cl;
      double lo2 = (ip2 >= 0) ? low  [ip2] : lo;
      double hi2 = (ip2 >= 0) ? high [ip2] : hi;

      // Indicadores M5 da barra anterior (si1 no array serie)
      double e9v   = ae9 [si1];
      double e21v  = ae21[si1];
      double e21p  = ae21[si2];   // EMA21 penultima barra
      double rsiv  = arsi[si1];
      double atrv  = aatr[si1];
      double vwap  = VwapC[ip];

      // Buscar barra M30 correspondente a esta barra M5
      // iBarShift retorna indice no PERIOD_M30 (0 = barra M30 mais recente)
      int m30i = iBarShift(Symbol(), PERIOD_M30, time[i], false);
      if(m30i < 0 || m30i >= m30n) { Sc[i]=0; ScClr[i]=2; continue; }

      double me21v = m30e21[m30i];
      double me50v = m30e50[m30i];
      double mrsiv = m30rsi[m30i];
      if(me21v == 0 || me50v == 0) { Sc[i]=0; ScClr[i]=2; continue; }

      // ── Condicoes binarias ─────────────────────────────────────
      bool trend_bull = me21v > me50v;
      bool trend_bear = me21v < me50v;
      bool mom_bull   = mrsiv >= InpRSILong;
      bool mom_bear   = mrsiv <= InpRSIShort;
      bool pb_bull    = (lo <= e21v*1.003) || (lo2 <= e21p*1.003);
      bool pb_bear    = (hi >= e21v*0.997) || (hi2 >= e21p*0.997);
      bool conf_bull  = cl > e21v && cl > e9v;
      bool conf_bear  = cl < e21v && cl < e9v;
      bool vwap_bull  = cl > vwap;
      bool vwap_bear  = cl < vwap;
      bool rsi5_bull  = rsiv >= InpRSILMin && rsiv <= InpRSILMax;
      bool rsi5_bear  = rsiv >= InpRSISMin && rsiv <= InpRSISMax;
      bool cndl_bull  = cl > op;
      bool cndl_bear  = cl < op;

      // ── Score LONG ──────────────────────────────────────────────
      double c1l = trend_bull ? W1 : 0.0;

      double c2l = 0.0;
      if(mom_bull) c2l = W2*MathMin(1.0, 0.5+(mrsiv-InpRSILong)/(100.0-InpRSILong));

      double c3l = pb_bull ? W3 : 0.0;

      double c4l = conf_bull ? W4 : (cl > e21v ? W4*0.5 : 0.0);

      double c5l = 0.0;
      if(vwap_bull) c5l = (atrv>0) ? W5*MathMin(1.0,0.4+(cl-vwap)/atrv) : W5*0.4;

      double c6l = 0.0;
      if(rsi5_bull)
      {
         double ctr = (InpRSILMin+InpRSILMax)/2.0, hlf = (InpRSILMax-InpRSILMin)/2.0;
         c6l = W6*(1.0-0.5*MathAbs(rsiv-ctr)/(hlf+0.001));
      }

      double rng = MathAbs(hi-lo)+0.0001;
      double c7l = cndl_bull ? W7*MathMin(1.0, MathAbs(cl-op)/rng*2.0) : 0.0;

      double scL = (c1l+c2l+c3l+c4l+c5l+c6l+c7l)/wTot;

      // ── Score SHORT ─────────────────────────────────────────────
      double c1s = trend_bear ? W1 : 0.0;

      double c2s = 0.0;
      if(mom_bear) c2s = W2*MathMin(1.0, 0.5+(InpRSIShort-mrsiv)/(InpRSIShort+0.001));

      double c3s = pb_bear ? W3 : 0.0;

      double c4s = conf_bear ? W4 : (cl < e21v ? W4*0.5 : 0.0);

      double c5s = 0.0;
      if(vwap_bear) c5s = (atrv>0) ? W5*MathMin(1.0,0.4+(vwap-cl)/atrv) : W5*0.4;

      double c6s = 0.0;
      if(rsi5_bear)
      {
         double ctr = (InpRSISMin+InpRSISMax)/2.0, hlf = (InpRSISMax-InpRSISMin)/2.0;
         c6s = W6*(1.0-0.5*MathAbs(rsiv-ctr)/(hlf+0.001));
      }

      double c7s = cndl_bear ? W7*MathMin(1.0, MathAbs(cl-op)/rng*2.0) : 0.0;

      double scS = (c1s+c2s+c3s+c4s+c5s+c6s+c7s)/wTot;

      // ── Score final: -1 a +1 ───────────────────────────────────
      double net = MathMax(-1.0, MathMin(1.0, scL - scS));
      Sc[i] = net;

      // Cor: 0=vermelho, 1=laranja, 2=ouro, 3=verde claro, 4=verde
      ScClr[i] = (net >=  0.60) ? 4 :
                 (net >=  0.20) ? 3 :
                 (net >= -0.20) ? 2 :
                 (net >= -0.60) ? 1 : 0;

      // ── Setas ──────────────────────────────────────────────────
      BuyArr[i]  = EMPTY_VALUE;
      SellArr[i] = EMPTY_VALUE;

      if(InpArrows)
      {
         bool fL = trend_bull && mom_bull && pb_bull && conf_bull &&
                   vwap_bull && rsi5_bull && cndl_bull;
         bool fS = trend_bear && mom_bear && pb_bear && conf_bear &&
                   vwap_bear && rsi5_bear && cndl_bear;

         if(fL) BuyArr[i]  = -0.90;
         if(fS) SellArr[i] =  0.90;

         if(i == rates_total-1) { pFL=fL; pFS=fS; }
      }

      // Guardar para painel
      if(i == rates_total-1)
      {
         pMe21=me21v; pMe50=me50v; pMrsi=mrsiv;
         pE9=e9v; pE21=e21v; pCl=cl; pOp=op; pRsi=rsiv; pVwap=vwap; pNet=net;
      }
   }

   // Atualizar painel
   if(InpPanel && panelOk)
      UpdatePanel(pMe21,pMe50,pMrsi,pE9,pE21,pCl,pOp,pRsi,pVwap,pNet,pFL,pFS);

   return rates_total;
}

//==================================================================
//  PAINEL
//==================================================================
void CreatePanel()
{
   ObjectsDeleteAll(0, PFX);
   int x=10, y=18, W=252, H=290;

   MkRect(PFX+"BG", panelWin, x-6, y-6, W, H, C'10,15,22', C'35,55,75');

   MkLbl(PFX+"T0", "▌ UsaTec Signal Score", panelWin, x,    y,    13, clrDodgerBlue);
   MkLbl(PFX+"T1", "─────────────────────", panelWin, x,    y+17, 9,  C'38,58,78');

   string lbl[7] = {
      "① Tend. M30 (EMA21>EMA50)",
      "② RSI M30  (≥60 bull / ≤40 bear)",
      "③ Pullback na EMA21 M5",
      "④ Confirm. (close>EMA21+EMA9)",
      "⑤ Posicao vs VWAP diario",
      "⑥ RSI M5 em zona valida",
      "⑦ Candle anterior direcional"
   };
   for(int k=0;k<7;k++)
   {
      MkLbl(PFX+"L"+IntegerToString(k), lbl[k],
            panelWin, x, y+29+k*29, 8, C'120,148,168');
      MkLbl(PFX+"V"+IntegerToString(k), "—",
            panelWin, x+4, y+41+k*29, 9, clrGray);
   }
   MkLbl(PFX+"SP", "─────────────────────",  panelWin, x,    y+244, 9,  C'38,58,78');
   MkLbl(PFX+"SL", "SCORE:",                  panelWin, x,    y+258, 10, C'120,148,168');
   MkLbl(PFX+"SV", "0.00",                    panelWin, x+60, y+258, 14, clrGray);
   MkLbl(PFX+"SS", "",                        panelWin, x+115,y+258, 11, clrGray);
}

void UpdatePanel(double me21,double me50,double mrsi,
                 double e9,double e21,double cl,double op,
                 double rsi5,double vwap,double score,
                 bool fL,bool fS)
{
   if(!InpPanel||!panelOk) return;

   // C1
   bool c1l=me21>me50, c1s=me21<me50;
   SetC(PFX+"V0", c1l, c1s, c1l?"▲ BULL":(c1s?"▼ BEAR":"NEUTRO"));

   // C2
   bool c2l=mrsi>=InpRSILong, c2s=mrsi<=InpRSIShort;
   SetC(PFX+"V1", c2l, c2s, StringFormat("%.1f  %s",mrsi,(c2l||c2s)?"✓":"—"));

   // C3 (aproximado - usa resultado do setup completo como proxy)
   SetC(PFX+"V2", fL, fS, (fL?"✓ long":(fS?"✓ short":"—")));

   // C4
   bool c4l=cl>e21&&cl>e9, c4s=cl<e21&&cl<e9;
   SetC(PFX+"V3", c4l, c4s, (c4l?"✓ acima":(c4s?"✓ abaixo":"—")));

   // C5
   bool c5l=cl>vwap, c5s=cl<vwap;
   SetC(PFX+"V4", c5l, c5s, (c5l?"✓ acima VWAP":"✓ abaixo VWAP"));

   // C6
   bool c6l=rsi5>=InpRSILMin&&rsi5<=InpRSILMax;
   bool c6s=rsi5>=InpRSISMin&&rsi5<=InpRSISMax;
   SetC(PFX+"V5", c6l, c6s, StringFormat("%.1f  %s",rsi5,(c6l||c6s)?"✓":"—"));

   // C7
   bool c7l=cl>op, c7s=cl<op;
   SetC(PFX+"V6", c7l, c7s, (c7l?"Bull ✓":(c7s?"Bear ✓":"Doji")));

   // Score
   color sc  = (score>= 0.4)?clrLimeGreen:(score<=-0.4)?clrTomato:clrGold;
   string sg = (score>= InpThresh)?"  ◄ BUY":(score<=-InpThresh)?"  ◄ SELL":"  ◄ WAIT";
   color  sc2= (score>=InpThresh)?clrLime:(score<=-InpThresh)?clrRed:clrGold;

   ObjSet(PFX+"SV", StringFormat("%+.2f", score), sc);
   ObjSet(PFX+"SS", sg, sc2);
   ChartRedraw();
}

void SetC(string n, bool bull, bool bear, string txt)
{
   color c = bull?clrLimeGreen:(bear?clrTomato:C'75,90,105');
   ObjSet(n, txt, c);
}

void ObjSet(string n, string txt, color clr)
{
   ObjectSetString (0,n,OBJPROP_TEXT, txt);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
}

void MkRect(string n,int sub,int x,int y,int w,int h,color bg,color brd)
{
   ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,sub,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,brd);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
}

void MkLbl(string n,string txt,int sub,int x,int y,int fs,color clr)
{
   ObjectCreate(0,n,OBJ_LABEL,sub,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetString (0,n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}
//+------------------------------------------------------------------+
