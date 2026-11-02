//+------------------------------------------------------------------+
//| AutoBS.mq5  v3.00                                                |
//| Auto-start two-sided fixed-lot grid.                             |
//|                                                                  |
//| On attach each enabled side opens LotSize at market at once.     |
//| Grid : PendingCount rolling limit orders GridDistancePoints apart |
//|        (fill one -> place one), vacated levels re-armed.         |
//| SL   : ONE real server-side SL for the whole side, set at         |
//|        first-entry -/+ SLPointsFromFirst on every order.          |
//| TP   : sum over the side's open positions of (price - entry) in   |
//|        points >= TPTotalPoints -> close that whole side.          |
//| Gate : a side only (re)starts while the OPPOSITE side has fewer   |
//|        than MaxOppositeLosingOrders positions in floating loss.   |
//| Stop : click StopSignalLot on a side -> that order is closed, the |
//|        side's pendings deleted, its positions left alone, and the |
//|        side stays off until you click LotSize on it again.        |
//| limitLot caps any position you click yourself (both sides).      |
//| Every calculation is PER SIDE. Requires a HEDGING account.       |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "AutoBS v3 - auto-start grid, fixed lot, shared real SL, total-points TP, opposite-side gate."

#include <Trade/Trade.mqh>

enum ENUM_BS_MODE { BS_BUY_ONLY = 0, BS_SELL_ONLY = 1, BS_BOTH = 2 };

//--------------------------- Inputs --------------------------------
input ENUM_BS_MODE Mode              = BS_BOTH; // which side(s) to run
input long   MagicNumber             = 8801;
input double LotSize                 = 0.01;    // fixed lot for every order; also the manual RESTART lot
input double StopSignalLot           = 0.02;    // manual STOP command lot
input double limitLot                = 0.3;     // cap on positions you click yourself (0 = off)
input int    GridDistancePoints      = 500;     // spacing between grid levels
input int    SLPointsFromFirst       = 50000;   // shared SL distance from the side's first entry
input int    TPTotalPoints           = 1000;    // close the side when its total points >= this
input int    MaxOppositeLosingOrders = 15;      // (re)start only if opposite side has fewer losing positions
input int    PendingCount            = 5;       // rolling pendings kept beyond the deepest fill
input int    SlippagePoints          = 30;

#define MAX_LEVEL 400
#define SIDE_BUY  0
#define SIDE_SELL 1

//--------------------------- Globals -------------------------------
CTrade trade;

// Per side: [0] = BUY, [1] = SELL. Nothing is shared.
bool     g_stopped[2];      // latched off by this side's StopSignalLot command
datetime g_stopTime[2];     // when that stop happened
datetime g_cycleStart[2];   // only positions opened at/after this belong to the cycle
double   g_anchor[2];       // entry price of the cycle's FIRST position
double   g_sl[2];           // the one SL price shared by the whole side

//--------------------------- Side helpers --------------------------
int    DirOf(const int s)    { return (s == SIDE_BUY) ? 1 : -1; }
string SideName(const int s) { return (s == SIDE_BUY) ? "BUY" : "SELL"; }
int    OppOf(const int s)    { return 1 - s; }

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

// State survives recompile / terminal restart, keyed per magic AND side.
string GvKey(const int s, const string k) {
  return "AutoBS3_" + IntegerToString(MagicNumber) + "_" + SideName(s) + "_" + k;
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
double MinStopDist() { return (double)MathMax(StopsLvl(), 1) * Pt(); }
bool   VolEq(const double a, const double b) { return (MathAbs(a - b) < 0.0000001); }

// ---- Ownership: symbol + this side + cycle window + (own magic OR manual LotSize)
bool IsMyPosition(const ulong tk, const int s) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != PosTypeOf(s)) return false;
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

// Positions of the OPPOSITE side that are currently in floating loss.
int CountOppositeLosing(const int s) {
  const int o = OppOf(s);
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, o)) continue;
    if (PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) < 0.0) n++;
  }
  return n;
}

// Sum of (price - entry) in points over this side's open positions.
double SidePointsSum(const int s) {
  const double pt = Pt();
  if (pt <= 0.0) return 0.0;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    const double op = PositionGetDouble(POSITION_PRICE_OPEN);
    sum += (s == SIDE_BUY) ? (bid - op) / pt : (op - ask) / pt;
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
// Any MANUAL (magic 0) position on this symbol bigger than limitLot is partially
// closed down to limitLot, on both sides regardless of Mode.
void EnforceManualLotLimit() {
  if (limitLot <= 0.0) return;
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (step <= 0.0) step = 0.01;
  const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double cap = NormalizeDouble(MathFloor(limitLot / step + 1e-7) * step, 2);
  if (cap < minLot) return;
  const double eps = step * 0.01;

  trade.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;
    const double vol = PositionGetDouble(POSITION_VOLUME);
    if (vol <= cap + eps) continue;
    double closeVol = NormalizeDouble(MathFloor((vol - cap) / step + 1e-7) * step, 2);
    if (closeVol < minLot - eps) continue;
    if (closeVol >= vol - eps) continue;
    trade.SetExpertMagicNumber(0);
    if (trade.PositionClosePartial(tk, closeVol))
      Print("[AutoBS] limitLot: trimmed manual ticket ", tk, " from ",
            DoubleToString(vol, 2), " to ", DoubleToString(vol - closeVol, 2));
    else
      Print("[AutoBS] limitLot: partial close failed tk=", tk, " ret=", trade.ResultRetcode());
  }
}

