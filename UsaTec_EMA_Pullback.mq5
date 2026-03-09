//+------------------------------------------------------------------+
//|  UsaTec_EMA_Pullback.mq5                                        |
//|  Estratégia: EMA Pullback + M30 RSI Momentum Filter             |
//|  Ativo:      UsaTec / NQ Futuro (adaptável a outros)            |
//|  Timeframe:  M5 (entrada) + M30 (viés/filtro)                   |
//|  Backtest:   Out 2024 – Mar 2026 | WR: 57,6% | PF: 1,53        |
//+------------------------------------------------------------------+
#property copyright   "UsaTec Strategy EA"
#property version     "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==================================================================
//  PARÂMETROS DE ENTRADA
//==================================================================

// --- Indicadores M5 ---
input group "=== INDICADORES M5 ==="
input int    InpEMA9        = 9;        // EMA Rápida (M5)
input int    InpEMA21       = 21;       // EMA Média — Pullback (M5)
input int    InpEMA50       = 50;       // EMA Lenta (M5)
input int    InpRSIPeriod   = 14;       // RSI Período (M5)
input int    InpATRPeriod   = 14;       // ATR Período (M5)

// --- Filtros M30 ---
input group "=== FILTROS M30 (VIÉS E MOMENTUM) ==="
input int    InpM30EMA21    = 21;       // EMA Rápida M30
input int    InpM30EMA50    = 50;       // EMA Lenta M30
input int    InpM30RSI      = 14;       // RSI Período M30
input double InpM30RSILong  = 60.0;    // RSI M30 mínimo para LONG
input double InpM30RSIShort = 40.0;    // RSI M30 máximo para SHORT

// --- Filtros M5 ---
input group "=== FILTROS RSI M5 ==="
input double InpRSILongMin  = 40.0;    // RSI M5 mínimo (Long)
input double InpRSILongMax  = 72.0;    // RSI M5 máximo (Long)
input double InpRSIShortMin = 28.0;    // RSI M5 mínimo (Short)
input double InpRSIShortMax = 60.0;    // RSI M5 máximo (Short)

// --- Tolerância do Pullback ---
input double InpPullbackToleranceUp   = 1.003; // Low candle ≤ EMA21 × este valor (Long)
input double InpPullbackToleranceDn   = 0.997; // High candle ≥ EMA21 × este valor (Short)

// --- Gestão de Risco ---
input group "=== GESTÃO DE RISCO ==="
input double InpRiskPct     = 1.5;     // Risco por trade (% do equity)
input double InpATRStopMult = 1.5;     // Stop = N × ATR(14) M5
input double InpRR          = 2.0;     // Risk:Reward (TP = RR × stop_dist)
input double InpBEatR       = 1.0;     // Mover para BE quando price move N×R no positivo
input double InpBEBuffer    = 0.5;     // Buffer acima/abaixo da entrada no BE (pontos)

// --- Controles Diários ---
input group "=== CONTROLES DIÁRIOS ==="
input int    InpMaxTradesDay = 3;       // Máximo de trades por dia
input double InpDailyDDPct  = 2.5;     // Stop do dia ao atingir N% de drawdown diário

// --- Sessão ---
input group "=== SESSÃO (UTC) ==="
input int    InpSessionStartH = 14;    // Hora início sessão UTC
input int    InpSessionStartM = 0;     // Minuto início
input int    InpSessionEndH   = 18;    // Hora fim entrada (sem novos trades após)
input int    InpSessionEndM   = 30;    // Minuto fim entrada
input int    InpForceCloseH   = 20;    // Hora fechamento forçado UTC
input int    InpForceCloseM   = 0;     // Minuto fechamento forçado

// --- Operacional ---
input group "=== CONFIGURAÇÃO OPERACIONAL ==="
input ulong  InpMagicNumber  = 20250101; // Magic number do EA
input string InpComment      = "UsaTec_EMA_PB"; // Comentário das ordens
input int    InpSlippage     = 10;      // Slippage máximo (pontos)
input bool   InpAllowLong    = true;    // Permitir operações LONG
input bool   InpAllowShort   = true;    // Permitir operações SHORT
input bool   InpEnableAlerts = true;    // Alertas de setup encontrado
input bool   InpEnableLogs   = true;    // Logs detalhados no diário

