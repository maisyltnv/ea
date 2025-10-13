//+------------------------------------------------------------------+
//| EMA9/EMA50 Retest Strategy EA                                   |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;
input int EMA9_Period = 9;
input int EMA50_Period = 50;
input ulong Magic = 123456;

// Global Variables
CTrade trade;
int hEMA9, hEMA50;
datetime lastBarTime = 0;

// State tracking variables
bool waitingForRetest = false;
bool waitingForPriceAboveEMA50 = false;  // for BUY retest
bool waitingForPriceBelowEMA50 = false;  // for SELL retest
string lastSignalType = "";

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
//| Get EMA values                                                   |
//+------------------------------------------------------------------+
bool GetEMAValues(double &ema9, double &ema50)
{
   if(hEMA9 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE) return false;
   
   double ema9_buf[1], ema50_buf[1];
   if(CopyBuffer(hEMA9, 0, 1, 1, ema9_buf) != 1) return false;
   if(CopyBuffer(hEMA50, 0, 1, 1, ema50_buf) != 1) return false;
   
   ema9 = ema9_buf[0];
   ema50 = ema50_buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Check if price retested EMA9                                     |
//+------------------------------------------------------------------+
bool PriceRetestedEMA9(double currentPrice, double ema9, string signalType)
{
   if(signalType == "BUY")
   {
      // For BUY: price should come down to EMA9 or close to it
      return (currentPrice <= ema9 * 1.001); // Allow small tolerance
   }
   else if(signalType == "SELL")
   {
      // For SELL: price should come up to EMA9 or close to it
      return (currentPrice >= ema9 * 0.999); // Allow small tolerance
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check exit conditions                                            |
//+------------------------------------------------------------------+
void CheckExitConditions()
{
   if(!PositionSelect(_Symbol)) return;
   
   double ema9, ema50;
   if(!GetEMAValues(ema9, ema50)) return;
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long posType = PositionGetInteger(POSITION_TYPE);
   
   // BUY position exit: price below EMA50
   if(posType == POSITION_TYPE_BUY && currentPrice < ema50)
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(trade.PositionClose(ticket))
      {
         Print("BUY position closed - Price below EMA50: ", currentPrice, " < ", ema50);
      }
   }
   // SELL position exit: price above EMA50
   else if(posType == POSITION_TYPE_SELL && currentPrice > ema50)
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(trade.PositionClose(ticket))
      {
         Print("SELL position closed - Price above EMA50: ", currentPrice, " > ", ema50);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   
   // Create EMA indicators
   hEMA9 = iMA(_Symbol, PERIOD_CURRENT, EMA9_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_CURRENT, EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(hEMA9 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE)
   {
      Print("Failed to create EMA handles");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("EMA9/EMA50 Retest Strategy EA initialized");
   Print("EMA9: ", EMA9_Period, ", EMA50: ", EMA50_Period);
   Print("Lots: ", Lots);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA9 != INVALID_HANDLE) IndicatorRelease(hEMA9);
   if(hEMA50 != INVALID_HANDLE) IndicatorRelease(hEMA50);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check exit conditions first
   CheckExitConditions();
   
   // If position exists, don't look for new signals
   if(PositionSelect(_Symbol)) return;
   
   if(!IsNewBar()) return;
   
   // Get indicator values
   double ema9, ema50;
   if(!GetEMAValues(ema9, ema50)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // BUY Signal Logic
   // 1. EMA9 above EMA50 (uptrend)
   // 2. Price above EMA50
   // 3. Wait for price to retest EMA9
   if(ema9 > ema50 && ask > ema50)
   {
      if(!waitingForRetest || lastSignalType != "BUY")
      {
         waitingForRetest = true;
         waitingForPriceAboveEMA50 = false;
         waitingForPriceBelowEMA50 = false;
         lastSignalType = "BUY";
         Print("BUY Setup: EMA9 > EMA50, Price above EMA50 - Waiting for retest of EMA9");
         Print("EMA9: ", ema9, ", EMA50: ", ema50, ", Current Price: ", ask);
      }
      else if(waitingForRetest && lastSignalType == "BUY")
      {
         // Check if price retested EMA9
         if(PriceRetestedEMA9(ask, ema9, "BUY"))
         {
            Print("BUY Signal: Price retested EMA9 - Opening BUY order");
            
            if(trade.Buy(Lots, _Symbol, ask, 0, 0, "EMA9/50 Retest Buy"))
            {
               Print("BUY order opened - Entry: ", ask);
               waitingForRetest = false;
               lastSignalType = "";
            }
            else
            {
               Print("BUY order failed - Error: ", trade.ResultRetcode());
            }
         }
      }
   }
   // SELL Signal Logic
   // 1. EMA9 below EMA50 (downtrend)
   // 2. Price below EMA50
   // 3. Wait for price to retest EMA9
   else if(ema9 < ema50 && bid < ema50)
   {
      if(!waitingForRetest || lastSignalType != "SELL")
      {
         waitingForRetest = true;
         waitingForPriceAboveEMA50 = false;
         waitingForPriceBelowEMA50 = false;
         lastSignalType = "SELL";
         Print("SELL Setup: EMA9 < EMA50, Price below EMA50 - Waiting for retest of EMA9");
         Print("EMA9: ", ema9, ", EMA50: ", ema50, ", Current Price: ", bid);
      }
      else if(waitingForRetest && lastSignalType == "SELL")
      {
         // Check if price retested EMA9
         if(PriceRetestedEMA9(bid, ema9, "SELL"))
         {
            Print("SELL Signal: Price retested EMA9 - Opening SELL order");
            
            if(trade.Sell(Lots, _Symbol, bid, 0, 0, "EMA9/50 Retest Sell"))
            {
               Print("SELL order opened - Entry: ", bid);
               waitingForRetest = false;
               lastSignalType = "";
            }
            else
            {
               Print("SELL order failed - Error: ", trade.ResultRetcode());
            }
         }
      }
   }
   // Reset waiting state if conditions no longer met
   else if(waitingForRetest)
   {
      waitingForRetest = false;
      lastSignalType = "";
      Print("Reset waiting state - Conditions no longer met");
   }
}
