#include <Trade\Trade.mqh>

input int nPeriod = 45;
input double lotSize = 1.0;
input datetime startDate = D'2024.01.01 00:00';

CTrade trade;

datetime lastDay = 0;

#define MAX_CACHE 5000
datetime cached_dates[MAX_CACHE];
double cached_devs[MAX_CACHE];
double cached_opens[MAX_CACHE];
int cache_count = 0;

double RoundToNearestHalf(double value) {
   return MathRound(value * 2.0) / 2.0;
}

int OnInit() {
   if(MQLInfoInteger(MQL_PROGRAM_TYPE) != PROGRAM_EXPERT) {
      Print("❌ Este código deve ser executado como Expert Advisor, não como indicador!");
      return INIT_FAILED;
   }
   
   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
      Print("❌ Trading automático não está habilitado!");
      return INIT_FAILED;
   }
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
      Print("❌ Trading não está habilitado no terminal!");
      return INIT_FAILED;
   }
   
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) {
      Print("❌ Trading não está habilitado na conta!");
      return INIT_FAILED;
   }
   
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) {
      Print("❌ Trading de Expert Advisors não está habilitado!");
      return INIT_FAILED;
   }
   
   Print("✅ Configurações de trading verificadas com sucesso!");
   Print("💰 Saldo da conta: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("📊 Margem livre: ", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
   
   if(MQLInfoInteger(MQL_TESTER)) {
      Print("🧪 Executando em modo BACKTEST");
   } else {
      Print("🌐 Executando em tempo REAL");
   }
   
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   Print("📅 Dia atual: ", TimeToString(currentDay));
   
   Sleep(2000);
   ProcessNewDay(currentDay);
   
   return INIT_SUCCEEDED;
}

bool GetDailyStats(datetime day, double &dev, double &open) {
   for (int i = 0; i < cache_count; i++) {
      if (cached_dates[i] == day) {
         dev = cached_devs[i];
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

   dev = MathSqrt(var / nPeriod);
   open = iOpen(_Symbol, PERIOD_D1, shift);

   if (cache_count < MAX_CACHE) {
      cached_dates[cache_count] = day;
      cached_devs[cache_count] = dev;
      cached_opens[cache_count] = open;
      cache_count++;
   }

   return true;
}

void PlacePendingOrder(int orderType, double volume, double price, string comment) {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
      Print("❌ Trading não está habilitado - pulando ordem ", comment);
      return;
   }
   
   double margin = 0;
   if(!OrderCalcMargin((ENUM_ORDER_TYPE)orderType, _Symbol, volume, price, margin)) {
      Print("❌ Erro ao calcular margem para ordem ", comment);
      return;
   }
   
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin) {
      Print("❌ Margem insuficiente para ordem ", comment, ". Necessário: ", DoubleToString(margin, 2), 
            ", Disponível: ", DoubleToString(freeMargin, 2));
      return;
   }
   
   double sl = 0, tp = 0;

   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = ask - bid;

   if (orderType == ORDER_TYPE_BUY_LIMIT) {
      if (price >= bid - stopLevel)
         price = bid - stopLevel - spread - 5 * _Point;
   }
   else if (orderType == ORDER_TYPE_SELL_LIMIT) {
      if (price <= ask + stopLevel)
         price = ask + stopLevel + spread + 5 * _Point;
   }

   Print("📋 Tentando ordem ", comment, ": tipo=", orderType, ", preço=", DoubleToString(price, _Digits), 
         ", bid=", DoubleToString(bid, _Digits), ", ask=", DoubleToString(ask, _Digits),
         ", margem=", DoubleToString(margin, 2));

   bool success = false;
   int retryCount = 0;
   const int maxRetries = 3;
   
   while (!success && retryCount < maxRetries) {
      if (orderType == ORDER_TYPE_BUY_LIMIT)
         success = trade.BuyLimit(volume, price, _Symbol, sl, tp, ORDER_TIME_GTC);
      else if (orderType == ORDER_TYPE_SELL_LIMIT)
         success = trade.SellLimit(volume, price, _Symbol, sl, tp, ORDER_TIME_GTC);
      
      if (!success) {
         int error = GetLastError();
         Print("❌ Tentativa ", retryCount + 1, " falhou para ordem ", comment, ". Código: ", error);
         
         if (error == 130 || error == 131 || error == 138) {
            if (orderType == ORDER_TYPE_BUY_LIMIT)
               price -= 10 * _Point;
            else
               price += 10 * _Point;
         }
         
         retryCount++;
         Sleep(100);
      }
   }
   
   if (success) {
      Print("✅ Ordem ", comment, " colocada com sucesso! Ticket: ", trade.ResultOrder());
   } else {
      Print("❌ Falha definitiva ao colocar ordem ", comment, " após ", maxRetries, " tentativas");
   }
}

