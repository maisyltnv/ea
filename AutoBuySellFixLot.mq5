//+------------------------------------------------------------------+
//| AutoBuySell EA                                                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// INPUT PARAMETERS
input double InitialLot=0.01;          // ຂະໜາດ lot ຄົງທີ່ (fixed)
input int GridLevelsPerSide=3;
input int GridDistancePoints=200;      // ຄວາມຫ່າງ
input int SideTargetProfitPoints=200;  // ກຳໄລເປັນຈຸດ

input double DailyProfitTargetUSD=10; // ກຳໄລຕໍ່ມື້ ເປັນ$
input double DailyLossLimitUSD=30;    // ເສຍຕໍ່ມື້ ເປັນ$

input int MagicBuy=1111;
input int MagicSell=2222;

bool stopTrading=false;

//+------------------------------------------------------------------+

double PointValue()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
}

//+------------------------------------------------------------------+

int CountBuyPendings()
{
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(!OrderSelect(t)) continue;

      if(OrderGetInteger(ORDER_MAGIC)==MagicBuy &&
         OrderGetInteger(ORDER_TYPE)==ORDER_TYPE_BUY_LIMIT)
         c++;
   }
   return c;
}

//+------------------------------------------------------------------+

int CountSellPendings()
{
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(!OrderSelect(t)) continue;

      if(OrderGetInteger(ORDER_MAGIC)==MagicSell &&
         OrderGetInteger(ORDER_TYPE)==ORDER_TYPE_SELL_LIMIT)
         c++;
   }
   return c;
}

//+------------------------------------------------------------------+

double GetLowestBuyPrice()
{
   double lowest=0;
   bool found=false;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(!OrderSelect(t)) continue;

      if(OrderGetInteger(ORDER_MAGIC)!=MagicBuy) continue;
      if(OrderGetInteger(ORDER_TYPE)!=ORDER_TYPE_BUY_LIMIT) continue;

      double p=OrderGetDouble(ORDER_PRICE_OPEN);

      if(!found || p<lowest)
      {
         lowest=p;
         found=true;
      }
   }

   return lowest;
}

//+------------------------------------------------------------------+

double GetHighestSellPrice()
{
   double highest=0;
   bool found=false;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(!OrderSelect(t)) continue;

      if(OrderGetInteger(ORDER_MAGIC)!=MagicSell) continue;
      if(OrderGetInteger(ORDER_TYPE)!=ORDER_TYPE_SELL_LIMIT) continue;

      double p=OrderGetDouble(ORDER_PRICE_OPEN);

      if(!found || p>highest)
      {
         highest=p;
         found=true;
      }
   }

   return highest;
}

//+------------------------------------------------------------------+

bool PlaceBuyPending(double price,double lot)
{
   trade.SetExpertMagicNumber(MagicBuy);
   if(trade.BuyLimit(lot,price,_Symbol))
      return true;
   Print("BuyLimit failed: ",trade.ResultRetcodeDescription()," retcode=",trade.ResultRetcode(),
         " price=",price," bid=",SymbolInfoDouble(_Symbol,SYMBOL_BID));
   return false;
}

//+------------------------------------------------------------------+

bool PlaceSellPending(double price,double lot)
{
   trade.SetExpertMagicNumber(MagicSell);
   if(trade.SellLimit(lot,price,_Symbol))
      return true;
   Print("SellLimit failed: ",trade.ResultRetcodeDescription()," retcode=",trade.ResultRetcode(),
         " price=",price," ask=",SymbolInfoDouble(_Symbol,SYMBOL_ASK));
   return false;
}

//+------------------------------------------------------------------+

void MaintainBuyGrid()
{
   int safety=0;
   const int maxPlacements=GridLevelsPerSide*5;

   while(CountBuyPendings()<GridLevelsPerSide && safety<maxPlacements)
   {
      safety++;

      double base=GetLowestBuyPrice();

      if(base==0)
         base=SymbolInfoDouble(_Symbol,SYMBOL_BID);

      double price=NormalizeDouble(base-GridDistancePoints*PointValue(),(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));

      // ເປີດ pending buy ດ້ວຍ lot ຄົງທີ່ — ຖ້າສັ່ງບໍ່ສຳເລັດຕ້ອງອອກຈາກວົງ (ບໍ່ດັ່ນຄ້າງໃນ Tester)
      if(!PlaceBuyPending(price,InitialLot))
         break;
   }
}

//+------------------------------------------------------------------+

void MaintainSellGrid()
{
   int safety=0;
   const int maxPlacements=GridLevelsPerSide*5;

   while(CountSellPendings()<GridLevelsPerSide && safety<maxPlacements)
   {
      safety++;

      double base=GetHighestSellPrice();

      if(base==0)
         base=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double price=NormalizeDouble(base+GridDistancePoints*PointValue(),(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));

      if(!PlaceSellPending(price,InitialLot))
         break;
   }
}

