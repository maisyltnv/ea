//+------------------------------------------------------------------+
//|                                               AutoEMAandSto.mq5 |
//| EMA M1+M5 + M1 Stoch 9,3,3 auto entry, swing SL, grid, BE, TP.   |
//| BUY:  M5&M1 EMA50>200, M1 Stoch%K<=10 → market + BuyLimit grid.   |
//| SELL: M5&M1 EMA50<200, M1 Stoch%K>=90 → market + SellLimit grid.  |
//| SL: swing low/high (M1), min distance; BE at profit; shared TP.   |
//| v1.01: MaxDailyProfitUSD — stop trading for the day when P/L >= cap. |
//| v1.02: 2+ legs → close bundle when sum(profit+swap) >= BasketProfitCloseUSD; |
//|        1 leg only → keep TP at TPPoints from anchor.              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"
#property description "Auto EMA+Stoch bundle EA with grid, BE, daily loss cap."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input double Lots                     = 0.01;
input long   MagicNumber              = 880880;
input int    SlippagePoints           = 20;
input int    MaxSpreadPoints          = 0;       // 0 = off

input int    TrendEMAFastPeriod       = 50;
input int    TrendEMASlowPeriod       = 200;
input int    TrendEMAShift            = 1;       // closed bar for EMA check

input int    StochKPeriod             = 9;
input int    StochDPeriod             = 3;
input int    StochSlowing             = 3;
input int    StochBuyMaxLevel         = 10;      // M1 %K <= this → BUY
input int    StochSellMinLevel        = 90;      // M1 %K >= this → SELL
input int    StochShift               = 0;       // 0 = current M1 bar (immediate)

input ENUM_TIMEFRAMES SwingTF         = PERIOD_M1;
input int    SwingLookbackBars        = 50;
input int    MinSLDistancePoints      = 1500;    // min entry→SL (widen if swing tighter)

input int    GridPendingCount         = 3;       // BuyLimit / SellLimit below/above entry
input int    BreakEvenTriggerPoints   = 500;     // first leg profit pts → BE all legs
input int    BreakEvenPlusPoints      = 20;      // BUY: SL = anchor + pts; SELL: anchor - pts
input int    TPPoints                 = 1000;    // shared TP from first leg entry (1 leg only)
input double BasketProfitCloseUSD     = 10.0;    // 2+ legs: close all when sum P/L+swap >= this (0=off)

input double MaxDailyLossUSD          = 40.0;    // 0 = off; closed+floating today <= -this → stop
input double MaxDailyProfitUSD        = 30.0;    // 0 = off; closed+floating today >= this → stop

//--------------------------- Bundle state ---------------------------
#define GRID_TAG_PREFIX "AES"

struct SideBundle {
  bool     active;
  ulong    anchorTicket;
  double   anchorOpen;
  double   bundleSL;
  double   bundleTP;
  bool     gridDone;
  bool     beDone;
};

CTrade      trade;
SideBundle  g_buy;
SideBundle  g_sell;

int g_hEmaFastM1 = INVALID_HANDLE;
int g_hEmaSlowM1 = INVALID_HANDLE;
int g_hEmaFastM5 = INVALID_HANDLE;
int g_hEmaSlowM5 = INVALID_HANDLE;
int g_hStochM1   = INVALID_HANDLE;

int      g_dailyDayKey = 0;
bool     g_dailyBlocked  = false;
bool     g_dailyCloseDone = false;

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double Np(const double p) { return NormalizeDouble(p, DigitsCount()); }
int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }

double NormalizeVolumeLocal(const double lotsIn) {
  double lots = lotsIn;
  const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step > 0.0) lots = MathFloor(lots / step) * step;
  if (lots < minv) lots = minv;
  if (maxv > 0.0 && lots > maxv) lots = maxv;
  return NormalizeDouble(lots, 2);
}

bool SpreadOK() {
  if (MaxSpreadPoints <= 0) return true;
  const long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  return (sp > 0 && sp <= MaxSpreadPoints);
}

