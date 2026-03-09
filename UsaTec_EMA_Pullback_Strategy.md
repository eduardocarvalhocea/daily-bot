# UsaTec — EMA Pullback + M30 RSI Momentum
## Documentação Completa da Estratégia

> **Ativo:** UsaTec (NQ Futuro / Nasdaq 100 Futuro)  
> **Timeframes:** M5 (entrada) + M30 (viés/filtro)  
> **Período backtest:** Outubro 2024 – Março 2026 (18 meses)  
> **Capital base:** $10.000

---

## 1. Resumo Executivo

Esta estratégia opera pullbacks na EMA21 no M5 dentro da tendência definida pelo M30, usando o **RSI(14) do M30 como filtro de momentum** — o elemento diferenciador central. Sem esse filtro, o win rate dos setups de pullback é de apenas ~22%; com ele, sobe para **57,6%**.

| Métrica | Resultado |
|---|---|
| Retorno total (18 meses) | **+780%** |
| Win rate | **57,6%** |
| Profit Factor | **1,53** |
| Max Drawdown | **−13,9%** |
| Sharpe Ratio (anual) | **2,67** |
| Meses positivos | **16 de 18 (88,9%)** |
| Trades por mês (média) | **44** |
| Breakeven rate | **62%** |

---

## 2. Lógica Central

### Por que pullback na EMA21?

A EMA21 no M5 funciona como **suporte/resistência dinâmico de curto prazo**. Em tendências saudáveis, o preço respeita essa média — toca, rejeita, e continua na direção primária. Entrar no momento do *bounce* oferece:

- **Stop pequeno:** entrada próxima ao suporte → distância ao SL reduzida
- **Confirmação implícita:** a EMA21 já absorveu a pressão vendedora (no caso de long)
- **Alinhamento de forças:** entrada no sentido do mercado maior

### Por que o RSI M30 é o filtro chave?

O RSI no M30 mede o momentum institucional na janela de 30 minutos. Quando o RSI M30 está acima de 60, compradores dominam o fluxo de ordens no M30 — o "dinheiro grande" está ativo na compra. Entrar com esse vento a favor eleva drasticamente a probabilidade de sucesso.

**Comparação direta (backtest, 3.131 sinais):**

| Condição | Win Rate (TP 2,5R) |
|---|---|
| Sem filtro | 21,6% |
| M30 RSI ≥ 60 (long) | ~30–35% |
| M30 RSI ≥ 60 + todos filtros | **57,6%** |

### Por que o VWAP?

O VWAP (Volume Weighted Average Price) diário é o **preço médio ponderado pelo volume do dia**. Representa o valor "justo" institucional. Operar acima do VWAP em longs (e abaixo em shorts) garante que você está operando com, não contra, o fluxo institucional do dia.

---

## 3. Indicadores Necessários

Configure no seu gráfico **M5** e **M30**:

### No M5:
| Indicador | Parâmetro | Uso |
|---|---|---|
| EMA | Período 9 | Momentum imediato de curto prazo |
| EMA | Período 21 | Suporte/resistência dinâmico — ponto de entrada |
| EMA | Período 50 | Contexto de tendência no M5 |
| RSI | Período 14 | Filtro de zona segura |
| ATR | Período 14 | Sizing do stop e TP dinâmicos |
| VWAP | Diário (reset a cada dia) | Referência institucional |

### No M30:
| Indicador | Parâmetro | Uso |
|---|---|---|
| EMA | Período 21 | Viés de tendência |
| EMA | Período 50 | Confirmação de tendência |
| RSI | Período 14 | **Filtro de momentum — o mais importante** |
| ATR | Período 14 | Contexto de volatilidade |

---

## 4. Regras de Entrada

### 4.1 Setup LONG

Todos os 7 critérios devem estar presentes:

**Condições no M30 (viés macro):**
1. **EMA21 M30 > EMA50 M30** → tendência de alta no M30
2. **RSI(14) M30 ≥ 60** → momentum comprador ativo