//==================================================================
//  VARIÁVEIS GLOBAIS
//==================================================================
CTrade         trade;
CPositionInfo  posInfo;

// Handles dos indicadores — M5
int h_ema9, h_ema21, h_ema50, h_rsi, h_atr;

// Handles dos indicadores — M30
int h_m30_ema21, h_m30_ema50, h_m30_rsi;

// Controle diário
datetime g_lastDay         = 0;
int      g_tradesToday     = 0;
double   g_equityDayStart  = 0;

// Breakeven tracker
ulong    g_beTicket        = 0;
bool     g_beDone          = false;
double   g_beEntryPrice    = 0;
double   g_beStopDist      = 0;
int      g_beDirection     = 0;   // 1=long, -1=short

//==================================================================
//  INICIALIZAÇÃO
//==================================================================
int OnInit()
{
   // Validar timeframe
   if(Period() != PERIOD_M5)
   {
      Alert("⚠ EA deve ser aplicado no gráfico M5! Atual: ", EnumToString(Period()));
      return INIT_FAILED;
   }

   // Configurar objeto de trade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Inicializar indicadores M5
   string sym = Symbol();
   h_ema9   = iMA(sym, PERIOD_M5, InpEMA9,  0, MODE_EMA, PRICE_CLOSE);
   h_ema21  = iMA(sym, PERIOD_M5, InpEMA21, 0, MODE_EMA, PRICE_CLOSE);
   h_ema50  = iMA(sym, PERIOD_M5, InpEMA50, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi    = iRSI(sym, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   h_atr    = iATR(sym, PERIOD_M5, InpATRPeriod);

   // Inicializar indicadores M30
   h_m30_ema21 = iMA(sym, PERIOD_M30, InpM30EMA21, 0, MODE_EMA, PRICE_CLOSE);
   h_m30_ema50 = iMA(sym, PERIOD_M30, InpM30EMA50, 0, MODE_EMA, PRICE_CLOSE);
   h_m30_rsi   = iRSI(sym, PERIOD_M30, InpM30RSI, PRICE_CLOSE);

   // Verificar se handles são válidos
   if(h_ema9 == INVALID_HANDLE || h_ema21 == INVALID_HANDLE || h_ema50 == INVALID_HANDLE ||
      h_rsi  == INVALID_HANDLE || h_atr   == INVALID_HANDLE ||
      h_m30_ema21 == INVALID_HANDLE || h_m30_ema50 == INVALID_HANDLE || h_m30_rsi == INVALID_HANDLE)
   {
      Alert("⚠ Erro ao criar handles de indicadores! Código: ", GetLastError());
      return INIT_FAILED;
   }

   if(InpEnableLogs)
      PrintFormat("✅ UsaTec EA iniciado | Símbolo: %s | Magic: %d | Risk: %.1f%%",
                  sym, InpMagicNumber, InpRiskPct);

   return INIT_SUCCEEDED;
}

//==================================================================
//  DESINICIALIZAÇÃO
//==================================================================
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ema9);
   IndicatorRelease(h_ema21);
   IndicatorRelease(h_ema50);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_m30_ema21);
   IndicatorRelease(h_m30_ema50);
   IndicatorRelease(h_m30_rsi);
}

//==================================================================
//  TICK PRINCIPAL
//==================================================================
void OnTick()
{
   // Só processar em novos candles M5
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(Symbol(), PERIOD_M5, 0);
   if(currentBarTime == lastBarTime) 
   {
      // Mesmo dentro do candle: checar breakeven
      CheckBreakeven();
      // Checar fechamento forçado de sessão
      CheckForceClose();
      return;
   }
   lastBarTime = currentBarTime;

   // ── Atualizar controles diários ──────────────────────────────
   UpdateDailyTracking();

   // ── Checar fechamento forçado ────────────────────────────────
   CheckForceClose();

   // ── Checar breakeven ────────────────────────────────────────
   CheckBreakeven();

   // ── Verificar se pode abrir novos trades ─────────────────────
   if(!CanTrade()) return;

   // ── Carregar dados dos indicadores ───────────────────────────
   SIndicators ind;
   if(!LoadIndicators(ind)) return;

   // ── Avaliar setups ────────────────────────────────────────────
   int signal = EvaluateSetup(ind);

   if(signal == 0) return;

   // ── Executar trade ────────────────────────────────────────────
   ExecuteTrade(signal, ind);
}

