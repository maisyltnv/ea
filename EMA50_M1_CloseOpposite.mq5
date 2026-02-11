//+------------------------------------------------------------------+
//| EMA50 M1 - Close opposite position                               |
//| M1, EMA 50                                                       |
//| Buy:  price > EMA50 => close SELL position if any                 |
//| Sell: price < EMA50 => close BUY position if any                 |
//+------------------------------------------------------------------+
#property strict
#property description "M1 EMA50: close opposite side when price crosses EMA50."
#property version   "1.00"

#include <Trade/Trade.mqh>

input int    EMA_Period   = 50;       // EMA period
input double Lots         = 0.01;     // Lot size
input int    MagicNumber  = 789012;   // Magic number
input int    SlippagePts  = 20;       // Slippage (points)

CTrade trade;
int    g_emaHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   string symbol = _Symbol;
   g_emaHandle = iMA(symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle. Error=", GetLastError());
      return(INIT_FAILED);
   }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   Print("EMA50 M1 EA initialized. Symbol=", symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Close all positions of given type for this EA                    |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE type)
{
   string symbol = _Symbol;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_emaHandle == INVALID_HANDLE)
      return;

   string symbol = _Symbol;

   // EMA50 on M1, last closed bar
   double emaBuf[1];
   if(CopyBuffer(g_emaHandle, 0, 1, 1, emaBuf) <= 0)
      return;

   double ema50 = emaBuf[0];
   double price = SymbolInfoDouble(symbol, SYMBOL_BID);  // use BID for comparison

   // Buy: price > EMA50  => close SELL if any
   if(price > ema50)
   {
      ClosePositionsByType(POSITION_TYPE_SELL);
      // Optional: open BUY if no BUY position (user did not ask, can add later)
   }
   // Sell: price < EMA50 => close BUY if any
   else if(price < ema50)
   {
      ClosePositionsByType(POSITION_TYPE_BUY);
   }
   // If price == ema50 we do nothing
}