//--------------------------- SL ------------------------------------
double ComputeSL(const int s) {
  if (g_anchor[s] <= 0.0 || SLPointsFromFirst <= 0) return 0.0;
  return NormalizeDouble(g_anchor[s] - DirOf(s) * SLPointsFromFirst * Pt(), Dg());
}

// Write the side's one SL price onto every position and pending that lacks it.
void ApplySharedSL(const int s) {
  const double sl = g_sl[s];
  if (sl <= 0.0) return;
  const double eps = Pt() / 2.0;
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    const double cur = PositionGetDouble(POSITION_SL);
    if (cur > 0.0 && MathAbs(cur - sl) <= eps) continue;
    const double tp = PositionGetDouble(POSITION_TP);
    SetMagicFor(tk);
    if (!trade.PositionModify(tk, sl, tp))
      Print("[AutoBS ", SideName(s), "] SL modify failed tk=", tk, " ret=", trade.ResultRetcode());
  }

  trade.SetExpertMagicNumber(MagicNumber);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot, s)) continue;
    const double cur = OrderGetDouble(ORDER_SL);
    if (cur > 0.0 && MathAbs(cur - sl) <= eps) continue;
    trade.OrderModify(ot, OrderGetDouble(ORDER_PRICE_OPEN), sl, OrderGetDouble(ORDER_TP),
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
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
  if (MathAbs(raw - (double)lv) > 0.35) return -1;
  return lv;
}

// A level sits at/beyond the side's SL (no point placing it).
bool LevelBeyondSL(const int s, const int lv) {
  if (g_sl[s] <= 0.0) return false;
  const double price = LevelPrice(s, lv);
  return (DirOf(s) * (price - g_sl[s]) <= MinStopDist());
}

// A limit order must sit beyond the market by at least the stops level.
bool LimitPriceOk(const int s, const double price) {
  const double minD = MinStopDist();
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if (s == SIDE_BUY) return ((ask - price) >= minD - 1e-10);
  return ((price - bid) >= minD - 1e-10);
}

bool PlaceLevelPending(const int s, const int lv) {
  if (LevelBeyondSL(s, lv)) return false;
  const double price = LevelPrice(s, lv);
  if (price <= 0.0) return false;
  if (!LimitPriceOk(s, price)) return false;
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  bool ok;
  if (s == SIDE_BUY)
    ok = trade.BuyLimit(lots, price, _Symbol, g_sl[s], 0.0, ORDER_TIME_GTC, 0, "AutoBS");
  else
    ok = trade.SellLimit(lots, price, _Symbol, g_sl[s], 0.0, ORDER_TIME_GTC, 0, "AutoBS");
  if (!ok)
    Print("[AutoBS ", SideName(s), "] limit failed lv=", lv, " price=", price,
          " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

// Keep every level 1..deepest armed (re-arm vacated ones) plus PendingCount
// fresh levels beyond the deepest fill, never past the SL.
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

  for (int lv = 1; lv <= deepest; lv++)
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(s, lv);

  for (int k = 1; k <= PendingCount; k++) {
    const int lv = deepest + k;
    if (lv >= MAX_LEVEL) break;
    if (LevelBeyondSL(s, lv)) break;
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(s, lv);
  }
}

//--------------------------- Exits / cycle -------------------------
void DeleteMyPendings(const int s) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot, s)) continue;
    if (!trade.OrderDelete(ot))
      Print("[AutoBS ", SideName(s), "] OrderDelete failed ot=", ot, " ret=", trade.ResultRetcode());
  }
}

void CloseMyPositions(const int s) {
  trade.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk, s)) continue;
    SetMagicFor(tk);
    if (!trade.PositionClose(tk))
      Print("[AutoBS ", SideName(s), "] PositionClose failed tk=", tk, " ret=", trade.ResultRetcode());
  }
}

void CloseEverything(const int s) {
  CloseMyPositions(s);
  DeleteMyPendings(s);
}

// Open the side's first market order, anchor the grid on it and set the SL.
bool OpenFirstPosition(const int s) {
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;
  g_cycleStart[s] = TimeCurrent();   // stamp BEFORE opening so older positions stay disowned
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
  g_sl[s]     = ComputeSL(s);
  ApplySharedSL(s);
  Print("[AutoBS ", SideName(s), "] new cycle: anchor=", DoubleToString(g_anchor[s], Dg()),
        " SL=", DoubleToString(g_sl[s], Dg()));
  return true;
}

