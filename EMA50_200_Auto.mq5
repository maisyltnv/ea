//+------------------------------------------------------------------+
//|                                                EMA50_200_Auto.mq5 |
//| XAUUSD M1 - EMA Grid Auto                                        |
//| Rules: EMA14/26/50/100/200 stack + grid pending orders            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA14/26/50/100/200 stack entry; first market then grid pending. Uses last closed candle only."

#include <Trade/Trade.mqh>

//--------------------------- Inputs ---------------------------------
input string         TradeSymbol                 = "";         // empty = current chart symbol
input ENUM_TIMEFRAMES Timeframe                  = PERIOD_M1;  // signal timeframe
input long           MagicNumber                 = 505200;     // magic
input double         InitialLot                  = 0.01;
input double         LotStep                     = 0.01;
input int            GridDistancePoints          = 300;
input int            EntryOffsetPoints           = 0;
input int            SLBufferPoints              = 100;
input int            TPPoints                    = 2000;
input int            MaxGridOrders               = 5;          // number of pending grid orders (excluding first market)
input int            MaxSpreadPoints             = 1000;
input int            SlippagePoints              = 50;
input bool           AllowBuy                    = true;
input bool           AllowSell                   = true;
input bool           OneCycleAtATime             = true;
input bool           DebugMode                   = true;
input bool           DeletePendingOnOppositeSignal = false;    // optional

// Daily stop (server day)
input bool           UseDailyStop                = true;
input int            StopAfterConsecutiveSL      = 2;          // stop trading for the day after N consecutive SL
input bool           StopAfterTPOnce             = true;       // stop trading for the day after 1 TP

//--------------------------- Globals --------------------------------
CTrade trade;
string Sym;

int hEma14  = INVALID_HANDLE;
int hEma26  = INVALID_HANDLE;
int hEma50  = INVALID_HANDLE;
int hEma100 = INVALID_HANDLE;
int hEma200 = INVALID_HANDLE;

datetime g_lastBarTime = 0;
datetime g_lastDbgBarTime = 0;

// cycle state (set when first market order opens)
bool   g_cycleActive = false;
int    g_cycleDir    = 0;     //  1=BUY, -1=SELL
double g_firstEntry  = 0.0;
double g_cycleSL     = 0.0;
double g_cycleTP     = 0.0;

// daily stop state (persisted in Global Variables)
int    g_dayKey        = 0;     // yyyymmdd server day
int    g_slStreak      = 0;     // consecutive SL count
bool   g_blockedToday  = false;

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(Sym, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS); }
double Np(const double p) { return NormalizeDouble(p, DigitsCount()); }
int StopsLevelPoints() { return (int)SymbolInfoInteger(Sym, SYMBOL_TRADE_STOPS_LEVEL); }

int DayKeyNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

string GvPrefix()
{
   return "EMA50_200_Auto." + Sym + "." + (string)MagicNumber + ".";
}

void SaveDailyState()
{
   if(!UseDailyStop) return;
   const string p = GvPrefix();
   GlobalVariableSet(p + "day", (double)g_dayKey);
   GlobalVariableSet(p + "slStreak", (double)g_slStreak);
   GlobalVariableSet(p + "blocked", g_blockedToday ? 1.0 : 0.0);
}

void LoadDailyState()
{
   if(!UseDailyStop) return;
   const string p = GvPrefix();
   if(GlobalVariableCheck(p + "day"))      g_dayKey = (int)GlobalVariableGet(p + "day");
   else                                   g_dayKey = DayKeyNow();
   if(GlobalVariableCheck(p + "slStreak")) g_slStreak = (int)GlobalVariableGet(p + "slStreak");
   else                                   g_slStreak = 0;
   if(GlobalVariableCheck(p + "blocked"))  g_blockedToday = (GlobalVariableGet(p + "blocked") > 0.5);
   else                                   g_blockedToday = false;
}

void ResetDailyStateIfNewDay()
{
   if(!UseDailyStop) return;
   const int dk = DayKeyNow();
   if(g_dayKey != dk)
   {
      g_dayKey = dk;
      g_slStreak = 0;
      g_blockedToday = false;
      SaveDailyState();
      if(DebugMode) Print("DailyStop reset: new day ", g_dayKey);
   }
}

void DbgOncePerBar(const string msg)
{
   if(!DebugMode) return;
   datetime t[1];
   if(CopyTime(Sym, Timeframe, 0, 1, t) != 1) return;
   if(t[0] == g_lastDbgBarTime) return;
   g_lastDbgBarTime = t[0];
   Print(msg);
}

