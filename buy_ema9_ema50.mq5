//+------------------------------------------------------------------+
//| BUY Only EMA50 Strategy with TP and Post-TP Conditions           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input double Lots = 0.10;
input int SL_Points = 500;
input int TP_Points = 1000;        // Take Profit in points
input int EMA_Period = 50;
input ulong Magic = 123456;
input int TrailingStart = 100;     // Not used - kept for compatibility
input int TrailingStep = 50;       // Not used - kept for compatibility
input int MinProfitToTrail = 500;  // Minimum profit in points before starting trailing
input int SLAboveEntry = 100;      // Move SL above entry price by this many points

CTrade trade;
int hEMA;
datetime lastBarTime = 0;
bool canTrade = true;

// State tracking for post-TP conditions
bool waitingForPriceBelowEMA = false;  // Waiting for price to go below EMA50
bool waitingForPriceAboveEMA = false;  // Waiting for price to go back above EMA50

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

bool CopyEMA(double &ema_value)
{
   if(hEMA == INVALID_HANDLE) return false;
   double ema[1];
   if(CopyBuffer(hEMA, 0, 1, 1, ema) != 1) return false;
   ema_value = ema[0];
   return true;
}

void UpdateTrailingStop()
{
   if(!PositionSelect(_Symbol)) return;
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double profitPoints = (bid - entry) / point;
   
   // Check if profit >= 500 points and SL is still below Entry+100
   double targetSL = NormalizeDouble(entry + (100.0 * point), digits);
   
   if(profitPoints >= MinProfitToTrail && currentSL < targetSL)
   {
      // Move SL to Entry+100 points
      double actualDistance = (targetSL - entry) / point;
      
      Print("Moving SL to Entry+100: Entry=", DoubleToString(entry, digits), 
            ", New SL=", DoubleToString(targetSL, digits), 
            ", Distance=", DoubleToString(actualDistance, 1), " points");
      
      if(trade.PositionModify(_Symbol, targetSL, currentTP))
      {
         Print("SUCCESS: SL moved to Entry+100 points");
      }
      else
      {
         Print("FAILED to modify SL - Error: ", trade.ResultRetcode());
      }
   }
}

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
   
   Print("BUY Only EMA50 EA initialized - TP: ", TP_Points, " points, SL moves to breakeven+", SLAboveEntry, " at ", MinProfitToTrail, " points profit, Post-TP conditions enabled");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
}

void OnTick()
{
   if(PositionSelect(_Symbol))
   {
      UpdateTrailingStop();
      return;
   }
   
   // Check if we need to reset after TP
   if(!canTrade)
   {
      // Start waiting for price to go below EMA50 after TP
      waitingForPriceBelowEMA = true;
      waitingForPriceAboveEMA = false;
      Print("Position closed - Waiting for price to go below EMA50");
   }
   
   if(!IsNewBar()) return;
   
   double ema50;
   if(!CopyEMA(ema50)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Check post-TP conditions first
   if(waitingForPriceBelowEMA)
   {
      if(ask < ema50)
      {
         waitingForPriceBelowEMA = false;
         waitingForPriceAboveEMA = true;
         Print("Price went below EMA50 - Now waiting for price to go back above EMA50");
      }
      else
      {
         static datetime lastPrint1 = 0;
         datetime currentTime = TimeCurrent();
         if(currentTime - lastPrint1 > 60)
         {
            Print("Waiting for price to go below EMA50 (Ask: ", ask, ", EMA50: ", ema50, ")");
            lastPrint1 = currentTime;
         }
      }
      return;
   }
   
   if(waitingForPriceAboveEMA)
   {
      if(ask > ema50)
      {
         waitingForPriceAboveEMA = false;
         canTrade = true;
         Print("Price back above EMA50 - Ready to trade again!");
      }
      else
      {
         static datetime lastPrint2 = 0;
         datetime currentTime = TimeCurrent();
         if(currentTime - lastPrint2 > 60)
         {
            Print("Waiting for price to go back above EMA50 (Ask: ", ask, ", EMA50: ", ema50, ")");
            lastPrint2 = currentTime;
         }
      }
      return;
   }
   
   // Normal trading logic - only trade when canTrade is true
   if(ask > ema50 && canTrade)
   {
      Print("BUY Signal: Price above EMA50 and canTrade is true");
      
      double sl = ask - SL_Points * point;
      double tp = ask + TP_Points * point;
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "Price above EMA50"))
      {
         Print("BUY order opened - SL: ", sl, ", TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
   else
   {
      static datetime lastPrint3 = 0;
      datetime currentTime = TimeCurrent();
      if(currentTime - lastPrint3 > 60)
      {
         if(!canTrade)
            Print("Cannot trade yet - Waiting for post-TP conditions to complete");
         else
            Print("Waiting: Price below EMA50 (Ask: ", ask, ", EMA50: ", ema50, ")");
         lastPrint3 = currentTime;
      }
   }
}