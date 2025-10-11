//+------------------------------------------------------------------+
//| BUY Only EMA50 Strategy - Simple Version                         |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;
input int SL_Points = 500;
input int TP_Points = 1000;
input int EMA_Period = 50;
input ulong Magic = 123456;

// Global Variables
CTrade trade;
int hEMA;
datetime lastBarTime = 0;
bool canTrade = true;

// State tracking for post-close conditions
bool waitingForPriceBelowEMA = false;
bool waitingForPriceAboveEMA = false;

//+------------------------------------------------------------------+
//| Check if new bar formed                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[2];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 2, t) < 2) return false;
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
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   
   hEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("BUY Only EA initialized - EMA", EMA_Period, ", SL: ", SL_Points, ", TP: ", TP_Points, " points");
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
   // If position is open, do nothing
   if(PositionSelect(_Symbol))
   {
      return;
   }
   
   // Check if we need to reset after position closed
   if(!canTrade)
   {
      waitingForPriceBelowEMA = true;
      waitingForPriceAboveEMA = false;
      Print("Position closed - Waiting for price to go below EMA50");
      canTrade = true; // Set to true so we can check conditions
   }
   
   if(!IsNewBar()) return;
   
   double ema50;
   if(!GetEMA(ema50)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Post-close conditions: Wait for price to go below then above EMA50
   if(waitingForPriceBelowEMA)
   {
      if(ask < ema50)
      {
         waitingForPriceBelowEMA = false;
         waitingForPriceAboveEMA = true;
         Print("Price went below EMA50 - Now waiting for price to go back above EMA50");
      }
      return; // Don't trade yet
   }
   
   if(waitingForPriceAboveEMA)
   {
      if(ask > ema50)
      {
         waitingForPriceAboveEMA = false;
         Print("Price back above EMA50 - Ready to trade again");
      }
      else
      {
         return; // Still waiting for price above EMA50
      }
   }
   
   // Normal trading logic: BUY when price above EMA50
   if(ask > ema50)
   {
      Print("BUY Signal: Price above EMA50");
      
      double sl = ask - SL_Points * point;
      double tp = ask + TP_Points * point;
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "Price above EMA50"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl, ", TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
}

