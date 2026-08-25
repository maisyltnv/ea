//+------------------------------------------------------------------+
//|                                                 EMA5and200.mq5    |
//|                                                                  |
//| ຈຸດປະສົງ (Auto EA — EMA50/EMA200 trend breakout, RR 1:2):        |
//| Timeframe = SignalTF (default M5). ໃຊ້ EMA50 ແລະ EMA200.          |
//|                                                                  |
//| BUY:  EMA50>EMA200 ແລະ close(bar1) > EMA50 → Buy LotSize ທັນທີ    |
//|       SL = EMA50 − SLPointsFromEMA (points)                       |
//|       R  = entry − SL ; TP = entry + TPRatio*R (default RR 1:2)   |
//| SELL: EMA50<EMA200 ແລະ close(bar1) < EMA50 → Sell LotSize ທັນທີ   |
//|       SL = EMA50 + SLPointsFromEMA ; TP = entry − TPRatio*R       |
//|                                                                  |
//| ຫຼັງໄມ້ປິດ (TP ຫຼື SL) ຝັ່ງນັ້ນຈະຖືກ block: ຕ້ອງມີແທ່ງປິດຜ່ານ     |
//| EMA50 ໄປອີກຝັ່ງ (BUY: ປິດຕ່ຳກວ່າ EMA50; SELL: ປິດເໜືອ EMA50)      |
//| ກ່ອນ ຈຶ່ງເຂົ້າໄມ້ໃໝ່ໄດ້ (pullback-cross reset).                   |
//|                                                                  |
//| ໝາຍເຫດ: ເປີດໄດ້ເທື່ອລະ 1 ໄມ້ເທົ່ານັ້ນ; ປະເມີນຕອນແທ່ງ M5 ປິດ;      |
//| EA ຈັດການສະເພາະໄມ້ magic == MagicNumber ຂອງຕົນເອງ.               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA50/EMA200 M5 breakout, RR 1:2, re-arm on EMA50 pullback-cross."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input long   MagicNumber        = 550050;      // EA manages only its own trades (this magic)
input double LotSize            = 0.01;        // lot per entry
input ENUM_TIMEFRAMES SignalTF  = PERIOD_M5;   // timeframe for EMA/close signals
input int    EmaFastPeriod      = 50;          // fast EMA (the "EMA50")
input int    EmaSlowPeriod      = 200;         // slow EMA (the "EMA200")
input int    SLPointsFromEMA    = 1000;        // SL distance from EMA50 (points)
input double TPRatio            = 2.0;         // TP = entry + TPRatio * risk (risk = entry−SL); RR
input int    SlippagePoints     = 20;

//--------------------------- Globals -------------------------------
CTrade trade;

int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
datetime g_lastBar       = 0;

// After a trade on a side closes, that side is blocked until price closes
// on the OTHER side of EMA50 (the dip/pop), then closes back to trigger.
bool     g_buyBlocked    = false;
bool     g_sellBlocked   = false;

// Track our open position so we can detect a close (TP/SL/manual).
bool     g_hasPos        = false;
int      g_posDir        = 0;   // +1 = BUY, -1 = SELL

//--------------------------- Helpers -------------------------------
double Pt()      { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int    DigitsN() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

// +1 if we currently hold a BUY, -1 a SELL, 0 if none (our magic, this symbol).
int OurOpenPositionDir() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    return (t == POSITION_TYPE_BUY) ? 1 : -1;
  }
  return 0;
}

double NormalizeLots(const double lotsIn) {
  double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (st <= 0.0) st = 0.01;
  double l = lotsIn;
  if (l < mn) l = mn;
  if (l > mx) l = mx;
  l = MathFloor(l / st + 1e-7) * st;
  if (l < mn) l = mn;
  return NormalizeDouble(l, 2);
}

// Broker minimum stops-level check (SL/TP not too close to market).
bool StopsOk(const bool isBuy, const double sl, const double tp) {
  const double pt = Pt();
  const int lvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  const double minD = (double)lvl * pt;
  if (minD <= 0.0) return true;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (isBuy) {
    if ((bid - sl) < minD - 1e-10) return false;
    if ((tp - bid) < minD - 1e-10) return false;
  } else {
    if ((sl - ask) < minD - 1e-10) return false;
    if ((ask - tp) < minD - 1e-10) return false;
  }
  return true;
}

// Read EMA50/EMA200 and close of the last CLOSED bar (index 1).
bool ReadSignalData(double &emaFast, double &emaSlow, double &closeClosed) {
  if (g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE)
    return false;
  double f[]; double s[];
  ArraySetAsSeries(f, true);
  ArraySetAsSeries(s, true);
  if (CopyBuffer(g_emaFastHandle, 0, 0, 2, f) < 2) return false;
  if (CopyBuffer(g_emaSlowHandle, 0, 0, 2, s) < 2) return false;
  emaFast = f[1];
  emaSlow = s[1];
  closeClosed = iClose(_Symbol, SignalTF, 1);
  return (closeClosed > 0.0);
}

