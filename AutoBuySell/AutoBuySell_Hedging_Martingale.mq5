//+------------------------------------------------------------------+
//|                      AutoBuySell_Hedging_Martingale.mq5          |
//|  Dual-direction hedging cycles with per-side pending stop ladder |
//|  Each newly opened market position spawns one same-SL/TP stop.   |
//|  Buy/Sell cycles are independent via separate magic numbers.     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input double LotSize          = 0.01;
input int    StopLossPoints   = 200;   // points
input int    TakeProfitPoints = 400;   // points
input int    PendingDistance  = 200;   // points

input int    MagicNumber_Buy  = 111;
input int    MagicNumber_Sell = 222;

input int    SlippagePoints   = 20;

// MACD (M1) gate for restarting after SL/TP
input int    MacdFastEMA      = 12;
input int    MacdSlowEMA      = 26;
input int    MacdSignalSMA    = 9;
input double MacdMainAbsMin   = 3.0;  // restart only if MACD > +X or < -X

//--------------------------- Globals -------------------------------
CTrade trade;

double g_anchorSLBuy  = 0.0;
double g_anchorTPBuy  = 0.0;
double g_anchorSLSell = 0.0;
double g_anchorTPSell = 0.0;

int  g_macdHandle = INVALID_HANDLE;
bool g_needMacdGateBuy  = false;
bool g_needMacdGateSell = false;
bool g_startedBuy  = false;
bool g_startedSell = false;

//--------------------------- Utils ---------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

bool ReadBuffer1(const int handle, const int bufferIdx, const int shift, double &outVal) {
  if (handle == INVALID_HANDLE) return false;
  double tmp[1];
  if (CopyBuffer(handle, bufferIdx, shift, 1, tmp) != 1) return false;
  outVal = tmp[0];
  return true;
}

bool GetMacdMainM1(double &macdMain) {
  // buffer 0 = MACD main line
  return ReadBuffer1(g_macdHandle, 0, 1, macdMain);
}

bool MacdGatePassed() {
  double m = 0.0;
  if (!GetMacdMainM1(m)) return false;
  return (m > MacdMainAbsMin || m < -MacdMainAbsMin);
}

double NormalizeLot(double lots) {
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step > 0.0) lots = MathRound(lots / step) * step;
  if (lots < minv) lots = minv;
  if (maxv > 0.0 && lots > maxv) lots = maxv;
  return lots;
}

int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
int FreezeLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); }

bool IsM1() { return (Period() == PERIOD_M1); }

int EffectiveDistancePoints(const int requestedPoints) {
  const int minPts = StopsLevelPoints();
  if (minPts <= 0) return requestedPoints;
  // +1 point buffer avoids equality edge-cases on some brokers
  return MathMax(requestedPoints, minPts + 1);
}

bool GetAnchors(const ENUM_POSITION_TYPE side, double &slOut, double &tpOut) {
  if (side == POSITION_TYPE_BUY) { slOut = g_anchorSLBuy; tpOut = g_anchorTPBuy; }
  else { slOut = g_anchorSLSell; tpOut = g_anchorTPSell; }
  return (slOut > 0.0 || tpOut > 0.0);
}

void SetAnchors(const ENUM_POSITION_TYPE side, const double sl, const double tp) {
  if (side == POSITION_TYPE_BUY) { g_anchorSLBuy = sl; g_anchorTPBuy = tp; }
  else { g_anchorSLSell = sl; g_anchorTPSell = tp; }
}

void ResetAnchors(const ENUM_POSITION_TYPE side) {
  if (side == POSITION_TYPE_BUY) { g_anchorSLBuy = 0.0; g_anchorTPBuy = 0.0; }
  else { g_anchorSLSell = 0.0; g_anchorTPSell = 0.0; }
}

ulong FindLatestPositionTicket(const ENUM_POSITION_TYPE side) {
  ulong bestTk = 0;
  long bestTime = -1;
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    const ulong tk = PositionGetTicket(i);
    if (!PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicForSide(side)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const long t = (long)PositionGetInteger(POSITION_TIME_MSC);
    if (t > bestTime) { bestTime = t; bestTk = tk; }
  }
  return bestTk;
}

