//+------------------------------------------------------------------+
//|                                              ManualSwingSLTP.mq5 |
//|                                                                  |
//| ຈຸດປະສົງ (Manual manager):                                       |
//| - ທ່ານເປີດ BUY/SELL ເອງ (manual) ແລ້ວ EA ຈະຊ່ວຍຕັ້ງ SL/TP ອັດຕະໂນມັດ |
//|                                                                  |
//| BUY:                                                             |
//|  - ເມື່ອພົບ manual BUY: ຕັ້ງ SL ໄປທີ່ swing low ກ່ອນໜ້າ (lookback) |
//|  - ເມື່ອກຳໄລ >= BreakEvenTriggerPoints:                          |
//|      SL = entry + BreakEvenPlusPoints, ແລະ TP = entry + TPPoints |
//|                                                                  |
//| SELL:                                                            |
//|  - ເມື່ອພົບ manual SELL: ຕັ້ງ SL ໄປທີ່ swing high ກ່ອນໜ້າ (lookback) |
//|  - ເມື່ອກຳໄລ >= BreakEvenTriggerPoints:                          |
//|      SL = entry - BreakEvenPlusPoints, ແລະ TP = entry - TPPoints |
//|                                                                  |
//| ໝາຍເຫດ: EA ຈັດການສະເພາະ manual positions (magic != MagicNumber) |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Manage manual trades: set SL to prior swing; at +X pts move SL to BE+Y and set TP."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input long   MagicNumber              = 909090; // EA will manage positions with magic != this
input ENUM_TIMEFRAMES SwingTF         = PERIOD_M1;
input int    SwingLookbackBars        = 50;     // search range for swing high/low
input int    SwingBufferPoints        = 0;      // extra buffer beyond swing (points)

input int    BreakEvenTriggerPoints   = 150;    // when profit >= this, set BE+ and TP
input int    BreakEvenPlusPoints      = 20;     // SL to entry +/- this (points)
input int    TPPoints                = 1000;   // TP distance from entry (points)

input int    SlippagePoints           = 20;

//--------------------------- Globals --------------------------------
CTrade trade;

struct TicketState {
  ulong ticket;
  bool  swingSLSet;
  bool  beTpSet;
};

TicketState g_states[200];
int g_statesCount = 0;

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double Np(const double p) { return NormalizeDouble(p, DigitsCount()); }
int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }

int FindStateIndex(const ulong ticket) {
  for (int i = 0; i < g_statesCount; i++) {
    if (g_states[i].ticket == ticket) return i;
  }
  return -1;
}

int EnsureState(const ulong ticket) {
  int idx = FindStateIndex(ticket);
  if (idx >= 0) return idx;
  if (g_statesCount >= 200) return -1;
  g_states[g_statesCount].ticket = ticket;
  g_states[g_statesCount].swingSLSet = false;
  g_states[g_statesCount].beTpSet = false;
  g_statesCount++;
  return g_statesCount - 1;
}

bool RespectStopsDistanceFromMarket(const bool isBuy, const double sl, const double tp) {
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int lvl = StopsLevelPoints();
  const double minDist = (double)lvl * pt;
  if (minDist <= 0.0) return true;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (sl > 0.0) {
    if (isBuy && (bid - sl) < (minDist - 1e-10)) return false;
    if (!isBuy && (sl - ask) < (minDist - 1e-10)) return false;
  }
  if (tp > 0.0) {
    if (isBuy && (tp - ask) < (minDist - 1e-10)) return false;
    if (!isBuy && (bid - tp) < (minDist - 1e-10)) return false;
  }
  return true;
}

bool RespectStopDistanceSLOnly(const bool isBuy, const double sl) {
  return RespectStopsDistanceFromMarket(isBuy, sl, 0.0);
}

bool RespectStopDistanceTPOnly(const bool isBuy, const double tp) {
  return RespectStopsDistanceFromMarket(isBuy, 0.0, tp);
}

double SwingLowPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  int start = 1; // use closed bars
  int count = SwingLookbackBars;
  int idx = iLowest(_Symbol, SwingTF, MODE_LOW, count, start);
  if (idx < 0) return 0.0;
  return iLow(_Symbol, SwingTF, idx);
}

double SwingHighPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  int start = 1;
  int count = SwingLookbackBars;
  int idx = iHighest(_Symbol, SwingTF, MODE_HIGH, count, start);
  if (idx < 0) return 0.0;
  return iHigh(_Symbol, SwingTF, idx);
}

