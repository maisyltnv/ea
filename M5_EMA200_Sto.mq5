//+------------------------------------------------------------------+
//| M5_EMA200_Sto.mq5                                                |
//| M5: EMA200 + Stochastic 9,3,3 — ສັນຍານຈາກເສັ້ນ 20/80             |
//+------------------------------------------------------------------+
#property copyright "M5_EMA200_Sto"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

input double InpLots              = 0.01;
input ulong  InpMagic             = 20250419;
input int    InpSlippage          = 30;

input int    InpEMAPeriod         = 200;
input int    InpStoK              = 9;
input int    InpStoD              = 3;
input int    InpStoSlow           = 3;
input int    InpLevelBuy          = 20;
input int    InpLevelSell         = 80;

input int    InpTPPoints          = 2000;
input int    InpTrailTriggerPts   = 1000;
input int    InpTrailLockPts      = 100;

input double InpDailyLossPercent  = 10.0;
input double InpDailyProfitPercent= 3.0;

int    g_maHandle   = INVALID_HANDLE;
int    g_stoHandle  = INVALID_HANDLE;

double g_dayStartBalance = 0;
int    g_dayKey          = -1;
bool   g_stopTradingDay  = false;

//+------------------------------------------------------------------+
int DayKeyFromTime(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t,s);
   return (int)(s.day + s.mon*100 + s.year*10000);
}

//+------------------------------------------------------------------+
void UpdateTradingDay()
{
   int k=DayKeyFromTime(TimeTradeServer());
   if(k==g_dayKey)
      return;
   g_dayKey=k;
   g_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_stopTradingDay=false;
}

//+------------------------------------------------------------------+
void CloseAllOurPositions()
{
   trade.SetExpertMagicNumber(InpMagic);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic)
         continue;
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void CheckDailyPortfolioLimits()
{
   if(g_stopTradingDay || g_dayStartBalance<=0.0)
      return;

   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double loss=g_dayStartBalance-eq;
   double profit=eq-g_dayStartBalance;

   if(loss>=g_dayStartBalance*InpDailyLossPercent/100.0)
   {
      Print("ຢຸດວັນນີ້: ຂາດທຶນຮອດ ",InpDailyLossPercent,"% ຂອງພອດເລີ່ມມື້");
      g_stopTradingDay=true;
      CloseAllOurPositions();
      return;
   }

   if(profit>=g_dayStartBalance*InpDailyProfitPercent/100.0)
   {
      Print("ຢຸດວັນນີ້: ກຳໄລຮອດ ",InpDailyProfitPercent,"% ຂອງພອດເລີ່ມມື້");
      g_stopTradingDay=true;
      CloseAllOurPositions();
   }
}

//+------------------------------------------------------------------+
double PointVal()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
}

//+------------------------------------------------------------------+
int DigitsVal()
{
   return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
}

//+------------------------------------------------------------------+
bool HasOurPosition()
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
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ManageBreakEvenLock()
{
   trade.SetExpertMagicNumber(InpMagic);
   double pt=PointVal();
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

      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      if(type==POSITION_TYPE_BUY)
      {
         double profitPts=(bid-open)/pt;
         if(profitPts<(double)InpTrailTriggerPts)
            continue;
         double newSL=NormalizeDouble(open+InpTrailLockPts*pt,DigitsVal());
         if(sl>0.0 && MathAbs(sl-newSL)<pt*0.5)
            continue;
         if(newSL>=bid-minDist)
            continue;
         if(sl>0.0 && newSL<=sl)
            continue;
         trade.PositionModify(ticket,newSL,PositionGetDouble(POSITION_TP));
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double profitPts=(open-ask)/pt;
         if(profitPts<(double)InpTrailTriggerPts)
            continue;
         double newSL=NormalizeDouble(open-InpTrailLockPts*pt,DigitsVal());
         if(sl>0.0 && MathAbs(sl-newSL)<pt*0.5)
            continue;
         if(newSL<=ask+minDist)
            continue;
         // ຍ້າຍ SL ລົງໃຫ້ໃກ້ຕະຫຼາດກວ່າເກົ່າເພື່ອກັນແຕ້ມ (ຂອງ sell ຕ້ອງຍັງຢູ່ເທິງ Ask)
         if(sl>0.0 && newSL>=sl)
            continue;
         trade.PositionModify(ticket,newSL,PositionGetDouble(POSITION_TP));
      }
   }
}

