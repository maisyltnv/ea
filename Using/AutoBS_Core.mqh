//+------------------------------------------------------------------+
//| AutoBS_Core.mqh                                                  |
//| Shared engine for AutoBS / AutoB / AutoS.                        |
//|                                                                  |
//| Manual-triggered fixed-lot grid, tiered shared TP, per-side      |
//| basket money exits. Every calculation - position count, anchor,  |
//| shared TP, basket profit and basket loss - is kept PER SIDE and  |
//| never combined.                                                  |
//|                                                                  |
//| Start : click BUY  at exactly LotSize (0.01) -> starts BUY side  |
//|         click SELL at exactly LotSize (0.01) -> starts SELL side |
//| Stop  : click the same side at StopSignalLot (0.02). That is a   |
//|         COMMAND, not a trade: the 0.02 order is closed at once,  |
//|         that side's pending ladder is deleted, its open          |
//|         positions are LEFT ALONE (never touched again), and the  |
//|         side stays off until you click 0.01 on it again.         |
//| Other lots (0.05, 0.3, ...) are IGNORED - trade them by hand,    |
//| but limitLot caps their SIZE (a manual 1.0 is trimmed to 0.3).   |
//| Requires a HEDGING account.                                      |
//|                                                                  |
//| A wrapper may #define BS_FIXED_MODE to lock the side and hide    |
//| the Mode input.                                                  |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

enum ENUM_BS_MODE { BS_BUY_ONLY = 0, BS_SELL_ONLY = 1, BS_BOTH = 2 };

//--------------------------- Inputs --------------------------------
#ifdef BS_FIXED_MODE
const ENUM_BS_MODE Mode = BS_FIXED_MODE;   // fixed by the wrapper EA
#else
input ENUM_BS_MODE Mode          = BS_BOTH; // which side(s) this instance manages
#endif
input long   MagicNumber         = 8801;    // EA's own orders
input double LotSize             = 0.01;    // fixed lot, and the manual START signal lot
input double StopSignalLot       = 0.02;    // manual STOP command: closes itself, kills that side's ladder
input double limitLot            = 0.3;     // cap on MANUAL orders: anything bigger is partially closed down to this (0 = off)
input int    GridDistancePoints  = 1000;    // spacing between grid levels
input int    PendingCount        = 3;       // pendings kept beyond the deepest fill
input int    TPStartPoints       = 1000;    // TP when exactly 1 position is open
input int    TPStepPoints        = 100;     // TP reduction per extra position
input int    MoneyModeCount      = 10;      // above this many positions -> money mode
input double BasketTPMoney       = 1000.0;  // money mode: close that side at this profit ($)
input double BasketSLMoney       = 5000.0;  // close that side + stop it at this loss ($)
input int    MaxPendings         = 30;      // safety cap on pending orders, per side
input int    SlippagePoints      = 30;
input bool   AutoStartForTest    = false;   // BACKTEST ONLY: start without the manual trigger

#define MAX_LEVEL 300
#define SIDE_BUY  0
#define SIDE_SELL 1

//--------------------------- Globals -------------------------------
CTrade trade;

// All state is per side: [0] = BUY, [1] = SELL. Nothing is ever shared.
bool     g_active[2];       // a cycle is running on this side
bool     g_stopped[2];      // latched off by this side's StopSignalLot command
datetime g_stopTime[2];     // when that stop happened
datetime g_cycleStart[2];   // ONLY positions opened at/after this belong to the cycle
double   g_anchor[2];       // entry price of the cycle's FIRST position

//--------------------------- Side helpers --------------------------
int    DirOf(const int s) { return (s == SIDE_BUY) ? 1 : -1; }
string SideName(const int s) { return (s == SIDE_BUY) ? "BUY" : "SELL"; }

