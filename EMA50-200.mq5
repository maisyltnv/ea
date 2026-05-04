//+------------------------------------------------------------------+
//| XAUUSD M1 EMA50/EMA200 + MACD + Stochastic EA                    |
//| Strategy: trend-following with pullback confirmation             |
//| Platform: MetaTrader 5 / MQL5                                    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA50/EMA200 + MACD + Stochastic EA for M1. Includes ATR SL/TP, risk lot, spread filter, trailing stop."

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- Inputs ----------------------------------
input string InpTradeSymbol          = "XAUUSD";          // Empty = current chart symbol
input ENUM_TIMEFRAMES InpTF          = PERIOD_M1;   // Signal timeframe
input ulong  InpMagic                = 5052001269;  // Magic number

// EMA settings
input int    InpEMA_Fast             = 50;
input int    InpEMA_Slow             = 200;

// MACD settings
input int    InpMACD_Fast            = 12;
input int    InpMACD_Slow            = 26;
input int    InpMACD_Signal          = 9;

// Stochastic settings
input int    InpStoch_K              = 9;
input int    InpStoch_D              = 3;
input int    InpStoch_Slowing        = 3;
input double InpStoch_BuyLevel       = 25.0;        // Buy only after pullback near oversold
input double InpStoch_SellLevel      = 75.0;        // Sell only after pullback near overbought

// Risk / position settings
input bool   InpUseRiskLot           = true;        // true = calculate lot by risk %
input double InpRiskPercent          = 1.0;         // Risk % per trade
input double InpFixedLot             = 0.01;        // Used when InpUseRiskLot=false
input int    InpMaxPositions         = 1;           // Max open positions for this symbol/magic
input int    InpSlippagePoints       = 30;
input int    InpMaxSpreadPoints      = 350;         // XAUUSD spread filter. Adjust by broker digits.

// ATR SL/TP settings
input int    InpATRPeriod            = 14;
input double InpSL_ATR_Mult          = 1.5;
input double InpTP_ATR_Mult          = 2.2;
input double InpMinSL_Points         = 250;         // Minimum stop loss in points
input double InpMinTP_Points         = 350;         // Minimum take profit in points

// Entry filters
input bool   InpUseEMA200Distance    = true;
input double InpMinDistanceEMA200Pts = 80;          // Avoid trading too close to EMA200
input bool   InpUseCandleConfirm     = true;        // Buy candle close bullish / sell close bearish
input bool   InpOneTradePerBar       = true;

// Trade direction
input bool   InpAllowBuy             = true;
input bool   InpAllowSell            = true;

// Time filter. Server time.
input bool   InpUseTimeFilter        = false;
input int    InpStartHour            = 7;
input int    InpEndHour              = 22;

// Break-even and trailing
input bool   InpUseBreakEven         = true;
input double InpBreakEven_ATR        = 1.0;         // Move SL to BE when profit >= ATR * this
input double InpBreakEvenPlusPoints  = 30;          // Lock small profit
input bool   InpUseTrailingStop      = true;
input double InpTrail_ATR_Mult       = 1.2;
input double InpTrailStart_ATR       = 1.4;

// Safety
input bool   InpCloseOnOppSignal     = false;       // Close position when opposite signal appears

//------------------------- Indicator handles ------------------------
int hEmaFast = INVALID_HANDLE;
int hEmaSlow = INVALID_HANDLE;
int hMacd    = INVALID_HANDLE;
int hStoch   = INVALID_HANDLE;
int hAtr     = INVALID_HANDLE;

string Sym;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[1];
   if(CopyTime(Sym, InpTF, 0, 1, t) != 1) return false;
   if(t[0] != lastBarTime)
   {
      lastBarTime = t[0];
      return true;
   }
   return false;
}

bool IsTradingTime()
{
   if(!InpUseTimeFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpStartHour == InpEndHour) return true;

   if(InpStartHour < InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);

   // Overnight session, e.g. 22 -> 5
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
}

bool SpreadOK()
{
   long spread = SymbolInfoInteger(Sym, SYMBOL_SPREAD);
   return (spread > 0 && spread <= InpMaxSpreadPoints);
}

int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == Sym &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         {
            count++;
         }
      }
   }
   return count;
}

bool HasPositionType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == Sym &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         {
            return true;
         }
      }
   }
   return false;
}

void ClosePositionsByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == Sym &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         {
            trade.PositionClose(ticket);
         }
      }
   }
}

