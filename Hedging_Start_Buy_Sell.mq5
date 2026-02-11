//+------------------------------------------------------------------+
//|                                                   LadderFlipEA.mq5|
//|                         Implements Buy/Sell ladder with TP reset  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// -------------------- Inputs --------------------
input double   InpTP_Points      = 200;      // Take Profit in points
input double   InpStep_Points    = 200;      // Distance between orders in points
input long     InpMagic          = 20260211; // Magic number
input double   InpLots1          = 0.01;
input double   InpLots2          = 0.02;
input double   InpLots3          = 0.03;
input double   InpLots4          = 0.05;
input int      InpMaxSteps       = 4;        // 1..4 steps in a cycle (lots list)
input int      InpSlippagePoints = 20;       // max slippage (points) for market orders

// -------------------- State --------------------
enum StartSide { START_BUY=0, START_SELL=1 };

StartSide g_start_side = START_BUY;  // default start side
int       g_step_index = 0;          // 0-based: 0,1,2,3 maps to lots1..lots4

// Last TP winner side (for next cycle)
StartSide g_next_start_side = START_BUY;

// Helper: lots by step
double LotsByStep(int step)
{
   if(step<=0) return InpLots1;
   if(step==1) return InpLots2;
   if(step==2) return InpLots3;
   return InpLots4;
}

double PointsToPrice(double pts) { return pts * _Point; }

// -------------------- Utilities --------------------
bool IsOurPosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   return true;
}

bool IsOurOrder(ulong ticket)
{
   if(!OrderSelect(ticket)) return false;
   if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) return false;
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   return true;
}

int CountOurPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t && PositionSelectByTicket(t))
      {
         if((long)PositionGetInteger(POSITION_MAGIC)==InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
            cnt++;
      }
   }
   return cnt;
}

int CountOurOrders()
{
   int cnt=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t && OrderSelect(t))
      {
         if((long)OrderGetInteger(ORDER_MAGIC)==InpMagic &&
            OrderGetString(ORDER_SYMBOL)==_Symbol)
            cnt++;
      }
   }
   return cnt;
}

void DeleteAllOurPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t && OrderSelect(t))
      {
         if((long)OrderGetInteger(ORDER_MAGIC)==InpMagic &&
            OrderGetString(ORDER_SYMBOL)==_Symbol)
         {
            ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP ||
               type==ORDER_TYPE_BUY_LIMIT|| type==ORDER_TYPE_SELL_LIMIT ||
               type==ORDER_TYPE_BUY_STOP_LIMIT|| type==ORDER_TYPE_SELL_STOP_LIMIT)
            {
               trade.OrderDelete(t);
            }
         }
      }
   }
}

void CloseAllOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t && PositionSelectByTicket(t))
      {
         if((long)PositionGetInteger(POSITION_MAGIC)==InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
         {
            trade.PositionClose(t);
         }
      }
   }
}

void ResetCycle(StartSide next_side)
{
   // Clean everything
   DeleteAllOurPending();
   CloseAllOurPositions();

   // Reset state
   g_start_side = next_side;
   g_step_index = 0;

   // Start again
   // (We call on next tick to avoid dealing with trade transaction ordering)
}

// Place market order for step 0
bool PlaceInitialMarket(StartSide side)
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   double lots = LotsByStep(0);
   double tp   = 0.0;

   double price = (side==START_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(side==START_BUY)
      tp = price + PointsToPrice(InpTP_Points);
   else
      tp = price - PointsToPrice(InpTP_Points);

   bool ok=false;
   if(side==START_BUY) ok = trade.Buy(lots, _Symbol, price, 0.0, tp, "Step0 BUY");
   else                ok = trade.Sell(lots,_Symbol, price, 0.0, tp, "Step0 SELL");

   return ok;
}

