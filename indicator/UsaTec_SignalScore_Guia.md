# UsaTec SignalScore M5 — Guia de Uso

## O que faz

Indicador de score composto que avalia 7 criterios simultaneos para gerar sinais de compra/venda. Opera no grafico **M5** usando filtros de tendencia do **M30**.

O score varia de **-1.0** (sell maximo) a **+1.0** (buy maximo), exibido como histograma colorido. Setas aparecem quando **todos os 7 criterios** sao confirmados ao mesmo tempo.

---

## Como instalar

1. Copie `UsaTec_SignalScore.mq5` para `MQL5/Indicators/`
2. Compile no MetaEditor (F7)
3. Arraste para um grafico **M5** do ativo desejado
4. **Dica**: abra tambem um grafico M30 do mesmo ativo para forcar o MT5 a carregar os dados M30

---

## Os 7 Criterios

| # | Criterio | Timeframe | O que avalia |
|---|----------|-----------|-------------|
| 1 | Tendencia | M30 | EMA21 > EMA50 (bull) ou EMA21 < EMA50 (bear) |
| 2 | Momentum | M30 | RSI acima de limiar bull ou abaixo de limiar bear |
| 3 | Pullback | M5 | Preco tocou/aproximou da EMA21 (tolerancia 0.3%) |
| 4 | Confirmacao | M5 | Close acima de EMA21 + EMA9 (bull) ou abaixo (bear) |
| 5 | VWAP | M5 | Close acima do VWAP diario (bull) ou abaixo (bear) |
| 6 | RSI M5 | M5 | RSI dentro da zona valida (nem sobrecomprado nem sobrevendido) |
| 7 | Candle | M5 | Candle anterior direcional (bull = close > open) |

---

## Leitura do Histograma

| Cor | Score | Significado |
|-----|-------|-------------|
| Verde forte | >= +0.60 | Forte pressao compradora |
| Verde claro | +0.20 a +0.60 | Pressao compradora moderada |
| Dourado | -0.20 a +0.20 | Neutro / sem direcao clara |
| Laranja | -0.60 a -0.20 | Pressao vendedora moderada |
| Vermelho | <= -0.60 | Forte pressao vendedora |

**Setas**: aparecem quando score >= threshold E todos os 7 criterios estao ativos. Sao sinais de alta confianca.

---

## Parametros e Otimizacao por Ativo

### US Tech / NAS100 (default)

Ativo com tendencias fortes e momentum sustentado. Os defaults foram calibrados para este ativo.

```
=== M5 Indicadores ===
EMA9              = 9
EMA21             = 21
RSI Period        = 14
ATR Period        = 14

=== M30 Filtros ===
M30 EMA21         = 21
M30 EMA50         = 50
RSI M30 Per       = 14
RSI Long  (bull)  = 60.0
RSI Short (bear)  = 40.0

=== RSI M5 Zonas ===
Long min          = 40.0
Long max          = 72.0
Short min         = 28.0
Short max         = 60.0

=== Pesos ===
W1 Tendencia M30  = 0.20
W2 RSI M30 mom.   = 0.25
W3 Pullback       = 0.15
W4 Confirmacao    = 0.15
W5 VWAP           = 0.10
W6 RSI M5         = 0.10
W7 Candle         = 0.05

=== Visual ===
Threshold         = 0.70
```

---

### Mini Dolar Futuro (WDOFUT / MINFDOL)

Ativo mais lateralizado, com reversoes frequentes e RSI que raramente atinge extremos no M30. Ajustes focam em **relaxar os filtros de momentum** e **alargar as zonas de RSI**.