//==================================================================
//  ESTRUTURA DE DADOS DOS INDICADORES
//==================================================================
struct SIndicators
{
   // M5 — candle atual (idx 0) e anteriores (1,2)
   double ema9_0,  ema9_1;
   double ema21_0, ema21_1, ema21_2;
   double ema50_0;
   double rsi_0;
   double atr_0;
   double close_0, close_1, close_2;
   double open_0,  open_1,  open_2;
   double high_0,  high_1,  high_2;
   double low_0,   low_1,   low_2;

   // M30
   double m30_ema21_0;
   double m30_ema50_0;
   double m30_rsi_0;

   // VWAP — calculado manualmente
   double vwap;
};

//==================================================================
//  CARGA DOS INDICADORES
//==================================================================
bool LoadIndicators(SIndicators &ind)
{
   string sym = Symbol();

   // Arrays temporários
   double buf[3];

   // EMA9 M5
   if(CopyBuffer(h_ema9, 0, 1, 2, buf) < 2) return false;
   ind.ema9_0 = buf[1]; ind.ema9_1 = buf[0];

   // EMA21 M5
   if(CopyBuffer(h_ema21, 0, 1, 3, buf) < 3) return false;
   ind.ema21_0 = buf[2]; ind.ema21_1 = buf[1]; ind.ema21_2 = buf[0];

   // EMA50 M5
   if(CopyBuffer(h_ema50, 0, 1, 1, buf) < 1) return false;
   ind.ema50_0 = buf[0];

   // RSI M5
   if(CopyBuffer(h_rsi, 0, 1, 1, buf) < 1) return false;
   ind.rsi_0 = buf[0];

   // ATR M5
   if(CopyBuffer(h_atr, 0, 1, 1, buf) < 1) return false;
   ind.atr_0 = buf[0];

   // M30 indicadores (usar candle 0 do M30 — já formado)
   if(CopyBuffer(h_m30_ema21, 0, 0, 1, buf) < 1) return false;
   ind.m30_ema21_0 = buf[0];

   if(CopyBuffer(h_m30_ema50, 0, 0, 1, buf) < 1) return false;
   ind.m30_ema50_0 = buf[0];

   if(CopyBuffer(h_m30_rsi, 0, 0, 1, buf) < 1) return false;
   ind.m30_rsi_0 = buf[0];

   // OHLC M5 (candles 1, 2, 3 = já fechados)
   ind.close_0 = iClose(sym, PERIOD_M5, 1);
   ind.close_1 = iClose(sym, PERIOD_M5, 2);
   ind.close_2 = iClose(sym, PERIOD_M5, 3);
   ind.open_0  = iOpen (sym, PERIOD_M5, 1);
   ind.open_1  = iOpen (sym, PERIOD_M5, 2);
   ind.high_0  = iHigh (sym, PERIOD_M5, 1);
   ind.high_1  = iHigh (sym, PERIOD_M5, 2);
   ind.low_0   = iLow  (sym, PERIOD_M5, 1);
   ind.low_1   = iLow  (sym, PERIOD_M5, 2);

   // VWAP diário simplificado (TP × Volume / Volume acumulado)
   ind.vwap = CalcVWAP();

   return true;
}

//==================================================================
//  CÁLCULO DO VWAP DIÁRIO
//==================================================================
double CalcVWAP()
{
   string sym     = Symbol();
   datetime today = iTime(sym, PERIOD_D1, 0);  // Abertura do dia atual

   double   cumTP  = 0.0;
   long     cumVol = 0;

   // Percorrer barras M5 desde o início do dia até a última fechada
   for(int i = 1; i <= 500; i++)
   {
      datetime bt = iTime(sym, PERIOD_M5, i);
      if(bt < today) break;

      double h = iHigh(sym,  PERIOD_M5, i);
      double l = iLow(sym,   PERIOD_M5, i);
      double c = iClose(sym, PERIOD_M5, i);
      long   v = (long)iVolume(sym, PERIOD_M5, i);

      double tp = (h + l + c) / 3.0;
      cumTP  += tp * v;
      cumVol += v;
   }

   if(cumVol == 0) return iClose(sym, PERIOD_M5, 1);
   return cumTP / cumVol;
}

