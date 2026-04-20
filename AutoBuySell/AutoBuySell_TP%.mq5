//+------------------------------------------------------------------+
//|                                               AutoBuySell.mq5    |
//|  Hedge + Grid EA (Immediate Entry on Start & Percent Risk)       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs --------------------------------
input double InitialLot = 0.01;
input int GridLevelsPerSide = 3;
input int GridDistancePoints = 50;
input double LotIncrement = 0.001;
input int SideTargetProfitPoints = 50;

// ປ່ຽນເປັນ % ຂອງພອດ
input double DailyProfitTargetPercent = 10.0; 
input double DailyLossLimitPercent = 100.0;   

input int SlippagePoints = 20;
input int MagicBuy = 11001;
input int MagicSell = 11002;

//--------------------------- Globals -------------------------------
datetime g_todayStart = 0;
bool g_stopToday = false;

//---------------------- Utility / Helpers -------------------------
double PointValue() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double NormalizeLot(double lots) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if (step > 0) lots = MathRound(lots / step) * step;
   return (lots < minv) ? minv : lots;
}

void SetTradeContext(int magic) {
   trade.SetExpertMagicNumber(magic);
   trade.SetDeviationInPoints(SlippagePoints);
}

//-------------------- Positions / Orders ----------------------
int CountPositionsBySide(int magic) {
   int n = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionSelectByTicket(PositionGetTicket(i)) && 
          PositionGetInteger(POSITION_MAGIC) == magic && 
          PositionGetString(POSITION_SYMBOL) == _Symbol) n++;
   }
   return n;
}

int CountPendingsBySide(int magic) {
   int n = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (OrderSelect(OrderGetTicket(i)) && 
          OrderGetInteger(ORDER_MAGIC) == magic && 
          OrderGetString(ORDER_SYMBOL) == _Symbol) n++;
   }
   return n;
}

// ຟັງຊັນສຳລັບເປີດໄມ້ທຳອິດ (ໃຊ້ທັງ OnInit ແລະ OnTick)
void CheckAndOpenInitialTrades() {
   if (g_stopToday) return;

   if (CountPositionsBySide(MagicBuy) == 0 && CountPendingsBySide(MagicBuy) == 0) {
      SetTradeContext(MagicBuy);
      trade.Buy(NormalizeLot(InitialLot), _Symbol);
   }
   
   if (CountPositionsBySide(MagicSell) == 0 && CountPendingsBySide(MagicSell) == 0) {
      SetTradeContext(MagicSell);
      trade.Sell(NormalizeLot(InitialLot), _Symbol);
   }
}

//--------------------------- Grid Logic ----------------------------
void MaintainGrids() {
   if (g_stopToday) return;

   // BUY Grid
   int bPos = CountPositionsBySide(MagicBuy);
   int bPend = CountPendingsBySide(MagicBuy);
   if (bPos > 0 && bPend < GridLevelsPerSide) {
      // ຫາລາຄາໄມ້ Buy ທີ່ຕໍ່າສຸດ
      double lowPrice = 0;
      for (int i = PositionsTotal()-1; i>=0; i--) {
         if (PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC)==MagicBuy) {
            double p = PositionGetDouble(POSITION_PRICE_OPEN);
            if (lowPrice == 0 || p < lowPrice) lowPrice = p;
         }
      }
      // ຖ້າມີ Pending ຢູ່ແລ້ວ ໃຫ້ໄລ່ຈາກລາຄາ Pending ທີ່ຕໍ່າສຸດລົງໄປອີກ
      for (int i = OrdersTotal()-1; i>=0; i--) {
         if (OrderSelect(OrderGetTicket(i)) && OrderGetInteger(ORDER_MAGIC)==MagicBuy) {
            double p = OrderGetDouble(ORDER_PRICE_OPEN);
            if (p < lowPrice) lowPrice = p;
         }
      }

      double price = lowPrice - (GridDistancePoints * PointValue());
      double lot = InitialLot + (LotIncrement * (bPos + bPend));
      SetTradeContext(MagicBuy);
      trade.BuyLimit(NormalizeLot(lot), NormalizeDouble(price, DigitsCount()), _Symbol);
   }

   // SELL Grid
   int sPos = CountPositionsBySide(MagicSell);
   int sPend = CountPendingsBySide(MagicSell);
   if (sPos > 0 && sPend < GridLevelsPerSide) {
      double highPrice = 0;
      for (int i = PositionsTotal()-1; i>=0; i--) {
         if (PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC)==MagicSell) {
            double p = PositionGetDouble(POSITION_PRICE_OPEN);
            if (highPrice == 0 || p > highPrice) highPrice = p;
         }
      }
      for (int i = OrdersTotal()-1; i>=0; i--) {
         if (OrderSelect(OrderGetTicket(i)) && OrderGetInteger(ORDER_MAGIC)==MagicSell) {
            double p = OrderGetDouble(ORDER_PRICE_OPEN);
            if (p > highPrice) highPrice = p;
         }
      }

      double price = highPrice + (GridDistancePoints * PointValue());
      double lot = InitialLot + (LotIncrement * (sPos + sPend));
      SetTradeContext(MagicSell);
      trade.SellLimit(NormalizeLot(lot), NormalizeDouble(price, DigitsCount()), _Symbol);
   }
}

