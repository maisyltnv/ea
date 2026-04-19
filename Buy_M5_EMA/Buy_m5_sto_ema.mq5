//+------------------------------------------------------------------+
//| Buy_m5_sto_ema.mq5                                               |
//| Buy only: M5 + M1 ລາຄາ > EMA50 > EMA200, SL = EMA200(M1)          |
//+------------------------------------------------------------------+
#property copyright "Buy_m5_sto_ema"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

input double InpLots                = 0.01;
input ulong  InpMagic               = 202504201;
input int    InpSlippage            = 30;

input int    InpEMAFast             = 50;
input int    InpEMASlow             = 200;

input int    InpLockTriggerPts      = 1000;
input int    InpLockProfitPts       = 500;
input int    InpTrailBelowBidPts    = 200;

int g_ema50_m5   = INVALID_HANDLE;
int g_ema200_m5  = INVALID_HANDLE;
int g_ema50_m1   = INVALID_HANDLE;
int g_ema200_m1  = INVALID_HANDLE;

//+------------------------------------------------------------------+
double Pt()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
}

//+------------------------------------------------------------------+
int Dg()
{
   return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
}

//+------------------------------------------------------------------+
bool TrendStackOK(const int hFast,const int hSlow,const ENUM_TIMEFRAMES tf,const int shift)
{
   double c=iClose(_Symbol,tf,shift);
   double ef[],es[];
   if(CopyBuffer(hFast,0,shift,1,ef)!=1)
      return false;
   if(CopyBuffer(hSlow,0,shift,1,es)!=1)
      return false;
   return (c>ef[0] && ef[0]>es[0]);
}

//+------------------------------------------------------------------+
bool EntrySignal()
{
   return TrendStackOK(g_ema50_m5,g_ema200_m5,PERIOD_M5,1)
       && TrendStackOK(g_ema50_m1,g_ema200_m1,PERIOD_M1,1);
}

//+------------------------------------------------------------------+
double SlFromEma200M1()
{
   double e[];
   if(CopyBuffer(g_ema200_m1,0,1,1,e)!=1)
      return 0.0;
   return NormalizeDouble(e[0],Dg());
}

//+------------------------------------------------------------------+
bool HasOurBuy()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void TryOpenBuy()
{
   if(HasOurBuy())
      return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double sl=SlFromEma200M1();
   if(sl<=0.0 || sl>=ask)
   {
      Print("ບໍ່ເປີດ Buy: EMA200 M1 ບໍ່ຢູ່ໃຕ້ລາຄາ (sl=",sl," ask=",ask,")");
      return;
   }

   double pt=Pt();
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minSl=ask-stops*pt;
   if(sl>minSl)
      sl=NormalizeDouble(minSl,Dg());

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!trade.Buy(InpLots,_Symbol,ask,sl,0.0))
      Print("Buy failed: ",trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageBuyTrail()
{
   trade.SetExpertMagicNumber(InpMagic);
   double pt=Pt();
   if(pt<=0.0)
      return;
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stops*pt;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      if(PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY)
         continue;

      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

      double profitPts=(bid-open)/pt;
      if(profitPts<(double)InpLockTriggerPts)
         continue;

      double lockSL=NormalizeDouble(open+InpLockProfitPts*pt,Dg());
      double trailSL=NormalizeDouble(bid-InpTrailBelowBidPts*pt,Dg());

      double newSL=MathMax(lockSL,trailSL);
      if(sl>0.0)
         newSL=MathMax(newSL,sl);

      if(newSL>=bid-minDist)
         newSL=NormalizeDouble(bid-minDist-pt,Dg());

      if(sl>0.0 && MathAbs(newSL-sl)<pt*0.5)
         continue;

      if(sl>0.0 && newSL<=sl)
         continue;

      trade.PositionModify(ticket,newSL,0.0);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageBuyTrail();

   static datetime lastM1Bar=0;
   datetime m1=iTime(_Symbol,PERIOD_M1,0);
   if(m1==0 || m1==lastM1Bar)
      return;
   lastM1Bar=m1;

   if(HasOurBuy())
      return;

   if(!EntrySignal())
      return;

   TryOpenBuy();
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_ema50_m5=iMA(_Symbol,PERIOD_M5,InpEMAFast,0,MODE_EMA,PRICE_CLOSE);
   g_ema200_m5=iMA(_Symbol,PERIOD_M5,InpEMASlow,0,MODE_EMA,PRICE_CLOSE);
   g_ema50_m1=iMA(_Symbol,PERIOD_M1,InpEMAFast,0,MODE_EMA,PRICE_CLOSE);
   g_ema200_m1=iMA(_Symbol,PERIOD_M1,InpEMASlow,0,MODE_EMA,PRICE_CLOSE);

   if(g_ema50_m5==INVALID_HANDLE || g_ema200_m5==INVALID_HANDLE ||
      g_ema50_m1==INVALID_HANDLE || g_ema200_m1==INVALID_HANDLE)
   {
      Print("ບໍ່ສາມາດສ້າງ EMA handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_ema50_m5!=INVALID_HANDLE)
      IndicatorRelease(g_ema50_m5);
   if(g_ema200_m5!=INVALID_HANDLE)
      IndicatorRelease(g_ema200_m5);
   if(g_ema50_m1!=INVALID_HANDLE)
      IndicatorRelease(g_ema50_m1);
   if(g_ema200_m1!=INVALID_HANDLE)
      IndicatorRelease(g_ema200_m1);
}

//+------------------------------------------------------------------+
