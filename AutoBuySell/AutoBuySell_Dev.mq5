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
input int GridDistancePoints = 100;
input double LotIncrement = 0.001;
input int SideTargetProfitMoney = 2;

// ປ່ຽນເປັນ % ຂອງພອດ
input double DailyProfitTargetPercent = 10.0; 
input double DailyLossLimitPercent = 100.0;   

input int SlippagePoints = 20;
input int MagicBuy = 11001;
input int MagicSell = 11002;

// MACD filter (trade only when MACD is near zero)
input double MacdAbsMax = 3.0;     // Trade only when -MacdAbsMax < MACD < MacdAbsMax (M1, M5 & M15)
input int MacdFastEMA = 12;
input int MacdSlowEMA = 26;
input int MacdSignalSMA = 9;
input bool MacdUseClosedCandle = true; // true=use shift=1 (more stable), false=shift=0
input int MacdSLDistancePoints = 500;  // when MACD is strongly trending, set SL relative to latest leg price

// Trading hours (Bangkok timezone, GMT+7)
input bool UseTradingHours = true;
input int TradeStartHourBkk = 5;  // inclusive
input int TradeEndHourBkk = 18;   // exclusive (18:00 is not traded)

//--------------------------- Globals -------------------------------
datetime g_todayStart = 0;
bool g_stopToday = false;
bool g_stopByMacd = false;
int g_macdHandleM1 = INVALID_HANDLE;
int g_macdHandleM5 = INVALID_HANDLE;
int g_macdHandleM15 = INVALID_HANDLE;
bool g_stopByTime = false;

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

//-------------------- Close helpers (EA only) ----------------------
void CloseAllEaPositionsAndPendings() {
   // Close positions (BUY+SELL) for this EA on this symbol
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if (mg != MagicBuy && mg != MagicSell) continue;
      trade.PositionClose(tk);
   }

   // Delete pendings for this EA on this symbol
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong tk = OrderGetTicket(i);
      if (!OrderSelect(tk)) continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      long mg = OrderGetInteger(ORDER_MAGIC);
      if (mg != MagicBuy && mg != MagicSell) continue;
      trade.OrderDelete(tk);
   }
}

//-------------------- MACD filter helpers --------------------------
bool ReadMacdMain(const int handle, const int shift, double &valueOut) {
   if (handle == INVALID_HANDLE) return false;
   double buff[1];
   if (CopyBuffer(handle, 0, shift, 1, buff) != 1) return false; // buffer 0 = MODE_MAIN
   valueOut = buff[0];
   return true;
}

bool GetMacdValues(double &m1Out, double &m5Out, double &m15Out) {
   const int shift = (MacdUseClosedCandle ? 1 : 0);
   if (!ReadMacdMain(g_macdHandleM1, shift, m1Out)) return false;
   if (!ReadMacdMain(g_macdHandleM5, shift, m5Out)) return false;
   if (!ReadMacdMain(g_macdHandleM15, shift, m15Out)) return false;
   return true;
}

bool IsMacdInRange() {
   double m1 = 0.0, m5 = 0.0, m15 = 0.0;
   if (!GetMacdValues(m1, m5, m15)) return true; // fail-open
   return (MathAbs(m1) < MacdAbsMax && MathAbs(m5) < MacdAbsMax && MathAbs(m15) < MacdAbsMax);
}

void CloseEaSidePositionsAndPendings(const int magic) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      trade.PositionClose(tk);
   }

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong tk = OrderGetTicket(i);
      if (!OrderSelect(tk)) continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if ((int)OrderGetInteger(ORDER_MAGIC) != magic) continue;
      trade.OrderDelete(tk);
   }
}

bool FindLatestOpenPriceBySide(const int magic, double &priceOut) {
   datetime latest = 0;
   double latestPrice = 0.0;
   bool found = false;

   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      if (!found || t > latest) {
         latest = t;
         latestPrice = p;
         found = true;
      }
   }

   if (!found) return false;
   priceOut = latestPrice;
   return true;
}

void SetStopLossForSidePositions(const int magic, const double slPrice) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double tp = PositionGetDouble(POSITION_TP);
      trade.PositionModify(tk, NormalizeDouble(slPrice, DigitsCount()), tp);
   }
}