ENUM_POSITION_TYPE PosTypeOf(const int s) {
  return (s == SIDE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}
ENUM_ORDER_TYPE LimitTypeOf(const int s) {
  return (s == SIDE_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
}
bool SideEnabled(const int s) {
  if (Mode == BS_BOTH) return true;
  return (Mode == BS_BUY_ONLY) ? (s == SIDE_BUY) : (s == SIDE_SELL);
}

// State survives recompile / terminal restart, keyed per magic AND per side.
string GvKey(const int s, const string k) {
  return "AutoBS_" + IntegerToString(MagicNumber) + "_" + SideName(s) + "_" + k;
}
void SaveState(const int s) {
  GlobalVariableSet(GvKey(s, "cycleStart"), (double)g_cycleStart[s]);
  GlobalVariableSet(GvKey(s, "stopTime"),   (double)g_stopTime[s]);
  GlobalVariableSet(GvKey(s, "stopped"),    g_stopped[s] ? 1.0 : 0.0);
}
void LoadState(const int s) {
  if (GlobalVariableCheck(GvKey(s, "cycleStart")))
    g_cycleStart[s] = (datetime)GlobalVariableGet(GvKey(s, "cycleStart"));
  if (GlobalVariableCheck(GvKey(s, "stopTime")))
    g_stopTime[s] = (datetime)GlobalVariableGet(GvKey(s, "stopTime"));
  if (GlobalVariableCheck(GvKey(s, "stopped")))
    g_stopped[s] = (GlobalVariableGet(GvKey(s, "stopped")) > 0.5);
}

//--------------------------- Market helpers ------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int    Dg() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
int    StopsLvl() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
bool   VolEq(const double a, const double b) { return (MathAbs(a - b) < 0.0000001); }

// ---- Ownership: symbol + this side + cycle window + (own magic OR manual LotSize)
bool IsMyPosition(const ulong tk, const int s) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != PosTypeOf(s)) return false;
  // Positions opened before this side's cycle started are NOT ours - that is
  // what keeps a stopped cycle's leftovers out of the next one.
  if (g_cycleStart[s] > 0 &&
      (datetime)PositionGetInteger(POSITION_TIME) < g_cycleStart[s]) return false;
  const long mg = (long)PositionGetInteger(POSITION_MAGIC);
  if (mg == MagicNumber) return true;
  if (mg == 0 && VolEq(PositionGetDouble(POSITION_VOLUME), LotSize)) return true;
  return false;
}

bool IsMyOrder(const ulong ot, const int s) {
  if (ot == 0 || !OrderSelect(ot)) return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
  if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) return false;
  if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != LimitTypeOf(s)) return false;
  return true;
}

int CountMyPositions(const int s) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
    if (IsMyPosition(PositionGetTicket(i), s)) n++;
  return n;
}

int CountMyPendings(const int s) {
  int n = 0;
  for (int j = OrdersTotal() - 1; j >= 0; j--)
    if (IsMyOrder(OrderGetTicket(j), s)) n++;
  return n;
}

// Floating P/L + swap of THIS side only.
double MyFloatingPL(const int s) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

// The cycle's first entry = the least-advanced price (BUY: highest, SELL: lowest).
double FirstEntryPrice(const int s) {
  double best = 0.0;
  bool found = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    const double op = PositionGetDouble(POSITION_PRICE_OPEN);
    if (!found) { best = op; found = true; continue; }
    if (s == SIDE_BUY) { if (op > best) best = op; }
    else               { if (op < best) best = op; }
  }
  return found ? best : 0.0;
}

// Manual (magic 0) position on this side with this volume, opened at/after minTime.
ulong FindManualPositionWithLot(const int s, const double lot, const datetime minTime) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != PosTypeOf(s)) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;
    if (minTime > 0 && (datetime)PositionGetInteger(POSITION_TIME) < minTime) continue;
    if (VolEq(PositionGetDouble(POSITION_VOLUME), lot)) return tk;
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

void SetMagicFor(const ulong tk) {
  if (!PositionSelectByTicket(tk)) return;
  if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
    trade.SetExpertMagicNumber(MagicNumber);
  else
    trade.SetExpertMagicNumber(0); // adopted manual: broker wants a neutral magic
}

//--------------------------- Manual lot cap ------------------------
// Any MANUAL (magic 0) position on this symbol bigger than limitLot is
// partially closed down to limitLot. Applies to BOTH sides regardless of Mode,
// and never touches the EA's own orders or another EA's orders.
// Trimming only caps the SIZE - it does NOT make the EA manage that position.
void EnforceManualLotLimit() {
  if (limitLot <= 0.0) return;

  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (step <= 0.0) step = 0.01;
  const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double cap = NormalizeDouble(MathFloor(limitLot / step + 1e-7) * step, 2);
  if (cap < minLot) return;              // cap smaller than the broker minimum
  const double eps = step * 0.01;

  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;   // manual only

    const double vol = PositionGetDouble(POSITION_VOLUME);
    if (vol <= cap + eps) continue;

    double closeVol = NormalizeDouble(MathFloor((vol - cap) / step + 1e-7) * step, 2);
    if (closeVol < minLot - eps) continue;   // remainder too small to close
    if (closeVol >= vol - eps) continue;     // would close the whole position

    trade.SetExpertMagicNumber(0);           // manual: neutral magic
    if (trade.PositionClosePartial(tk, closeVol))
      Print("[AutoBS] limitLot: trimmed manual ticket ", tk, " from ",
            DoubleToString(vol, 2), " to ", DoubleToString(vol - closeVol, 2));
    else
      Print("[AutoBS] limitLot: partial close failed tk=", tk,
            " vol=", DoubleToString(vol, 2), " close=", DoubleToString(closeVol, 2),
            " ret=", trade.ResultRetcode());
  }
}

