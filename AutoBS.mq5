//+------------------------------------------------------------------+
//| AutoBS.mq5                                                       |
//| Manual-triggered fixed-lot grid, tiered shared TP, money exits.  |
//|                                                                  |
//| Attach TWICE (one chart each):                                   |
//|   Direction=BS_BUY , MagicNumber=8801                            |
//|   Direction=BS_SELL, MagicNumber=8802                            |
//| Each instance sees ONLY its own side — counts, TP and basket     |
//| money are computed separately, never combined.                   |
//|                                                                  |
//| Start : you click BUY (or SELL) at exactly LotSize (0.01).       |
//| Pause : you click the same side at StopSignalLot (0.02) ->       |
//|         pendings are deleted and NO new orders are opened, but    |
//|         open positions are kept and still managed. Close that     |
//|         0.02 order to resume.                                     |
//| Other lots (0.05, 0.3, ...) are IGNORED — trade them by hand.    |
//| Requires a HEDGING account.                                      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "AutoBS - manual-triggered grid, tiered shared TP, basket money exit."

#include <Trade/Trade.mqh>

enum ENUM_BS_DIR { BS_BUY = 0, BS_SELL = 1 };

//--------------------------- Inputs --------------------------------
input ENUM_BS_DIR Direction      = BS_BUY;  // side this instance manages
input long   MagicNumber         = 8801;    // MUST differ per instance (BUY 8801 / SELL 8802)
input double LotSize             = 0.01;    // fixed lot, and the manual START signal lot
input double StopSignalLot       = 0.02;    // manual PAUSE switch: while open -> no new orders, pendings deleted
input int    GridDistancePoints  = 1000;    // spacing between grid levels
input int    PendingCount        = 3;       // pendings kept beyond the deepest fill
input int    TPStartPoints       = 1000;    // TP when exactly 1 position is open
input int    TPStepPoints        = 100;     // TP reduction per extra position
input int    MoneyModeCount      = 10;      // above this many positions -> money mode
input double BasketTPMoney       = 1000.0;  // money mode: close all at this profit ($)
input double BasketSLMoney       = 5000.0;  // close all + go idle at this loss ($)
input int    MaxPendings         = 30;      // safety cap on pending orders
input int    SlippagePoints      = 30;
input bool   AutoStartForTest    = false;   // BACKTEST ONLY: start a cycle without the manual trigger

#define MAX_LEVEL 300

//--------------------------- Globals -------------------------------
CTrade trade;

bool   g_active = false;   // true once a cycle is running
bool   g_paused = false;   // true while a manual StopSignalLot order is open
double g_anchor = 0.0;     // entry price of the cycle's FIRST position

//--------------------------- Helpers -------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int    Dg() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
int    StopsLvl() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }

// +1 for BUY, -1 for SELL. Grid goes AGAINST this sign.
int    Dir() { return (Direction == BS_BUY) ? 1 : -1; }

ENUM_POSITION_TYPE MyPosType() {
  return (Direction == BS_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}
ENUM_ORDER_TYPE MyLimitType() {
  return (Direction == BS_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
}

bool VolEq(const double a, const double b) { return (MathAbs(a - b) < 0.0000001); }

// ---- Ownership: symbol + direction + (own magic OR adopted manual at LotSize)
bool IsMyPosition(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != MyPosType()) return false;
  const long mg = (long)PositionGetInteger(POSITION_MAGIC);
  if (mg == MagicNumber) return true;
  if (mg == 0 && VolEq(PositionGetDouble(POSITION_VOLUME), LotSize)) return true;
  return false;
}

bool IsMyOrder(const ulong ot) {
  if (ot == 0 || !OrderSelect(ot)) return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
  if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) return false;
  if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != MyLimitType()) return false;
  return true;
}

int CountMyPositions() {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--)
    if (IsMyPosition(PositionGetTicket(i))) n++;
  return n;
}

int CountMyPendings() {
  int n = 0;
  for (int j = OrdersTotal() - 1; j >= 0; j--)
    if (IsMyOrder(OrderGetTicket(j))) n++;
  return n;
}

// Floating P/L + swap of THIS side only.
double MyFloatingPL() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk)) continue;
    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

// The cycle's first entry = the least-advanced price (BUY: highest, SELL: lowest).
double FirstEntryPrice() {
  double best = 0.0;
  bool found = false;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk)) continue;
    const double op = PositionGetDouble(POSITION_PRICE_OPEN);
    if (!found) { best = op; found = true; continue; }
    if (Direction == BS_BUY) { if (op > best) best = op; }
    else                     { if (op < best) best = op; }
  }
  return found ? best : 0.0;
}

// Manual position on this side whose volume equals `lot` (0 = none).
ulong FindManualPositionWithLot(const double lot) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != MyPosType()) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;
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

//--------------------------- Grid levels ---------------------------
// Level 0 = anchor. Level k is k*GridDistance AGAINST the trade direction.
double LevelPrice(const int lv) {
  return NormalizeDouble(g_anchor - Dir() * lv * GridDistancePoints * Pt(), Dg());
}