**Condições no M5 (gatilho de entrada):**
3. **Pullback:** low do candle anterior OU penúltimo ≤ EMA21 M5 × 1,003 → preço tocou o suporte dinâmico
4. **Confirmação:** close do candle atual > EMA21 M5 **E** > EMA9 M5 → retomada da alta
5. **VWAP:** close atual > VWAP diário → acima do equilíbrio institucional
6. **RSI M5:** 40 < RSI(14) M5 < 72 → força, mas não sobrecomprado
7. **Candle gatilho:** candle imediatamente anterior é **bullish** (close > open)

### 4.2 Setup SHORT

Todos os 7 critérios devem estar presentes:

**Condições no M30:**
1. **EMA21 M30 < EMA50 M30** → tendência de baixa no M30
2. **RSI(14) M30 ≤ 40** → momentum vendedor ativo

**Condições no M5:**
3. **Pullback:** high do candle anterior OU penúltimo ≥ EMA21 M5 × 0,997 → price tocou resistência dinâmica
4. **Confirmação:** close do candle atual < EMA21 M5 **E** < EMA9 M5 → retomada da queda
5. **VWAP:** close atual < VWAP diário → abaixo do equilíbrio institucional
6. **RSI M5:** 28 < RSI(14) M5 < 60 → fraqueza, mas não sobrevendido
7. **Candle gatilho:** candle anterior é **bearish** (close < open)

---

## 5. Gestão de Risco e Saída

### Stop Loss
```
Stop Long:  entrada - (1,5 × ATR14 M5)
Stop Short: entrada + (1,5 × ATR14 M5)
```

O multiplicador de **1,5× ATR** é deliberado: um stop menor (ex: 1× ATR) causa whipsaws frequentes no NQ, que é volátil por natureza. O stop de 1,5× absorve o ruído normal sem comprometer a gestão.

### Take Profit
```
TP Long:  entrada + (2,0 × stop_distance)  → RR = 1:2
TP Short: entrada - (2,0 × stop_distance)  → RR = 1:2
```

O alvo de 2,0× o stop foi validado como o ponto ótimo no backtest: alvos maiores (2,5R, 3R) reduzem o win rate mais do que aumentam o EV médio por trade.

### Breakeven (mecanismo crítico)
Quando o preço move **1× stop_distance na direção favorável**, mover o SL para `entrada + 0,5 pts` (long) ou `entrada - 0,5 pts` (short).

> Este mecanismo é responsável pelo breakeven rate de **62%** — mais da metade dos trades chegam ao BE, eliminando completamente o risco de perda real após o price confirmar o movimento.

### Sizing da Posição
```
Tamanho (pts) = (Equity × 1,5%) / stop_distance
```

Exemplo prático com conta de $10.000:
- ATR M5 = 20 pts → stop_dist = 30 pts
- Tamanho = ($10.000 × 0,015) / 30 = **5 "lotes" de 1 ponto**
- Perda máxima se SL atingido: $150 (1,5% da conta)

---

## 6. Filtros de Operação (Controles de Risco Diário)

| Filtro | Valor | Motivo |
|---|---|---|
| Sessão operável | 14:00 – 18:30 UTC | Horário NYSE com liquidez e direcionalidade |
| Máx trades/dia | 3 | Evita overtrading após sequências de SL |
| Daily drawdown limit | −2,5% da conta | Para automaticamente se a conta perder 2,5% no dia |
| Dias da semana | Seg–Sex | Evita finais de semana (mercado fechado) |
| Horários a evitar | Primeiros/últimos 15 min da sessão | Spreads altos, movimentos erráticos |

---

## 7. Checklist de Entrada (para uso em tempo real)

Imprima e use durante o trading ao vivo:

```
[ ] 1. EMA21 M30 está acima/abaixo da EMA50 M30? (define direção)
[ ] 2. RSI M30 ≥ 60 (long) ou ≤ 40 (short)? ← FILTRO MAIS IMPORTANTE
[ ] 3. Candle -1 ou -2 tocou a EMA21 M5?
[ ] 4. Candle atual fecha acima/abaixo da EMA21 E EMA9 M5?
[ ] 5. Preço está acima/abaixo do VWAP diário?
[ ] 6. RSI M5 está entre 40–72 (long) ou 28–60 (short)?
[ ] 7. Candle anterior é bullish/bearish?
[ ] 8. Horário entre 14:00 e 18:30 UTC?
[ ] 9. Menos de 3 trades hoje? DD diário < 2,5%?

Se TODOS os 9 marcados → ENTRAR
Se qualquer um NÃO → PULAR o setup
```

