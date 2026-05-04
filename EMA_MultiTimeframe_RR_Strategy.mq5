//+------------------------------------------------------------------+
//|                                  EMA_MultiTimeframe_RR_Strategy.mq5 |
//| EMA M1/M5 multi-timeframe entries with R:R-based TP and post-TP   |
//| EMA50 cross gate. One position per symbol.                        |
//+------------------------------------------------------------------+
#property copyright "EMA_MultiTimeframe_RR_Strategy"
#property link      ""
#property version   "1.00"
#property description "M5+M1 entry; SL at EMA fast M1. After broker TP: wait EMA50 M1 cross, then next M1 bar, then re-check conditions before new entry. Lot reset on TP."

#include <Trade/Trade.mqh>

//--------------------------- Inputs ---------------------------------
input double         InitialLot           = 0.01;    // Starting lot after TP reset
input double         LotStepAfterSL       = 0.01;    // Add to next lot after each SL close
input int            EMAFastPeriod        = 50;      // Fast EMA (e.g. 50)
input int            EMASlowPeriod        = 200;     // Slow EMA on M1 only (e.g. 200)
input int            EntryBufferPoints    = 100;     // Extra distance beyond fast EMA M1 (points)
input int            SLBufferPoints       = 100;     // SL offset from fast EMA M1 (points)
input double         RiskRewardRatio      = 2.0;     // TP = risk * RR
input long           MagicNumber          = 123456;
input int            Slippage             = 30;      // Max slippage (points)
input string         TradeSymbol          = "";      // Empty = chart symbol
input int            MaxSpreadPoints      = 0;       // 0 = disabled

//--------------------------- Globals --------------------------------
CTrade  g_trade;
string  g_sym;

int     g_hEmaFast_M1  = INVALID_HANDLE;
int     g_hEmaSlow_M1  = INVALID_HANDLE;
int     g_hEmaFast_M5  = INVALID_HANDLE;

// Next trade lot (updated on SL/TP close)
double  g_nextLot = 0.0;

// After TP: block new trades until price crosses EMA fast M1 (direction-specific)
bool    g_waitEMACross = false;
int     g_waitCrossDir = 0;   // +1 = need buy-style cross (below -> above), -1 = sell-style (above -> below)
bool    g_crossSeenPhase = false; // buy: seen price at/below EMA; sell: seen price at/above EMA

datetime g_lastM1BarTime = 0;

// After post-TP EMA cross completes: do not open on the same M1 candle (forces cross -> new bar -> signal)
datetime g_noEntryUntilM1BarChangesFrom = 0;

// Latest fully processed OUT deal (avoids double-count; OnInit seeds to skip old history)
ulong   g_lastHandledExitDealId = 0;

//--------------------------- Forward declarations -------------------
bool     ReadEMA(const int handle, const int shift, double &out);
bool     GetEMA(const int handle, const int shift, double &out);
double   Pt();
int      DigitsCount();
double   Np(const double price);
double   NormalizeLotVolume(const double lots);
bool     HasOpenPosition();
bool     CheckBuyCondition();
bool     CheckSellCondition();
bool     OpenBuy();
bool     OpenSell();
void     UpdateLotAfterClosedTrade(const ENUM_DEAL_REASON reason, const bool closedLong, const bool closedShort, const double closedVolume);
void     CheckEMACrossAfterTP();
ulong    FindNewestOurExitDealTicket();
void     TryProcessExitDeal(const ulong dealTicket);
void     SyncExitStateFromHistory();
bool     IsNewM1Bar();
bool     SpreadOK();
bool     StopsDistanceOK(const bool isBuy, const double entry, const double sl, const double tp);