bool GetBuffers(double &emaFast1, double &emaFast2,
                double &emaSlow1, double &emaSlow2,
                double &macdMain1, double &macdMain2,
                double &macdSignal1, double &macdSignal2,
                double &stochK1, double &stochK2,
                double &stochD1, double &stochD2,
                double &atr1,
                MqlRates &bar1, MqlRates &bar2)
{
   double emaF[3], emaS[3], macdM[3], macdSig[3], stK[3], stD[3], atr[3];
   MqlRates rates[3];

   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(macdM, true);
   ArraySetAsSeries(macdSig, true);
   ArraySetAsSeries(stK, true);
   ArraySetAsSeries(stD, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rates, true);

   if(CopyBuffer(hEmaFast, 0, 0, 3, emaF) != 3) return false;
   if(CopyBuffer(hEmaSlow, 0, 0, 3, emaS) != 3) return false;
   if(CopyBuffer(hMacd, 0, 0, 3, macdM) != 3) return false;
   if(CopyBuffer(hMacd, 1, 0, 3, macdSig) != 3) return false;
   if(CopyBuffer(hStoch, 0, 0, 3, stK) != 3) return false;
   if(CopyBuffer(hStoch, 1, 0, 3, stD) != 3) return false;
   if(CopyBuffer(hAtr, 0, 0, 3, atr) != 3) return false;
   if(CopyRates(Sym, InpTF, 0, 3, rates) != 3) return false;

   // Use closed candles: index 1 = last closed, index 2 = candle before that
   emaFast1   = emaF[1];
   emaFast2   = emaF[2];
   emaSlow1   = emaS[1];
   emaSlow2   = emaS[2];
   macdMain1  = macdM[1];
   macdMain2  = macdM[2];
   macdSignal1= macdSig[1];
   macdSignal2= macdSig[2];
   stochK1    = stK[1];
   stochK2    = stK[2];
   stochD1    = stD[1];
   stochD2    = stD[2];
   atr1       = atr[1];
   bar1       = rates[1];
   bar2       = rates[2];

   return true;
}

double NormalizeVolume(double lot)
{
   double minLot  = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(Sym, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(lot, maxLot));
   lot = MathFloor(lot / stepLot) * stepLot;
   return NormalizeDouble(lot, 2);
}