//==================================================================
//  AVALIAÇÃO DO SETUP
//==================================================================
int EvaluateSetup(const SIndicators &ind)
{
   // ── SETUP LONG ────────────────────────────────────────────────
   if(InpAllowLong)
   {
      // 1. Tendência M30: EMA21 > EMA50
      bool trend_m30_bull = (ind.m30_ema21_0 > ind.m30_ema50_0);

      // 2. Momentum M30: RSI ≥ InpM30RSILong
      bool momentum_long  = (ind.m30_rsi_0 >= InpM30RSILong);

      // 3. Pullback: low do candle anterior ou penúltimo tocou EMA21 M5
      bool pullback_long  = (ind.low_0 <= ind.ema21_1 * InpPullbackToleranceUp) ||
                            (ind.low_1 <= ind.ema21_2 * InpPullbackToleranceUp);

      // 4. Confirmação: candle fechado acima da EMA21 e EMA9
      bool confirm_long   = (ind.close_0 > ind.ema21_0) && (ind.close_0 > ind.ema9_0);

      // 5. Preço acima do VWAP
      bool above_vwap     = (ind.close_0 > ind.vwap);

      // 6. RSI M5 em zona saudável
      bool rsi_long       = (ind.rsi_0 > InpRSILongMin) && (ind.rsi_0 < InpRSILongMax);

      // 7. Candle anterior bullish
      bool bull_candle    = (ind.close_0 > ind.open_0);

      if(trend_m30_bull && momentum_long && pullback_long && confirm_long &&
         above_vwap && rsi_long && bull_candle)
      {
         if(InpEnableLogs)
            PrintFormat("📗 LONG Setup | Price: %.2f | EMA21: %.2f | VWAP: %.2f | M30RSI: %.1f | M5RSI: %.1f",
                        ind.close_0, ind.ema21_0, ind.vwap, ind.m30_rsi_0, ind.rsi_0);
         if(InpEnableAlerts)
            Alert("📗 LONG Setup - ", Symbol(), " | M30RSI: ", DoubleToString(ind.m30_rsi_0,1),
                  " | M5RSI: ", DoubleToString(ind.rsi_0,1));
         return 1;
      }
   }

   // ── SETUP SHORT ───────────────────────────────────────────────
   if(InpAllowShort)
   {
      // 1. Tendência M30: EMA21 < EMA50
      bool trend_m30_bear = (ind.m30_ema21_0 < ind.m30_ema50_0);

      // 2. Momentum M30: RSI ≤ InpM30RSIShort
      bool momentum_short = (ind.m30_rsi_0 <= InpM30RSIShort);

      // 3. Pullback: high do candle anterior ou penúltimo tocou EMA21
      bool pullback_short = (ind.high_0 >= ind.ema21_1 * InpPullbackToleranceDn) ||
                            (ind.high_1 >= ind.ema21_2 * InpPullbackToleranceDn);

      // 4. Confirmação: candle fechado abaixo da EMA21 e EMA9
      bool confirm_short  = (ind.close_0 < ind.ema21_0) && (ind.close_0 < ind.ema9_0);

      // 5. Preço abaixo do VWAP
      bool below_vwap     = (ind.close_0 < ind.vwap);

      // 6. RSI M5 em zona saudável
      bool rsi_short      = (ind.rsi_0 > InpRSIShortMin) && (ind.rsi_0 < InpRSIShortMax);

      // 7. Candle anterior bearish
      bool bear_candle    = (ind.close_0 < ind.open_0);

      if(trend_m30_bear && momentum_short && pullback_short && confirm_short &&
         below_vwap && rsi_short && bear_candle)
      {
         if(InpEnableLogs)
            PrintFormat("📕 SHORT Setup | Price: %.2f | EMA21: %.2f | VWAP: %.2f | M30RSI: %.1f | M5RSI: %.1f",
                        ind.close_0, ind.ema21_0, ind.vwap, ind.m30_rsi_0, ind.rsi_0);
         if(InpEnableAlerts)
            Alert("📕 SHORT Setup - ", Symbol(), " | M30RSI: ", DoubleToString(ind.m30_rsi_0,1),
                  " | M5RSI: ", DoubleToString(ind.rsi_0,1));
         return -1;
      }
   }

   return 0;
}

