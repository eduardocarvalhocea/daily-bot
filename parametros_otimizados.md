# Parâmetros Otimizados — ORB Bot

> Configurar no MetaTrader em: **Navegador → Expert Advisors → bot → parâmetros de entrada**

---

## UsaTec (Nasdaq 100)

> Servidor do broker: **UTC+3**
> Otimização: parâmetros default do código

### Session
| Parâmetro | Valor |
|---|---|
| `rangeStartHour` | `15` |
| `rangeStartMin` | `0` |
| `rangeEndHour` | `15` |
| `rangeEndMin` | `30` |
| `eodHour` | `21` |
| `eodMin` | `0` |

### Trade
| Parâmetro | Valor |
|---|---|
| `rrMultiplier` | `5.0` |
| `minRangePoints` | `0` |
| `maxRangePoints` | `0` |
| `entryOffsetPts` | `0` |

### Breakeven & Trail
| Parâmetro | Valor |
|---|---|
| `useBreakeven` | `true` |
| `beBufTicks` | `2` |
| `useTrail` | `false` |
| `trailRangeMult` | `1.5` |

### Position Sizing
| Parâmetro | Valor |
|---|---|
| `useDynamicLot` | `true` |
| `riskPct` | `0.015` |
| `pointValue` | `20.0` |
| `fixedLot` | `1.0` |
| `minLot` | `0.01` |
| `maxLot` | `100.0` |

### General
| Parâmetro | Valor |
|---|---|
| `magicNumber` | `789012` |
| `startDate` | `2024.01.01` |

---

## Bra50 (WIN Mini — Ibovespa)

> Servidor do broker: **UTC**
> Grid search: 824 pregões · 373 trades · Sharpe 3,92

### Session
| Parâmetro | Valor | Horário BRT |
|---|---|---|
| `rangeStartHour` | `13` | 10:00 BRT (abertura B3) |
| `rangeStartMin` | `0` | |
| `rangeEndHour` | `13` | 10:30 BRT |
| `rangeEndMin` | `30` | |
| `eodHour` | `23` | 20:00 BRT |
| `eodMin` | `0` | |

### Trade
| Parâmetro | Valor |
|---|---|
| `rrMultiplier` | `3.0` |
| `minRangePoints` | `0` |
| `maxRangePoints` | `0` |
| `entryOffsetPts` | `0` |

### Breakeven & Trail
| Parâmetro | Valor |
|---|---|
| `useBreakeven` | `true` |
| `beBufTicks` | `2` |
| `useTrail` | `false` |
| `trailRangeMult` | `1.5` |

### Position Sizing
| Parâmetro | Valor |
|---|---|
| `useDynamicLot` | `true` |
| `riskPct` | `0.015` |
| `pointValue` | `❓` |
| `fixedLot` | `1.0` |
| `minLot` | `0.01` |
| `maxLot` | `100.0` |

> ⚠️ **pointValue**: verificar tick value do contrato WIN no broker antes de ligar o bot.

### General
| Parâmetro | Valor |
|---|---|
| `magicNumber` | `789013` |
| `startDate` | `2024.01.01` |

### Resultado do backtest
| Métrica | Valor |
|---|---|
| Trades | 373 |
| Net (pts) | 72.500 |
| Profit Factor | 1,68 |
| Win Rate | 45,0% |
| Max Drawdown | -6.745 pts |
| Sharpe | 3,92 |
| Max perdas consecutivas | 9 |

---

## MinDol (WDO Mini — USD/BRL)

> Servidor do broker: **UTC**
> Grid search: 91 pregões · 89 trades · Sharpe 1,09
> ⚠️ Poucos dados — resultados direcionais, não estatisticamente robustos.

### Session
| Parâmetro | Valor | Horário BRT |
|---|---|---|
| `rangeStartHour` | `14` | 11:00 BRT |
| `rangeStartMin` | `0` | |
| `rangeEndHour` | `14` | 11:30 BRT |
| `rangeEndMin` | `30` | |
| `eodHour` | `22` | 19:00 BRT |
| `eodMin` | `0` | |

### Trade
| Parâmetro | Valor |
|---|---|
| `rrMultiplier` | `2.0` |
| `minRangePoints` | `0` |
| `maxRangePoints` | `0` |
| `entryOffsetPts` | `0` |

### Breakeven & Trail
| Parâmetro | Valor |
|---|---|
| `useBreakeven` | `true` |
| `beBufTicks` | `2` |
| `useTrail` | `false` |
| `trailRangeMult` | `1.5` |

### Position Sizing
| Parâmetro | Valor |
|---|---|
| `useDynamicLot` | `true` |
| `riskPct` | `0.015` |
| `pointValue` | `❓` |
| `fixedLot` | `1.0` |
| `minLot` | `0.01` |
| `maxLot` | `100.0` |

> ⚠️ **pointValue**: verificar tick value do contrato WDO no broker antes de ligar o bot.

### General
| Parâmetro | Valor |
|---|---|
| `magicNumber` | `789014` |
| `startDate` | `2025.10.01` |

### Resultado do backtest
| Métrica | Valor |
|---|---|
| Trades | 89 |
| Net (pts) | 170,7 |
| Profit Factor | 1,31 |
| Win Rate | 47,2% |
| Max Drawdown | -96,1 pts |
| Sharpe | 1,09 |
| Max perdas consecutivas | 5 |

> Janelas da abertura B3 (13:00 UTC) não geraram trades suficientes no WDO — liquidez concentrada após 14:00 UTC.
> Com apenas 91 dias, considere Bra50 como referência se quiser testar RR=3.0 aqui também.