double CalculateLot(double slPoints)
{
   if(!InpUseRiskLot) return NormalizeVolume(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(Sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(Sym, SYMBOL_TRADE_TICK_VALUE);
   double point     = SymbolInfoDouble(Sym, SYMBOL_POINT);

   if(tickSize <= 0.0 || tickValue <= 0.0 || point <= 0.0 || slPoints <= 0.0)
      return NormalizeVolume(InpFixedLot);

   double lossPerLot = (slPoints * point / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return NormalizeVolume(InpFixedLot);

   double lot = riskMoney / lossPerLot;
   return NormalizeVolume(lot);
}

bool BuildSignal(bool &buySignal, bool &sellSignal, double &atrValue)
{
   buySignal = false;
   sellSignal = false;

   double emaFast1, emaFast2, emaSlow1, emaSlow2;
   double macdMain1, macdMain2, macdSignal1, macdSignal2;
   double stochK1, stochK2, stochD1, stochD2;
   MqlRates bar1, bar2;

   if(!GetBuffers(emaFast1, emaFast2, emaSlow1, emaSlow2,
                  macdMain1, macdMain2, macdSignal1, macdSignal2,
                  stochK1, stochK2, stochD1, stochD2,
                  atrValue, bar1, bar2))
   {
      return false;
   }

   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double close1 = bar1.close;
   bool bullishCandle = (bar1.close > bar1.open);
   bool bearishCandle = (bar1.close < bar1.open);

   // Trend filter
   bool upTrend   = (emaFast1 > emaSlow1 && close1 > emaFast1 && close1 > emaSlow1);
   bool downTrend = (emaFast1 < emaSlow1 && close1 < emaFast1 && close1 < emaSlow1);

   // Optional distance from EMA200 to avoid chop zone
   if(InpUseEMA200Distance)
   {
      double distPts = MathAbs(close1 - emaSlow1) / point;
      if(distPts < InpMinDistanceEMA200Pts)
      {
         upTrend = false;
         downTrend = false;
      }
   }

   // MACD confirmation
   bool macdBuy  = (macdMain1 > macdSignal1 && macdMain1 > 0.0 && macdMain1 > macdMain2);
   bool macdSell = (macdMain1 < macdSignal1 && macdMain1 < 0.0 && macdMain1 < macdMain2);

   // Stochastic pullback trigger
   bool stochBuyCross  = (stochK2 <= stochD2 && stochK1 > stochD1 && stochK2 <= InpStoch_BuyLevel);
   bool stochSellCross = (stochK2 >= stochD2 && stochK1 < stochD1 && stochK2 >= InpStoch_SellLevel);

   // Pullback area: previous or current closed candle touches/comes near EMA50
   double nearPts = MathMax(atrValue / point * 0.35, 80.0);
   bool buyPullback  = (bar1.low <= emaFast1 + nearPts * point || bar2.low <= emaFast2 + nearPts * point);
   bool sellPullback = (bar1.high >= emaFast1 - nearPts * point || bar2.high >= emaFast2 - nearPts * point);

   buySignal  = InpAllowBuy  && upTrend   && macdBuy  && stochBuyCross  && buyPullback;
   sellSignal = InpAllowSell && downTrend && macdSell && stochSellCross && sellPullback;

   if(InpUseCandleConfirm)
   {
      buySignal  = buySignal  && bullishCandle;
      sellSignal = sellSignal && bearishCandle;
   }

   return true;
}

void OpenBuy(double atrValue)
{
   double ask   = SymbolInfoDouble(Sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);

   double slPts = MathMax((atrValue / point) * InpSL_ATR_Mult, InpMinSL_Points);
   double tpPts = MathMax((atrValue / point) * InpTP_ATR_Mult, InpMinTP_Points);
   double lot   = CalculateLot(slPts);

   double sl = NormalizeDouble(ask - slPts * point, digits);
   double tp = NormalizeDouble(ask + tpPts * point, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.Buy(lot, Sym, ask, sl, tp, "EMA MACD Stoch BUY");
}

void OpenSell(double atrValue)
{
   double bid   = SymbolInfoDouble(Sym, SYMBOL_BID);
   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);

   double slPts = MathMax((atrValue / point) * InpSL_ATR_Mult, InpMinSL_Points);
   double tpPts = MathMax((atrValue / point) * InpTP_ATR_Mult, InpMinTP_Points);
   double lot   = CalculateLot(slPts);

   double sl = NormalizeDouble(bid + slPts * point, digits);
   double tp = NormalizeDouble(bid - tpPts * point, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.Sell(lot, Sym, bid, sl, tp, "EMA MACD Stoch SELL");
}

void ManagePositions()
{
   double atr[2];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hAtr, 0, 0, 2, atr) != 2) return;

   double atrValue = atr[1];
   double point    = SymbolInfoDouble(Sym, SYMBOL_POINT);
   int digits      = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);
   if(atrValue <= 0.0 || point <= 0.0) return;

   double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != Sym ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      {
         continue;
      }

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double profitDist = bid - openPrice;
         double newSL = sl;

         if(InpUseBreakEven && profitDist >= atrValue * InpBreakEven_ATR)
         {
            double beSL = NormalizeDouble(openPrice + InpBreakEvenPlusPoints * point, digits);
            if(sl == 0.0 || beSL > newSL) newSL = beSL;
         }

         if(InpUseTrailingStop && profitDist >= atrValue * InpTrailStart_ATR)
         {
            double trailSL = NormalizeDouble(bid - atrValue * InpTrail_ATR_Mult, digits);
            if(sl == 0.0 || trailSL > newSL) newSL = trailSL;
         }

         if(newSL > sl && newSL < bid)
            trade.PositionModify(ticket, newSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitDist = openPrice - ask;
         double newSL = sl;

         if(InpUseBreakEven && profitDist >= atrValue * InpBreakEven_ATR)
         {
            double beSL = NormalizeDouble(openPrice - InpBreakEvenPlusPoints * point, digits);
            if(sl == 0.0 || beSL < newSL) newSL = beSL;
         }

         if(InpUseTrailingStop && profitDist >= atrValue * InpTrailStart_ATR)
         {
            double trailSL = NormalizeDouble(ask + atrValue * InpTrail_ATR_Mult, digits);
            if(sl == 0.0 || trailSL < newSL) newSL = trailSL;
         }

         if((sl == 0.0 || newSL < sl) && newSL > ask)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Sym = (InpTradeSymbol == "") ? _Symbol : InpTradeSymbol;

   if(!SymbolSelect(Sym, true))
   {
      Print("Cannot select symbol: ", Sym);
      return INIT_FAILED;
   }

   hEmaFast = iMA(Sym, InpTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(Sym, InpTF, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hMacd    = iMACD(Sym, InpTF, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   hStoch   = iStochastic(Sym, InpTF, InpStoch_K, InpStoch_D, InpStoch_Slowing, MODE_SMA, STO_LOWHIGH);
   hAtr     = iATR(Sym, InpTF, InpATRPeriod);

   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hMacd == INVALID_HANDLE || hStoch == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("EA initialized on ", Sym, " TF=", EnumToString(InpTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hMacd    != INVALID_HANDLE) IndicatorRelease(hMacd);
   if(hStoch   != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   if(Sym == "") return;

   ManagePositions();

   if(InpOneTradePerBar && !IsNewBar()) return;
   if(!IsTradingTime()) return;
   if(!SpreadOK()) return;

   bool buySignal = false;
   bool sellSignal = false;
   double atrValue = 0.0;

   if(!BuildSignal(buySignal, sellSignal, atrValue)) return;

   if(InpCloseOnOppSignal)
   {
      if(buySignal)  ClosePositionsByType(POSITION_TYPE_SELL);
      if(sellSignal) ClosePositionsByType(POSITION_TYPE_BUY);
   }

   if(CountPositions() >= InpMaxPositions) return;

   if(buySignal && !HasPositionType(POSITION_TYPE_BUY))
      OpenBuy(atrValue);
   else if(sellSignal && !HasPositionType(POSITION_TYPE_SELL))
      OpenSell(atrValue);
}
//+------------------------------------------------------------------+