int LevelOf(const double price) {
  const double step = GridDistancePoints * Pt();
  if (step <= 0.0) return -1;
  const double raw = (g_anchor - price) / step * (double)Dir();
  const int lv = (int)MathRound(raw);
  if (MathAbs(raw - (double)lv) > 0.35) return -1; // not on a grid level
  return lv;
}

// A limit order must sit beyond the market by at least the stops level.
bool LimitPriceOk(const double price) {
  const double minD = (double)MathMax(StopsLvl(), 1) * Pt();
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  if (Direction == BS_BUY) return ((ask - price) >= minD - 1e-10);
  return ((price - bid) >= minD - 1e-10);
}

bool PlaceLevelPending(const int lv) {
  if (CountMyPendings() >= MaxPendings) return false;
  const double price = LevelPrice(lv);
  if (price <= 0.0) return false;
  if (!LimitPriceOk(price)) return false;
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok;
  if (Direction == BS_BUY)
    ok = trade.BuyLimit(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "AutoBS");
  else
    ok = trade.SellLimit(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "AutoBS");

  if (!ok)
    Print("[AutoBS] limit failed lv=", lv, " price=", price,
          " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  return ok;
}

// Keep every level from 0..deepest armed (re-arm vacated ones), plus
// PendingCount fresh levels beyond the deepest filled position.
void MaintainGrid() {
  if (g_anchor <= 0.0) return;

  bool occ[MAX_LEVEL];
  bool pend[MAX_LEVEL];
  ArrayInitialize(occ, false);
  ArrayInitialize(pend, false);

  int deepest = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk)) continue;
    const int lv = LevelOf(PositionGetDouble(POSITION_PRICE_OPEN));
    if (lv < 0 || lv >= MAX_LEVEL) continue;
    occ[lv] = true;
    if (lv > deepest) deepest = lv;
  }
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot)) continue;
    const int lv = LevelOf(OrderGetDouble(ORDER_PRICE_OPEN));
    if (lv < 0 || lv >= MAX_LEVEL) continue;
    pend[lv] = true;
  }

  // Re-arm any vacated level above the deepest fill.
  for (int lv = 0; lv <= deepest; lv++)
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(lv);

  // Extend the ladder below the deepest fill.
  for (int k = 1; k <= PendingCount; k++) {
    const int lv = deepest + k;
    if (lv >= MAX_LEVEL) break;
    if (!occ[lv] && !pend[lv]) PlaceLevelPending(lv);
  }
}

//--------------------------- Exits ---------------------------------
void DeleteMyPendings() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot)) continue;
    if (!trade.OrderDelete(ot))
      Print("[AutoBS] OrderDelete failed ot=", ot, " ret=", trade.ResultRetcode());
  }
}

void CloseMyPositions() {
  trade.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk)) continue;
    SetMagicFor(tk);
    if (!trade.PositionClose(tk))
      Print("[AutoBS] PositionClose failed tk=", tk, " ret=", trade.ResultRetcode());
  }
}

void CloseEverything() {
  CloseMyPositions();
  DeleteMyPendings();
}

// Open the cycle's first market order and anchor the grid on it.
bool OpenFirstPosition() {
  const double lots = NormalizeLots(LotSize);
  if (lots <= 0.0) return false;
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok;
  if (Direction == BS_BUY) ok = trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "AutoBS");
  else                     ok = trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "AutoBS");

  if (!ok) {
    Print("[AutoBS] open first failed ret=", trade.ResultRetcode(), " ",
          trade.ResultRetcodeDescription());
    return false;
  }
  g_anchor = FirstEntryPrice();
  Print("[AutoBS] new cycle started, anchor=", DoubleToString(g_anchor, Dg()));
  return true;
}

void RestartCycle() {
  CloseEverything();
  g_anchor = 0.0;
  if (g_paused) { g_active = false; return; }  // paused: bank the profit, open nothing
  if (OpenFirstPosition()) MaintainGrid();
}

void GoIdle(const string why) {
  CloseEverything();
  g_active = false;
  g_anchor = 0.0;
  Print("[AutoBS] STOPPED (", why, "). Waiting for a manual ",
        (Direction == BS_BUY ? "BUY" : "SELL"), " of ", DoubleToString(LotSize, 2));
}

//--------------------------- Take profit ---------------------------
// Shared TP price for the whole side: anchor +/- (TPStart - TPStep*(n-1)).
void ApplyTP(const double tp) {
  const double eps = Pt() / 2.0;
  const bool clear = (tp <= 0.0);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsMyPosition(tk)) continue;
    const double sl = PositionGetDouble(POSITION_SL);
    const double cur = PositionGetDouble(POSITION_TP);
    if (clear) { if (cur <= 0.0) continue; }
    else       { if (cur > 0.0 && MathAbs(cur - tp) <= eps) continue; }
    SetMagicFor(tk);
    if (!trade.PositionModify(tk, sl, clear ? 0.0 : tp))
      Print("[AutoBS] TP modify failed tk=", tk, " ret=", trade.ResultRetcode());
  }

  // Mirror it onto the pendings so a fill is never left naked.
  trade.SetExpertMagicNumber(MagicNumber);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsMyOrder(ot)) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    const double cur = OrderGetDouble(ORDER_TP);
    if (clear) { if (cur <= 0.0) continue; }
    else       { if (cur > 0.0 && MathAbs(cur - tp) <= eps) continue; }
    trade.OrderModify(ot, op, 0.0, clear ? 0.0 : tp,
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
  }
}