//------------------------------ MT5 Events -------------------------
int OnInit() {
   g_todayStart = iTime(_Symbol, PERIOD_D1, 0);
   g_stopToday = false;
   
   // --- ເປີດອໍເດີທັນທີທີ່ Start EA ---
   CheckAndOpenInitialTrades();
   
   return (INIT_SUCCEEDED);
}

void OnTick() {
   // 1. Reset ມື້ໃໝ່
   datetime d = iTime(_Symbol, PERIOD_D1, 0);
   if (d != g_todayStart) { g_todayStart = d; g_stopToday = false; }

   // 2. Check Daily Stop (Percent based)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double targetMoney = balance * (DailyProfitTargetPercent / 100.0);
   double lossMoney = balance * (DailyLossLimitPercent / 100.0);

   double todayP = 0;
   HistorySelect(g_todayStart, TimeCurrent());
   for(int i = HistoryDealsTotal()-1; i >= 0; i--) {
      ulong tk = HistoryDealGetTicket(i);
      if (tk > 0 && HistoryDealGetString(tk, DEAL_SYMBOL) == _Symbol) 
         todayP += HistoryDealGetDouble(tk, DEAL_PROFIT);
   }

   if (todayP >= targetMoney || todayP <= -lossMoney) {
      if (!g_stopToday) {
         for(int i=PositionsTotal()-1; i>=0; i--) trade.PositionClose(PositionGetTicket(i));
         for(int i=OrdersTotal()-1; i>=0; i--) trade.OrderDelete(OrderGetTicket(i));
         g_stopToday = true;
         Print("Daily Limit Reached. Today Profit: ", todayP);
      }
      return;
   }

   // 3. ຮັກສາອໍເດີ ແລະ Grid
   CheckAndOpenInitialTrades();
   MaintainGrids();

   // 4. Check Side TP (Points)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pVal = PointValue();

   // Buy Side Reset
   double bPts = 0; int bCount = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicBuy) {
         bPts += (bid - PositionGetDouble(POSITION_PRICE_OPEN)) / pVal;
         bCount++;
      }
   }
   if(bPts >= SideTargetProfitPoints && bCount > 0) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong tk = PositionGetTicket(i);
         if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicBuy) trade.PositionClose(tk);
      }
      for(int i=OrdersTotal()-1; i>=0; i--) {
         ulong tk = OrderGetTicket(i);
         if(OrderSelect(tk) && OrderGetInteger(ORDER_MAGIC)==MagicBuy) trade.OrderDelete(tk);
      }
   }

   // Sell Side Reset
   double sPts = 0; int sCount = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicSell) {
         sPts += (PositionGetDouble(POSITION_PRICE_OPEN) - ask) / pVal;
         sCount++;
      }
   }
   if(sPts >= SideTargetProfitPoints && sCount > 0) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong tk = PositionGetTicket(i);
         if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicSell) trade.PositionClose(tk);
      }
      for(int i=OrdersTotal()-1; i>=0; i--) {
         ulong tk = OrderGetTicket(i);
         if(OrderSelect(tk) && OrderGetInteger(ORDER_MAGIC)==MagicSell) trade.OrderDelete(tk);
      }
   }
}