bool ReadEma(const int h, const int shift, double &v) {
  v = 0.0;
  if (h == INVALID_HANDLE) return false;
  double b[1];
  const int sh = (shift < 0) ? 0 : shift;
  if (CopyBuffer(h, 0, sh, 1, b) != 1) return false;
  v = b[0];
  return (v > 0.0);
}

bool EmaTrendBuyOK() {
  const int sh = (TrendEMAShift < 0) ? 0 : TrendEMAShift;
  double f1 = 0.0, s1 = 0.0, f5 = 0.0, s5 = 0.0;
  if (!ReadEma(g_hEmaFastM1, sh, f1) || !ReadEma(g_hEmaSlowM1, sh, s1)) return false;
  if (!ReadEma(g_hEmaFastM5, sh, f5) || !ReadEma(g_hEmaSlowM5, sh, s5)) return false;
  return (f1 > s1 && f5 > s5);
}

bool EmaTrendSellOK() {
  const int sh = (TrendEMAShift < 0) ? 0 : TrendEMAShift;
  double f1 = 0.0, s1 = 0.0, f5 = 0.0, s5 = 0.0;
  if (!ReadEma(g_hEmaFastM1, sh, f1) || !ReadEma(g_hEmaSlowM1, sh, s1)) return false;
  if (!ReadEma(g_hEmaFastM5, sh, f5) || !ReadEma(g_hEmaSlowM5, sh, s5)) return false;
  return (f1 < s1 && f5 < s5);
}

bool GetStochMainK(const int shift, double &k) {
  k = 0.0;
  if (g_hStochM1 == INVALID_HANDLE) return false;
  const int sh = (shift < 0) ? 0 : shift;
  double b[1];
  if (CopyBuffer(g_hStochM1, 0, sh, 1, b) != 1) return false;
  k = b[0];
  return true;
}

bool StochBuySignal() {
  double k = 0.0;
  if (!GetStochMainK(StochShift, k)) return false;
  return (k <= (double)StochBuyMaxLevel);
}

bool StochSellSignal() {
  double k = 0.0;
  if (!GetStochMainK(StochShift, k)) return false;
  return (k >= (double)StochSellMinLevel);
}

double SwingLowPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  const int idx = iLowest(_Symbol, SwingTF, MODE_LOW, SwingLookbackBars, 1);
  if (idx < 0) return 0.0;
  return iLow(_Symbol, SwingTF, idx);
}

double SwingHighPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  const int idx = iHighest(_Symbol, SwingTF, MODE_HIGH, SwingLookbackBars, 1);
  if (idx < 0) return 0.0;
  return iHigh(_Symbol, SwingTF, idx);
}

double WidenSLToMinDistance(const bool isBuy, const double entry, double sl) {
  if (MinSLDistancePoints <= 0 || sl <= 0.0 || entry <= 0.0) return sl;
  const double pt = Pt();
  if (pt <= 0.0) return sl;
  const int digits = DigitsCount();
  if (isBuy) {
    if (sl >= entry) return sl;
    if ((entry - sl) / pt < (double)MinSLDistancePoints)
      sl = entry - (double)MinSLDistancePoints * pt;
  } else {
    if (sl <= entry) return sl;
    if ((sl - entry) / pt < (double)MinSLDistancePoints)
      sl = entry + (double)MinSLDistancePoints * pt;
  }
  return Np(sl);
}

bool RespectStopsDistance(const bool isBuy, const double sl, const double tp) {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int lvl = StopsLevelPoints();
  const double minDist = (double)MathMax(lvl, 1) * pt;
  if (minDist <= 0.0) return true;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (sl > 0.0) {
    if (isBuy && (bid - sl) < minDist - 1e-10) return false;
    if (!isBuy && (sl - ask) < minDist - 1e-10) return false;
  }
  if (tp > 0.0) {
    if (isBuy && (tp - ask) < minDist - 1e-10) return false;
    if (!isBuy && (bid - tp) < minDist - 1e-10) return false;
  }
  return true;
}

