//+------------------------------------------------------------------+
//|                                                   M1M5_5EMA.mq5  |
//|                                                                  |
//| ເງື່ອນໄຂເຂົ້າອໍເດີ (EMA Multi-TF):                               |
//|  BUY                                                             |
//|   - M5:  Price > EMA50 > EMA100 > EMA200                         |
//|   - M1:  Price > EMA14 > EMA26 > EMA50 > EMA100 > EMA200         |
//|   -> ເປີດ BUY ທັນທີ (Lot ຕາມ BaseLot + SL count * LotStep)        |
//|                                                                  |
//|  SELL                                                            |
//|   - M5:  Price < EMA50 < EMA100 < EMA200                         |
//|   - M1:  Price < EMA14 < EMA26 < EMA50 < EMA100 < EMA200         |
//|   -> ເປີດ SELL ທັນທີ                                            |
//|                                                                  |
//| ການຈັດການຄວາມສ່ຽງ:                                              |
//|  - SL = StopLossPoints, TP = TakeProfitPoints (points)            |
//|  - ເມື່ອກຳໄລ >= BreakEvenTriggerPoints: ຍ້າຍ SL ໄປ BE+Offset       |
//|    (BUY: entry + BreakEvenOffsetPoints, SELL: entry - Offset)     |
//|  - ຖ້າໂດນ SL: ໄມ້ຕໍ່ໄປ Lot ເພີ່ມ LotStepAfterSL (ສູງສຸດ 4 ໄມ້/ມື້) |
//|  - ຖ້າ SL ໄມ້ທີ 4 ຫຼື TP ເກີດ: ຢຸດເທຣດທັງມື້ (restart ມື້ໃໝ່)       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "M1+M5 EMA entry with SL/TP, BE+offset, and 4-step SL lot ladder daily stop."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input long   MagicNumber               = 515050;
input double BaseLot                   = 0.01;
input double LotStepAfterSL            = 0.01;  // add after each SL (today)
input int    MaxTradesPerDay           = 4;     // stop after SL on trade #4

input int    StopLossPoints            = 500;
input int    TakeProfitPoints          = 2000;

input int    BreakEvenTriggerPoints    = 500;  // when profit >= this, move SL to BE+offset
input int    BreakEvenOffsetPoints     = 50;   // BE + 50 points

input bool   UseClosedCandle           = true; // true=use shift 1 price close; false=use current bid/ask
input int    SlippagePoints            = 20;

//--------------------------- Globals --------------------------------
CTrade trade;

datetime g_dayStart = 0;
bool     g_stopToday = false;
int      g_slCountToday = 0; // number of SL hits today (max MaxTradesPerDay)

// indicator handles
int g_m1_ema14  = INVALID_HANDLE;
int g_m1_ema26  = INVALID_HANDLE;
int g_m1_ema50  = INVALID_HANDLE;
int g_m1_ema100 = INVALID_HANDLE;
int g_m1_ema200 = INVALID_HANDLE;

int g_m5_ema50  = INVALID_HANDLE;
int g_m5_ema100 = INVALID_HANDLE;
int g_m5_ema200 = INVALID_HANDLE;

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