bool EnsurePositionSLTPToAnchors(const ENUM_POSITION_TYPE side, const ulong posTicket) {
  if (posTicket == 0 || !PositionSelectByTicket(posTicket)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((int)PositionGetInteger(POSITION_MAGIC) != MagicForSide(side)) return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;

  double aSL = 0.0, aTP = 0.0;
  if (!GetAnchors(side, aSL, aTP)) return true; // anchors not set yet

  const int digits = DigitsCount();
  const double curSL = PositionGetDouble(POSITION_SL);
  const double curTP = PositionGetDouble(POSITION_TP);

  const double nASL = (aSL > 0.0) ? NormalizeDouble(aSL, digits) : 0.0;
  const double nATP = (aTP > 0.0) ? NormalizeDouble(aTP, digits) : 0.0;

  const double nCurSL = (curSL > 0.0) ? NormalizeDouble(curSL, digits) : 0.0;
  const double nCurTP = (curTP > 0.0) ? NormalizeDouble(curTP, digits) : 0.0;

  if (nCurSL == nASL && nCurTP == nATP) return true;

  trade.SetExpertMagicNumber(MagicForSide(side));
  trade.SetDeviationInPoints(SlippagePoints);
  if (!trade.PositionModify(posTicket, nASL, nATP)) {
    Print("PositionModify failed. side=", SideTag(side), " ticket=", (long)posTicket, " err=", GetLastError());
    return false;
  }
  return true;
}

bool GetOrCreateAnchors(const ENUM_POSITION_TYPE side, const double cycleEntryPrice, double &slOut, double &tpOut) {
  if (GetAnchors(side, slOut, tpOut)) return true;
  if (!BuildSLTPForEntry(side, cycleEntryPrice, slOut, tpOut)) return false;
  SetAnchors(side, slOut, tpOut);
  return true;
}

string SideTag(const ENUM_POSITION_TYPE side) { return (side == POSITION_TYPE_BUY) ? "BUY" : "SELL"; }

int MagicForSide(const ENUM_POSITION_TYPE side) {
  return (side == POSITION_TYPE_BUY) ? MagicNumber_Buy : MagicNumber_Sell;
}

bool IsStopOrderTypeForSide(const ENUM_ORDER_TYPE t, const ENUM_POSITION_TYPE side) {
  if (side == POSITION_TYPE_BUY)  return (t == ORDER_TYPE_BUY_STOP);
  if (side == POSITION_TYPE_SELL) return (t == ORDER_TYPE_SELL_STOP);
  return false;
}

string PendingCommentForPos(const ENUM_POSITION_TYPE side, const ulong posTicket) {
  return (side == POSITION_TYPE_BUY)
         ? StringFormat("BS_from_%I64u", (long)posTicket)
         : StringFormat("SS_from_%I64u", (long)posTicket);
}

bool HasPendingWithComment(const ENUM_POSITION_TYPE side, const string comment, ulong &ticketOut) {
  ticketOut = 0;
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    const ulong tk = OrderGetTicket(i);
    if (tk == 0) continue;
    if (!OrderSelect(tk)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicForSide(side)) continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (!IsStopOrderTypeForSide(t, side)) continue;
    if (OrderGetString(ORDER_COMMENT) != comment) continue;
    ticketOut = (ulong)OrderGetInteger(ORDER_TICKET);
    return true;
  }
  return false;
}

int CountPositionsBySide(const ENUM_POSITION_TYPE side) {
  int count = 0;
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicForSide(side)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    ++count;
  }
  return count;
}

int CountPendingsBySide(const ENUM_POSITION_TYPE side) {
  int count = 0;
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    const ulong tk = OrderGetTicket(i);
    if (tk == 0) continue;
    if (!OrderSelect(tk)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicForSide(side)) continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (!IsStopOrderTypeForSide(t, side)) continue;
    ++count;
  }
  return count;
}

void DeleteAllPendingsBySide(const ENUM_POSITION_TYPE side) {
  trade.SetExpertMagicNumber(MagicForSide(side));
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    const ulong tk = OrderGetTicket(i);
    if (tk == 0) continue;
    if (!OrderSelect(tk)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicForSide(side)) continue;
    const ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (!IsStopOrderTypeForSide(t, side)) continue;

    const ulong ticket = (ulong)OrderGetInteger(ORDER_TICKET);
    if (!trade.OrderDelete(ticket)) {
      Print("OrderDelete failed. side=", SideTag(side), " ticket=", (long)ticket, " err=", GetLastError());
    }
  }
}