bool IsNewBar()
{
   datetime t[1];
   if(CopyTime(Sym, Timeframe, 0, 1, t) != 1) return false;
   if(t[0] != g_lastBarTime)
   {
      g_lastBarTime = t[0];
      return true;
   }
   return false;
}

bool SpreadOK()
{
   long spread = SymbolInfoInteger(Sym, SYMBOL_SPREAD);
   return (spread > 0 && spread <= MaxSpreadPoints);
}

double NormalizeLot(double lots)
{
   double step = SymbolInfoDouble(Sym, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MAX);

   double v = lots;
   if(step > 0.0) v = MathFloor(v / step) * step;
   if(v < minv) v = minv;
   if(maxv > 0.0 && v > maxv) v = maxv;

   // try to keep decent precision
   return NormalizeDouble(v, 2);
}

bool ReadBuf1(const int h, const int shift, double &out)
{
   if(h == INVALID_HANDLE) return false;
   double b[1];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return false;
   out = b[0];
   return true;
}

bool GetEmaValues(const int shift, double &ema14, double &ema26, double &ema50, double &ema100, double &ema200)
{
   return ReadBuf1(hEma14, shift, ema14) &&
          ReadBuf1(hEma26, shift, ema26) &&
          ReadBuf1(hEma50, shift, ema50) &&
          ReadBuf1(hEma100, shift, ema100) &&
          ReadBuf1(hEma200, shift, ema200);
}

bool GetLastClosedCandle(MqlRates &bar)
{
   MqlRates r[2];
   ArraySetAsSeries(r, true);
   if(CopyRates(Sym, Timeframe, 0, 2, r) != 2) return false;
   bar = r[1]; // last closed
   return true;
}

int CountOurPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != Sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      cnt++;
   }
   return cnt;
}

int CountOurOrders()
{
   int cnt = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(!OrderSelect(tk)) continue;
      if(OrderGetString(ORDER_SYMBOL) != Sym) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT) cnt++;
   }
   return cnt;
}

bool HasAnyCycleObjects()
{
   return (CountOurPositions() > 0 || CountOurOrders() > 0);
}

void DeleteOurPendingOrders()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(!OrderSelect(tk)) continue;
      if(OrderGetString(ORDER_SYMBOL) != Sym) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_SELL_LIMIT) continue;
      trade.OrderDelete(tk);
   }
}

bool RespectStopsForMarketSLTP(const bool isBuy, const double sl, const double tp)
{
   const double pt = Pt();
   if(pt <= 0.0) return false;
   int lvl = StopsLevelPoints();
   if(lvl <= 0) return true;
   const double minDist = (double)lvl * pt;
   const double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);

   if(isBuy)
   {
      if(sl > 0.0 && (bid - sl) < (minDist - 1e-10)) return false;
      if(tp > 0.0 && (tp - ask) < (minDist - 1e-10)) return false;
   }
   else
   {
      if(sl > 0.0 && (sl - ask) < (minDist - 1e-10)) return false;
      if(tp > 0.0 && (bid - tp) < (minDist - 1e-10)) return false;
   }
   return true;
}

bool RespectStopsForPending(const ENUM_ORDER_TYPE pendingType, const double price, const double sl, const double tp)
{
   const double pt = Pt();
   if(pt <= 0.0) return false;
   int lvl = StopsLevelPoints();
   if(lvl <= 0) return true;
   const double minDist = (double)lvl * pt;
   const double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);

   if(pendingType == ORDER_TYPE_BUY_LIMIT)
   {
      if((ask - price) < (minDist - 1e-10)) return false;
      if(sl > 0.0 && (price - sl) < (minDist - 1e-10)) return false;
      if(tp > 0.0 && (tp - price) < (minDist - 1e-10)) return false;
   }
   else if(pendingType == ORDER_TYPE_SELL_LIMIT)
   {
      if((price - bid) < (minDist - 1e-10)) return false;
      if(sl > 0.0 && (sl - price) < (minDist - 1e-10)) return false;
      if(tp > 0.0 && (price - tp) < (minDist - 1e-10)) return false;
   }
   return true;
}

string CycleComment(const string side)
{
   return "EMA50_200_Auto " + side;
}