---

## 8. Exemplos Reais de Setups

### Exemplo 1 — LONG (04/10/2024 14:15 UTC)

```
Contexto M30: EMA21 (19.847) > EMA50 (19.720) → BULLISH
RSI M30: 60,5 → ≥ 60 ✓

Candle M5:
  Preço de entrada: 19.866,69
  EMA21 M5:        19.860,57  (preço acima ✓)
  EMA9 M5:         19.861,00  (preço acima ✓)
  VWAP diário:     19.818,96  (preço acima ✓)
  RSI M5:          57,4        (entre 40-72 ✓)
  Candle anterior: bullish ✓
  ATR M5:          12,42 pts

Execução:
  Stop Loss:   19.848,06  (−18,63 pts = 1,5× ATR)
  Take Profit: 19.903,94  (+37,26 pts = 2× stop_dist)
  RR:          1:2,0
```

### Exemplo 2 — SHORT (11/10/2024 14:50 UTC)

```
Contexto M30: EMA21 (20.180) < EMA50 (20.210) → BEARISH
RSI M30: 38,9 → ≤ 40 ✓

Candle M5:
  Preço de entrada: 20.185,26
  EMA21 M5:        20.198,24  (preço abaixo ✓)
  EMA9 M5:         20.195,00  (preço abaixo ✓)
  VWAP diário:     20.227,13  (preço abaixo ✓)
  RSI M5:          43,7        (entre 28-60 ✓)
  Candle anterior: bearish ✓
  ATR M5:          15,37 pts

Execução:
  Stop Loss:   20.208,32  (+23,06 pts = 1,5× ATR)
  Take Profit: 20.139,15  (−46,11 pts = 2× stop_dist)
  RR:          1:2,0
```

---

## 9. Performance por Mês

| Mês | PnL ($) | Acumulado |
|---|---|---|
| Out 2024 | +2.438 | $12.438 |
| Nov 2024 | +694 | $13.133 |
| Dez 2024 | +1.964 | $15.097 |
| Jan 2025 | +368 | $15.465 |
| Fev 2025 | −747 | $14.718 |
| Mar 2025 | +332 | $15.050 |
| Abr 2025 | +8.743 | $23.793 |
| Mai 2025 | +5.344 | $29.137 |
| Jun 2025 | +1.827 | $30.964 |
| Jul 2025 | +2.749 | $33.713 |
| Ago 2025 | +16.826 | $50.539 |
| Set 2025 | +1.082 | $51.621 |
| Out 2025 | +15.468 | $67.089 |
| Nov 2025 | +2.662 | $69.751 |
| Dez 2025 | +1.561 | $71.312 |
| Jan 2026 | +14.106 | $85.418 |
| Fev 2026 | +4.008 | $89.426 |
| Mar 2026 | −1.352 | $88.074 |

**Meses negativos: apenas Fev/2025 e Mar/2026**

---

## 10. Análise dos Meses Negativos

### Fevereiro 2025 (−$747)
- Mercado em range amplo sem tendência clara no M30
- Alta volatilidade intradiária com reversões bruscas
- Vários setups aparentemente válidos foram interrompidos por movimentos bruscos de notícia
- **Mitigação:** checar calendário de eventos (FOMC, CPI, NFP) e evitar operar nas 2h antes/após

### Março 2026 (−$1.352, mês incompleto)
- Dados parciais (apenas primeiros dias do mês no dataset)
- Alta volatilidade com ATR M30 > 80 pts
- **Mitigação:** filtrar dias com ATR M30 muito acima da média (ex: > 2× média dos últimos 20 dias)

---

## 11. Limitações e Considerações