// Detect our position closing (TP/SL/manual) → block that side for reset.
void UpdatePositionCloseState() {
  const int dir = OurOpenPositionDir();
  if (g_hasPos && dir == 0) {
    if (g_posDir > 0) g_buyBlocked = true;
    else if (g_posDir < 0) g_sellBlocked = true;
    Print("[EMA5and200] ", (g_posDir > 0 ? "BUY" : "SELL"),
          " closed → needs EMA50 pullback-cross before re-entry.");
  }
  g_hasPos = (dir != 0);
  if (dir != 0) g_posDir = dir;
}

void OpenBuy(const double emaFast) {
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return;
  const int digits = DigitsN();
  const double pt = Pt();
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double sl = NormalizeDouble(emaFast - (double)SLPointsFromEMA * pt, digits);
  const double risk = ask - sl;
  if (risk <= 0.0) {
    Print("[EMA5and200] BUY skipped: non-positive risk (ask=", ask, " sl=", sl, ")");
    return;
  }
  const double tp = NormalizeDouble(ask + TPRatio * risk, digits);
  if (!StopsOk(true, sl, tp)) {
    Print("[EMA5and200] BUY skipped: SL/TP inside broker stops level.");
    return;
  }
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  if (trade.Buy(lots, _Symbol, 0.0, sl, tp, "EMA5and200")) {
    g_hasPos = true;
    g_posDir = 1;
    Print("[EMA5and200] BUY ", DoubleToString(lots, 2), " sl=", DoubleToString(sl, digits),
          " tp=", DoubleToString(tp, digits), " R=", DoubleToString(risk, digits));
  } else {
    Print("[EMA5and200] BUY failed ret=", trade.ResultRetcode(), " ",
          trade.ResultRetcodeDescription());
  }
}

void OpenSell(const double emaFast) {
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return;
  const int digits = DigitsN();
  const double pt = Pt();
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double sl = NormalizeDouble(emaFast + (double)SLPointsFromEMA * pt, digits);
  const double risk = sl - bid;
  if (risk <= 0.0) {
    Print("[EMA5and200] SELL skipped: non-positive risk (bid=", bid, " sl=", sl, ")");
    return;
  }
  const double tp = NormalizeDouble(bid - TPRatio * risk, digits);
  if (!StopsOk(false, sl, tp)) {
    Print("[EMA5and200] SELL skipped: SL/TP inside broker stops level.");
    return;
  }
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  if (trade.Sell(lots, _Symbol, 0.0, sl, tp, "EMA5and200")) {
    g_hasPos = true;
    g_posDir = -1;
    Print("[EMA5and200] SELL ", DoubleToString(lots, 2), " sl=", DoubleToString(sl, digits),
          " tp=", DoubleToString(tp, digits), " R=", DoubleToString(risk, digits));
  } else {
    Print("[EMA5and200] SELL failed ret=", trade.ResultRetcode(), " ",
          trade.ResultRetcodeDescription());
  }
}

//--------------------------- MT5 Events ----------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)      trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
  else                                     trade.SetTypeFilling(ORDER_FILLING_RETURN);

  g_emaFastHandle = iMA(_Symbol, SignalTF, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_emaSlowHandle = iMA(_Symbol, SignalTF, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  if (g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE) {
    Print("[EMA5and200] Failed to create EMA handles.");
    return INIT_FAILED;
  }

  const int dir = OurOpenPositionDir();
  g_hasPos = (dir != 0);
  g_posDir = dir;
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
  if (g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  // Catch SL/TP closes promptly (every tick).
  UpdatePositionCloseState();

  // Signal logic runs once per newly CLOSED SignalTF bar.
  const datetime curBar = iTime(_Symbol, SignalTF, 0);
  if (curBar == 0 || curBar == g_lastBar) return;

  double emaFast = 0.0, emaSlow = 0.0, closeClosed = 0.0;
  if (!ReadSignalData(emaFast, emaSlow, closeClosed)) return; // not ready — retry next tick
  g_lastBar = curBar;

  // Re-arm: a close on the OTHER side of EMA50 clears the block for that side.
  if (g_buyBlocked && closeClosed < emaFast) {
    g_buyBlocked = false;
    Print("[EMA5and200] BUY re-armed (bar closed below EMA50).");
  }
  if (g_sellBlocked && closeClosed > emaFast) {
    g_sellBlocked = false;
    Print("[EMA5and200] SELL re-armed (bar closed above EMA50).");
  }

  // One position at a time.
  if (OurOpenPositionDir() != 0) return;

  // Entries (mutually exclusive: EMA50>EMA200 vs EMA50<EMA200).
  if (emaFast > emaSlow && closeClosed > emaFast && !g_buyBlocked) {
    OpenBuy(emaFast);
  } else if (emaFast < emaSlow && closeClosed < emaFast && !g_sellBlocked) {
    OpenSell(emaFast);
  }
}
//+------------------------------------------------------------------+