bool PendingSlOk(const bool isBuyLimit, const double orderPrice, const double sl) {
  if (sl <= 0.0) return false;
  const double pt = Pt();
  const double minD = (double)MathMax(StopsLevelPoints(), 1) * pt;
  if (isBuyLimit) return (orderPrice - sl) >= minD - 1e-10;
  return (sl - orderPrice) >= minD - 1e-10;
}

string GridTag(const ulong parentTk) {
  return GRID_TAG_PREFIX + IntegerToString((long)parentTk);
}

bool IsOurPositionTicket(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  return ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

bool IsOurGridPending(const ulong ot) {
  if (ot == 0 || !OrderSelect(ot)) return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
  if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) return false;
  const string c = OrderGetString(ORDER_COMMENT);
  return (StringFind(c, GRID_TAG_PREFIX) == 0);
}

int CountSidePositions(const bool buySide) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t == POSITION_TYPE_BUY) n++;
    if (!buySide && t == POSITION_TYPE_SELL) n++;
  }
  return n;
}

int CountSideGridPendings(const bool buySide) {
  int n = 0;
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsOurGridPending(ot)) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (buySide && typ == ORDER_TYPE_BUY_LIMIT) n++;
    if (!buySide && typ == ORDER_TYPE_SELL_LIMIT) n++;
  }
  return n;
}

bool HasSideExposure(const bool buySide) {
  return (CountSidePositions(buySide) > 0 || CountSideGridPendings(buySide) > 0);
}

void ResetSideBundle(SideBundle &b) {
  b.active = false;
  b.anchorTicket = 0;
  b.anchorOpen = 0.0;
  b.bundleSL = 0.0;
  b.bundleTP = 0.0;
  b.gridDone = false;
  b.beDone = false;
}

int TodayKey() {
  MqlDateTime dt;
  TimeToStruct(TimeCurrent(), dt);
  return dt.year * 10000 + dt.mon * 100 + dt.day;
}

double TodayClosedPlusFloatingPL() {
  const datetime from = iTime(_Symbol, PERIOD_D1, 0);
  if (!HistorySelect(from, TimeCurrent() + 60)) return 0.0;

  double closed = 0.0;
  for (int i = HistoryDealsTotal() - 1; i >= 0; i--) {
    const ulong deal = HistoryDealGetTicket(i);
    if (deal == 0) continue;
    if (HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
    if ((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;
    if (HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT &&
        HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_INOUT)
      continue;
    closed += HistoryDealGetDouble(deal, DEAL_PROFIT);
    closed += HistoryDealGetDouble(deal, DEAL_SWAP);
    closed += HistoryDealGetDouble(deal, DEAL_COMMISSION);
  }

  double floating = 0.0;
  for (int p = PositionsTotal() - 1; p >= 0; p--) {
    const ulong tk = PositionGetTicket(p);
    if (!IsOurPositionTicket(tk)) continue;
    floating += PositionGetDouble(POSITION_PROFIT);
    floating += PositionGetDouble(POSITION_SWAP);
  }
  return closed + floating;
}

void UpdateDailyBlock() {
  const int key = TodayKey();
  if (key != g_dailyDayKey) {
    g_dailyDayKey = key;
    g_dailyBlocked = false;
    g_dailyCloseDone = false;
  }
  if (MaxDailyLossUSD <= 0.0 && MaxDailyProfitUSD <= 0.0) return;

  const double dayPL = TodayClosedPlusFloatingPL();

  if (MaxDailyLossUSD > 0.0 && dayPL <= -MaxDailyLossUSD) {
    if (!g_dailyBlocked) {
      Print("[AutoEMAandSto] Daily loss cap hit: ", DoubleToString(dayPL, 2),
            " <= -", DoubleToString(MaxDailyLossUSD, 2));
      g_dailyBlocked = true;
      g_dailyCloseDone = false;
    }
    return;
  }

  if (MaxDailyProfitUSD > 0.0 && dayPL >= MaxDailyProfitUSD) {
    if (!g_dailyBlocked) {
      Print("[AutoEMAandSto] Daily profit cap hit: ", DoubleToString(dayPL, 2),
            " >= ", DoubleToString(MaxDailyProfitUSD, 2), " — stop for today.");
      g_dailyBlocked = true;
      g_dailyCloseDone = false;
    }
  }
}

void CloseAllOurPositionsAndOrders() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    if (!trade.PositionClose(tk))
      Print("[AutoEMAandSto] PositionClose failed tk=", tk);
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if (!trade.OrderDelete(ot))
      Print("[AutoEMAandSto] OrderDelete failed ot=", ot);
  }

  ResetSideBundle(g_buy);
  ResetSideBundle(g_sell);
}

ulong FindOldestSideTicket(const bool buySide) {
  ulong oldest = 0;
  datetime oldestTime = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t != POSITION_TYPE_BUY) continue;
    if (!buySide && t != POSITION_TYPE_SELL) continue;
    const datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
    if (oldest == 0 || ot < oldestTime) {
      oldest = tk;
      oldestTime = ot;
    }
  }
  return oldest;
}