//==================================================================
//  EXECUÇÃO DO TRADE
//==================================================================
void ExecuteTrade(int signal, const SIndicators &ind)
{
   string sym   = Symbol();
   double price = (signal == 1) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                : SymbolInfoDouble(sym, SYMBOL_BID);

   double stopDist = InpATRStopMult * ind.atr_0;
   if(stopDist <= 0)
   {
      PrintFormat("⚠ stopDist inválido (ATR=%.5f)", ind.atr_0);
      return;
   }

   double sl, tp;
   if(signal == 1)
   {
      sl = price - stopDist;
      tp = price + InpRR * stopDist;
   }
   else
   {
      sl = price + stopDist;
      tp = price - InpRR * stopDist;
   }

   // Normalizar preços
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // Calcular volume
   double volume = CalcVolume(stopDist);
   if(volume <= 0)
   {
      if(InpEnableLogs) PrintFormat("⚠ Volume calculado inválido. Equity: %.2f, StopDist: %.5f", AccountInfoDouble(ACCOUNT_EQUITY), stopDist);
      return;
   }

   // Verificar se já existe posição aberta para este símbolo + magic
   if(HasOpenPosition())
   {
      if(InpEnableLogs) PrintFormat("ℹ Já existe posição aberta. Aguardando fechamento.");
      return;
   }

   // Executar
   bool ok = false;
   if(signal == 1)
      ok = trade.Buy(volume, sym, price, sl, tp, InpComment);
   else
      ok = trade.Sell(volume, sym, price, sl, tp, InpComment);

   if(ok)
   {
      g_tradesToday++;

      // Configurar rastreamento de breakeven
      g_beTicket     = trade.ResultOrder();
      g_beDone       = false;
      g_beEntryPrice = price;
      g_beStopDist   = stopDist;
      g_beDirection  = signal;

      PrintFormat("✅ Trade aberto | %s | Preço: %.2f | SL: %.2f | TP: %.2f | Vol: %.2f | Ticket: %d",
                  (signal==1 ? "LONG" : "SHORT"), price, sl, tp, volume, g_beTicket);
   }
   else
   {
      PrintFormat("❌ Erro ao abrir trade: %d | %s", trade.ResultRetcode(), trade.ResultComment());
   }
}

//==================================================================
//  CÁLCULO DO VOLUME (SIZING)
//==================================================================
double CalcVolume(double stopDist)
{
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (InpRiskPct / 100.0);

   // Obter valor de 1 ponto para o símbolo
   double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return 0;

   double pointValue = tickValue / tickSize;  // Valor por ponto por lote
   if(pointValue <= 0) return 0;

   double volume = riskAmount / (stopDist * pointValue);

   // Normalizar para os limites do símbolo
   double volMin  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / volStep) * volStep;
   volume = MathMax(volume, volMin);
   volume = MathMin(volume, volMax);

   return volume;
}

//==================================================================
//  GERENCIAMENTO DE BREAKEVEN
//==================================================================
void CheckBreakeven()
{
   if(g_beTicket == 0 || g_beDone) return;
   if(!posInfo.SelectByTicket(g_beTicket)) return;
   if(posInfo.Magic() != InpMagicNumber) return;

   double currentPrice = (g_beDirection == 1) ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                                               : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double currentSL    = posInfo.StopLoss();

   bool beTrigger = false;
   double newSL   = 0;

   if(g_beDirection == 1)
   {
      // Long: mover BE quando price atinge entrada + 1×stopDist
      if(currentPrice >= g_beEntryPrice + InpBEatR * g_beStopDist)
      {
         newSL = NormalizeDouble(g_beEntryPrice + InpBEBuffer, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
         if(currentSL < newSL) beTrigger = true;
      }
   }
   else
   {
      // Short: mover BE quando price atinge entrada - 1×stopDist
      if(currentPrice <= g_beEntryPrice - InpBEatR * g_beStopDist)
      {
         newSL = NormalizeDouble(g_beEntryPrice - InpBEBuffer, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS));
         if(currentSL > newSL || currentSL == 0) beTrigger = true;
      }
   }

   if(beTrigger)
   {
      double tp = posInfo.TakeProfit();
      if(trade.PositionModify(g_beTicket, newSL, tp))
      {
         g_beDone = true;
         if(InpEnableLogs)
            PrintFormat("🔒 Breakeven ativado | Ticket: %d | Novo SL: %.5f", g_beTicket, newSL);
      }
   }
}