//--------------------------- Signals --------------------------------
bool BuildSignals(bool &buySignal, bool &sellSignal,
                  double &close1,
                  double &ema14, double &ema26, double &ema50, double &ema100, double &ema200)
{
   buySignal = false;
   sellSignal = false;

   MqlRates bar;
   if(!GetLastClosedCandle(bar)) return false;
   close1 = bar.close;

   // Use last closed candle only
   const int sh = 1;
   if(!GetEmaValues(sh, ema14, ema26, ema50, ema100, ema200)) return false;

   const double pt = Pt();
   if(pt <= 0.0) return false;

   buySignal =
      AllowBuy &&
      (close1 > (ema14 + (double)EntryOffsetPoints * pt)) &&
      (ema14 > ema26) &&
      (ema26 > ema50) &&
      (ema50 > ema100) &&
      (ema100 > ema200);

   sellSignal =
      AllowSell &&
      (close1 < (ema14 - (double)EntryOffsetPoints * pt)) &&
      (ema14 < ema26) &&
      (ema26 < ema50) &&
      (ema50 < ema100) &&
      (ema100 < ema200);

   return true;
}

//--------------------------- Cycle Open ------------------------------
bool OpenFirstBuy(const double ema200)
{
   const double pt = Pt();
   if(pt <= 0.0) return false;

   const double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);
   const double entry = ask;
   const double sl = Np(ema200 - (double)SLBufferPoints * pt);
   const double tp = Np(entry + (double)TPPoints * pt);

   if(!RespectStopsForMarketSLTP(true, sl, tp))
   {
      DbgOncePerBar(StringFormat("BUY blocked: stops-level. entry=%.5f sl=%.5f tp=%.5f", entry, sl, tp));
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool ok = trade.Buy(NormalizeLot(InitialLot), Sym, 0.0, sl, tp, CycleComment("BUY"));
   if(!ok)
   {
      Print(StringFormat("BUY failed. ret=%d err=%d", (int)trade.ResultRetcode(), (int)GetLastError()));
      return false;
   }

   g_cycleActive = true;
   g_cycleDir = 1;
   g_firstEntry = entry;
   g_cycleSL = sl;
   g_cycleTP = tp;

   if(DebugMode)
      Print(StringFormat("First BUY opened. entry=%.5f sl=%.5f tp=%.5f lot=%.2f",
                         entry, sl, tp, NormalizeLot(InitialLot)));

   return true;
}