double ProfitPointsFirstLeg(const bool buySide, const double anchorOpen) {
  const double pt = Pt();
  if (pt <= 0.0 || anchorOpen <= 0.0) return 0.0;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (buySide) return (bid - anchorOpen) / pt;
  return (anchorOpen - ask) / pt;
}

bool CalcBuySLTP(const double entry, double &sl, double &tp) {
  const double pt = Pt();
  sl = SwingLowPrice();
  if (sl <= 0.0) return false;
  sl = WidenSLToMinDistance(true, entry, sl);
  sl = Np(sl);
  tp = Np(entry + (double)TPPoints * pt);
  return RespectStopsDistance(true, sl, tp);
}

bool CalcSellSLTP(const double entry, double &sl, double &tp) {
  const double pt = Pt();
  sl = SwingHighPrice();
  if (sl <= 0.0) return false;
  sl = WidenSLToMinDistance(false, entry, sl);
  sl = Np(sl);
  tp = Np(entry - (double)TPPoints * pt);
  return RespectStopsDistance(false, sl, tp);
}

void PlaceGridPendings(const bool buySide, const ulong parentTk,
                       const double entry, const double sl, const double tp) {
  int legs = GridPendingCount;
  if (legs < 1 || sl <= 0.0) return;
  if (legs > 50) legs = 50;

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();
  const double minDist = (double)MathMax(StopsLevelPoints(), 1) * pt;
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double lot = NormalizeVolumeLocal(Lots);
  if (lot <= 0.0) return;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const string tag = GridTag(parentTk);
  const double nsl = Np(sl);
  const double ntp = (tp > 0.0) ? Np(tp) : 0.0;

  if (buySide) {
    const double floorSL = sl + minDist;
    const double span = entry - floorSL;
    if (span <= pt) return;
    const double step = span / (double)(legs + 1);
    for (int i = 1; i <= legs; i++) {
      const double price = Np(entry - step * (double)i);
      if (price <= floorSL) break;
      if (price >= ask - minDist) continue;
      if (!PendingSlOk(true, price, nsl)) continue;
      if (!trade.BuyLimit(lot, price, _Symbol, nsl, ntp, ORDER_TIME_GTC, 0, tag))
        Print("[AutoEMAandSto] BuyLimit failed i=", i, " ret=", trade.ResultRetcode());
    }
  } else {
    const double ceilSL = sl - minDist;
    const double span = ceilSL - entry;
    if (span <= pt) return;
    const double step = span / (double)(legs + 1);
    for (int i = 1; i <= legs; i++) {
      const double price = Np(entry + step * (double)i);
      if (price >= ceilSL) break;
      if (price <= bid + minDist) continue;
      if (!PendingSlOk(false, price, nsl)) continue;
      if (!trade.SellLimit(lot, price, _Symbol, nsl, ntp, ORDER_TIME_GTC, 0, tag))
        Print("[AutoEMAandSto] SellLimit failed i=", i, " ret=", trade.ResultRetcode());
    }
  }
}

void DeleteSideGridPendings(const bool buySide) {
  trade.SetExpertMagicNumber(MagicNumber);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsOurGridPending(ot)) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (buySide && typ != ORDER_TYPE_BUY_LIMIT) continue;
    if (!buySide && typ != ORDER_TYPE_SELL_LIMIT) continue;
    trade.OrderDelete(ot);
  }
}