//--------------------------- Grid levels ---------------------------
// Level 0 = anchor. Level k is k*GridDistance AGAINST the trade direction.
double LevelPrice(const int s, const int lv) {
  return NormalizeDouble(g_anchor[s] - DirOf(s) * lv * GridDistancePoints * Pt(), Dg());
}

int LevelOf(const int s, const double price) {
  const double step = GridDistancePoints * Pt();
  if (step <= 0.0) return -1;
  const double raw = (g_anchor[s] - price) / step * (double)DirOf(s);
  const int lv = (int)MathRound(raw);
  if (MathAbs(raw - (double)lv) > 0.35) return -1; // not on a grid level
  return lv;
}

// A limit order must sit beyond the market by at least the stops level.
bool LimitPriceOk(const int s, const double price) {
  const double minD = (double)MathMax(StopsLvl(), 1) * Pt();
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if (s == SIDE_BUY) return ((ask - price) >= minD - 1e-10);
  return ((price - bid) >= minD - 1e-10);
}

bool PlaceLevelPending(const int s, const int lv) {
  if (CountMyPendings(s) >= MaxPendings) return false;
  const double price = LevelPrice(s, lv);
  if (price <= 0.0) return false;
  if (!LimitPriceOk(s, price)) return false;
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok;
  if (s == SIDE_BUY)
    ok = trade.BuyLimit(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "AutoBS");
  else
    ok = trade.SellLimit(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "AutoBS");

  if (!ok)
    Print("[AutoBS ", SideName(s), "] limit failed lv=", lv, " price=", price,
          " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

// Keep every level 0..deepest armed (re-arm vacated ones), plus PendingCount
// fresh levels beyond the deepest filled position.
void MaintainGrid(const int s) {
  if (g_anchor[s] <= 0.0) return;

  bool occ[MAX_LEVEL];
  bool pend[MAX_LEVEL];
  ArrayInitialize(occ, false);
  ArrayInitialize(pend, false);

  int deepest = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    const int lv = LevelOf(s, PositionGetDouble(POSITION_PRICE_OPEN));
    if (lv < 0 || lv >= MAX_LEVEL) continue;
    occ[lv] = true;
    if (lv > deepest) deepest = lv;
  }
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot, s)) continue;
    const int lv = LevelOf(s, OrderGetDouble(ORDER_PRICE_OPEN));
    if (lv < 0 || lv >= MAX_LEVEL) continue;
    pend[lv] = true;
  }

  // Re-arm any vacated level above the deepest fill.
  for (int lv = 0; lv <= deepest; lv++)
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(s, lv);

  // Extend the ladder below the deepest fill.
  for (int k = 1; k <= PendingCount; k++) {
    const int lv = deepest + k;
    if (lv >= MAX_LEVEL) break;
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(s, lv);
  }
}

//--------------------------- Exits ---------------------------------
void DeleteMyPendings(const int s) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot, s)) continue;
    if (!trade.OrderDelete(ot))
      Print("[AutoBS ", SideName(s), "] OrderDelete failed ot=", ot,
            " ret=", trade.ResultRetcode());
  }
}

void CloseMyPositions(const int s) {
  trade.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    SetMagicFor(tk);
    if (!trade.PositionClose(tk))
      Print("[AutoBS ", SideName(s), "] PositionClose failed tk=", tk,
            " ret=", trade.ResultRetcode());
  }
}

void CloseEverything(const int s) {
  CloseMyPositions(s);
  DeleteMyPendings(s);
}

// Open this side's first market order and anchor its grid on it.
bool OpenFirstPosition(const int s) {
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;
  // Stamp the new cycle BEFORE opening so older positions stay disowned.
  g_cycleStart[s] = TimeCurrent();
  SaveState(s);
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok;
  if (s == SIDE_BUY) ok = trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "AutoBS");
  else               ok = trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "AutoBS");

  if (!ok) {
    Print("[AutoBS ", SideName(s), "] open first failed ret=", trade.ResultRetcode(),
          " ", trade.ResultRetcodeDescription());
    return false;
  }
  g_anchor[s] = FirstEntryPrice(s);
  Print("[AutoBS ", SideName(s), "] new cycle started, anchor=",
        DoubleToString(g_anchor[s], Dg()));
  return true;
}