bool BuildSLTPForEntry(const ENUM_POSITION_TYPE side, const double entryPrice, double &slOut, double &tpOut) {
  slOut = 0.0;
  tpOut = 0.0;
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int digits = DigitsCount();

  const int slPts = EffectiveDistancePoints(StopLossPoints);
  const int tpPts = EffectiveDistancePoints(TakeProfitPoints);

  if (side == POSITION_TYPE_BUY) {
    if (StopLossPoints > 0)   slOut = NormalizeDouble(entryPrice - slPts * pt, digits);
    if (TakeProfitPoints > 0) tpOut = NormalizeDouble(entryPrice + tpPts * pt, digits);
  } else {
    if (StopLossPoints > 0)   slOut = NormalizeDouble(entryPrice + slPts * pt, digits);
    if (TakeProfitPoints > 0) tpOut = NormalizeDouble(entryPrice - tpPts * pt, digits);
  }
  return true;
}

bool PriceRespectsStopsLevel(const ENUM_POSITION_TYPE side, const double entry, const double sl, const double tp) {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const double minDist = (double)StopsLevelPoints() * pt;
  if (minDist <= 0.0) return true;

  if (sl > 0.0) {
    const double d = MathAbs(entry - sl);
    if (d + (0.1 * pt) < minDist) return false;
  }
  if (tp > 0.0) {
    const double d = MathAbs(entry - tp);
    if (d + (0.1 * pt) < minDist) return false;
  }
  return true;
}

bool PlaceMarket(const ENUM_POSITION_TYPE side, ulong &posTicketOut) {
  posTicketOut = 0;
  const double pt = Pt();
  if (pt <= 0.0) return false;

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double entry = (side == POSITION_TYPE_BUY) ? ask : bid;

  double sl = 0.0, tp = 0.0;
  if (!GetOrCreateAnchors(side, entry, sl, tp)) return false;
  if (!PriceRespectsStopsLevel(side, entry, sl, tp)) {
    Print("Market ", SideTag(side), " blocked: SL/TP too close for StopsLevel. stopsLevelPoints=", StopsLevelPoints());
    return false;
  }

  trade.SetExpertMagicNumber(MagicForSide(side));
  trade.SetDeviationInPoints(SlippagePoints);

  const double lots = NormalizeLot(LotSize);
  bool ok = false;
  if (side == POSITION_TYPE_BUY)
    ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, "AutoBuy cycle");
  else
    ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, "AutoSell cycle");

  if (!ok) {
    Print("Market ", SideTag(side), " failed. err=", GetLastError());
    return false;
  }

  // Ticket capture + store broker-rounded anchors
  posTicketOut = FindLatestPositionTicket(side);
  if (posTicketOut != 0 && PositionSelectByTicket(posTicketOut)) {
    const double pSL = PositionGetDouble(POSITION_SL);
    const double pTP = PositionGetDouble(POSITION_TP);
    if (pSL > 0.0 || pTP > 0.0) SetAnchors(side, pSL, pTP);
    EnsurePositionSLTPToAnchors(side, posTicketOut);
  }
  return true;
}