void CancelAllOrders() {
   Print("🗑️ Verificando ordens para cancelamento - Total: ", OrdersTotal());
   
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if (OrderSelect(ticket)) {
         long magic = OrderGetInteger(ORDER_MAGIC);
         
         Print("   Ordem ", i, ": Ticket=", ticket, ", Magic=", magic);
         
         // Cancelar apenas ordens com magic 123456
         if (magic == 123456) {
            Print("   🎯 Cancelando ordem com magic 123456");
            if (trade.OrderDelete(ticket)) {
               Print("🗑️ Ordem pendente cancelada com sucesso");
            } else {
               Print("❌ Erro ao cancelar ordem - Erro: ", GetLastError());
            }
         } else {
            Print("   ⏭️ Pulando ordem (magic diferente): Magic=", magic);
         }
      }
   }
}

void CloseAllPositions() {
   Print("🕐 Fechando todas as posições - horário limite atingido (22:30)");
   
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            
            if (magic == 123456) {
               ulong ticket = PositionGetTicket(i);
               ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               
               Print("🗑️ Fechando posição: ", (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"), " - Ticket: ", ticket);
               
               if (trade.PositionClose(ticket)) {
                  Print("✅ Posição fechada com sucesso");
               } else {
                  Print("❌ Erro ao fechar posição: ", GetLastError());
               }
            }
         }
      }
   }
   
   // Cancelar todas as ordens pendentes também
   CancelAllOrders();
}

bool IsTimeToCloseOperations() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Verificar se é depois das 22:30
   if (dt.hour > 22 || (dt.hour == 22 && dt.min >= 30)) {
      return true;
   }
   
   return false;
}

void OnTick() {
   static datetime lastProcessedDay = 0;
   static int lastOrdersCount = 0;
   static int lastPositionsCount = 0;
   static bool dailyCloseExecuted = false;
   
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   
   // Verificar se é hora de fechar operações (22:30)
   if (IsTimeToCloseOperations() && !dailyCloseExecuted) {
      Print("🕐 Horário limite atingido (22:30) - fechando todas as operações");
      CloseAllPositions();
      dailyCloseExecuted = true;
      return; // Não executar mais nada neste tick
   }
   
   // Resetar flag de fechamento diário quando passar para o próximo dia
   if (currentDay != lastProcessedDay) {
      Print("🔄 Novo dia detectado: ", TimeToString(currentDay));
      lastProcessedDay = currentDay;
      dailyCloseExecuted = false; // Resetar flag para novo dia
      Sleep(1000);
      ProcessNewDay(currentDay);
   }
   
   // Se já executou o fechamento diário, não fazer mais nada
   if (dailyCloseExecuted) {
      return;
   }
   
   // Verificar mudanças nas ordens e posições
   int currentOrdersCount = OrdersTotal();
   int currentPositionsCount = PositionsTotal();
   
   // Se o número de ordens diminuiu ou posições aumentou, pode ter havido execução
   if (currentOrdersCount < lastOrdersCount || currentPositionsCount > lastPositionsCount) {
      Print("🔄 Mudança detectada - Ordens: ", lastOrdersCount, "->", currentOrdersCount, 
            " | Posições: ", lastPositionsCount, "->", currentPositionsCount);
      
      // Aguardar um pouco para garantir que a execução foi processada
      Sleep(200);
      
      Print("🎯 Chamando CheckExecutionAndPlaceTP após mudança detectada");
      // Verificar execução e colocar TP
      CheckExecutionAndPlaceTP();
      
      // Forçar verificação adicional após um delay
      Sleep(500);
      Print("🔄 Verificação adicional após delay");
      CheckExecutionAndPlaceTP();
   }
   
   // Atualizar contadores
   lastOrdersCount = currentOrdersCount;
   lastPositionsCount = currentPositionsCount;
   
   // Verificações regulares (a cada tick)
   static datetime lastRegularCheck = 0;
   if (TimeCurrent() - lastRegularCheck > 1) { // Verificar a cada segundo
      CheckExecutionAndPlaceTP();
      PreventMultiplePositions();
      lastRegularCheck = TimeCurrent();
   }
}

