//+------------------------------------------------------------------+
//|                                             AutoBuySell_TP%.mq5  |
//|                                                                  |
//| ຄຳອະທິບາຍ (ລາວ):                                                   |
//| - EA ແນວ Hedge + Grid: ເມື່ອເລີ່ມຫຼືຕອນທີ່ຝັ່ງໃດຝັ່ງໜຶ່ງບໍ່ມີ Position/Order, |
//|   ຈະເປີດ Market Buy ແລະ Market Sell ທັນທີ (ແຍກ MagicBuy/MagicSell). |
//| - Grid (ບໍ່ໃຊ້ SL/TP ຕໍ່ກະຕ່າ):                                    |
//|   - BUY: ຖ້າມີ Buy positions ແລະ pending < GridLevelsPerSide ຈະວາງ BuyLimit |
//|     ຕໍ່າກວ່າລາຄາຕໍ່າສຸດ (ລາຄາ Position/Pending) ຫ່າງ GridDistancePoints. |
//|   - SELL: ຖ້າມີ Sell positions ແລະ pending < GridLevelsPerSide ຈະວາງ SellLimit |
//|     ສູງກວ່າລາຄາສູງສຸດ (ລາຄາ Position/Pending) ຫ່າງ GridDistancePoints. |
//|   - Lot ຂອງ grid ເພີ່ມຕາມ InitialLot + LotIncrement*(จำนวน pos+pending). |
//| - Daily Stop (% ຂອງ Balance): ຄິດກຳໄລ/ຂາດທຶນຂອງມື້ນີ້ຈາກ History deals.      |
//|   ຖ້າຮອດ DailyProfitTargetPercent ຫຼື DailyLossLimitPercent ຈະປິດ Position |
//|   ແລະລຶບ Pending (ແລ້ວຢຸດທັງມື້). ໝາຍເຫດ: ໂຄ້ດປິດ/ລຶບແບບລວມທົ່ວ account. |
//| - Side Target Profit (Points): ລວມ points ຂອງ positions ຝັ່ງນັ້ນ; ຖ້າ >=      |
//|   SideTargetProfitPoints ຈະປິດ positions + ລຶບ pendings ຂອງ magic ຝັ່ງນັ້ນ.  |
//|                                                                  |
//| Summary (EN): Immediate hedge entry (Buy+Sell) when a side is     |
//| flat; maintains buy-limit grid below lowest price and sell-limit  |
//| grid above highest price; daily % profit/loss lockout; per-side   |
//| point basket take-profit closes that side's orders.               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Hedge+Grid EA with daily % lockout + per-side point TP. Opens Buy+Sell when side is flat; maintains BuyLimit/SellLimit grids; closes positions/pendings on targets."

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs --------------------------------
input double InitialLot = 0.01;
input int GridLevelsPerSide = 3;
input int GridDistancePoints = 50;
input double LotIncrement = 0.001;
input int SideTargetProfitPoints = 50;
input int StopLossAllPoints = 500; // SL for every order (market & pending), points from its entry price

// ປ່ຽນເປັນ % ຂອງພອດ
input double DailyProfitTargetPercent = 3.0; 
input double DailyLossLimitPercent = 10.0;   

input int SlippagePoints = 20;
input int MagicBuy = 11001;
input int MagicSell = 11002;

//--------------------------- Globals -------------------------------
datetime g_todayStart = 0;
bool g_stopToday = false;

//---------------------- Utility / Helpers -------------------------
double PointValue() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
double NormPrice(double p) { return NormalizeDouble(p, DigitsCount()); }

bool RespectStopsDistance(const bool isBuy, const double entry, const double slPrice) {
   const double pt = PointValue();
   if (pt <= 0) return false;
   const int lvl = StopsLevelPoints();
   const double minDist = (double)lvl * pt;
   if (minDist <= 0) return true;
   if (slPrice <= 0) return true;
   if (isBuy) return (entry - slPrice) >= (minDist - 1e-10);
   return (slPrice - entry) >= (minDist - 1e-10);
}

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

