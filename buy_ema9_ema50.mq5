//+------------------------------------------------------------------+
//|               EMA Crossover Simple EA (Buy only)                 |
//|                         MQL5 (fixed)                             |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

input int              EMA_Fast          = 9;
input int              EMA_Slow          = 50;
input double           LotSize           = 0.10;
input int              StopLossPoints    = 500;
input int              TakeProfitPoints  = 500;
input ENUM_TIMEFRAMES  TimeFrame         = PERIOD_M5;

int    hFast = INVALID_HANDLE;
int    hSlow = INVALID_HANDLE;
CTrade trade;

// control: wait for a NEW crossover after a trade finishes
bool   waitForNextCross = false;

//------------------------------------------------------------------
int OnInit()
{
   hFast = iMA(_Symbol, TimeFrame, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, TimeFrame, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
   {
      Print("❌ Failed to create iMA handles. Err=", GetLastError());
      return(INIT_FAILED);
   }

   Print("✅ EMA Crossover EA initialized.");
   return(INIT_SUCCEEDED);
}
//------------------------------------------------------------------
void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
}
//------------------------------------------------------------------
void OnTick()
{
   // get EMA values (current and previous)
   double f[2], s[2];
   if(CopyBuffer(hFast, 0, 0, 2, f) != 2) return;
   if(CopyBuffer(hSlow, 0, 0, 2, s) != 2) return;

   double emaFastCurr = f[0];
   double emaFastPrev = f[1];
   double emaSlowCurr = s[0];
   double emaSlowPrev = s[1];

   bool crossUp = (emaFastPrev < emaSlowPrev) && (emaFastCurr > emaSlowCurr);

   // if there is no open position on this symbol
   if(PositionsTotalBySymbol(_Symbol) == 0)
   {
      // after a trade closes, we require a NEW crossover first
      if(waitForNextCross)
      {
         if(crossUp)
            waitForNextCross = false; // armed again on the next bar
         return;
      }

      // place BUY when crossover happens
      if(crossUp)
      {
         double ask = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits);
         double sl  = NormalizeDouble(ask - StopLossPoints  * _Point, _Digits);
         double tp  = NormalizeDouble(ask + TakeProfitPoints* _Point, _Digits);

         trade.SetDeviationInPoints(10);
         trade.SetExpertMagicNumber(12345);

         if(trade.Buy(LotSize, NULL, ask, sl, tp, "EMA Buy"))
            Print("✅ Buy placed @ ", ask, " SL=", sl, " TP=", tp);
         else
            Print("❌ Buy failed. Err=", GetLastError());
      }
   }
   else
   {
      // if a position exists, monitor for closure by SL/TP.
      // when it closes (next ticks will see 0 positions), we will
      // require the NEXT crossover before entering again.
      // set the flag here so the moment it closes we wait for new cross.
      waitForNextCross = true;
   }
}

// helper: count positions for this symbol
int PositionsTotalBySymbol(string sym)
{
   int cnt = 0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == sym) cnt++;
      }
   }
   return cnt;
}