bool OpenFirstSell(const double ema200)
{
   const double pt = Pt();
   if(pt <= 0.0) return false;

   const double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   const double entry = bid;
   const double sl = Np(ema200 + (double)SLBufferPoints * pt);
   const double tp = Np(entry - (double)TPPoints * pt);

   if(!RespectStopsForMarketSLTP(false, sl, tp))
   {
      DbgOncePerBar(StringFormat("SELL blocked: stops-level. entry=%.5f sl=%.5f tp=%.5f", entry, sl, tp));
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   bool ok = trade.Sell(NormalizeLot(InitialLot), Sym, 0.0, sl, tp, CycleComment("SELL"));
   if(!ok)
   {
      Print(StringFormat("SELL failed. ret=%d err=%d", (int)trade.ResultRetcode(), (int)GetLastError()));
      return false;
   }

   g_cycleActive = true;
   g_cycleDir = -1;
   g_firstEntry = entry;
   g_cycleSL = sl;
   g_cycleTP = tp;

   if(DebugMode)
      Print(StringFormat("First SELL opened. entry=%.5f sl=%.5f tp=%.5f lot=%.2f",
                         entry, sl, tp, NormalizeLot(InitialLot)));

   return true;
}

void PlaceBuyGrid(const double ema200)
{
   if(!g_cycleActive || g_cycleDir != 1) return;
   const double pt = Pt();
   if(pt <= 0.0) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   for(int i = 1; i <= MaxGridOrders; i++)
   {
      double price = Np(g_firstEntry - (double)GridDistancePoints * pt * (double)i);
      if(price <= ema200) break; // must stay strictly above EMA200

      double lot = NormalizeLot(InitialLot + LotStep * (double)i);
      ENUM_ORDER_TYPE ot = ORDER_TYPE_BUY_LIMIT;

      if(!RespectStopsForPending(ot, price, g_cycleSL, g_cycleTP))
      {
         if(DebugMode)
            Print(StringFormat("Skip BUY LIMIT (stops-level). i=%d price=%.5f lot=%.2f sl=%.5f tp=%.5f",
                               i, price, lot, g_cycleSL, g_cycleTP));
         continue;
      }

      bool ok = trade.BuyLimit(lot, price, Sym, g_cycleSL, g_cycleTP, ORDER_TIME_GTC, 0, CycleComment("BUYGRID"));
      if(!ok)
      {
         Print(StringFormat("BuyLimit failed. i=%d price=%.5f lot=%.2f ret=%d err=%d",
                            i, price, lot, (int)trade.ResultRetcode(), (int)GetLastError()));
      }
      else if(DebugMode)
      {
         Print(StringFormat("Placed BUY LIMIT i=%d price=%.5f lot=%.2f sl=%.5f tp=%.5f",
                            i, price, lot, g_cycleSL, g_cycleTP));
      }
   }
}

void PlaceSellGrid(const double ema200)
{
   if(!g_cycleActive || g_cycleDir != -1) return;
   const double pt = Pt();
   if(pt <= 0.0) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   for(int i = 1; i <= MaxGridOrders; i++)
   {
      double price = Np(g_firstEntry + (double)GridDistancePoints * pt * (double)i);
      if(price >= ema200) break; // must stay strictly below EMA200

      double lot = NormalizeLot(InitialLot + LotStep * (double)i);
      ENUM_ORDER_TYPE ot = ORDER_TYPE_SELL_LIMIT;

      if(!RespectStopsForPending(ot, price, g_cycleSL, g_cycleTP))
      {
         if(DebugMode)
            Print(StringFormat("Skip SELL LIMIT (stops-level). i=%d price=%.5f lot=%.2f sl=%.5f tp=%.5f",
                               i, price, lot, g_cycleSL, g_cycleTP));
         continue;
      }

      bool ok = trade.SellLimit(lot, price, Sym, g_cycleSL, g_cycleTP, ORDER_TIME_GTC, 0, CycleComment("SELLGRID"));
      if(!ok)
      {
         Print(StringFormat("SellLimit failed. i=%d price=%.5f lot=%.2f ret=%d err=%d",
                            i, price, lot, (int)trade.ResultRetcode(), (int)GetLastError()));
      }
      else if(DebugMode)
      {
         Print(StringFormat("Placed SELL LIMIT i=%d price=%.5f lot=%.2f sl=%.5f tp=%.5f",
                            i, price, lot, g_cycleSL, g_cycleTP));
      }
   }
}

void RefreshCycleStateFromExisting()
{
   const int pos = CountOurPositions();
   const int ord = CountOurOrders();

   // If all positions are closed but pending remain: clean them up (end cycle)
   if(pos == 0 && ord > 0)
   {
      DeleteOurPendingOrders();
      g_cycleActive = false;
      g_cycleDir = 0;
      g_firstEntry = 0.0;
      g_cycleSL = 0.0;
      g_cycleTP = 0.0;
      if(DebugMode) Print("Cycle cleanup: positions=0, deleted remaining pending orders.");
      return;
   }

   // If there are any positions or pending, cycle is active
   if(pos > 0 || ord > 0)
   {
      g_cycleActive = true;
      return;
   }

   // fully closed (nothing left)
   g_cycleActive = false;
   g_cycleDir = 0;
   g_firstEntry = 0.0;
   g_cycleSL = 0.0;
   g_cycleTP = 0.0;
}

//--------------------------- MT5 Events ------------------------------
int OnInit()
{
   Sym = (TradeSymbol == "") ? _Symbol : TradeSymbol;
   if(!SymbolSelect(Sym, true))
   {
      Print("Cannot select symbol: ", Sym);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   hEma14  = iMA(Sym, Timeframe, 14, 0, MODE_EMA, PRICE_CLOSE);
   hEma26  = iMA(Sym, Timeframe, 26, 0, MODE_EMA, PRICE_CLOSE);
   hEma50  = iMA(Sym, Timeframe, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEma100 = iMA(Sym, Timeframe, 100, 0, MODE_EMA, PRICE_CLOSE);
   hEma200 = iMA(Sym, Timeframe, 200, 0, MODE_EMA, PRICE_CLOSE);

   if(hEma14 == INVALID_HANDLE || hEma26 == INVALID_HANDLE || hEma50 == INVALID_HANDLE ||
      hEma100 == INVALID_HANDLE || hEma200 == INVALID_HANDLE)
   {
      Print("Indicator init failed. err=", GetLastError());
      return INIT_FAILED;
   }

   // load daily stop state
   g_dayKey = DayKeyNow();
   LoadDailyState();
   ResetDailyStateIfNewDay();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEma14  != INVALID_HANDLE) IndicatorRelease(hEma14);
   if(hEma26  != INVALID_HANDLE) IndicatorRelease(hEma26);
   if(hEma50  != INVALID_HANDLE) IndicatorRelease(hEma50);
   if(hEma100 != INVALID_HANDLE) IndicatorRelease(hEma100);
   if(hEma200 != INVALID_HANDLE) IndicatorRelease(hEma200);
}

void OnTick()
{
   if(Sym == "") return;
   if(!SymbolInfoInteger(Sym, SYMBOL_SELECT)) SymbolSelect(Sym, true);

   ResetDailyStateIfNewDay();
   RefreshCycleStateFromExisting();

   // If blocked for the day, do not open new cycles (but still allow cleanup above)
   if(UseDailyStop && g_blockedToday)
   {
      DbgOncePerBar(StringFormat("DailyStop: trading blocked for today. day=%d slStreak=%d",
                                 g_dayKey, g_slStreak));
      return;
   }

   // Only process once per new bar (signals must use last closed candle)
   if(!IsNewBar()) return;

   double close1=0, ema14=0, ema26=0, ema50=0, ema100=0, ema200=0;
   bool buySignal=false, sellSignal=false;
   if(!BuildSignals(buySignal, sellSignal, close1, ema14, ema26, ema50, ema100, ema200))
   {
      DbgOncePerBar("Blocked: cannot build signals (buffers/rates not ready).");
      return;
   }

   if(DebugMode)
   {
      Print(StringFormat("DBG Close=%.5f EMA14=%.5f EMA26=%.5f EMA50=%.5f EMA100=%.5f EMA200=%.5f BuySignal=%s SellSignal=%s",
                         close1, ema14, ema26, ema50, ema100, ema200,
                         buySignal ? "true" : "false",
                         sellSignal ? "true" : "false"));
   }

   // Optional: delete pending on opposite signal, but never start a new cycle until finished
   if(DeletePendingOnOppositeSignal && g_cycleActive)
   {
      if(g_cycleDir == 1 && sellSignal) { DeleteOurPendingOrders(); if(DebugMode) Print("Deleted pending on opposite SELL signal."); }
      if(g_cycleDir == -1 && buySignal) { DeleteOurPendingOrders(); if(DebugMode) Print("Deleted pending on opposite BUY signal."); }
   }

   // Cycle gate
   if(OneCycleAtATime && HasAnyCycleObjects())
   {
      if(DebugMode) Print("Cycle active: skip new entries.");
      return;
   }

   // Spread filter before opening first order
   if(!SpreadOK())
   {
      long spread = SymbolInfoInteger(Sym, SYMBOL_SPREAD);
      DbgOncePerBar(StringFormat("Blocked: spread too high. spread=%d pts max=%d pts", (int)spread, MaxSpreadPoints));
      return;
   }

   // Entry and grid placement
   if(buySignal)
   {
      if(OpenFirstBuy(ema200))
      {
         if(DebugMode) Print(StringFormat("Cycle BUY: firstEntry=%.5f SL=%.5f TP=%.5f", g_firstEntry, g_cycleSL, g_cycleTP));
         PlaceBuyGrid(ema200);
      }
      return;
   }

   if(sellSignal)
   {
      if(OpenFirstSell(ema200))
      {
         if(DebugMode) Print(StringFormat("Cycle SELL: firstEntry=%.5f SL=%.5f TP=%.5f", g_firstEntry, g_cycleSL, g_cycleTP));
         PlaceSellGrid(ema200);
      }
      return;
   }
}

//--------------------------- Trade Events ----------------------------
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(!UseDailyStop) return;
   if(Sym == "") return;

   // reset on new day even if no ticks
   ResetDailyStateIfNewDay();

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   const ulong deal = trans.deal;
   if(deal == 0) return;

   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != Sym) return;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) return;

   const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT) return; // only consider closing deals

   const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);

   if(reason == DEAL_REASON_SL)
   {
      g_slStreak++;
      if(DebugMode) Print(StringFormat("DailyStop: SL hit. slStreak=%d / %d", g_slStreak, StopAfterConsecutiveSL));
      if(StopAfterConsecutiveSL > 0 && g_slStreak >= StopAfterConsecutiveSL)
      {
         g_blockedToday = true;
         if(DebugMode) Print("DailyStop: blocked for today due to consecutive SL.");
      }
      SaveDailyState();
      return;
   }

   if(reason == DEAL_REASON_TP)
   {
      g_slStreak = 0;
      if(DebugMode) Print("DailyStop: TP hit.");
      if(StopAfterTPOnce)
      {
         g_blockedToday = true;
         if(DebugMode) Print("DailyStop: blocked for today due to TP.");
      }
      SaveDailyState();
      return;
   }

   // Any other closure reason resets the SL streak (manual close, stop-out, etc.)
   g_slStreak = 0;
   SaveDailyState();
}