// Ensure all EA orders (this symbol + magic) have SL = StopLossAllPoints from their own entry
void EnsureSLForSide(const int magic, const bool isBuy) {
   if (StopLossAllPoints <= 0) return;
   const double pt = PointValue();
   if (pt <= 0) return;
   const int digits = DigitsCount();

   // Market positions
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      const int typ = (int)PositionGetInteger(POSITION_TYPE);
      if (isBuy && typ != POSITION_TYPE_BUY) continue;
      if (!isBuy && typ != POSITION_TYPE_SELL) continue;

      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);
      const double wantSL = NormalizeDouble(open + (isBuy ? -1.0 : 1.0) * (double)StopLossAllPoints * pt, digits);
      if (curSL > 0 && MathAbs(curSL - wantSL) < (pt * 0.1)) continue;
      if (!RespectStopsDistance(isBuy, open, wantSL)) continue;

      SetTradeContext(magic);
      trade.PositionModify(tk, wantSL, curTP);
   }

   // Pending orders (grid limits)
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ot = OrderGetTicket(i);
      if (!OrderSelect(ot)) continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if ((int)OrderGetInteger(ORDER_MAGIC) != magic) continue;

      const int otyp = (int)OrderGetInteger(ORDER_TYPE);
      if (isBuy && otyp != ORDER_TYPE_BUY_LIMIT) continue;
      if (!isBuy && otyp != ORDER_TYPE_SELL_LIMIT) continue;

      const double price = OrderGetDouble(ORDER_PRICE_OPEN);
      const double curSL = OrderGetDouble(ORDER_SL);
      const double curTP = OrderGetDouble(ORDER_TP);
      const double wantSL = NormalizeDouble(price + (isBuy ? -1.0 : 1.0) * (double)StopLossAllPoints * pt, digits);
      if (curSL > 0 && MathAbs(curSL - wantSL) < (pt * 0.1)) continue;
      if (!RespectStopsDistance(isBuy, price, wantSL)) continue;

      SetTradeContext(magic);
      ENUM_ORDER_TYPE_TIME ttype = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      trade.OrderModify(ot, price, wantSL, curTP, ttype, exp);
   }
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
      double sl = 0.0;
      if (StopLossAllPoints > 0) {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         sl = NormPrice(ask - (double)StopLossAllPoints * PointValue());
         if (!RespectStopsDistance(true, ask, sl)) sl = 0.0;
      }
      trade.Buy(NormalizeLot(InitialLot), _Symbol, 0.0, sl, 0.0);
   }
   
   if (CountPositionsBySide(MagicSell) == 0 && CountPendingsBySide(MagicSell) == 0) {
      SetTradeContext(MagicSell);
      double sl = 0.0;
      if (StopLossAllPoints > 0) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         sl = NormPrice(bid + (double)StopLossAllPoints * PointValue());
         if (!RespectStopsDistance(false, bid, sl)) sl = 0.0;
      }
      trade.Sell(NormalizeLot(InitialLot), _Symbol, 0.0, sl, 0.0);
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
      double p = NormalizeDouble(price, DigitsCount());
      double sl = 0.0;
      if (StopLossAllPoints > 0) {
         sl = NormPrice(p - (double)StopLossAllPoints * PointValue());
         if (!RespectStopsDistance(true, p, sl)) sl = 0.0;
      }
      trade.BuyLimit(NormalizeLot(lot), p, _Symbol, sl, 0.0);
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
      double p = NormalizeDouble(price, DigitsCount());
      double sl = 0.0;
      if (StopLossAllPoints > 0) {
         sl = NormPrice(p + (double)StopLossAllPoints * PointValue());
         if (!RespectStopsDistance(false, p, sl)) sl = 0.0;
      }
      trade.SellLimit(NormalizeLot(lot), p, _Symbol, sl, 0.0);
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
   // 3.1 Ensure every EA order has SL (market & pending, both sides)
   EnsureSLForSide(MagicBuy, true);
   EnsureSLForSide(MagicSell, false);

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