//+------------------------------------------------------------------+
//| Point size (price)                                               |
//+------------------------------------------------------------------+
double Pt()
{
   return SymbolInfoDouble(g_sym, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
int DigitsCount()
{
   return (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
}

//+------------------------------------------------------------------+
double Np(const double price)
{
   return NormalizeDouble(price, DigitsCount());
}

//+------------------------------------------------------------------+
//| Read one EMA value from indicator handle                         |
//+------------------------------------------------------------------+
bool ReadEMA(const int handle, const int shift, double &out)
{
   if(handle == INVALID_HANDLE)
      return false;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return false;
   out = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Public helper: get EMA by handle (alias for clarity)             |
//+------------------------------------------------------------------+
bool GetEMA(const int handle, const int shift, double &out)
{
   return ReadEMA(handle, shift, out);
}

//+------------------------------------------------------------------+
//| Clamp lot to min/max/step                                        |
//+------------------------------------------------------------------+
double NormalizeLotVolume(const double lots)
{
   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);

   double v = lots;
   if(step > 0.0)
      v = MathFloor(v / step) * step;
   if(v < minv)
      v = minv;
   if(maxv > 0.0 && v > maxv)
      v = maxv;

   int volDigits = 2;
   double step10 = step;
   while(step10 < 1.0 && volDigits < 8)
   {
      step10 *= 10.0;
      volDigits++;
   }
   return NormalizeDouble(v, volDigits);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   if(MaxSpreadPoints <= 0)
      return true;
   const long sp = SymbolInfoInteger(g_sym, SYMBOL_SPREAD);
   return (sp > 0 && sp <= MaxSpreadPoints);
}

//+------------------------------------------------------------------+
bool IsNewM1Bar()
{
   datetime t[1];
   ArraySetAsSeries(t, true);
   if(CopyTime(g_sym, PERIOD_M1, 0, 1, t) != 1)
      return false;
   if(t[0] != g_lastM1BarTime)
   {
      g_lastM1BarTime = t[0];
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Broker minimum stop distance                                     |
//+------------------------------------------------------------------+
bool StopsDistanceOK(const bool isBuy, const double entry, const double sl, const double tp)
{
   const double pt = Pt();
   if(pt <= 0.0)
      return false;

   const int lvl = (int)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(lvl <= 0)
      return true;

   const double minDist = (double)lvl * pt;
   const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);

   if(isBuy)
   {
      if(sl > 0.0 && (bid - sl) < (minDist - 1e-10))
         return false;
      if(tp > 0.0 && (tp - ask) < (minDist - 1e-10))
         return false;
   }
   else
   {
      if(sl > 0.0 && (sl - ask) < (minDist - 1e-10))
         return false;
      if(tp > 0.0 && (bid - tp) < (minDist - 1e-10))
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Buy: M5 price above fast EMA; M1 fast > slow; price above fast   |
//+------------------------------------------------------------------+
bool CheckBuyCondition()
{
   const double pt = Pt();
   if(pt <= 0.0)
      return false;

   double emaFast_M5 = 0.0, emaFast_M1 = 0.0, emaSlow_M1 = 0.0;
   if(!GetEMA(g_hEmaFast_M5, 0, emaFast_M5))
      return false;
   if(!GetEMA(g_hEmaFast_M1, 0, emaFast_M1))
      return false;
   if(!GetEMA(g_hEmaSlow_M1, 0, emaSlow_M1))
      return false;

   const double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   const double entryBuf = (double)EntryBufferPoints * pt;

   // M5: price above EMA fast (use Ask for long-side "price")
   if(!(ask > emaFast_M5))
      return false;

   // M1: EMA50 > EMA200 and price above EMA50 + buffer
   if(!(emaFast_M1 > emaSlow_M1))
      return false;
   if(!(ask > emaFast_M1 + entryBuf))
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Sell: M5 price below fast EMA; M1 fast < slow; price below fast    |
//+------------------------------------------------------------------+
bool CheckSellCondition()
{
   const double pt = Pt();
   if(pt <= 0.0)
      return false;

   double emaFast_M5 = 0.0, emaFast_M1 = 0.0, emaSlow_M1 = 0.0;
   if(!GetEMA(g_hEmaFast_M5, 0, emaFast_M5))
      return false;
   if(!GetEMA(g_hEmaFast_M1, 0, emaFast_M1))
      return false;
   if(!GetEMA(g_hEmaSlow_M1, 0, emaSlow_M1))
      return false;

   const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   const double entryBuf = (double)EntryBufferPoints * pt;

   if(!(bid < emaFast_M5))
      return false;

   if(!(emaFast_M1 < emaSlow_M1))
      return false;
   if(!(bid < emaFast_M1 - entryBuf))
      return false;

   return true;
}

//+------------------------------------------------------------------+
bool OpenBuy()
{
   double emaFast_M1 = 0.0;
   if(!GetEMA(g_hEmaFast_M1, 0, emaFast_M1))
   {
      Print("OpenBuy: cannot read EMA fast M1.");
      return false;
   }

   const double pt = Pt();
   const double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   const double entry = ask;
   const double sl = Np(emaFast_M1 - (double)SLBufferPoints * pt);

   const double riskDist = entry - sl;
   if(riskDist <= 0.0)
   {
      Print(StringFormat("OpenBuy: invalid risk distance (entry=%.5f sl=%.5f).", entry, sl));
      return false;
   }

   const double tp = Np(entry + riskDist * RiskRewardRatio);

   if(!StopsDistanceOK(true, entry, sl, tp))
   {
      Print(StringFormat("OpenBuy: stops level too close. entry=%.5f sl=%.5f tp=%.5f", entry, sl, tp));
      return false;
   }

   const double lot = NormalizeLotVolume(g_nextLot);
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints(Slippage);

   const string cmt = "EMA_MTF_RR BUY";
   if(!g_trade.Buy(lot, g_sym, 0.0, sl, tp, cmt))
   {
      Print(StringFormat("OpenBuy failed. retcode=%d last error=%d comment=%s",
                         (int)g_trade.ResultRetcode(), GetLastError(), g_trade.ResultComment()));
      return false;
   }

   Print(StringFormat("OpenBuy OK. lot=%.4f entry=%.5f sl=%.5f tp=%.5f", lot, entry, sl, tp));
   return true;
}

//+------------------------------------------------------------------+
bool OpenSell()
{
   double emaFast_M1 = 0.0;
   if(!GetEMA(g_hEmaFast_M1, 0, emaFast_M1))
   {
      Print("OpenSell: cannot read EMA fast M1.");
      return false;
   }

   const double pt = Pt();
   const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   const double entry = bid;
   const double sl = Np(emaFast_M1 + (double)SLBufferPoints * pt);

   const double riskDist = sl - entry;
   if(riskDist <= 0.0)
   {
      Print(StringFormat("OpenSell: invalid risk distance (entry=%.5f sl=%.5f).", entry, sl));
      return false;
   }

   const double tp = Np(entry - riskDist * RiskRewardRatio);

   if(!StopsDistanceOK(false, entry, sl, tp))
   {
      Print(StringFormat("OpenSell: stops level too close. entry=%.5f sl=%.5f tp=%.5f", entry, sl, tp));
      return false;
   }

   const double lot = NormalizeLotVolume(g_nextLot);
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints(Slippage);

   const string cmt = "EMA_MTF_RR SELL";
   if(!g_trade.Sell(lot, g_sym, 0.0, sl, tp, cmt))
   {
      Print(StringFormat("OpenSell failed. retcode=%d last error=%d comment=%s",
                         (int)g_trade.ResultRetcode(), GetLastError(), g_trade.ResultComment()));
      return false;
   }

   Print(StringFormat("OpenSell OK. lot=%.4f entry=%.5f sl=%.5f tp=%.5f", lot, entry, sl, tp));
   return true;
}

//+------------------------------------------------------------------+
//| Adjust next lot after a fully closed position (SL / TP / other)    |
//+------------------------------------------------------------------+
void UpdateLotAfterClosedTrade(const ENUM_DEAL_REASON reason, const bool closedLong, const bool closedShort, const double closedVolume)
{
   if(reason == DEAL_REASON_SL)
   {
      // Next lot = last closed volume + step (e.g. 0.01 -> SL -> 0.02)
      g_nextLot = closedVolume + LotStepAfterSL;
      g_nextLot = NormalizeLotVolume(g_nextLot);

      g_noEntryUntilM1BarChangesFrom = 0;
      // SL closes do not activate EMA cross wait
      Print(StringFormat("Last close: SL. Next lot set to %.4f", g_nextLot));
      return;
   }

   if(reason == DEAL_REASON_TP)
   {
      g_nextLot = NormalizeLotVolume(InitialLot);
      Print(StringFormat("Last close: TP. Next lot reset to InitialLot=%.4f", g_nextLot));

      // Post-TP: wait for EMA cross on M1 fast before any new trade
      g_waitEMACross = true;
      g_crossSeenPhase = false;

      // MT5: closing a BUY position creates an OUT deal of type SELL; closing SELL -> OUT deal BUY.
      if(closedLong)
      {
         g_waitCrossDir = +1;
         Print("Post-TP (long closed): waiting for bullish EMA cross / touch sequence on M1 fast EMA.");
      }
      else if(closedShort)
      {
         g_waitCrossDir = -1;
         Print("Post-TP (short closed): waiting for bearish EMA cross / touch sequence on M1 fast EMA.");
      }
      else
      {
         g_waitEMACross = false;
         g_waitCrossDir = 0;
      }
      return;
   }

   // Manual / other reasons: keep next lot conservative (reset to InitialLot)
   g_nextLot = NormalizeLotVolume(InitialLot);
   g_waitEMACross = false;
   g_waitCrossDir = 0;
   g_noEntryUntilM1BarChangesFrom = 0;
   Print("Last close: non SL/TP. Next lot reset to InitialLot.");
}

//+------------------------------------------------------------------+
//| Newest OUT deal ticket for this symbol + magic (history range)    |
//+------------------------------------------------------------------+
ulong FindNewestOurExitDealTicket()
{
   const datetime to = TimeCurrent() + 60;
   const datetime from = to - 86400 * 90; // 90 days
   if(!HistorySelect(from, to))
      return 0;

   datetime bestTm = 0;
   ulong    bestId = 0;
   const int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong tid = HistoryDealGetTicket(i);
      if(tid == 0)
         continue;
      if(!HistoryDealSelect(tid))
         continue;
      if(HistoryDealGetString(tid, DEAL_SYMBOL) != g_sym)
         continue;
      if((long)HistoryDealGetInteger(tid, DEAL_MAGIC) != MagicNumber)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tid, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      const datetime dtm = (datetime)HistoryDealGetInteger(tid, DEAL_TIME);
      if(dtm > bestTm || (dtm == bestTm && tid > bestId))
      {
         bestTm = dtm;
         bestId = tid;
      }
   }
   return bestId;
}

//+------------------------------------------------------------------+
//| Apply SL/TP / post-TP wait from one exit deal (idempotent by id)   |
//+------------------------------------------------------------------+
void TryProcessExitDeal(const ulong dealTicket)
{
   if(dealTicket == 0 || dealTicket == g_lastHandledExitDealId)
      return;
   if(!HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != g_sym)
      return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
      return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   // Partial close: consume deal id but do not change lot / EMA-wait until fully flat
   if(HasOpenPosition())
   {
      g_lastHandledExitDealId = dealTicket;
      return;
   }

   const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   const ENUM_DEAL_TYPE  dtype  = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   const double          vol    = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

   const bool closedLong  = (dtype == DEAL_TYPE_SELL);
   const bool closedShort = (dtype == DEAL_TYPE_BUY);

   UpdateLotAfterClosedTrade(reason, closedLong, closedShort, vol);
   g_lastHandledExitDealId = dealTicket;
}

//+------------------------------------------------------------------+
//| OnTick may run before OnTradeTransaction — sync from history first |
//+------------------------------------------------------------------+
void SyncExitStateFromHistory()
{
   if(HasOpenPosition())
      return;

   const ulong tid = FindNewestOurExitDealTicket();
   if(tid == 0 || tid == g_lastHandledExitDealId)
      return;

   TryProcessExitDeal(tid);
}

//+------------------------------------------------------------------+
//| After TP: detect cross of price vs fast EMA on M1                |
//| Buy:  see price <= EMA then price > EMA                          |
//| Sell: see price >= EMA then price < EMA                          |
//+------------------------------------------------------------------+
void CheckEMACrossAfterTP()
{
   if(!g_waitEMACross || g_waitCrossDir == 0)
      return;

   double emaFast_M1 = 0.0;
   if(!GetEMA(g_hEmaFast_M1, 0, emaFast_M1))
      return;

   const double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);

   if(g_waitCrossDir > 0)
   {
      // Bullish cross wait after buy TP
      if(!g_crossSeenPhase)
      {
         if(bid <= emaFast_M1)
            g_crossSeenPhase = true;
      }
      else
      {
         if(bid > emaFast_M1)
         {
            g_waitEMACross = false;
            g_waitCrossDir = 0;
            g_crossSeenPhase = false;
            datetime tb[1];
            ArraySetAsSeries(tb, true);
            if(CopyTime(g_sym, PERIOD_M1, 0, 1, tb) == 1)
               g_noEntryUntilM1BarChangesFrom = tb[0];
            Print("EMA cross (buy side): done. No new entry until next M1 bar, then conditions re-checked.");
         }
      }
   }
   else
   {
      // Bearish cross wait after sell TP
      if(!g_crossSeenPhase)
      {
         if(bid >= emaFast_M1)
            g_crossSeenPhase = true;
      }
      else
      {
         if(bid < emaFast_M1)
         {
            g_waitEMACross = false;
            g_waitCrossDir = 0;
            g_crossSeenPhase = false;
            datetime tb[1];
            ArraySetAsSeries(tb, true);
            if(CopyTime(g_sym, PERIOD_M1, 0, 1, tb) == 1)
               g_noEntryUntilM1BarChangesFrom = tb[0];
            Print("EMA cross (sell side): done. No new entry until next M1 bar, then conditions re-checked.");
         }
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_sym = (TradeSymbol == "") ? _Symbol : TradeSymbol;
   if(!SymbolSelect(g_sym, true))
   {
      Print("OnInit: cannot select symbol ", g_sym);
      return INIT_FAILED;
   }

   g_hEmaFast_M1 = iMA(g_sym, PERIOD_M1, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow_M1 = iMA(g_sym, PERIOD_M1, EMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaFast_M5 = iMA(g_sym, PERIOD_M5, EMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hEmaFast_M1 == INVALID_HANDLE || g_hEmaSlow_M1 == INVALID_HANDLE || g_hEmaFast_M5 == INVALID_HANDLE)
   {
      Print("OnInit: indicator create failed. Error=", GetLastError());
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints(Slippage);

   g_nextLot = NormalizeLotVolume(InitialLot);
   g_waitEMACross = false;
   g_waitCrossDir = 0;
   g_crossSeenPhase = false;
   g_noEntryUntilM1BarChangesFrom = 0;

   // Warm-up: align M1 bar timer so first IsNewM1Bar() does not fire immediately spuriously
   datetime t0[1];
   ArraySetAsSeries(t0, true);
   if(CopyTime(g_sym, PERIOD_M1, 0, 1, t0) == 1)
      g_lastM1BarTime = t0[0];

   // Do not react to exits that happened before this run (prevents stale TP wait on attach)
   g_lastHandledExitDealId = FindNewestOurExitDealTicket();

   Print("EMA_MultiTimeframe_RR_Strategy initialized on ", g_sym);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEmaFast_M1 != INVALID_HANDLE)
      IndicatorRelease(g_hEmaFast_M1);
   if(g_hEmaSlow_M1 != INVALID_HANDLE)
      IndicatorRelease(g_hEmaSlow_M1);
   if(g_hEmaFast_M5 != INVALID_HANDLE)
      IndicatorRelease(g_hEmaFast_M5);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!SymbolInfoInteger(g_sym, SYMBOL_SELECT))
      SymbolSelect(g_sym, true);

   // CRITICAL: OnTick can run before OnTradeTransaction after a TP/SL fill.
   // Sync from deal history first so g_waitEMACross is set before any entry logic.
   SyncExitStateFromHistory();

   // Resolve post-TP EMA cross on ticks (intrabar)
   CheckEMACrossAfterTP();

   if(HasOpenPosition())
      return;

   if(g_waitEMACross)
      return;

   // After EMA cross post-TP: wait until M1 rolls to a NEW candle before re-checking entry (no same-bar instant re-entry)
   if(g_noEntryUntilM1BarChangesFrom != 0)
   {
      datetime tcur[1];
      ArraySetAsSeries(tcur, true);
      if(CopyTime(g_sym, PERIOD_M1, 0, 1, tcur) != 1)
         return;
      if(tcur[0] == g_noEntryUntilM1BarChangesFrom)
         return;
      g_noEntryUntilM1BarChangesFrom = 0;
      Print("Post-cross: new M1 bar — entry conditions can be evaluated again.");
   }

   if(!SpreadOK())
      return;

   // New signal check once per M1 bar when flat (reduces noise vs every tick)
   if(!IsNewM1Bar())
      return;

   const bool buyOk = CheckBuyCondition();
   const bool sellOk = CheckSellCondition();

   if(buyOk && sellOk)
   {
      Print("OnTick: both buy and sell true; skipping (ambiguous).");
      return;
   }

   if(buyOk)
   {
      OpenBuy();
      return;
   }

   if(sellOk)
   {
      OpenSell();
      return;
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   const ulong deal = trans.deal;
   if(deal == 0)
      return;

   if(!HistoryDealSelect(deal))
      return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_sym)
      return;

   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)
      return;

   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   // Same idempotent path as OnTick history sync (handles event order vs OnTick)
   TryProcessExitDeal(deal);
}

//+------------------------------------------------------------------+