double SideFloatingProfitUSD(const bool buySide) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t != POSITION_TYPE_BUY) continue;
    if (!buySide && t != POSITION_TYPE_SELL) continue;
    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

void CloseSideBundleOnly(const bool buySide) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t != POSITION_TYPE_BUY) continue;
    if (!buySide && t != POSITION_TYPE_SELL) continue;
    if (!trade.PositionClose(tk))
      Print("[AutoEMAandSto] Basket close: position failed tk=", tk);
  }
  DeleteSideGridPendings(buySide);
  if (buySide) ResetSideBundle(g_buy);
  else ResetSideBundle(g_sell);
}

void ClearSideTakeProfit(const bool buySide) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const bool isBuy = buySide;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t != POSITION_TYPE_BUY) continue;
    if (!buySide && t != POSITION_TYPE_SELL) continue;
    const double sl = PositionGetDouble(POSITION_SL);
    const double tp = PositionGetDouble(POSITION_TP);
    if (tp <= 0.0) continue;
    if (!RespectStopsDistance(isBuy, sl, 0.0)) continue;
    trade.PositionModify(tk, sl, 0.0);
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsOurGridPending(ot)) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (buySide && typ != ORDER_TYPE_BUY_LIMIT) continue;
    if (!buySide && typ != ORDER_TYPE_SELL_LIMIT) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    const double osl = OrderGetDouble(ORDER_SL);
    const double otp = OrderGetDouble(ORDER_TP);
    if (otp <= 0.0) continue;
    trade.OrderModify(ot, op, osl, 0.0,
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
  }
}

// 1 open leg → TP at bundleTP; 2+ legs → no TP, close when basket USD target hit.
void ProcessSideBasketExit(SideBundle &b, const bool buySide) {
  const int nPos = CountSidePositions(buySide);
  if (nPos <= 0) return;

  if (b.bundleTP <= 0.0 && nPos == 1) {
    const ulong anchor = FindOldestSideTicket(buySide);
    if (anchor > 0 && PositionSelectByTicket(anchor)) {
      b.anchorOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      const double pt = Pt();
      b.bundleTP = buySide ? Np(b.anchorOpen + (double)TPPoints * pt)
                           : Np(b.anchorOpen - (double)TPPoints * pt);
    }
  }

  const double slSync = (b.bundleSL > 0.0) ? b.bundleSL : 0.0;
  if (BasketProfitCloseUSD > 0.0 && nPos >= 2) {
    if (slSync > 0.0)
      SyncSideLegsSLTP(buySide, slSync, 0.0);
    else
      ClearSideTakeProfit(buySide);
    const double basket = SideFloatingProfitUSD(buySide);
    if (basket >= BasketProfitCloseUSD) {
      Print("[AutoEMAandSto] ", buySide ? "BUY" : "SELL",
            " basket profit close: $", DoubleToString(basket, 2), " (target $",
            DoubleToString(BasketProfitCloseUSD, 2), ", legs=", nPos, ")");
      CloseSideBundleOnly(buySide);
    }
    return;
  }

  if (nPos == 1 && b.bundleTP > 0.0 && slSync > 0.0)
    SyncSideLegsSLTP(buySide, slSync, b.bundleTP);
}

void SyncSideLegsSLTP(const bool buySide, const double sl, const double tp) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const double nsl = (sl > 0.0) ? Np(sl) : 0.0;
  const double ntp = (tp > 0.0) ? Np(tp) : 0.0;
  const bool isBuy = buySide;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsOurPositionTicket(tk)) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && t != POSITION_TYPE_BUY) continue;
    if (!buySide && t != POSITION_TYPE_SELL) continue;
    if (!RespectStopsDistance(isBuy, nsl, ntp)) continue;
    trade.PositionModify(tk, nsl, ntp);
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsOurGridPending(ot)) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (buySide && typ != ORDER_TYPE_BUY_LIMIT) continue;
    if (!buySide && typ != ORDER_TYPE_SELL_LIMIT) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    if (!PendingSlOk(buySide, op, nsl)) continue;
    trade.OrderModify(ot, op, nsl, ntp,
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
  }
}