void RestartCycle(const int s) {
  CloseEverything(s);
  g_anchor[s] = 0.0;
  if (g_stopped[s]) { g_active[s] = false; return; } // stopped: open nothing
  if (OpenFirstPosition(s)) MaintainGrid(s);
}

void StopSide(const int s, const string why) {
  CloseEverything(s);
  g_active[s]     = false;
  g_stopped[s]    = true;
  g_anchor[s]     = 0.0;
  g_stopTime[s]   = TimeCurrent();
  g_cycleStart[s] = g_stopTime[s];
  SaveState(s);
  Print("[AutoBS ", SideName(s), "] STOPPED (", why, "). Click ",
        DoubleToString(LotSize, 2), " on this side to start again.");
}

//--------------------------- Take profit ---------------------------
// One shared TP price for the whole side: anchor +/- (TPStart - TPStep*(n-1)).
void ApplyTP(const int s, const double tp) {
  const double eps = Pt() / 2.0;
  const bool clear = (tp <= 0.0);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    const double sl = PositionGetDouble(POSITION_SL);
    const double cur = PositionGetDouble(POSITION_TP);
    if (clear) { if (cur <= 0.0) continue; }
    else       { if (cur > 0.0 && MathAbs(cur - tp) <= eps) continue; }
    SetMagicFor(tk);
    if (!trade.PositionModify(tk, sl, clear ? 0.0 : tp))
      Print("[AutoBS ", SideName(s), "] TP modify failed tk=", tk,
            " ret=", trade.ResultRetcode());
  }

  // Mirror it onto the pendings so a fill is never left naked.
  trade.SetExpertMagicNumber(MagicNumber);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot, s)) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    const double cur = OrderGetDouble(ORDER_TP);
    if (clear) { if (cur <= 0.0) continue; }
    else       { if (cur > 0.0 && MathAbs(cur - tp) <= eps) continue; }
    trade.OrderModify(ot, op, 0.0, clear ? 0.0 : tp,
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
  }
}

// Returns true if this side's cycle was closed/restarted on this tick.
bool ManageExits(const int s) {
  const int n = CountMyPositions(s);
  if (n <= 0) return false;

  const double pl = MyFloatingPL(s);

  // 1) Hard money stop for THIS side only.
  if (BasketSLMoney > 0.0 && pl <= -BasketSLMoney) {
    Print("[AutoBS ", SideName(s), "] basket SL hit: ", DoubleToString(pl, 2));
    StopSide(s, "basket SL");
    return true;
  }

  // 2) Money mode above MoneyModeCount positions: no price TP, close on profit.
  if (n > MoneyModeCount) {
    ApplyTP(s, 0.0); // strip any leftover price TP
    if (BasketTPMoney > 0.0 && pl >= BasketTPMoney) {
      Print("[AutoBS ", SideName(s), "] basket TP hit: ", DoubleToString(pl, 2));
      RestartCycle(s);
      return true;
    }
    return false;
  }

  // 3) Tiered shared TP.
  const int tpPts = TPStartPoints - TPStepPoints * (n - 1);
  if (tpPts <= 0) { ApplyTP(s, 0.0); return false; }

  const double tp = NormalizeDouble(g_anchor[s] + DirOf(s) * tpPts * Pt(), Dg());
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  // Price already at/through the target -> close the cycle ourselves.
  const bool reached = (s == SIDE_BUY) ? (bid >= tp) : (ask <= tp);
  if (reached) {
    Print("[AutoBS ", SideName(s), "] shared TP reached (n=", n, ", ", tpPts, " pts)");
    RestartCycle(s);
    return true;
  }

  // Otherwise write it to the broker (only if it clears the stops level).
  const double minD = (double)MathMax(StopsLvl(), 1) * Pt();
  const bool tpOk = (s == SIDE_BUY) ? ((tp - bid) >= minD - 1e-10)
                                    : ((ask - tp) >= minD - 1e-10);
  if (tpOk) ApplyTP(s, tp);
  return false;
}