double PriceForSignal(const bool isBuy) {
  if (UseClosedCandle) return iClose(_Symbol, PERIOD_M1, 1);
  return isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
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

bool RespectMinStopDistance(const bool isBuy, const double entry, const double sl, const double tp) {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int lvl = StopsLevelPoints();
  const double minDist = (double)lvl * pt;
  if (minDist <= 0.0) return true;
  if (sl > 0.0) {
    if (isBuy && (entry - sl) < (minDist - 1e-10)) return false;
    if (!isBuy && (sl - entry) < (minDist - 1e-10)) return false;
  }
  if (tp > 0.0) {
    if (isBuy && (tp - entry) < (minDist - 1e-10)) return false;
    if (!isBuy && (entry - tp) < (minDist - 1e-10)) return false;
  }
  return true;
}

//--------------------------- EMA Conditions --------------------------
bool GetM1EmaStack(double &e14, double &e26, double &e50, double &e100, double &e200) {
  const int sh = CandleShift();
  return ReadBuf1(g_m1_ema14, sh, e14) &&
         ReadBuf1(g_m1_ema26, sh, e26) &&
         ReadBuf1(g_m1_ema50, sh, e50) &&
         ReadBuf1(g_m1_ema100, sh, e100) &&
         ReadBuf1(g_m1_ema200, sh, e200);
}

bool GetM5EmaStack(double &e50, double &e100, double &e200) {
  const int sh = UseClosedCandle ? 1 : 0;
  return ReadBuf1(g_m5_ema50, sh, e50) &&
         ReadBuf1(g_m5_ema100, sh, e100) &&
         ReadBuf1(g_m5_ema200, sh, e200);
}

bool BuyCondition() {
  double m1_14=0, m1_26=0, m1_50=0, m1_100=0, m1_200=0;
  double m5_50=0, m5_100=0, m5_200=0;
  if (!GetM1EmaStack(m1_14, m1_26, m1_50, m1_100, m1_200)) return false;
  if (!GetM5EmaStack(m5_50, m5_100, m5_200)) return false;

  const double price = PriceForSignal(true);
  const bool m5ok = (price > m5_50 && m5_50 > m5_100 && m5_100 > m5_200);
  const bool m1ok = (price > m1_14 && m1_14 > m1_26 && m1_26 > m1_50 && m1_50 > m1_100 && m1_100 > m1_200);
  return m5ok && m1ok;
}

bool SellCondition() {
  double m1_14=0, m1_26=0, m1_50=0, m1_100=0, m1_200=0;
  double m5_50=0, m5_100=0, m5_200=0;
  if (!GetM1EmaStack(m1_14, m1_26, m1_50, m1_100, m1_200)) return false;
  if (!GetM5EmaStack(m5_50, m5_100, m5_200)) return false;

  const double price = PriceForSignal(false);
  const bool m5ok = (price < m5_50 && m5_50 < m5_100 && m5_100 < m5_200);
  const bool m1ok = (price < m1_14 && m1_14 < m1_26 && m1_26 < m1_50 && m1_50 < m1_100 && m1_100 < m1_200);
  return m5ok && m1ok;
}

//--------------------------- Trade Logic -----------------------------
double NextLot() {
  const double lots = BaseLot + (double)g_slCountToday * LotStepAfterSL;
  return NormalizeLot(lots);
}

bool OpenBuy() {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double entry = ask;
  const double sl = Np(entry - (double)StopLossPoints * pt);
  const double tp = Np(entry + (double)TakeProfitPoints * pt);
  if (!RespectMinStopDistance(true, entry, sl, tp)) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  return trade.Buy(NextLot(), _Symbol, 0.0, sl, tp, "M1M5_5EMA BUY");
}

bool OpenSell() {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double entry = bid;
  const double sl = Np(entry + (double)StopLossPoints * pt);
  const double tp = Np(entry - (double)TakeProfitPoints * pt);
  if (!RespectMinStopDistance(false, entry, sl, tp)) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  return trade.Sell(NextLot(), _Symbol, 0.0, sl, tp, "M1M5_5EMA SELL");
}

void ApplyBreakEvenIfNeeded(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return;
  if ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return;

  const double pt = Pt();
  if (pt <= 0.0) return;

  const ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  const double curSL = PositionGetDouble(POSITION_SL);
  const double curTP = PositionGetDouble(POSITION_TP);

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  double profitPts = 0.0;
  if (typ == POSITION_TYPE_BUY) profitPts = (bid - open) / pt;
  else profitPts = (open - ask) / pt;

  if (profitPts < (double)BreakEvenTriggerPoints) return;

  double wantSL = 0.0;
  if (typ == POSITION_TYPE_BUY) wantSL = Np(open + (double)BreakEvenOffsetPoints * pt);
  else wantSL = Np(open - (double)BreakEvenOffsetPoints * pt);

  // only tighten SL (never loosen)
  if (curSL > 0.0) {
    if (typ == POSITION_TYPE_BUY && wantSL <= curSL) return;
    if (typ == POSITION_TYPE_SELL && wantSL >= curSL) return;
  }

  // respect broker stop level at current price
  const int lvl = StopsLevelPoints();
  const double minDist = (double)lvl * pt;
  if (minDist > 0.0) {
    if (typ == POSITION_TYPE_BUY && (bid - wantSL) < minDist) return;
    if (typ == POSITION_TYPE_SELL && (wantSL - ask) < minDist) return;
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.PositionModify(tk, wantSL, curTP);
}

//--------------------------- Daily Reset -----------------------------
void ResetDayIfNeeded() {
  datetime d = iTime(_Symbol, PERIOD_D1, 0);
  if (d != g_dayStart) {
    g_dayStart = d;
    g_stopToday = false;
    g_slCountToday = 0;
  }
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  g_dayStart = iTime(_Symbol, PERIOD_D1, 0);
  g_stopToday = false;
  g_slCountToday = 0;

  // EMA handles
  g_m1_ema14  = iMA(_Symbol, PERIOD_M1, 14, 0, MODE_EMA, PRICE_CLOSE);
  g_m1_ema26  = iMA(_Symbol, PERIOD_M1, 26, 0, MODE_EMA, PRICE_CLOSE);
  g_m1_ema50  = iMA(_Symbol, PERIOD_M1, 50, 0, MODE_EMA, PRICE_CLOSE);
  g_m1_ema100 = iMA(_Symbol, PERIOD_M1, 100, 0, MODE_EMA, PRICE_CLOSE);
  g_m1_ema200 = iMA(_Symbol, PERIOD_M1, 200, 0, MODE_EMA, PRICE_CLOSE);

  g_m5_ema50  = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
  g_m5_ema100 = iMA(_Symbol, PERIOD_M5, 100, 0, MODE_EMA, PRICE_CLOSE);
  g_m5_ema200 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);

  if (g_m1_ema14 == INVALID_HANDLE || g_m1_ema26 == INVALID_HANDLE ||
      g_m1_ema50 == INVALID_HANDLE || g_m1_ema100 == INVALID_HANDLE ||
      g_m1_ema200 == INVALID_HANDLE || g_m5_ema50 == INVALID_HANDLE ||
      g_m5_ema100 == INVALID_HANDLE || g_m5_ema200 == INVALID_HANDLE) {
    Print("M1M5_5EMA init failed: indicator handle invalid. err=", GetLastError());
    return INIT_FAILED;
  }

  Print("M1M5_5EMA init: symbol=", _Symbol,
        " Magic=", MagicNumber,
        " BaseLot=", DoubleToString(BaseLot, 4),
        " LotStepAfterSL=", DoubleToString(LotStepAfterSL, 4),
        " SL=", StopLossPoints, " TP=", TakeProfitPoints,
        " BE trigger=", BreakEvenTriggerPoints, " offset=", BreakEvenOffsetPoints,
        " MaxTradesPerDay=", MaxTradesPerDay);

  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_m1_ema14  != INVALID_HANDLE) IndicatorRelease(g_m1_ema14);
  if (g_m1_ema26  != INVALID_HANDLE) IndicatorRelease(g_m1_ema26);
  if (g_m1_ema50  != INVALID_HANDLE) IndicatorRelease(g_m1_ema50);
  if (g_m1_ema100 != INVALID_HANDLE) IndicatorRelease(g_m1_ema100);
  if (g_m1_ema200 != INVALID_HANDLE) IndicatorRelease(g_m1_ema200);
  if (g_m5_ema50  != INVALID_HANDLE) IndicatorRelease(g_m5_ema50);
  if (g_m5_ema100 != INVALID_HANDLE) IndicatorRelease(g_m5_ema100);
  if (g_m5_ema200 != INVALID_HANDLE) IndicatorRelease(g_m5_ema200);
  Print("M1M5_5EMA stopped. reason=", reason);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  if (trans.deal == 0) return;
  if (!HistoryDealSelect(trans.deal)) return;
  if (HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

  const long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
  if (magic != MagicNumber) return;

  const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

  const ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
  if (reason == DEAL_REASON_TP) {
    g_stopToday = true;
    Print("M1M5_5EMA: TP hit -> stop trading for today.");
  } else if (reason == DEAL_REASON_SL) {
    g_slCountToday++;
    Print("M1M5_5EMA: SL hit #", g_slCountToday, "/", MaxTradesPerDay);
    if (g_slCountToday >= MaxTradesPerDay) {
      g_stopToday = true;
      Print("M1M5_5EMA: SL on trade #", MaxTradesPerDay, " -> stop trading for today.");
    }
  }
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);
  ResetDayIfNeeded();

  ulong posTk = 0;
  ENUM_POSITION_TYPE posType;
  if (HasOpenPosition(posTk, posType)) {
    ApplyBreakEvenIfNeeded(posTk);
    return;
  }

  if (g_stopToday) return;

  // Entry (one trade at a time)
  if (BuyCondition()) {
    OpenBuy();
    return;
  }
  if (SellCondition()) {
    OpenSell();
    return;
  }
}