void CheckExecutionAndPlaceTP() {
   static bool tpPlaced = false;
   static datetime lastCheck = 0;
   
   Print("🔍 CheckExecutionAndPlaceTP chamada - tpPlaced=", tpPlaced);
   
   // Verificar se há posições abertas
   bool hasBuyPosition = false;
   bool hasSellPosition = false;
   double buyVolume = 0;
   double sellVolume = 0;
   ulong buyTicket = 0;
   ulong sellTicket = 0;
   
   Print("🔍 Verificando posições - Total: ", PositionsTotal());
   
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            double vol = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            ulong ticket = PositionGetTicket(i);
            
            Print("   Posição ", i, ": Tipo=", (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"), 
                  ", Volume=", vol, ", Magic=", magic, ", Ticket=", ticket);
            
            // Verificação por magic number (123456 é o magic do bot)
            if (magic == 123456) {
               if (posType == POSITION_TYPE_BUY) {
                  hasBuyPosition = true;
                  buyVolume = vol;
                  buyTicket = ticket;
                  Print("   ✅ Detectada posição BUY por magic number");
               }
               else if (posType == POSITION_TYPE_SELL) {
                  hasSellPosition = true;
                  sellVolume = vol;
                  sellTicket = ticket;
                  Print("   ✅ Detectada posição SELL por magic number");
               }
            }
            else {
               Print("   ❌ Magic number não reconhecido: ", magic);
            }
         }
      }
   }
   
   Print("🎯 Status: hasBuyPosition=", hasBuyPosition, ", hasSellPosition=", hasSellPosition, ", tpPlaced=", tpPlaced);
   
   // Se tem posições e ainda não colocou TP
   if ((hasBuyPosition || hasSellPosition) && !tpPlaced) {
      Print("🎯 Posição detectada - Cancelando ordens pendentes e colocando TP");
      Print("   BUY: ", hasBuyPosition ? "SIM" : "NÃO", " | SELL: ", hasSellPosition ? "SIM" : "NÃO");
      
      // Cancelar todas as ordens DEV1 pendentes
      CancelAllOrders();
      Sleep(500);
      
      // Colocar take profit para cada posição modificando a posição existente
      if (hasBuyPosition) {
         double open_price = 0;
         if (cache_count > 0) {
            open_price = RoundToNearestHalf(cached_opens[cache_count - 1]);
         } else {
            open_price = RoundToNearestHalf(iOpen(_Symbol, PERIOD_D1, 0));
         }
         
         Print("🎯 Colocando TP para posição BUY em: ", DoubleToString(open_price, _Digits));
         // Modificar a posição existente para adicionar take profit
         if (trade.PositionModify(buyTicket, 0, open_price)) {
            Print("✅ Take profit para BUY colocado com sucesso!");
         } else {
            Print("❌ Erro ao colocar TP para BUY: ", GetLastError());
         }
      }
      
      if (hasSellPosition) {
         double open_price = 0;
         if (cache_count > 0) {
            open_price = RoundToNearestHalf(cached_opens[cache_count - 1]);
         } else {
            open_price = RoundToNearestHalf(iOpen(_Symbol, PERIOD_D1, 0));
         }
         
         Print("🎯 Colocando TP para posição SELL em: ", DoubleToString(open_price, _Digits));
         // Modificar a posição existente para adicionar take profit
         if (trade.PositionModify(sellTicket, 0, open_price)) {
            Print("✅ Take profit para SELL colocado com sucesso!");
         } else {
            Print("❌ Erro ao colocar TP para SELL: ", GetLastError());
         }
      }
      
      tpPlaced = true;
      lastCheck = TimeCurrent();
      Print("✅ tpPlaced definido como TRUE");
   } else {
      if (hasBuyPosition || hasSellPosition) {
         Print("⚠️ Posições detectadas mas tpPlaced já é TRUE - não colocando TP novamente");
      } else {
         Print("ℹ️ Nenhuma posição detectada");
      }
   }
   
   // Resetar flag quando não há posições
   if (!hasBuyPosition && !hasSellPosition) {
      if (tpPlaced) {
         Print("🔄 Resetando tpPlaced para FALSE (não há posições)");
      }
      tpPlaced = false;
   }
   
   // Verificar se há ordens pendentes quando não deveria ter
   if (hasBuyPosition || hasSellPosition) {
      int pendingOrders = 0;
      for (int i = OrdersTotal() - 1; i >= 0; i--) {
         ulong ticket = OrderGetTicket(i);
         if (OrderSelect(ticket)) {
            long magic = OrderGetInteger(ORDER_MAGIC);
            if (magic == 123456) {
               pendingOrders++;
            }
         }
      }
      
      if (pendingOrders > 0) {
         Print("⚠️ Detectadas ", pendingOrders, " ordens pendentes quando deveria ter posição - cancelando");
         CancelAllOrders();
         Sleep(500);
      }
   }
}