//+------------------------------------------------------------------+

void OpenInitialOrders()
{
   trade.SetExpertMagicNumber(MagicBuy);
   if(!trade.Buy(InitialLot))
      Print("OpenInitial Buy failed: ",trade.ResultRetcodeDescription()," ",trade.ResultRetcode());

   trade.SetExpertMagicNumber(MagicSell);
   if(!trade.Sell(InitialLot))
      Print("OpenInitial Sell failed: ",trade.ResultRetcodeDescription()," ",trade.ResultRetcode());

   MaintainBuyGrid();
   MaintainSellGrid();
}

//+------------------------------------------------------------------+

double BuySidePoints()
{
   double points=0;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);

      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicBuy) continue;

      double open=PositionGetDouble(POSITION_PRICE_OPEN);

      points+=(bid-open)/PointValue();
   }

   return points;
}

//+------------------------------------------------------------------+

double SellSidePoints()
{
   double points=0;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);

      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC)!=MagicSell) continue;

      double open=PositionGetDouble(POSITION_PRICE_OPEN);

      points+=(open-ask)/PointValue();
   }

   return points;
}

//+------------------------------------------------------------------+

void CloseSide(int magic)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);

      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;

      trade.PositionClose(t);
   }

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);

      if(!OrderSelect(t)) continue;

      if(OrderGetInteger(ORDER_MAGIC)!=magic) continue;

      trade.OrderDelete(t);
   }
}

//+------------------------------------------------------------------+

void ResetBuySide()
{
   CloseSide(MagicBuy);

   trade.SetExpertMagicNumber(MagicBuy);
   trade.Buy(InitialLot);
   MaintainBuyGrid();
}

//+------------------------------------------------------------------+

void ResetSellSide()
{
   CloseSide(MagicSell);

   trade.SetExpertMagicNumber(MagicSell);
   trade.Sell(InitialLot);
   MaintainSellGrid();
}

//+------------------------------------------------------------------+

void CheckDailyProfit()
{
   datetime dayStart=iTime(_Symbol,PERIOD_D1,0);
   datetime nowSrv=TimeTradeServer();
   if(dayStart==0 || nowSrv==0)
      return;

   // ໂຫຼດ history ເຂົ້າ cache — ບໍ່ມີບັນທັດນີ້ໃນ Tester ຫຼາຍຄັ້ງຈະບໍ່ມີ deal / ກຳໄລຜິດ
   if(!HistorySelect(dayStart,nowSrv))
      return;

   double profit=0;
   int n=HistoryDealsTotal();

   for(int i=0;i<n;i++)
   {
      ulong t=HistoryDealGetTicket(i);
      if(t==0)
         continue;

      datetime dealTime=(datetime)HistoryDealGetInteger(t,DEAL_TIME);
      if(dealTime<dayStart)
         continue;

      profit+=HistoryDealGetDouble(t,DEAL_PROFIT)
            +HistoryDealGetDouble(t,DEAL_SWAP)
            +HistoryDealGetDouble(t,DEAL_COMMISSION);
   }

   if(profit>=DailyProfitTargetUSD || profit<=-DailyLossLimitUSD)
   {
      stopTrading=true;

      CloseSide(MagicBuy);
      CloseSide(MagicSell);
   }
}

//+------------------------------------------------------------------+

int OnInit()
{
   // EA ນີ້ຕ້ອງມີຕຳແໜ່ງ Buy ແລະ Sell ແຍກກັນ (magic ຕ່າງກັນ) — ໃນ MT5 ຕ້ອງໃຊ້ບັນຊີ Hedging; Netting ຈະລວມຕຳແໜ່ງແລ້ວທົດສອບບໍ່ກົງກັບຕະຫຼາດແທ້
   long marginMode=(long)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("ຄຳເຕືອນ: ບັນຊີນີ້ບໍ່ແມ່ນ Hedging (mode=",marginMode,
            "). EA ນີ້ອອກແບບມາສຳລັບ Hedging — ໃນ Strategy Tester ໃຫ້ເລືອກ 'Hedging' ໃນການຕັ້ງຄ່າທົດສອບ.");

   OpenInitialOrders();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+

void OnTick()
{
   if(stopTrading) return;

   CheckDailyProfit();

   MaintainBuyGrid();
   MaintainSellGrid();

   if(BuySidePoints()>=SideTargetProfitPoints)
      ResetBuySide();

   if(SellSidePoints()>=SideTargetProfitPoints)
      ResetSellSide();
}

//+------------------------------------------------------------------+

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(stopTrading) return;

   MaintainBuyGrid();
   MaintainSellGrid();
}