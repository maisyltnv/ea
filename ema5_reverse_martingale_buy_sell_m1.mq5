#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input ulong   InpMagicNumber          = 90010505;   // Magic Number (reverse martingale BUY+SELL EA)
input int     InpSlPoints             = 200;        // Stop Loss (points)
input int     InpTpPoints             = 300;        // Take Profit (points)
input int     InpEmaFastPeriod        = 5;          // Fast EMA period (M1)
input int     InpPriceOffsetPoints    = 5;          // Price offset (points)

// Reverse martingale lot sequence (3 steps): 0.01 -> 0.02 -> 0.03; reset to 0.01 on loss
input double  InpLotStep1             = 0.01;
input double  InpLotStep2             = 0.02;
input double  InpLotStep3             = 0.03;

// Internal state
CTrade        trade;
int           handleEmaM1_Fast = -1;

string        gvRevMartiStepBuyName;
string        gvRevMartiStepSellName;

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

int ReadStep(const string name)
{
   if(!GlobalVariableCheck(name))
      GlobalVariableSet(name, 1.0);
   double v = GlobalVariableGet(name);
   int step = (int)MathRound(v);
   if(step < 1 || step > 3) step = 1;
   return step;
}

void WriteStep(const string name, const int step)
{
   int s = step;
   if(s < 1) s = 1;
   if(s > 3) s = 3;
   GlobalVariableSet(name, (double)s);
}

double GetLotForStep(const int step)
{
   switch(step)
   {
      case 1:  return NormalizeToLotStep(InpLotStep1);
      case 2:  return NormalizeToLotStep(InpLotStep2);
      default: return NormalizeToLotStep(InpLotStep3);
   }
}

bool UpdateStepsFromLastClosed()
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

   int type = (int)HistoryDealGetInteger((ulong)lastTicket, DEAL_TYPE);
   bool wasBuy = (type == DEAL_TYPE_BUY);

   string stepName = wasBuy ? gvRevMartiStepBuyName : gvRevMartiStepSellName;
   int step = ReadStep(stepName);
   if(net >= 0.0)
   {
      // TP or positive close -> advance step (1->2->3->1)
      step++;
      if(step > 3) step = 1;
      WriteStep(stepName, step);
   }
   else
   {
      // SL or negative close -> reset to step 1
      WriteStep(stepName, 1);
   }
   return true;
}

bool GetEmaFast(double &emaM1Fast)
{
   emaM1Fast = 0.0;
   if(handleEmaM1_Fast < 0)
      return false;

   double bufFast[];
   ArraySetAsSeries(bufFast, true);

   // Read the previous closed bar (shift=1)
   if(CopyBuffer(handleEmaM1_Fast, 0, 1, 1, bufFast) < 1) return false;

   emaM1Fast = bufFast[0];
   return true;
}

bool EntryConditionBuy()
{
   double emaF;
   if(!GetEmaFast(emaF))
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return false;

   // Buy when price > EMA5 + offset (points) on M1
   double offset = InpPriceOffsetPoints * GetPoint();
   if(!(ask > (emaF + offset))) return false;

   return true;
}

bool EntryConditionSell()
{
   double emaF;
   if(!GetEmaFast(emaF))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return false;

   // Sell when price < EMA5 - offset (points) on M1
   double offset = InpPriceOffsetPoints * GetPoint();
   if(!(bid < (emaF - offset))) return false;

   return true;
}

void TryOpenBuy()
{
   if(GetOpenPositionsCountForThisEA() > 0)
      return;

   if(!EntryConditionBuy())
      return;

   int step = ReadStep(gvRevMartiStepBuyName);
   double lots = GetLotForStep(step);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = GetPoint();

   double sl = 0.0, tp = 0.0;
   if(InpSlPoints > 0) sl = ask - InpSlPoints * pt;
   if(InpTpPoints > 0) tp = ask + InpTpPoints * pt;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetDeviationInPoints(10);

   bool ok = trade.Buy(lots, _Symbol, ask, sl, tp, "EMA5_RevMarti_BS_Buy");
   if(!ok)
   {
      PrintFormat("Buy failed: %s", trade.ResultRetcodeDescription());
   }
}

void TryOpenSell()
{
   if(GetOpenPositionsCountForThisEA() > 0)
      return;

   if(!EntryConditionSell())
      return;

   int step = ReadStep(gvRevMartiStepSellName);
   double lots = GetLotForStep(step);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt  = GetPoint();

   double sl = 0.0, tp = 0.0;
   if(InpSlPoints > 0) sl = bid + InpSlPoints * pt;
   if(InpTpPoints > 0) tp = bid - InpTpPoints * pt;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetDeviationInPoints(10);

   bool ok = trade.Sell(lots, _Symbol, bid, sl, tp, "EMA5_RevMarti_BS_Sell");
   if(!ok)
   {
      PrintFormat("Sell failed: %s", trade.ResultRetcodeDescription());
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   gvRevMartiStepBuyName  = StringFormat("EA5_RevMartiStepBuy_%s_%I64u", _Symbol, InpMagicNumber);
   gvRevMartiStepSellName = StringFormat("EA5_RevMartiStepSell_%s_%I64u", _Symbol, InpMagicNumber);
   if(!GlobalVariableCheck(gvRevMartiStepBuyName))
      GlobalVariableSet(gvRevMartiStepBuyName, 1.0);
   if(!GlobalVariableCheck(gvRevMartiStepSellName))
      GlobalVariableSet(gvRevMartiStepSellName, 1.0);

   // Indicator
   handleEmaM1_Fast = iMA(_Symbol, PERIOD_M1, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEmaM1_Fast < 0)
   {
      Print("Failed to create indicator handle");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   // If there are no open positions for this EA, check last closed result to set reverse martingale step per side
   if(GetOpenPositionsCountForThisEA() == 0)
   {
      UpdateStepsFromLastClosed();
      TryOpenBuy();
      TryOpenSell();
   }
}