// Place the next pending stop based on last triggered entry price and direction
bool PlaceNextPending(double base_entry_price, StartSide next_direction, int next_step)
{
   trade.SetExpertMagicNumber(InpMagic);

   double lots = LotsByStep(next_step);
   double tp   = 0.0;
   double pend_price = 0.0;

   if(next_direction==START_BUY)
   {
      pend_price = base_entry_price + PointsToPrice(InpStep_Points);
      tp         = pend_price + PointsToPrice(InpTP_Points);
      return trade.BuyStop(lots, pend_price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "BUY_STOP");
   }
   else
   {
      pend_price = base_entry_price - PointsToPrice(InpStep_Points);
      tp         = pend_price - PointsToPrice(InpTP_Points);
      return trade.SellStop(lots, pend_price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "SELL_STOP");
   }
}

// Decide what pending should exist based on cycle rules:
// Buy-start cycle: after BUY filled -> place SELL STOP below; after SELL filled -> place BUY STOP above; etc.
// Sell-start cycle: after SELL filled -> place BUY STOP below; after BUY filled -> place SELL STOP above; etc.
StartSide NextPendingSideAfterFill(StartSide filled_side, StartSide start_side)
{
   // In both modes it alternates, BUT the pending distance direction differs:
   // Your spec is effectively "flip to opposite side each time".
   return (filled_side==START_BUY) ? START_SELL : START_BUY;
}

// For price anchoring, always place next pending relative to the entry price of the trade that just got triggered.
bool EnsureNextPendingFromLatestFill()
{
   // If we already have one pending, do nothing
   if(CountOurOrders() > 0) return true;

   // Find the most recently opened position (by time) among our positions
   datetime latest_time=0;
   ulong latest_ticket=0;
   StartSide latest_side=START_BUY;
   double latest_price=0.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t && PositionSelectByTicket(t))
      {
         if((long)PositionGetInteger(POSITION_MAGIC)==InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
         {
            datetime tm=(datetime)PositionGetInteger(POSITION_TIME);
            if(tm > latest_time)
            {
               latest_time=tm;
               latest_ticket=t;
               latest_price=PositionGetDouble(POSITION_PRICE_OPEN);
               ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               latest_side = (pt==POSITION_TYPE_BUY) ? START_BUY : START_SELL;
            }
         }
      }
   }

   if(latest_ticket==0) return false;

   // Next step
   int next_step = g_step_index + 1;
   if(next_step >= InpMaxSteps) next_step = InpMaxSteps-1; // cap at last lot

   StartSide pending_side = NextPendingSideAfterFill(latest_side, g_start_side);

   bool ok = PlaceNextPending(latest_price, pending_side, next_step);
   if(ok) g_step_index = next_step;
   return ok;
}

// -------------------- MT5 Events --------------------
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   g_next_start_side = START_BUY;
   g_start_side = START_BUY;
   g_step_index = 0;
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // If no positions and no pendings => start cycle
   if(CountOurPositions()==0 && CountOurOrders()==0)
   {
      // Start from current g_start_side
      if(PlaceInitialMarket(g_start_side))
      {
         // After initial fill, we will place next pending on subsequent ticks
      }
      return;
   }

   // If we have positions but no pending => place the next pending based on latest fill
   if(CountOurPositions()>0 && CountOurOrders()==0)
   {
      EnsureNextPendingFromLatestFill();
   }
}

// Detect TP hit + decide next start direction
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // We care about deals that close a position (DEAL_ENTRY_OUT)
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;

   if(!HistoryDealSelect(trans.deal)) return;

   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(sym != _Symbol) return;

   long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != InpMagic) return;

   long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT) return;

   long reason = (long)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   // If closed by Take Profit
   if(reason == DEAL_REASON_TP)
   {
      // Determine which side's position hit TP:
      // deal type here is SELL for closing a BUY, BUY for closing a SELL (depends),
      // better read position type from deal's "DEAL_POSITION_ID" but we can infer from profit direction:
      long deal_type = (long)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

      // When a BUY position is closed, the closing deal is usually SELL.
      // When a SELL position is closed, the closing deal is usually BUY.
      StartSide winner = (deal_type==DEAL_TYPE_SELL) ? START_BUY : START_SELL;

      // Set next cycle start based on winner side
      g_next_start_side = winner;

      // Reset everything
      ResetCycle(g_next_start_side);

      // After reset, we need to actually start again (next ticks will do it)
      return;
   }
}