//--------------------------- Per-side tick -------------------------
void ProcessSide(const int s) {
  // --- STOP command: a manual order at StopSignalLot is a COMMAND, not a trade.
  const ulong stopTk = FindManualPositionWithLot(s, StopSignalLot, 0);
  if (stopTk != 0) {
    trade.SetDeviationInPoints(SlippagePoints);
    trade.SetExpertMagicNumber(0);
    if (!trade.PositionClose(stopTk))
      Print("[AutoBS ", SideName(s), "] could not close the stop command order, ret=", trade.ResultRetcode());
    DeleteMyPendings(s);
    g_stopped[s]    = true;
    g_stopTime[s]   = TimeCurrent();
    g_cycleStart[s] = g_stopTime[s];   // disown everything opened before now
    g_anchor[s]     = 0.0;
    g_sl[s]         = 0.0;
    SaveState(s);
    Print("[AutoBS ", SideName(s), "] STOPPED by manual ", DoubleToString(StopSignalLot, 2),
          " - pendings deleted, open positions left untouched. Click ",
          DoubleToString(LotSize, 2), " to start again.");
    return;
  }

  // --- Stopped: only a manual LotSize order opened AFTER the stop restarts the side.
  if (g_stopped[s]) {
    const ulong startTk = FindManualPositionWithLot(s, LotSize, g_stopTime[s]);
    if (startTk == 0 || !PositionSelectByTicket(startTk)) return;
    g_cycleStart[s] = (datetime)PositionGetInteger(POSITION_TIME);
    g_anchor[s]     = PositionGetDouble(POSITION_PRICE_OPEN);
    g_sl[s]         = ComputeSL(s);
    g_stopped[s]    = false;
    SaveState(s);
    Print("[AutoBS ", SideName(s), "] RESTARTED by manual ", DoubleToString(LotSize, 2),
          ", anchor=", DoubleToString(g_anchor[s], Dg()));
  }

  // --- Flat (fresh attach, after TP, or after SL): start a new cycle if allowed.
  if (CountMyPositions(s) == 0) {
    DeleteMyPendings(s);          // e.g. leftovers after an SL hit
    g_anchor[s] = 0.0;
    g_sl[s]     = 0.0;
    const int oppLosing = CountOppositeLosing(s);
    if (oppLosing >= MaxOppositeLosingOrders) return;   // opposite side too deep - wait
    if (!OpenFirstPosition(s)) return;
  }

  if (g_anchor[s] <= 0.0) { g_anchor[s] = FirstEntryPrice(s); g_sl[s] = ComputeSL(s); }
  if (g_anchor[s] <= 0.0) return;

  // --- TP: total points over the side's open positions.
  const double pts = SidePointsSum(s);
  if (TPTotalPoints > 0 && pts >= (double)TPTotalPoints) {
    Print("[AutoBS ", SideName(s), "] TP: total ", DoubleToString(pts, 1),
          " pts >= ", TPTotalPoints, " - closing side");
    CloseEverything(s);
    g_anchor[s] = 0.0;
    g_sl[s]     = 0.0;
    return;                       // next tick decides whether to restart
  }

  // --- Keep the shared SL and the ladder in shape.
  ApplySharedSL(s);
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
    Print("[AutoBS] WARNING: account is not Hedging - running BUY and SELL together needs Hedging.");
  if (VolEq(LotSize, StopSignalLot))
    Print("[AutoBS] WARNING: LotSize equals StopSignalLot - restart and stop signals clash.");
  if (limitLot > 0.0 && (VolEq(limitLot, LotSize) || VolEq(limitLot, StopSignalLot)))
    Print("[AutoBS] WARNING: limitLot equals LotSize/StopSignalLot - a trimmed order would look like a signal.");

  for (int s = 0; s < 2; s++) {
    g_stopped[s]    = false;
    g_stopTime[s]   = 0;
    g_cycleStart[s] = 0;
    g_anchor[s]     = 0.0;
    g_sl[s]         = 0.0;
    if (!SideEnabled(s)) continue;
    LoadState(s);
    if (!g_stopped[s] && CountMyPositions(s) > 0) {   // resume an in-progress cycle
      g_anchor[s] = FirstEntryPrice(s);
      g_sl[s]     = ComputeSL(s);
      Print("[AutoBS ", SideName(s), "] resumed cycle, anchor=", DoubleToString(g_anchor[s], Dg()));
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
  EnforceManualLotLimit();
  for (int s = 0; s < 2; s++) {
    if (!SideEnabled(s) || g_stopped[s] || g_anchor[s] <= 0.0) continue;
    ApplySharedSL(s);   // a fresh fill gets the side's SL at once
    MaintainGrid(s);    // and the ladder is refilled at once
  }
}
//+------------------------------------------------------------------+
