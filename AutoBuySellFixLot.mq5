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

input double DailyProfitTargetUSD=100; // ກຳໄລຕໍ່ມື້ ເປັນ$
input double DailyLossLimitUSD=300;    // ເສຍຕໍ່ມື້ ເປັນ$

input int MagicBuy=1111;
input int MagicSell=2222;

datetime todayStart;
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

void PlaceBuyPending(double price,double lot)
{
   trade.SetExpertMagicNumber(MagicBuy);
   trade.BuyLimit(lot,price,_Symbol);
}

//+------------------------------------------------------------------+

void PlaceSellPending(double price,double lot)
{
   trade.SetExpertMagicNumber(MagicSell);
   trade.SellLimit(lot,price,_Symbol);
}

//+------------------------------------------------------------------+

void MaintainBuyGrid()
{
   while(CountBuyPendings()<GridLevelsPerSide)
   {
      double base=GetLowestBuyPrice();

      if(base==0)
         base=SymbolInfoDouble(_Symbol,SYMBOL_BID);

      double price=base-GridDistancePoints*PointValue();

      // ເປີດ pending buy ດ້ວຍ lot ຄົງທີ່
      PlaceBuyPending(price,InitialLot);
   }
}

//+------------------------------------------------------------------+

void MaintainSellGrid()
{
   while(CountSellPendings()<GridLevelsPerSide)
   {
      double base=GetHighestSellPrice();

      if(base==0)
         base=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double price=base+GridDistancePoints*PointValue();

      // ເປີດ pending sell ດ້ວຍ lot ຄົງທີ່
      PlaceSellPending(price,InitialLot);
   }
}

//+------------------------------------------------------------------+

void OpenInitialOrders()
{
   trade.SetExpertMagicNumber(MagicBuy);
   trade.Buy(InitialLot);

   trade.SetExpertMagicNumber(MagicSell);
   trade.Sell(InitialLot);

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
   double profit=0;

   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong t=HistoryDealGetTicket(i);

      datetime time=HistoryDealGetInteger(t,DEAL_TIME);

      if(time<todayStart) break;

      profit+=HistoryDealGetDouble(t,DEAL_PROFIT);
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
   todayStart=iTime(_Symbol,PERIOD_D1,0);

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