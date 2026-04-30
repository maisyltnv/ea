//+------------------------------------------------------------------+
//|                                                        EMA50.mq5 |
//|                                                                  |
//| Rules                                                            |
//|  BUY                                                             |
//|   - EMA50 > EMA200 AND Price > EMA50 + EntryOffsetPoints         |
//|   - Open BUY immediately (LotSize)                               |
//|   - SL = StopLossPoints                                          |
//|   - When profit >= TrailStartPoints:                             |
//|       1) move SL to BE + BreakEvenOffsetPoints                   |
//|       2) then trail SL along EMA50 (tighten only)                |
//|                                                                  |
//|  SELL                                                            |
//|   - EMA50 < EMA200 AND Price < EMA50 - EntryOffsetPoints         |
//|   - Open SELL immediately (LotSize)                              |
//|   - SL = StopLossPoints                                          |
//|   - When profit >= TrailStartPoints:                             |
//|       1) move SL to BE - BreakEvenOffsetPoints                   |
//|       2) then trail SL along EMA50 (tighten only)                |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA50 vs EMA200 entry; BE+offset then trail SL on EMA50."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input ENUM_TIMEFRAMES SignalTF          = PERIOD_M1;
input bool   UseClosedCandle            = true;   // true=shift 1, false=shift 0
input double LotSize                    = 0.01;
input int    EntryOffsetPoints          = 20;     // price distance from EMA50
input int    StopLossPoints             = 200;
input int    TrailStartPoints           = 120;    // start BE+trail after this profit (points)
input int    BreakEvenOffsetPoints      = 20;     // BE +/- 20 points
input int    SlippagePoints             = 20;
input long   MagicNumber                = 505050;

// Re-entry guard after BE stop-out:
// If position closed by SL with ~0 profit (breakeven), do NOT re-enter immediately
// while price still on the same side of EMA50. Wait for a full cross and re-cross of EMA50.
input bool   EnableRearmAfterBreakevenSL = true;
input double BreakevenAbsProfitMaxMoney = 2.0; // treat |profit| <= this as BE (commission/swap tolerance)

//--------------------------- Globals --------------------------------
CTrade trade;
int g_ema50  = INVALID_HANDLE;
int g_ema200 = INVALID_HANDLE;

// 0 = ready, 1 = waiting first cross (to wrong side), 2 = waiting cross back (to signal side)
int g_buyRearmStage  = 0;
int g_sellRearmStage = 0;

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double Np(const double p) { return NormalizeDouble(p, DigitsCount()); }
int CandleShift() { return UseClosedCandle ? 1 : 0; }
int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }

double NormalizeLot(double lots) {
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double v = lots;
  if (step > 0.0) v = MathRound(v / step) * step;
  if (v < minv) v = minv;
  if (maxv > 0.0 && v > maxv) v = maxv;
  return v;
}

bool ReadBuf1(const int h, const int shift, double &out) {
  if (h == INVALID_HANDLE) return false;
  double b[1];
  if (CopyBuffer(h, 0, shift, 1, b) != 1) return false;
  out = b[0];
  return true;
}

bool GetEmaValues(double &ema50, double &ema200) {
  const int sh = CandleShift();
  return ReadBuf1(g_ema50, sh, ema50) && ReadBuf1(g_ema200, sh, ema200);
}

double SignalPriceClose() {
  const int sh = CandleShift();
  const double c = iClose(_Symbol, SignalTF, sh);
  return c;
}

bool HasOpenPosition(ulong &ticketOut, ENUM_POSITION_TYPE &typeOut) {
  ticketOut = 0;
  typeOut = POSITION_TYPE_BUY;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    ticketOut = tk;
    typeOut = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    return true;
  }
  return false;
}

bool RespectStopsNow(const bool isBuy, const double slPrice) {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int lvl = StopsLevelPoints();
  const double minDist = (double)lvl * pt;
  if (minDist <= 0.0) return true;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (slPrice <= 0.0) return true;
  if (isBuy) return (bid - slPrice) >= (minDist - 1e-10);
  return (slPrice - ask) >= (minDist - 1e-10);
}

//--------------------------- Trading --------------------------------
bool OpenBuy() {
  const double pt = Pt();
  if (pt <= 0.0) return false;

  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double entry = ask;
  const double sl = Np(entry - (double)StopLossPoints * pt);
  const double tp = 0.0; // user did not request TP here; keep only SL+trail

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  return trade.Buy(NormalizeLot(LotSize), _Symbol, 0.0, sl, tp, "EMA50 BUY");
}

bool OpenSell() {
  const double pt = Pt();
  if (pt <= 0.0) return false;

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double entry = bid;
  const double sl = Np(entry + (double)StopLossPoints * pt);
  const double tp = 0.0;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  return trade.Sell(NormalizeLot(LotSize), _Symbol, 0.0, sl, tp, "EMA50 SELL");
}