bool TryStartBuyBundle() {
  if (g_dailyBlocked || !SpreadOK()) return false;
  if (HasSideExposure(true)) return false;
  if (!EmaTrendBuyOK() || !StochBuySignal()) return false;

  const double pt = Pt();
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double sl = 0.0, tp = 0.0;
  if (!CalcBuySLTP(ask, sl, tp)) return false;

  const double lot = NormalizeVolumeLocal(Lots);
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (!trade.Buy(lot, _Symbol, ask, sl, tp, "AutoEMAandSto BUY")) {
    Print("[AutoEMAandSto] Buy failed ret=", trade.ResultRetcode());
    return false;
  }

  ulong tk = FindOldestSideTicket(true);

  g_buy.active = true;
  g_buy.anchorTicket = tk;
  g_buy.anchorOpen = ask;
  g_buy.bundleSL = sl;
  g_buy.bundleTP = tp;
  g_buy.gridDone = false;
  g_buy.beDone = false;

  if (PositionSelectByTicket(tk)) {
    g_buy.anchorOpen = PositionGetDouble(POSITION_PRICE_OPEN);
    g_buy.anchorTicket = tk;
  }

  PlaceGridPendings(true, g_buy.anchorTicket, g_buy.anchorOpen, g_buy.bundleSL, g_buy.bundleTP);
  g_buy.gridDone = true;

  Print("[AutoEMAandSto] BUY bundle started tk=", g_buy.anchorTicket,
        " SL=", DoubleToString(g_buy.bundleSL, DigitsCount()),
        " TP=", DoubleToString(g_buy.bundleTP, DigitsCount()));
  return true;
}

bool TryStartSellBundle() {
  if (g_dailyBlocked || !SpreadOK()) return false;
  if (HasSideExposure(false)) return false;
  if (!EmaTrendSellOK() || !StochSellSignal()) return false;

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double sl = 0.0, tp = 0.0;
  if (!CalcSellSLTP(bid, sl, tp)) return false;

  const double lot = NormalizeVolumeLocal(Lots);
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (!trade.Sell(lot, _Symbol, bid, sl, tp, "AutoEMAandSto SELL")) {
    Print("[AutoEMAandSto] Sell failed ret=", trade.ResultRetcode());
    return false;
  }

  ulong tk = FindOldestSideTicket(false);

  g_sell.active = true;
  g_sell.anchorTicket = tk;
  g_sell.anchorOpen = bid;
  g_sell.bundleSL = sl;
  g_sell.bundleTP = tp;
  g_sell.gridDone = false;
  g_sell.beDone = false;

  if (PositionSelectByTicket(tk)) {
    g_sell.anchorOpen = PositionGetDouble(POSITION_PRICE_OPEN);
    g_sell.anchorTicket = tk;
  }

  PlaceGridPendings(false, g_sell.anchorTicket, g_sell.anchorOpen, g_sell.bundleSL, g_sell.bundleTP);
  g_sell.gridDone = true;

  Print("[AutoEMAandSto] SELL bundle started tk=", g_sell.anchorTicket,
        " SL=", DoubleToString(g_sell.bundleSL, DigitsCount()),
        " TP=", DoubleToString(g_sell.bundleTP, DigitsCount()));
  return true;
}