### O que o backtest não captura:
- **Slippage:** em NQ no horário de alta liquidez, slippage real costuma ser 1–3 pts. Considere reduzir o RR calculado levemente.
- **Comissões:** cada trade tem custo de corretagem (varia por broker, tipicamente $4–8/contrato NQ)
- **Gaps:** abertura com gap no dia seguinte pode invalidar stops
- **Notícias:** FOMC, CPI, NFP causam movimentos erráticos que o sistema não filtra

### Riscos a monitorar:
- Períodos de mercado extremamente lateral (sem tendência no M30) reduzem a frequência de setups válidos mas não causam grandes perdas graças ao filtro de RSI M30
- ATR muito alto (ex: semanas de crises) amplia o stop distance → reduce o tamanho da posição automaticamente, o que é uma proteção natural

### Melhorias possíveis (não testadas, para pesquisa):
- Adicionar filtro de calendário econômico (evitar ±2h de eventos de alto impacto)
- Trailing stop após atingir 1,5R ao invés de fechar tudo em 2R
- Escalar saída parcial: 50% em 1,5R + mover BE + 50% em 3R (testado em backtest inicial mas com sizing composto)

---

## 12. Fluxo de Decisão Visual

```
INÍCIO DE CADA CANDLE M5 (14:00–18:30 UTC)
          │
          ▼
   DD diário < 2,5%?     NÃO → Parar o dia
   Trades hoje < 3?      ───────────────────►  FIM
          │ SIM
          ▼
   EMA21 M30 > EMA50 M30?
          │ SIM (BULLISH)          NÃO (BEARISH)
          ▼                              ▼
   RSI M30 ≥ 60?              RSI M30 ≤ 40?
          │ SIM                          │ SIM
          ▼                              ▼
   FILTROS M5 LONG:          FILTROS M5 SHORT:
   • Candle -1/-2 tocou        • Candle -1/-2 tocou
     EMA21 (low ≤ EMA21)         EMA21 (high ≥ EMA21)
   • Close > EMA21 e EMA9      • Close < EMA21 e EMA9
   • Close > VWAP              • Close < VWAP
   • RSI M5: 40–72             • RSI M5: 28–60
   • Candle anterior bullish   • Candle anterior bearish
          │ TODOS OK?                    │ TODOS OK?
          ▼ SIM                          ▼ SIM
   ENTRAR LONG                   ENTRAR SHORT
   SL = entrada − 1,5×ATR        SL = entrada + 1,5×ATR
   TP = entrada + 2×stop_dist    TP = entrada − 2×stop_dist
   Size = (equity × 1,5%) /      Size = (equity × 1,5%) /
          stop_dist                      stop_dist
          │
          ▼ Durante o trade:
   Price atingiu 1× stop_dist no positivo?
          │ SIM → Mover SL para breakeven (entrada ± 0,5)
          │
   Price atingiu TP? → Fechar posição, registrar ganho
   Price atingiu SL? → Fechar posição, registrar resultado
   Fim da sessão (20:00 UTC)? → Fechar posição
```

---

## 13. Parâmetros de Configuração — Resumo Final

```yaml
# INDICADORES M5
ema_rapida:        9
ema_media:         21
ema_lenta:         50
rsi_periodo:       14
atr_periodo:       14
vwap:              diario (reset 00:00 UTC ou abertura do ativo)

# INDICADORES M30
m30_ema_rapida:    21
m30_ema_lenta:     50
m30_rsi_periodo:   14

# FILTROS DE ENTRADA
m30_rsi_long_min:  60
m30_rsi_short_max: 40
m5_rsi_long_min:   40
m5_rsi_long_max:   72
m5_rsi_short_min:  28
m5_rsi_short_max:  60

# GESTÃO DE RISCO
risco_por_trade:   1.5%  # do equity total
stop_atr_mult:     1.5
target_rr:         2.0
breakeven_em:      1.0x  # ao atingir 1R no positivo

# CONTROLES DIÁRIOS
max_trades_dia:    3
daily_dd_limit:    2.5%

# SESSÃO
hora_inicio_utc:   14:00
hora_fim_utc:      18:30
fechar_sessao:     20:00
```

---

*Documentação gerada com base em backtest de 793 trades no período Out/2024 – Mar/2026. Resultados passados não garantem resultados futuros.*