```
=== M5 Indicadores ===
EMA9              = 9
EMA21             = 21
RSI Period        = 14
ATR Period        = 14

=== M30 Filtros ===
M30 EMA21         = 21
M30 EMA50         = 50
RSI M30 Per       = 14
RSI Long  (bull)  = 55.0    # (default 60) — dolar raramente sustenta RSI alto
RSI Short (bear)  = 45.0    # (default 40) — idem para RSI baixo

=== RSI M5 Zonas ===
Long min          = 38.0    # (default 40) — aceita entradas com RSI mais baixo
Long max          = 75.0    # (default 72) — permite momentum mais esticado
Short min         = 25.0    # (default 28)
Short max         = 62.0    # (default 60)

=== Pesos ===
W1 Tendencia M30  = 0.15    # (default 0.20) — tendencia M30 menos confiavel
W2 RSI M30 mom.   = 0.20    # (default 0.25) — momentum pesa menos
W3 Pullback       = 0.20    # (default 0.15) — pullback mais importante (mean-reversion)
W4 Confirmacao    = 0.15
W5 VWAP           = 0.15    # (default 0.10) — VWAP mais relevante no dolar
W6 RSI M5         = 0.10
W7 Candle         = 0.05

=== Visual ===
Threshold         = 0.60    # (default 0.70) — gera mais sinais, score pleno e raro
```

**Notas sobre MINFDOL:**
- O dolar futuro tem sessao das 9h00 as 18h00 (BRT). O VWAP reseta a meia-noite UTC, o que pode causar divergencia no inicio do pregao. Considere reduzir W5 se o VWAP parecer inconsistente.
- Tendencias no dolar sao mais curtas. Considere usar EMAs mais curtas no M30 (EMA13/EMA34) se o sinal estiver atrasado.

---

### Mini Indice Bovespa (WINFUT / MINIFUT)

Ativo com boa tendencia intraday, volatilidade elevada e influencia forte do fluxo institucional. Comportamento intermediario entre NAS100 e dolar.

```
=== M5 Indicadores ===
EMA9              = 9
EMA21             = 21
RSI Period        = 14
ATR Period        = 14

=== M30 Filtros ===
M30 EMA21         = 21
M30 EMA50         = 50
RSI M30 Per       = 14
RSI Long  (bull)  = 57.0    # (default 60) — leve relaxamento
RSI Short (bear)  = 43.0    # (default 40)

=== RSI M5 Zonas ===
Long min          = 38.0    # (default 40)
Long max          = 74.0    # (default 72)
Short min         = 26.0    # (default 28)
Short max         = 62.0    # (default 60)

=== Pesos ===
W1 Tendencia M30  = 0.20
W2 RSI M30 mom.   = 0.20    # (default 0.25) — leve reducao
W3 Pullback       = 0.15
W4 Confirmacao    = 0.15
W5 VWAP           = 0.15    # (default 0.10) — VWAP e respeitado no WIN
W6 RSI M5         = 0.10
W7 Candle         = 0.05

=== Visual ===
Threshold         = 0.65    # (default 0.70) — leve relaxamento
```

**Notas sobre Mini Indice:**
- Sessao das 9h00 as 18h10 (BRT). Mesma observacao do VWAP que o dolar.
- O WIN respeita bem o VWAP, por isso o peso W5 foi aumentado.
- Nos primeiros 15 minutos (9h00-9h15) a volatilidade e muito alta e os sinais podem ser menos confiaveis. Considere ignorar setas nesse periodo.
- Em dias de vencimento (3a quarta do mes par) a dinamica muda — os parametros podem precisar de ajuste.

---

## Dicas Gerais

1. **Sempre valide visualmente** antes de operar com parametros novos. Aplique o indicador no historico e observe se os sinais fazem sentido para o ativo.

2. **Setas sao raras por design** — exigem todos os 7 criterios. Se nenhuma seta aparece em dias, reduza o Threshold ou relaxe os filtros de RSI M30.

3. **O histograma e o sinal principal** para o dia a dia. Barras verdes consistentes = bias comprador. Barras vermelhas consistentes = bias vendedor. Transicoes de cor indicam mudanca de momentum.

4. **Otimizacao manual**: comece com os defaults sugeridos e ajuste um parametro por vez observando o impacto no historico recente (ultimas 2-4 semanas).

5. **Pesos devem somar 1.0**. Se alterar um peso, compense em outro para manter a escala do score.
