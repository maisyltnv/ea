//+------------------------------------------------------------------+
//| H4 EMA26 Strategy - BUY and SELL                                 |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;
input int EMA_Period = 26;
input int MinBarMovement = 200;    // Minimum points the H4 bar must move
input int SL_Points = 500;         // SL distance from bar open
input int TP_Points = 1500;        // TP in points
input ulong Magic = 123456;

// Global Variables
CTrade trade;
int hEMA;
datetime lastBarTime = 0;
bool canTrade = true;

//+------------------------------------------------------------------+
//| Check if new H4 bar formed                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[2];
   if(CopyTime(_Symbol, PERIOD_H4, 0, 2, t) < 2) return false;
   if(t[0] != lastBarTime) 
   { 
      lastBarTime = t[0]; 
      return true; 
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get EMA value                                                    |
//+------------------------------------------------------------------+
bool GetEMA(double &ema_value)
{
   if(hEMA == INVALID_HANDLE) return false;
   double ema[1];
   if(CopyBuffer(hEMA, 0, 1, 1, ema) != 1) return false;
   ema_value = ema[0];
   return true;
}

//+------------------------------------------------------------------+
//| Get H4 bar data                                                  |
//+------------------------------------------------------------------+
bool GetH4BarData(double &bar_open, double &bar_high, double &bar_low, double &bar_close)
{
   double open[1], high[1], low[1], close[1];
   
   if(CopyOpen(_Symbol, PERIOD_H4, 0, 1, open) != 1) return false;
   if(CopyHigh(_Symbol, PERIOD_H4, 0, 1, high) != 1) return false;
   if(CopyLow(_Symbol, PERIOD_H4, 0, 1, low) != 1) return false;
   if(CopyClose(_Symbol, PERIOD_H4, 0, 1, close) != 1) return false;
   
   bar_open = open[0];
   bar_high = high[0];
   bar_low = low[0];
   bar_close = close[0];
   
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   
   hEMA = iMA(_Symbol, PERIOD_H4, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_H4, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("H4 Strategy EA initialized - EMA", EMA_Period, ", MinMove: ", MinBarMovement, ", SL: ", SL_Points, ", TP: ", TP_Points);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only allow one position at a time
   if(PositionSelect(_Symbol))
   {
      return;
   }
   
   // Reset canTrade when no position
   if(!canTrade)
   {
      canTrade = true;
      Print("Position closed - Ready to trade again");
   }
   
   if(!IsNewBar()) return;
   if(!canTrade) return;
   
   // Get EMA value
   double ema26;
   if(!GetEMA(ema26)) return;
   
   // Get H4 bar data
   double bar_open, bar_high, bar_low, bar_close;
   if(!GetH4BarData(bar_open, bar_high, bar_low, bar_close)) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Calculate current bar movement
   double bullishMove = (bar_close - bar_open) / point;
   double bearishMove = (bar_open - bar_close) / point;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // BUY Conditions
   bool buyCondition1 = (ask > ema26);  // Price above EMA26
   bool buyCondition2 = (bar_close > bar_open) || (bullishMove >= MinBarMovement);  // Green bar OR moved up 200 points
   
   if(buyCondition1 && buyCondition2)
   {
      Print("BUY Signal - Price: ", ask, ", EMA26: ", ema26, ", Bar movement: ", (int)bullishMove, " points");
      
      // SL: 500 points below bar open
      double sl = bar_open - (SL_Points * point);
      // TP: 1500 points above entry
      double tp = ask + (TP_Points * point);
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "H4 BUY"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl, " (", (int)((ask-sl)/point), " pts from entry), TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
      return;
   }
   
   // SELL Conditions
   bool sellCondition1 = (bid < ema26);  // Price below EMA26
   bool sellCondition2 = (bar_close < bar_open) || (bearishMove >= MinBarMovement);  // Red bar OR moved down 200 points
   
   if(sellCondition1 && sellCondition2)
   {
      Print("SELL Signal - Price: ", bid, ", EMA26: ", ema26, ", Bar movement: ", (int)bearishMove, " points");
      
      // SL: 500 points above bar open
      double sl = bar_open + (SL_Points * point);
      // TP: 1500 points below entry
      double tp = bid - (TP_Points * point);
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Sell(Lots, _Symbol, bid, sl, tp, "H4 SELL"))
      {
         Print("SELL order opened - Entry: ", bid, ", SL: ", sl, " (", (int)((sl-bid)/point), " pts from entry), TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("SELL order failed - Error: ", trade.ResultRetcode());
      }
      return;
   }
}

