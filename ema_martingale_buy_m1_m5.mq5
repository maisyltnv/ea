#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input ulong   InpMagicNumber          = 90010501;   // Magic Number
input int     InpSlPoints             = 200;        // Stop Loss (points)
input int     InpTpPoints             = 300;        // Take Profit (points)
input int     InpEmaFastPeriod        = 5;          // Fast EMA period (M1)
input int     InpEmaSlowPeriod        = 50;         // Slow EMA period (M1)
input int     InpPriceOffsetPoints    = 5;          // Price > EMA5 + offset (points)

// Martingale lot sequence (10 steps)
input double  InpLotStep1             = 0.01;
input double  InpLotStep2             = 0.02;
input double  InpLotStep3             = 0.04;
input double  InpLotStep4             = 0.08;
input double  InpLotStep5             = 0.16;
input double  InpLotStep6             = 0.32;
input double  InpLotStep7             = 0.64;
input double  InpLotStep8             = 1.28;
input double  InpLotStep9             = 2.56;
input double  InpLotStep10            = 5.12;

// Internal state
CTrade        trade;
int           handleEmaM1_Fast = -1;
int           handleEmaM1_Slow = -1;

string        gvMartiStepName;

//--- helpers
double GetPoint() { return(_Point); }
double NormalizeToLotStep(const double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double v = MathFloor(lots/step + 1e-8) * step;
   if(v < minL) v = minL;
   if(v > maxL) v = maxL;
   return v;
}

int GetOpenPositionsCountForThisEA()
{
   int total = PositionsTotal();
   int count = 0;
   for(int i=0;i<total;i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

int ReadMartingaleStep()
{
   if(!GlobalVariableCheck(gvMartiStepName))
      GlobalVariableSet(gvMartiStepName, 1.0);
   double v = GlobalVariableGet(gvMartiStepName);
   int step = (int)MathRound(v);
   if(step < 1 || step > 10) step = 1;
   return step;
}

void WriteMartingaleStep(const int step)
{
   int s = step;
   if(s < 1) s = 1;
   if(s > 10) s = 10;
   GlobalVariableSet(gvMartiStepName, (double)s);
}

double GetLotForStep(const int step)
{
   switch(step)
   {
      case 1:  return NormalizeToLotStep(InpLotStep1);
      case 2:  return NormalizeToLotStep(InpLotStep2);
      case 3:  return NormalizeToLotStep(InpLotStep3);
      case 4:  return NormalizeToLotStep(InpLotStep4);
      case 5:  return NormalizeToLotStep(InpLotStep5);
      case 6:  return NormalizeToLotStep(InpLotStep6);
      case 7:  return NormalizeToLotStep(InpLotStep7);
      case 8:  return NormalizeToLotStep(InpLotStep8);
      case 9:  return NormalizeToLotStep(InpLotStep9);
      default: return NormalizeToLotStep(InpLotStep10);
   }
}

bool UpdateMartingaleStepFromLastClosed()
{
   datetime from = (datetime)0;
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to))
      return false;

   long lastTicket = -1;
   datetime lastTime = 0;
   int deals = HistoryDealsTotal();
   for(int i=deals-1;i>=0;i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      string sym = (string)HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      long   mgc = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      int    type = (int)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      if(sym != _Symbol || mgc != (long)InpMagicNumber) continue;
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      datetime t = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(t > lastTime)
      {
         lastTime = t;
         lastTicket = (long)dealTicket;
      }
   }

   if(lastTicket < 0)
      return false;

   // Determine profit result
   double profit  = HistoryDealGetDouble((ulong)lastTicket, DEAL_PROFIT);
   double swap    = HistoryDealGetDouble((ulong)lastTicket, DEAL_SWAP);
   double commission = HistoryDealGetDouble((ulong)lastTicket, DEAL_COMMISSION);
   double net = profit + swap + commission;

   int step = ReadMartingaleStep();
   if(net >= 0.0)
   {
      // TP or positive close -> reset to step 1
      WriteMartingaleStep(1);
   }
   else
   {
      // SL or negative close -> increment; if beyond 10, reset to 1 per spec
      step++;
      if(step > 10) step = 1;
      WriteMartingaleStep(step);
   }
   return true;
}

bool GetEmaValues(double &emaM1Fast, double &emaM1Slow)
{
   emaM1Fast = 0.0;
   emaM1Slow = 0.0;
   if(handleEmaM1_Fast < 0 || handleEmaM1_Slow < 0)
      return false;

   double bufFast[];
   double bufSlowM1[];
   ArraySetAsSeries(bufFast, true);
   ArraySetAsSeries(bufSlowM1, true);

   // Read the previous closed bar (shift=1)
   if(CopyBuffer(handleEmaM1_Fast, 0, 1, 1, bufFast) < 1) return false;
   if(CopyBuffer(handleEmaM1_Slow, 0, 1, 1, bufSlowM1) < 1) return false;

   emaM1Fast = bufFast[0];
   emaM1Slow = bufSlowM1[0];
   return true;
}

bool EntryCondition()
{
   double emaF, emaS1;
   if(!GetEmaValues(emaF, emaS1))
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return false;

   // Buy when price > EMA5 + offset (points) on M1
   double offset = InpPriceOffsetPoints * GetPoint();
   if(!(ask > (emaF + offset))) return false;

   return true;
}

void TryOpenBuy()
{
   if(GetOpenPositionsCountForThisEA() > 0)
      return;

   if(!EntryCondition())
      return;

   int step = ReadMartingaleStep();
   double lots = GetLotForStep(step);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = GetPoint();

   double sl = 0.0, tp = 0.0;
   if(InpSlPoints > 0) sl = ask - InpSlPoints * pt;
   if(InpTpPoints > 0) tp = ask + InpTpPoints * pt;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetDeviationInPoints(10);

   bool ok = trade.Buy(lots, _Symbol, ask, sl, tp, "EMA_Marti_Buy");
   if(!ok)
   {
      PrintFormat("Buy failed: %s", trade.ResultRetcodeDescription());
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   gvMartiStepName = StringFormat("EA_MartiStep_%s_%I64u", _Symbol, InpMagicNumber);
   if(!GlobalVariableCheck(gvMartiStepName))
      GlobalVariableSet(gvMartiStepName, 1.0);

   // Indicators
   handleEmaM1_Fast = iMA(_Symbol, PERIOD_M1, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   handleEmaM1_Slow = iMA(_Symbol, PERIOD_M1, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEmaM1_Fast < 0 || handleEmaM1_Slow < 0)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   // If there are no open positions for this EA, check last closed result to set martingale step
   if(GetOpenPositionsCountForThisEA() == 0)
   {
      UpdateMartingaleStepFromLastClosed();
      TryOpenBuy();
   }
}