void ManageBreakEvenAndTrail(const ulong tk, const ENUM_POSITION_TYPE typ, const double ema50) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return;
  const double pt = Pt();
  if (pt <= 0.0) return;

  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  const double curSL = PositionGetDouble(POSITION_SL);
  const double curTP = PositionGetDouble(POSITION_TP);

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  double profitPts = 0.0;
  if (typ == POSITION_TYPE_BUY) profitPts = (bid - open) / pt;
  else profitPts = (open - ask) / pt;

  if (profitPts < (double)TrailStartPoints) return;

  // 1) BE+offset
  double beSL = 0.0;
  if (typ == POSITION_TYPE_BUY) beSL = Np(open + (double)BreakEvenOffsetPoints * pt);
  else beSL = Np(open - (double)BreakEvenOffsetPoints * pt);

  // 2) trailing target = EMA50 but never worse than BE+offset
  double trailSL = Np(ema50);
  double wantSL = beSL;

  if (typ == POSITION_TYPE_BUY) {
    if (trailSL > wantSL) wantSL = trailSL;
    // tighten only
    if (curSL > 0.0 && wantSL <= curSL) return;
    if (!RespectStopsNow(true, wantSL)) return;
  } else {
    if (trailSL < wantSL) wantSL = trailSL;
    // tighten only (for sell, SL moves downward)
    if (curSL > 0.0 && wantSL >= curSL) return;
    if (!RespectStopsNow(false, wantSL)) return;
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.PositionModify(tk, wantSL, curTP);
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  g_ema50  = iMA(_Symbol, SignalTF, 50, 0, MODE_EMA, PRICE_CLOSE);
  g_ema200 = iMA(_Symbol, SignalTF, 200, 0, MODE_EMA, PRICE_CLOSE);
  if (g_ema50 == INVALID_HANDLE || g_ema200 == INVALID_HANDLE) {
    Print("EMA50 init failed: indicator handle invalid. err=", GetLastError());
    return INIT_FAILED;
  }
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_ema50  != INVALID_HANDLE) IndicatorRelease(g_ema50);
  if (g_ema200 != INVALID_HANDLE) IndicatorRelease(g_ema200);
}

void UpdateRearmStages(const double priceClose, const double ema50) {
  if (!EnableRearmAfterBreakevenSL) return;

  // BUY re-arm: need Close < EMA50 first, then Close > EMA50
  if (g_buyRearmStage == 1) {
    if (priceClose < ema50) g_buyRearmStage = 2;
  } else if (g_buyRearmStage == 2) {
    if (priceClose > ema50) g_buyRearmStage = 0;
  }

  // SELL re-arm: need Close > EMA50 first, then Close < EMA50
  if (g_sellRearmStage == 1) {
    if (priceClose > ema50) g_sellRearmStage = 2;
  } else if (g_sellRearmStage == 2) {
    if (priceClose < ema50) g_sellRearmStage = 0;
  }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (!EnableRearmAfterBreakevenSL) return;
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  if (trans.deal <= 0) return;

  if (!HistoryDealSelect((ulong)trans.deal)) return;
  if (HistoryDealGetString((ulong)trans.deal, DEAL_SYMBOL) != _Symbol) return;
  if ((long)HistoryDealGetInteger((ulong)trans.deal, DEAL_MAGIC) != MagicNumber) return;

  const long entry  = HistoryDealGetInteger((ulong)trans.deal, DEAL_ENTRY);
  if (entry != DEAL_ENTRY_OUT) return;

  const long reason = HistoryDealGetInteger((ulong)trans.deal, DEAL_REASON);
  if (reason != DEAL_REASON_SL) return;

  const double profit = HistoryDealGetDouble((ulong)trans.deal, DEAL_PROFIT);
  if (MathAbs(profit) > BreakevenAbsProfitMaxMoney) return; // not a BE-type stop-out

  // Closing a BUY position is typically a SELL deal, and vice versa.
  const long dealType = HistoryDealGetInteger((ulong)trans.deal, DEAL_TYPE);
  if (dealType == DEAL_TYPE_SELL) {
    g_buyRearmStage = 1;
  } else if (dealType == DEAL_TYPE_BUY) {
    g_sellRearmStage = 1;
  }
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  double ema50 = 0.0, ema200 = 0.0;
  if (!GetEmaValues(ema50, ema200)) return;

  const double priceClose = SignalPriceClose();
  if (priceClose > 0.0) UpdateRearmStages(priceClose, ema50);

  // Manage existing position
  ulong tk = 0;
  ENUM_POSITION_TYPE typ;
  if (HasOpenPosition(tk, typ)) {
    ManageBreakEvenAndTrail(tk, typ, ema50);
    return;
  }

  // Entry (one position at a time)
  const double pt = Pt();
  if (pt <= 0.0) return;

  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (g_buyRearmStage == 0 && ema50 > ema200 && ask > (ema50 + (double)EntryOffsetPoints * pt)) {
    OpenBuy();
    return;
  }
  if (g_sellRearmStage == 0 && ema50 < ema200 && bid < (ema50 - (double)EntryOffsetPoints * pt)) {
    OpenSell();
    return;
  }
}