bool PlacePendingFromPosition(const ENUM_POSITION_TYPE side, const ulong posTicket) {
  if (posTicket == 0 || !PositionSelectByTicket(posTicket)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((int)PositionGetInteger(POSITION_MAGIC) != MagicForSide(side)) return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;

  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int digits = DigitsCount();

  const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = 0.0, tp = 0.0;
  if (!GetOrCreateAnchors(side, entry, sl, tp)) return false;

  const int pendPts = EffectiveDistancePoints(PendingDistance);
  double pendingPrice = 0.0;
  if (side == POSITION_TYPE_BUY)
    pendingPrice = NormalizeDouble(entry + pendPts * pt, digits);
  else
    pendingPrice = NormalizeDouble(entry - pendPts * pt, digits);

  // Respect broker minimum stop distance from current price for pending orders
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double ref = (side == POSITION_TYPE_BUY) ? ask : bid;
  // (EffectiveDistancePoints already accounted for StopsLevel, but keep a hard guard anyway)
  const double minDist = (double)StopsLevelPoints() * pt;
  if (minDist > 0.0 && MathAbs(pendingPrice - ref) + (0.1 * pt) < minDist) {
    Print("Pending ", SideTag(side), "Stop blocked even after adjust. pending=",
          DoubleToString(pendingPrice, digits), " ref=", DoubleToString(ref, digits),
          " stopsLevelPoints=", StopsLevelPoints());
    return false;
  }

  if (!PriceRespectsStopsLevel(side, pendingPrice, sl, tp)) {
    Print("Pending ", SideTag(side), "Stop blocked: SL/TP too close for StopsLevel.");
    return false;
  }

  const string cmt = PendingCommentForPos(side, posTicket);
  ulong existing = 0;
  if (HasPendingWithComment(side, cmt, existing)) return true; // already synced

  trade.SetExpertMagicNumber(MagicForSide(side));
  trade.SetDeviationInPoints(SlippagePoints);

  const double lots = NormalizeLot(LotSize);
  bool ok = false;
  if (side == POSITION_TYPE_BUY)
    ok = trade.BuyStop(lots, pendingPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
  else
    ok = trade.SellStop(lots, pendingPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);

  if (!ok) {
    Print("Pending ", SideTag(side), "Stop failed. err=", GetLastError(),
          " price=", DoubleToString(pendingPrice, digits),
          " sl=", DoubleToString(sl, digits),
          " tp=", DoubleToString(tp, digits));
  }
  return ok;
}

void EnsurePendingsForAllPositions(const ENUM_POSITION_TYPE side) {
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicForSide(side)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    EnsurePositionSLTPToAnchors(side, tk);
    PlacePendingFromPosition(side, tk);
  }
}

void EnsureSideCycle(const ENUM_POSITION_TYPE side) {
  const int posCount = CountPositionsBySide(side);

  // Reset / restart condition: no positions left => delete any side pendings and restart cycle
  if (posCount == 0) {
    if (CountPendingsBySide(side) > 0) DeleteAllPendingsBySide(side);
    ResetAnchors(side);

    bool canStart = false;
    if (side == POSITION_TYPE_BUY) {
      if (!g_startedBuy) canStart = true;
      else if (g_needMacdGateBuy && MacdGatePassed()) canStart = true;

      if (canStart) {
        ulong newTk = 0;
        if (PlaceMarket(side, newTk)) {
          g_startedBuy = true;
          g_needMacdGateBuy = false;
          EnsurePendingsForAllPositions(side);
        }
      }
    } else {
      if (!g_startedSell) canStart = true;
      else if (g_needMacdGateSell && MacdGatePassed()) canStart = true;

      if (canStart) {
        ulong newTk = 0;
        if (PlaceMarket(side, newTk)) {
          g_startedSell = true;
          g_needMacdGateSell = false;
          EnsurePendingsForAllPositions(side);
        }
      }
    }
    return;
  }

  // Positions exist => ensure each has its corresponding stop pending
  EnsurePendingsForAllPositions(side);
}

//--------------------------- MT5 Events -----------------------------
int OnInit() {
  trade.SetDeviationInPoints(SlippagePoints);

  if (!IsM1()) {
    Print("Warning: EA is intended for M1. Current timeframe=", (int)Period());
  }

  // Make sure symbol is selected/visible
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  g_macdHandle = iMACD(_Symbol, PERIOD_M1, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);
  if (g_macdHandle == INVALID_HANDLE) {
    Print("MACD init failed. err=", GetLastError());
    return INIT_FAILED;
  }

  // Start both cycles immediately
  EnsureSideCycle(POSITION_TYPE_BUY);
  EnsureSideCycle(POSITION_TYPE_SELL);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_macdHandle != INVALID_HANDLE) IndicatorRelease(g_macdHandle);
}

void OnTick() {
  // Run per tick; both cycles are independent via magic numbers
  EnsureSideCycle(POSITION_TYPE_BUY);
  EnsureSideCycle(POSITION_TYPE_SELL);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  const ulong deal = trans.deal;
  if (deal == 0) return;
  if (!HistoryDealSelect(deal)) return;

  if (HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;

  const long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
  if (entry != DEAL_ENTRY_OUT) return;

  const long reason = (long)HistoryDealGetInteger(deal, DEAL_REASON);
  if (reason != DEAL_REASON_SL && reason != DEAL_REASON_TP) return;

  const long magic = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);

  if ((int)magic == MagicNumber_Buy) {
    g_needMacdGateBuy = true;
  } else if ((int)magic == MagicNumber_Sell) {
    g_needMacdGateSell = true;
  }
}