double ProfitPointsForPosition(const ENUM_POSITION_TYPE typ, const double open) {
  const double pt = Pt();
  if (pt <= 0.0) return 0.0;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (typ == POSITION_TYPE_BUY) return (bid - open) / pt;
  return (open - ask) / pt;
}

//--------------------------- Core logic ------------------------------
void ManageManualPosition(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return;

  const long magic = (long)PositionGetInteger(POSITION_MAGIC);
  if (magic == MagicNumber) return; // skip EA's own positions

  const ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  const double curSL = PositionGetDouble(POSITION_SL);
  const double curTP = PositionGetDouble(POSITION_TP);

  int st = EnsureState(tk);
  if (st < 0) return;

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();

  trade.SetExpertMagicNumber(MagicNumber); // for modifications only
  trade.SetDeviationInPoints(SlippagePoints);

  // 1) Set SL to swing (only if SL is empty AND not already set by us)
  if (!g_states[st].swingSLSet && curSL <= 0.0) {
    double sl = 0.0;
    if (typ == POSITION_TYPE_BUY) {
      double sw = SwingLowPrice();
      if (sw > 0.0) sl = sw - (double)SwingBufferPoints * pt;
    } else {
      double sw = SwingHighPrice();
      if (sw > 0.0) sl = sw + (double)SwingBufferPoints * pt;
    }
    if (sl > 0.0) sl = NormalizeDouble(sl, digits);

    if (sl > 0.0 && RespectStopsDistanceFromMarket(typ == POSITION_TYPE_BUY, sl, 0.0)) {
      if (trade.PositionModify(tk, sl, curTP)) {
        g_states[st].swingSLSet = true;
      }
    }
  }

  // 2) After profit reaches trigger, set SL to BE+ and set TP (if not done)
  if (!g_states[st].beTpSet) {
    const double pPts = ProfitPointsForPosition(typ, open);
    if (pPts >= (double)BreakEvenTriggerPoints) {
      double wantSL = 0.0, wantTP = 0.0;
      if (typ == POSITION_TYPE_BUY) {
        wantSL = open + (double)BreakEvenPlusPoints * pt;
        wantTP = open + (double)TPPoints * pt;
      } else {
        wantSL = open - (double)BreakEvenPlusPoints * pt;
        wantTP = open - (double)TPPoints * pt;
      }
      wantSL = NormalizeDouble(wantSL, digits);
      wantTP = NormalizeDouble(wantTP, digits);

      // do not loosen SL if user already tightened it beyond our target
      if (curSL > 0.0) {
        if (typ == POSITION_TYPE_BUY && wantSL <= curSL) wantSL = curSL;
        if (typ == POSITION_TYPE_SELL && wantSL >= curSL) wantSL = curSL;
      }
      // if user already has TP, keep it; else set ours
      if (curTP > 0.0) wantTP = curTP;

      const bool isBuy = (typ == POSITION_TYPE_BUY);

      // If SL target is not acceptable now, keep current SL (still try to set TP).
      if (wantSL > 0.0 && !RespectStopDistanceSLOnly(isBuy, wantSL)) {
        wantSL = curSL; // may be 0, that's ok
      }
      // If TP target not acceptable now, keep current TP (or 0).
      if (wantTP > 0.0 && !RespectStopDistanceTPOnly(isBuy, wantTP)) {
        wantTP = curTP; // may be 0
      }

      // If nothing to change, still mark as done (avoids repeated calls)
      const double nCurSL = (curSL > 0.0) ? NormalizeDouble(curSL, digits) : 0.0;
      const double nCurTP = (curTP > 0.0) ? NormalizeDouble(curTP, digits) : 0.0;
      const double nWantSL = (wantSL > 0.0) ? NormalizeDouble(wantSL, digits) : 0.0;
      const double nWantTP = (wantTP > 0.0) ? NormalizeDouble(wantTP, digits) : 0.0;

      if (nCurSL == nWantSL && nCurTP == nWantTP) {
        g_states[st].beTpSet = true;
        return;
      }

      if (trade.PositionModify(tk, nWantSL, nWantTP)) {
        g_states[st].beTpSet = true;
      } else {
        Print("[ManualSwingSLTP] Modify BE/TP failed. ticket=", tk,
              " profitPts=", DoubleToString(pPts, 1),
              " wantSL=", DoubleToString(nWantSL, digits),
              " wantTP=", DoubleToString(nWantTP, digits),
              " err=", GetLastError());
      }
    }
  }
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  return INIT_SUCCEEDED;
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  // Manage all manual positions on this symbol
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0) continue;
    ManageManualPosition(tk);
  }
}