void ProcessSideBreakEven(SideBundle &b, const bool buySide) {
  if (!b.active || b.beDone) return;
  if (!HasSideExposure(buySide)) {
    ResetSideBundle(b);
    return;
  }

  const ulong anchor = FindOldestSideTicket(buySide);
  if (anchor == 0) {
    ResetSideBundle(b);
    return;
  }
  if (!PositionSelectByTicket(anchor)) return;

  b.anchorTicket = anchor;
  b.anchorOpen = PositionGetDouble(POSITION_PRICE_OPEN);
  if (b.bundleTP <= 0.0) {
    const double pt = Pt();
    b.bundleTP = buySide ? Np(b.anchorOpen + (double)TPPoints * pt)
                         : Np(b.anchorOpen - (double)TPPoints * pt);
  }

  const double pts = ProfitPointsFirstLeg(buySide, b.anchorOpen);
  if (pts < (double)BreakEvenTriggerPoints) return;

  const double pt = Pt();
  double beSL = buySide ? Np(b.anchorOpen + (double)BreakEvenPlusPoints * pt)
                        : Np(b.anchorOpen - (double)BreakEvenPlusPoints * pt);

  const int nPos = CountSidePositions(buySide);
  const double exitTP =
      (BasketProfitCloseUSD > 0.0 && nPos >= 2) ? 0.0 : b.bundleTP;
  SyncSideLegsSLTP(buySide, beSL, exitTP);
  DeleteSideGridPendings(buySide);
  b.beDone = true;
  b.bundleSL = beSL;

  Print("[AutoEMAandSto] ", buySide ? "BUY" : "SELL", " BE applied anchor=",
        DoubleToString(b.anchorOpen, DigitsCount()), " pts=", DoubleToString(pts, 1));
}

void MaintainBundles() {
  if (!HasSideExposure(true)) {
    if (g_buy.active) ResetSideBundle(g_buy);
  } else
    g_buy.active = true;

  if (!HasSideExposure(false)) {
    if (g_sell.active) ResetSideBundle(g_sell);
  } else
    g_sell.active = true;
}

void TryEntries() {
  if (g_dailyBlocked) return;
  if (!HasSideExposure(true)) TryStartBuyBundle();
  if (!HasSideExposure(false)) TryStartSellBundle();
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  ResetSideBundle(g_buy);
  ResetSideBundle(g_sell);
  g_dailyDayKey = TodayKey();

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)
    trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0)
    trade.SetTypeFilling(ORDER_FILLING_FOK);
  else
    trade.SetTypeFilling(ORDER_FILLING_RETURN);

  g_hEmaFastM1 = iMA(_Symbol, PERIOD_M1, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaSlowM1 = iMA(_Symbol, PERIOD_M1, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaFastM5 = iMA(_Symbol, PERIOD_M5, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaSlowM5 = iMA(_Symbol, PERIOD_M5, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hStochM1 = iStochastic(_Symbol, PERIOD_M1, StochKPeriod, StochDPeriod, StochSlowing,
                           MODE_SMA, STO_LOWHIGH);

  if (g_hEmaFastM1 == INVALID_HANDLE || g_hEmaSlowM1 == INVALID_HANDLE ||
      g_hEmaFastM5 == INVALID_HANDLE || g_hEmaSlowM5 == INVALID_HANDLE ||
      g_hStochM1 == INVALID_HANDLE) {
    Print("[AutoEMAandSto] Indicator init failed.");
    return INIT_FAILED;
  }

  Print("[AutoEMAandSto] Ready. 1 leg=TP ", TPPoints, " pts; 2+ legs=basket $",
        DoubleToString(BasketProfitCloseUSD, 2),
        "; daily loss $", DoubleToString(MaxDailyLossUSD, 2),
        ", daily profit $", DoubleToString(MaxDailyProfitUSD, 2));
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_hEmaFastM1 != INVALID_HANDLE) IndicatorRelease(g_hEmaFastM1);
  if (g_hEmaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowM1);
  if (g_hEmaFastM5 != INVALID_HANDLE) IndicatorRelease(g_hEmaFastM5);
  if (g_hEmaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowM5);
  if (g_hStochM1 != INVALID_HANDLE) IndicatorRelease(g_hStochM1);
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  UpdateDailyBlock();
  if (g_dailyBlocked) {
    if (!g_dailyCloseDone) {
      CloseAllOurPositionsAndOrders();
      g_dailyCloseDone = true;
    }
    return;
  }

  MaintainBundles();
  ProcessSideBreakEven(g_buy, true);
  ProcessSideBreakEven(g_sell, false);
  ProcessSideBasketExit(g_buy, true);
  ProcessSideBasketExit(g_sell, false);
  TryEntries();
}