bool IsWithinBangkokTradingHours() {
   if (!UseTradingHours) return true;

   const datetime bkk = TimeGMT() + 7 * 3600;
   MqlDateTime dt;
   TimeToStruct(bkk, dt);

   const int h = dt.hour;
   const int startH = TradeStartHourBkk;
   const int endH = TradeEndHourBkk;

   if (startH == endH) return false; // no trading window
   if (startH < endH) return (h >= startH && h < endH);

   // window crosses midnight, e.g. 22 -> 5
   return (h >= startH || h < endH);
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
   g_stopByMacd = false;
   g_stopByTime = false;

   g_macdHandleM1 = iMACD(_Symbol, PERIOD_M1, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);
   g_macdHandleM5 = iMACD(_Symbol, PERIOD_M5, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);
   g_macdHandleM15 = iMACD(_Symbol, PERIOD_M15, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);
   
   // Do NOT open immediately. Wait until gates are satisfied (handled on ticks).
   
   return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   if (g_macdHandleM1 != INVALID_HANDLE) IndicatorRelease(g_macdHandleM1);
   if (g_macdHandleM5 != INVALID_HANDLE) IndicatorRelease(g_macdHandleM5);
   if (g_macdHandleM15 != INVALID_HANDLE) IndicatorRelease(g_macdHandleM15);
}

void OnTick() {
   // 1. Reset ມື້ໃໝ່
   datetime d = iTime(_Symbol, PERIOD_D1, 0);
   if (d != g_todayStart) { g_todayStart = d; g_stopToday = false; }

   // 1.4 Trading hours gate (Bangkok)
   if (!IsWithinBangkokTradingHours()) {
      if (!g_stopByTime) {
         CloseAllEaPositionsAndPendings();
         g_stopByTime = true;
         Print("Outside trading hours (Bangkok). Pausing EA until within time window.");
      }
      return;
   } else {
      g_stopByTime = false;
   }

   // 1.5 MACD filter gate (M1 & M5): outside range => close all EA orders and pause
   if (!IsMacdInRange()) {
      if (!g_stopByMacd) {
         // When MACD strongly trends in one direction on ALL TFs (M1, M5, M15),
         // close the opposing side and protect the remaining side with SL.
         double m1 = 0.0, m5 = 0.0, m15 = 0.0;
         if (!GetMacdValues(m1, m5, m15)) {
            CloseAllEaPositionsAndPendings();
            g_stopByMacd = true;
            Print("MACD unavailable. Pausing EA until MACD returns.");
            return;
         }

         const bool allAbove = (m1 > MacdAbsMax && m5 > MacdAbsMax && m15 > MacdAbsMax);
         const bool allBelow = (m1 < -MacdAbsMax && m5 < -MacdAbsMax && m15 < -MacdAbsMax);

         if (allAbove) {
            // Up momentum: close BUY side, keep SELL side but set SL above latest SELL open price + distance
            CloseEaSidePositionsAndPendings(MagicBuy);
            double latestSell = 0.0;
            if (FindLatestOpenPriceBySide(MagicSell, latestSell)) {
               double sl = latestSell + (MacdSLDistancePoints * PointValue());
               SetStopLossForSidePositions(MagicSell, sl);
            }
            g_stopByMacd = true;
            Print("MACD > +", MacdAbsMax, " on M1/M5/M15. Closed BUY side and set SL on SELL side.");
         } else if (allBelow) {
            // Down momentum: close SELL side, keep BUY side but set SL below latest BUY open price - distance
            CloseEaSidePositionsAndPendings(MagicSell);
            double latestBuy = 0.0;
            if (FindLatestOpenPriceBySide(MagicBuy, latestBuy)) {
               double sl = latestBuy - (MacdSLDistancePoints * PointValue());
               SetStopLossForSidePositions(MagicBuy, sl);
            }
            g_stopByMacd = true;
            Print("MACD < -", MacdAbsMax, " on M1/M5/M15. Closed SELL side and set SL on BUY side.");
         } else {
            // Mixed direction or only some TFs are trending: fallback to original behavior
            CloseAllEaPositionsAndPendings();
            g_stopByMacd = true;
            Print("MACD out of range (mixed). Pausing EA until MACD returns to range.");
         }
      }
      return;
   } else {
      // back in range -> allow EA to run again
      g_stopByMacd = false;
   }

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

   // 4. Check Side TP (Money)

   // Buy Side Reset
   double bMoney = 0; int bCount = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicBuy) {
         bMoney += PositionGetDouble(POSITION_PROFIT);
         bMoney += PositionGetDouble(POSITION_SWAP);
         bCount++;
      }
   }
   if(bMoney >= (double)SideTargetProfitMoney && bCount > 0) {
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
   double sMoney = 0; int sCount = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==MagicSell) {
         sMoney += PositionGetDouble(POSITION_PROFIT);
         sMoney += PositionGetDouble(POSITION_SWAP);
         sCount++;
      }
   }
   if(sMoney >= (double)SideTargetProfitMoney && sCount > 0) {
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