//--------------------------- Per-side tick -------------------------
void ProcessSide(const int s) {
  // --- STOP command: a manual order at StopSignalLot is a COMMAND, not a trade.
  const ulong stopTk = FindManualPositionWithLot(s, StopSignalLot, 0);
  if (stopTk != 0) {
    trade.SetDeviationInPoints(SlippagePoints);
    trade.SetExpertMagicNumber(0);
    if (!trade.PositionClose(stopTk))
      Print("[AutoBS ", SideName(s), "] could not close the stop command order, ret=",
            trade.ResultRetcode());

    DeleteMyPendings(s);               // remove this side's ladder only
    g_stopped[s]    = true;
    g_stopTime[s]   = TimeCurrent();
    g_cycleStart[s] = g_stopTime[s];   // disown everything opened before now
    g_active[s]     = false;
    g_anchor[s]     = 0.0;
    SaveState(s);
    Print("[AutoBS ", SideName(s), "] STOPPED by manual ",
          DoubleToString(StopSignalLot, 2),
          " - pendings deleted, open positions left untouched. Click ",
          DoubleToString(LotSize, 2), " to start again.");
    return;
  }

  // --- Idle / stopped: only a manual LotSize order opened AFTER the stop starts
  // a new cycle. Positions left over from the stopped cycle stay ignored.
  if (!g_active[s]) {
    const ulong startTk = FindManualPositionWithLot(s, LotSize, g_stopTime[s]);
    if (startTk != 0 && PositionSelectByTicket(startTk)) {
      g_cycleStart[s] = (datetime)PositionGetInteger(POSITION_TIME);
      g_anchor[s]     = PositionGetDouble(POSITION_PRICE_OPEN);
      g_active[s]     = true;
      g_stopped[s]    = false;
      SaveState(s);
      Print("[AutoBS ", SideName(s), "] START signal detected, anchor=",
            DoubleToString(g_anchor[s], Dg()));
    } else if (AutoStartForTest && !g_stopped[s]) {
      if (!OpenFirstPosition(s)) return;   // backtest: trigger ourselves
      g_active[s] = true;
    } else {
      return;                               // live: keep waiting for the manual click
    }
  }

  // --- Side went flat: open the next cycle immediately.
  if (CountMyPositions(s) == 0) {
    DeleteMyPendings(s);
    g_anchor[s] = 0.0;
    if (!OpenFirstPosition(s)) return;
  }

  if (g_anchor[s] <= 0.0) g_anchor[s] = FirstEntryPrice(s);
  if (g_anchor[s] <= 0.0) return;

  if (ManageExits(s)) return;   // cycle closed/restarted this tick

  MaintainGrid(s);
}

//--------------------------- MT5 events ----------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)      trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
  else                                     trade.SetTypeFilling(ORDER_FILLING_RETURN);

  if ((long)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    Print("[AutoBS] WARNING: account is not Hedging - holding BUY and SELL together "
          "needs a Hedging account.");

  if (VolEq(LotSize, StopSignalLot))
    Print("[AutoBS] WARNING: LotSize equals StopSignalLot - the start and stop "
          "signals cannot be told apart.");

  if (limitLot > 0.0 && (VolEq(limitLot, LotSize) || VolEq(limitLot, StopSignalLot)))
    Print("[AutoBS] WARNING: limitLot equals LotSize/StopSignalLot - a trimmed manual "
          "order would look like a start/stop signal. Pick a different value.");

  for (int s = 0; s < 2; s++) {
    g_active[s]     = false;
    g_stopped[s]    = false;
    g_stopTime[s]   = 0;
    g_cycleStart[s] = 0;
    g_anchor[s]     = 0.0;
    if (!SideEnabled(s)) continue;

    LoadState(s);
    // Re-adopt an in-progress cycle after a restart/recompile.
    if (!g_stopped[s] && CountMyPositions(s) > 0) {
      g_anchor[s] = FirstEntryPrice(s);
      g_active[s] = true;
      Print("[AutoBS ", SideName(s), "] resumed existing cycle, anchor=",
            DoubleToString(g_anchor[s], Dg()));
    }
  }
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);
  EnforceManualLotLimit();
  for (int s = 0; s < 2; s++)
    if (SideEnabled(s)) ProcessSide(s);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  EnforceManualLotLimit();   // cut an oversized manual entry within the same second
  for (int s = 0; s < 2; s++) {
    if (!SideEnabled(s)) continue;
    if (g_stopped[s] || !g_active[s] || g_anchor[s] <= 0.0) continue;
    MaintainGrid(s);   // refill that side's ladder as soon as a level fills
  }
}
//+------------------------------------------------------------------+