//==================================================================
//  FECHAMENTO FORÇADO NO FIM DA SESSÃO
//==================================================================
void CheckForceClose()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int nowMins = dt.hour * 60 + dt.min;
   int closeMins = InpForceCloseH * 60 + InpForceCloseM;

   if(nowMins < closeMins) return;

   // Fechar todas as posições com o magic number
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == InpMagicNumber)
         {
            if(trade.PositionClose(posInfo.Ticket()))
            {
               if(InpEnableLogs)
                  PrintFormat("🔔 Posição fechada por fim de sessão | Ticket: %d | PnL: %.2f",
                              posInfo.Ticket(), posInfo.Profit());
            }
         }
      }
   }
}

//==================================================================
//  CONTROLE DIÁRIO
//==================================================================
void UpdateDailyTracking()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00:00",
                                              dt.year, dt.mon, dt.day));

   if(today != g_lastDay)
   {
      g_lastDay        = today;
      g_tradesToday    = 0;
      g_equityDayStart = AccountInfoDouble(ACCOUNT_EQUITY);
      g_beTicket       = 0;
      g_beDone         = false;

      // Contar trades já realizados hoje (para reinicialização)
      int cnt = 0;
      HistorySelect(today, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber)
            if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
               cnt++;
      }
      g_tradesToday = cnt;

      if(InpEnableLogs)
         PrintFormat("📅 Novo dia | Equity: $%.2f | Trades hoje: %d",
                     g_equityDayStart, g_tradesToday);
   }
}

//==================================================================
//  VERIFICAÇÃO SE PODE OPERAR
//==================================================================
bool CanTrade()
{
   // Checar se está dentro da sessão de trading
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int nowMins   = dt.hour * 60 + dt.min;
   int startMins = InpSessionStartH * 60 + InpSessionStartM;
   int endMins   = InpSessionEndH   * 60 + InpSessionEndM;

   if(nowMins < startMins || nowMins > endMins) return false;

   // Checar dia da semana (Seg=1 a Sex=5, Sab=6, Dom=0)
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;

   // Checar limite de trades diários
   if(g_tradesToday >= InpMaxTradesDay)
   {
      // Log apenas uma vez por candle
      static datetime lastLog = 0;
      datetime curBar = iTime(Symbol(), PERIOD_M5, 0);
      if(curBar != lastLog)
      {
         if(InpEnableLogs) PrintFormat("ℹ Limite de %d trades/dia atingido.", InpMaxTradesDay);
         lastLog = curBar;
      }
      return false;
   }

   // Checar drawdown diário
   if(g_equityDayStart > 0)
   {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = (g_equityDayStart - currentEquity) / g_equityDayStart * 100.0;
      if(ddPct >= InpDailyDDPct)
      {
         static datetime lastDDLog = 0;
         datetime curBar = iTime(Symbol(), PERIOD_M5, 0);
         if(curBar != lastDDLog)
         {
            PrintFormat("🛑 Daily DD limit atingido: %.2f%% | Parado por hoje.", ddPct);
            lastDDLog = curBar;
         }
         return false;
      }
   }

   // Checar se já existe posição aberta
   if(HasOpenPosition()) return false;

   return true;
}

//==================================================================
//  VERIFICA SE HÁ POSIÇÃO ABERTA DO EA
//==================================================================
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == InpMagicNumber)
            return true;
   }
   return false;
}

//==================================================================
//  EVENTOS DE TRADE (log de fechamentos)
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(magic != InpMagicNumber) return;

         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT)
         {
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            string reason = "";
            if(profit > 0)  reason = "✅ TP / Positivo";
            else if(profit == 0) reason = "🔒 Breakeven";
            else reason = "❌ SL / Negativo";

            if(InpEnableLogs)
               PrintFormat("Trade fechado | %s | PnL: $%.2f | Ticket: %d",
                           reason, profit, trans.deal);
         }
      }
   }
}

//+------------------------------------------------------------------+
//  FIM DO EA
//+------------------------------------------------------------------+