// Returns true if the cycle was closed and restarted this tick.
bool ManageExits() {
  const int n = CountMyPositions();
  if (n <= 0) return false;

  const double pl = MyFloatingPL();

  // 1) Hard money stop for THIS side only.
  if (BasketSLMoney > 0.0 && pl <= -BasketSLMoney) {
    Print("[AutoBS] basket SL hit: ", DoubleToString(pl, 2));
    GoIdle("basket SL");
    return true;
  }

  // 2) Money mode above MoneyModeCount positions: no price TP, close on profit.
  if (n > MoneyModeCount) {
    ApplyTP(0.0); // strip any leftover price TP
    if (BasketTPMoney > 0.0 && pl >= BasketTPMoney) {
      Print("[AutoBS] basket TP hit: ", DoubleToString(pl, 2));
      RestartCycle();
      return true;
    }
    return false;
  }

  // 3) Tiered shared TP.
  const int tpPts = TPStartPoints - TPStepPoints * (n - 1);
  if (tpPts <= 0) { ApplyTP(0.0); return false; }

  const double tp = NormalizeDouble(g_anchor + Dir() * tpPts * Pt(), Dg());
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  // Price already at/through the target -> close the cycle ourselves.
  const bool reached = (Direction == BS_BUY) ? (bid >= tp) : (ask <= tp);
  if (reached) {
    Print("[AutoBS] shared TP reached (n=", n, ", ", tpPts, " pts)");
    RestartCycle();
    return true;
  }

  // Otherwise write it to the broker (only if it clears the stops level).
  const double minD = (double)MathMax(StopsLvl(), 1) * Pt();
  const bool tpOk = (Direction == BS_BUY) ? ((tp - bid) >= minD - 1e-10)
                                          : ((ask - tp) >= minD - 1e-10);
  if (tpOk) ApplyTP(tp);
  return false;
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
    Print("[AutoBS] WARNING: account is not Hedging — running BUY and SELL instances "
          "together needs a Hedging account.");

  if (VolEq(LotSize, StopSignalLot))
    Print("[AutoBS] WARNING: LotSize equals StopSignalLot — the start and stop "
          "signals cannot be told apart.");

  // Re-adopt an in-progress cycle after a restart/recompile.
  if (CountMyPositions() > 0) {
    g_anchor = FirstEntryPrice();
    g_active = true;
    Print("[AutoBS] resumed existing cycle, anchor=", DoubleToString(g_anchor, Dg()));
  }
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  // --- PAUSE switch: while a manual order at StopSignalLot is open, the EA
  // stops opening anything new and removes the pending ladder, but it LEAVES
  // the open positions alone and keeps managing their exits. Close that
  // StopSignalLot order to resume normal operation.
  const bool wasPaused = g_paused;
  g_paused = (FindManualPositionWithLot(StopSignalLot) != 0);

  if (g_paused) {
    if (!wasPaused)
      Print("[AutoBS] PAUSED by manual ", DoubleToString(StopSignalLot, 2),
            " — pendings deleted, open positions kept.");
    DeleteMyPendings();
    if (g_active && CountMyPositions() > 0) {
      if (g_anchor <= 0.0) g_anchor = FirstEntryPrice();
      if (g_anchor > 0.0) ManageExits();   // still honour TP / basket rules
    } else if (CountMyPositions() == 0) {
      g_active = false;
      g_anchor = 0.0;
    }
    return;                                 // never open anything while paused
  }
  if (wasPaused) Print("[AutoBS] RESUMED (stop order closed).");

  // --- Idle: wait for a manual order at exactly LotSize to start a cycle.
  if (!g_active) {
    const ulong startTk = FindManualPositionWithLot(LotSize);
    if (startTk != 0 && PositionSelectByTicket(startTk)) {
      g_anchor = PositionGetDouble(POSITION_PRICE_OPEN);
      g_active = true;
      Print("[AutoBS] START signal detected, anchor=", DoubleToString(g_anchor, Dg()));
    } else if (AutoStartForTest) {
      if (!OpenFirstPosition()) return;   // backtest: trigger ourselves
      g_active = true;
    } else {
      return;                              // live: keep waiting for the manual click
    }
  }

  // --- Side went flat: open the next cycle immediately.
  if (CountMyPositions() == 0) {
    DeleteMyPendings();
    g_anchor = 0.0;
    if (!OpenFirstPosition()) return;
  }

  if (g_anchor <= 0.0) g_anchor = FirstEntryPrice();
  if (g_anchor <= 0.0) return;

  if (ManageExits()) return;   // cycle closed/restarted this tick

  MaintainGrid();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  if (g_paused || !g_active || g_anchor <= 0.0) return;
  MaintainGrid();   // refill the ladder as soon as a level fills
}
//+------------------------------------------------------------------+