void ProcessNewDay(datetime day) {
   Print("📅 Processando novo dia: ", TimeToString(day));
   
   // Verificar se já tem posições abertas
   bool hasPositions = false;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            if (magic == 123456) {
               hasPositions = true;
               break;
            }
         }
      }
   }
   
   // Se tem posições, não colocar novas ordens
   if (hasPositions) {
      Print("⚠️ Posições já existem - não colocando novas ordens");
      return;
   }
   
   // Cancelar TODAS as ordens antes de colocar novas
   CancelAllOrders();
   Sleep(500); // Aguardar cancelamento
   
   double dev, o;
   if (GetDailyStats(day, dev, o)) {
      Print("📊 Estatísticas do dia: Open=", DoubleToString(o, _Digits), ", Dev=", DoubleToString(dev, _Digits));
      
      double openD = RoundToNearestHalf(o);
      double dev_plus_1 = RoundToNearestHalf(o + dev);
      double dev_minus_1 = RoundToNearestHalf(o - dev);
      double dev_plus_2 = RoundToNearestHalf(o + 2 * dev);
      double dev_minus_2 = RoundToNearestHalf(o - 2 * dev);
      double dev_plus_3 = RoundToNearestHalf(o + 3 * dev);
      double dev_minus_3 = RoundToNearestHalf(o - 3 * dev);
      double dev_plus_4 = RoundToNearestHalf(o + 4 * dev);
      double dev_minus_4 = RoundToNearestHalf(o - 4 * dev);
      
      Print("📈 Faixas calculadas:");
      Print("   OpenD: ", DoubleToString(openD, _Digits));
      Print("   Dev+1: ", DoubleToString(dev_plus_1, _Digits), " | Dev-1: ", DoubleToString(dev_minus_1, _Digits));
      Print("   Dev+2: ", DoubleToString(dev_plus_2, _Digits), " | Dev-2: ", DoubleToString(dev_minus_2, _Digits));
      Print("   Dev+3: ", DoubleToString(dev_plus_3, _Digits), " | Dev-3: ", DoubleToString(dev_minus_3, _Digits));
      Print("   Dev+4: ", DoubleToString(dev_plus_4, _Digits), " | Dev-4: ", DoubleToString(dev_minus_4, _Digits));
      
      PlacePendingOrder(ORDER_TYPE_BUY_LIMIT, lotSize, dev_minus_1, "BUY_DEV1");
      PlacePendingOrder(ORDER_TYPE_SELL_LIMIT, lotSize, dev_plus_1, "SELL_DEV1");
   } else {
      Print("❌ Erro ao obter estatísticas do dia: ", TimeToString(day));
   }
}

void PreventMultiplePositions() {
   int buyCount = 0;
   int sellCount = 0;
   
   // Contar posições existentes
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if (magic == 123456) {
               if (posType == POSITION_TYPE_BUY) {
                  buyCount++;
               }
               else if (posType == POSITION_TYPE_SELL) {
                  sellCount++;
               }
            }
         }
      }
   }
   
   // Se tem múltiplas posições do mesmo tipo, fechar as extras
   if (buyCount > 1) {
      Print("⚠️ Detectadas ", buyCount, " posições BUY - fechando extras");
      CloseExtraPositions(POSITION_TYPE_BUY, buyCount - 1);
   }
   
   if (sellCount > 1) {
      Print("⚠️ Detectadas ", sellCount, " posições SELL - fechando extras");
      CloseExtraPositions(POSITION_TYPE_SELL, sellCount - 1);
   }
}

void CloseExtraPositions(ENUM_POSITION_TYPE positionType, int countToClose) {
   int closed = 0;
   
   for (int i = PositionsTotal() - 1; i >= 0 && closed < countToClose; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if (magic == 123456 && posType == positionType) {
               ulong ticket = PositionGetTicket(i);
               if (trade.PositionClose(ticket)) {
                  Print("🗑️ Posição extra fechada: ", (positionType == POSITION_TYPE_BUY ? "BUY" : "SELL"));
                  closed++;
               }
            }
         }
      }
   }
}

void OnDeinit(const int reason) {
   Print("🛑 Bot sendo finalizado - Razão: ", reason);
   
   // Verificar se há posições abertas e colocar TP se necessário
   bool hasPositions = false;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionSelectByTicket(PositionGetTicket(i))) {
            long magic = PositionGetInteger(POSITION_MAGIC);
            if (magic == 123456) {
               hasPositions = true;
               break;
            }
         }
      }
   }
   
   if (hasPositions) {
      Print("⚠️ Posições abertas detectadas no OnDeinit - colocando TP");
      CheckExecutionAndPlaceTP();
   }
   
   Print("✅ Bot finalizado com sucesso");
}

