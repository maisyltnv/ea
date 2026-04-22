//+------------------------------------------------------------------+
//|                                                     3EMA.mq5     |
//|  Buy-only EMA stack + MACD gate with EMA50 trailing              |
// ພອດ  500 ທົດສອບ 2025-22/4/2026 ໄດ້ກຳໄລ 474 ລວມເປັນ 970
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs --------------------------------
input double Lots = 0.01;
input int SlippagePoints = 20;
input int MagicNumber = 33001;

input int EmaFastPeriod = 14;
input int EmaMidPeriod  = 26;
input int EmaSlowPeriod = 50;

input int MacdFastEMA = 12;
input int MacdSlowEMA = 26;
input int MacdSignalSMA = 9;
input double MacdMainMin = 3.0; // enter only when MACD(main) > this (M1)

input int StopLossPoints = 1000;
input int ProfitToTrailPoints = 2000; // when profit reaches this, SL moves to EMA50 and trails

//--------------------------- Globals -------------------------------
datetime g_todayStart = 0;
bool g_stopForToday = false;

int g_emaFastHandle = INVALID_HANDLE;
int g_emaMidHandle  = INVALID_HANDLE;
int g_emaSlowHandle = INVALID_HANDLE;
int g_macdHandle    = INVALID_HANDLE;

//--------------------------- Helpers -------------------------------
double PointValue() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

bool ReadBuffer1(const int handle, const int bufferIndex, const int shift, double &valueOut) {
   if (handle == INVALID_HANDLE) return false;
   double buff[1];
   if (CopyBuffer(handle, bufferIndex, shift, 1, buff) != 1) return false;
   valueOut = buff[0];
   return true;
}

bool HasOpenBuyPosition(ulong &ticketOut) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      ticketOut = tk;
      return true;
   }
   return false;
}

double ClampBuyStopLoss(double desiredSl) {
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double pt = PointValue();
   const int stopsLevelPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = (double)stopsLevelPts * pt;

   // SL must be below bid and at least stops level away
   double sl = desiredSl;
   if (sl >= bid - minDist) sl = bid - minDist - (2.0 * pt);
   return NormalizeDouble(sl, DigitsCount());
}

//------------------------------ MT5 Events -------------------------
int OnInit() {
   g_todayStart = iTime(_Symbol, PERIOD_D1, 0);
   g_stopForToday = false;

   g_emaFastHandle = iMA(_Symbol, PERIOD_M1, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaMidHandle  = iMA(_Symbol, PERIOD_M1, EmaMidPeriod,  0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, PERIOD_M1, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_macdHandle    = iMACD(_Symbol, PERIOD_M1, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if (g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if (g_emaMidHandle  != INVALID_HANDLE) IndicatorRelease(g_emaMidHandle);
   if (g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if (g_macdHandle    != INVALID_HANDLE) IndicatorRelease(g_macdHandle);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
   // When our position is closed (by SL or trailing or anything), stop trading for the day.
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (trans.symbol != _Symbol) return;

   ulong deal = trans.deal;
   if (deal == 0) return;

   if (!HistoryDealSelect(deal)) return;
   if ((int)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if (entry != DEAL_ENTRY_OUT) return;

   g_stopForToday = true;
}

void OnTick() {
   // Reset new day
   datetime d = iTime(_Symbol, PERIOD_D1, 0);
   if (d != g_todayStart) {
      g_todayStart = d;
      g_stopForToday = false;
   }

   ulong posTicket = 0;
   const bool hasPos = HasOpenBuyPosition(posTicket);

   // Trailing logic (EMA50 trailing after profit threshold)
   if (hasPos) {
      if (!PositionSelectByTicket(posTicket)) return;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double pt = PointValue();
      const double profitPts = (bid - openPrice) / pt;

      double emaSlow = 0.0;
      if (profitPts >= (double)ProfitToTrailPoints && ReadBuffer1(g_emaSlowHandle, 0, 1, emaSlow)) {
         double currentSl = PositionGetDouble(POSITION_SL);
         double desiredSl = ClampBuyStopLoss(emaSlow);

         // Only raise SL (never lower)
         if (currentSl <= 0.0 || desiredSl > currentSl + (0.5 * pt)) {
            double tp = PositionGetDouble(POSITION_TP);
            trade.PositionModify(posTicket, desiredSl, tp);
         }
      }

      return; // only one position at a time
   }

   if (g_stopForToday) return;

   // Entry condition on M1 closed candle
   const int shift = 1;
   const double close1 = iClose(_Symbol, PERIOD_M1, shift);
   if (close1 <= 0.0) return;

   double emaFast = 0.0, emaMid = 0.0, emaSlow = 0.0, macdMain = 0.0;
   if (!ReadBuffer1(g_emaFastHandle, 0, shift, emaFast)) return;
   if (!ReadBuffer1(g_emaMidHandle,  0, shift, emaMid))  return;
   if (!ReadBuffer1(g_emaSlowHandle, 0, shift, emaSlow)) return;
   if (!ReadBuffer1(g_macdHandle,    0, shift, macdMain)) return; // buffer 0 = main

   if (!(close1 > emaFast && emaFast > emaMid && emaMid > emaSlow)) return;
   if (!(macdMain > MacdMainMin)) return;

   // Place BUY with fixed SL (points)
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = ask - (StopLossPoints * PointValue());
   sl = ClampBuyStopLoss(sl);

   trade.Buy(Lots, _Symbol, 0.0, sl, 0.0);
}