//+------------------------------------------------------------------+
bool PullBuffers(double &ema[],double &stoMain[])
{
   ArrayResize(ema,3);
   ArrayResize(stoMain,3);
   ArraySetAsSeries(ema,true);
   ArraySetAsSeries(stoMain,true);

   if(CopyBuffer(g_maHandle,0,0,3,ema)!=3)
      return false;
   if(CopyBuffer(g_stoHandle,0,0,3,stoMain)!=3)
      return false;
   return true;
}

//+------------------------------------------------------------------+
bool TryOpenBuy(double emaSl)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double pt=PointVal();
   int dig=DigitsVal();
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   double sl=NormalizeDouble(emaSl,dig);
   double tp=NormalizeDouble(ask+InpTPPoints*pt,dig);

   if(sl>=ask)
   {
      Print("Buy ບໍ່ເປີດ: EMA200 (SL) ບໍ່ຢູ່ໃຕ້ລາຄາເຂົ້າ");
      return false;
   }

   double minSL=ask-stops*pt;
   if(sl>minSL)
      sl=NormalizeDouble(minSL,dig);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   if(!trade.Buy(InpLots,_Symbol,ask,sl,tp))
   {
      Print("Buy failed: ",trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool TryOpenSell(double emaSl)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt=PointVal();
   int dig=DigitsVal();
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);

   double sl=NormalizeDouble(emaSl,dig);
   double tp=NormalizeDouble(bid-InpTPPoints*pt,dig);

   if(sl<=bid)
   {
      Print("Sell ບໍ່ເປີດ: EMA200 (SL) ບໍ່ຢູ່ເທິງລາຄາເຂົ້າ");
      return false;
   }

   double maxSL=bid+stops*pt;
   if(sl<maxSL)
      sl=NormalizeDouble(maxSL,dig);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   if(!trade.Sell(InpLots,_Symbol,bid,sl,tp))
   {
      Print("Sell failed: ",trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Period()!=PERIOD_M5)
      return;

   UpdateTradingDay();
   CheckDailyPortfolioLimits();

   if(g_stopTradingDay)
      return;

   ManageBreakEvenLock();

   static datetime lastBar=0;
   datetime t=iTime(_Symbol,PERIOD_M5,0);
   if(t==lastBar)
      return;
   lastBar=t;

   if(HasOurPosition())
      return;

   double ema[],sto[];
   if(!PullBuffers(ema,sto))
      return;

   double close1=iClose(_Symbol,PERIOD_M5,1);

   // Buy: ລາຍ > EMA, Sto ຕັດຂຶ້ນເສັ້ນ InpLevelBuy (ຈາກລຸ່ມ/ເທົ່າຂຶ້ນເທິງ)
   bool priceAboveEma=(close1>ema[1]);
   bool stoCrossUp=(sto[2]<=(double)InpLevelBuy && sto[1]>(double)InpLevelBuy);

   if(priceAboveEma && stoCrossUp)
   {
      TryOpenBuy(ema[1]);
      return;
   }

   // Sell: ລາຄາ < EMA, Sto ຕັດລົງເສັ້ນ InpLevelSell (ຈາກເທິງລົງລຸ່ມ)
   bool priceBelowEma=(close1<ema[1]);
   bool stoCrossDn=(sto[2]>=(double)InpLevelSell && sto[1]<(double)InpLevelSell);

   if(priceBelowEma && stoCrossDn)
   {
      TryOpenSell(ema[1]);
      return;
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(Period()!=PERIOD_M5)
   {
      Print("ແນະນຳ: ໃຫ້ຕິດ EA ນີ້ໃນແຜງ M5 ເທົ່ານັ້ນ");
   }

   g_maHandle=iMA(_Symbol,PERIOD_M5,InpEMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   if(g_maHandle==INVALID_HANDLE)
   {
      Print("ບໍ່ສາມາດສ້າງ EMA");
      return INIT_FAILED;
   }

   g_stoHandle=iStochastic(_Symbol,PERIOD_M5,InpStoK,InpStoD,InpStoSlow,MODE_SMA,STO_LOWHIGH);
   if(g_stoHandle==INVALID_HANDLE)
   {
      Print("ບໍ່ສາມາດສ້າງ Stochastic");
      IndicatorRelease(g_maHandle);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_dayKey=-1;
   UpdateTradingDay();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_maHandle!=INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   if(g_stoHandle!=INVALID_HANDLE)
      IndicatorRelease(g_stoHandle);
}

//+------------------------------------------------------------------+
