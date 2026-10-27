//+------------------------------------------------------------------+
//| MGridBS.mq5                                                      |
//| Manual manager + signal ALERTS. Manages magic != MagicNumber.    |
//|                                                                  |
//| Manager: swing SL (+grid pendings, increaseLot), count-based TP  |
//|   per side: TP = first entry + TPRiskReward x first SL distance,  |
//|   per-side USD stop, MaxLotPerLeg.                               |
//| You may TIGHTEN the side SL (never widen) and move the side TP   |
//|   on the oldest leg — EA copies it to every leg + grid pending.  |
//| Over-trading guards per side: MinOrdersBeforeAdd, MaxTotalLot,   |
//|   MaxTotalOrders (manual add that breaks a rule is closed back). |
//| ALERT (AutoTF): BUY EMA50>EMA200 & close>EMA50 & %K<=BuyLevel;    |
//|   SELL mirror. Popup / push / sound only — you click the order.   |
//| Version history: see git.                                        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "MGridBS - grid, shared SL/TP you can trail, 6-tier TP, per-side USD stop, over-trading guards."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input long   MagicNumber              = 909090; // EA will manage positions with magic != this
input ENUM_TIMEFRAMES SwingTF         = PERIOD_M1;
input int    SwingLookbackBars        = 50;     // search range for swing high/low
input int    SwingBufferPoints        = 200;    // SL = swing low - this (BUY) / swing high + this (SELL), points
input int    MinSLDistancePoints      = 1000;   // first SL only: if entry→SL < this, push SL out to exactly this (0=off)

//------- Shared TP per side -------
input double TPRiskReward             = 1.5;    // TP = first entry + this x (first entry→first SL); same TP on every leg (0=off)

input int    SlippagePoints           = 20;

input bool   UseGridPendingOrders     = true;   // after swing SL is set
input int    GridExtraPendingLegs     = 3;      // grid legs when entry→SL >= GridFullDistancePoints; fewer when closer (min 1)
input int    GridFullDistancePoints   = 1000;   // entry→SL distance that gets the full leg count; legs are spread evenly entry→SL
input double increaseLot              = 0.01;    // grid: add this lot to each next leg (0=all equal; e.g. 0.02 → leg1 base, leg2 +0.02, leg3 +0.04 …)
input double MaxLotPerLeg             = 0.03;   // max lot per leg; bigger open is partially closed down to this (0=off)
input int    MinOrdersBeforeAdd       = 2;      // manual add while side is losing: side must already have >= this open legs (grid level 1 filled), else close it back (0=off)
input double MaxTotalLot              = 0.1;    // per side: sum of open lots must stay <= this; manual add over it is closed back, grid stops (0=off)
input int    MaxTotalOrders           = 0;      // per side: open positions must stay <= this; manual add over it is closed back, grid stops (0=off)
input double SideLossPercent          = 5.0;    // per side: floating P/L+swap <= -this % of day base → close that side only (0=off)
input double DailyLossPercent         = 10.0;   // account daily loss (closed+floating) vs day-start base: close all + stop until next day (0=off)
input int    DayStartHourLao          = 5;      // trading day starts at this hour, Lao time (GMT+7); base = min(balance, equity) then
input int    ServerGMTOffsetHours     = 3;      // broker server time vs GMT (FBS: +3 summer, +2 winter). Chart warns if the terminal disagrees
input bool   GridOnRefSLEntries       = false;  // if false, skip grid when SL copied from another manual (stack)

input bool   ProtectSLRestoreIfRemoved = true;  // if you delete the SL, put the side SL back
input bool ShareInitialSLPriceToAllLegs = true; // same SL price on every same-side leg with SL=0; grid ONLY on anchor ticket
// Side SL: you may move the oldest leg's SL TOWARD price (BUY up / SELL down); EA copies it to the side.
// Moving it away (more loss) is restored. Grid pendings beyond the new SL are deleted.

//----------------- Auto-trade (AutoTF EMA50 + Stochastic 9,3,3) -----------------
input bool   SignalAlertEnabled    = true;   // alert on BUY/SELL signal (no order is opened — you click)
input bool   AlertPush             = true;   // also push to phone (MT5: Tools → Options → Notifications → MetaQuotes ID)
input bool   AlertSound            = true;   // also play alert.wav
input ENUM_TIMEFRAMES AutoTF       = PERIOD_M5; // timeframe for all signals (EMA50/EMA200/Stoch/close)
input int    AutoEmaPeriod         = 50;     // fast EMA period on AutoTF (BUY if price>EMA, SELL if price<EMA)
input int    AutoEmaSlowPeriod     = 200;    // slow EMA period on AutoTF trend filter (BUY needs EMA50>EMA200, SELL EMA50<EMA200)
input int    AutoStochKPeriod      = 9;      // Stochastic %K period
input int    AutoStochDPeriod      = 3;      // Stochastic %D period
input int    AutoStochSlowing      = 3;      // Stochastic slowing
input double AutoStochBuyLevel     = 20.0;   // BUY when %K reaches down to <= this
input double AutoStochSellLevel    = 80.0;   // SELL when %K reaches up   to >= this

//--------------------------- Globals --------------------------------
CTrade trade;

// Auto-trade indicator handles (AutoTF) + last processed bar (one signal per bar).
int      g_autoEmaHandle     = INVALID_HANDLE;
int      g_autoEmaSlowHandle = INVALID_HANDLE;
int      g_autoStochHandle   = INVALID_HANDLE;
datetime g_autoLastBar       = 0;


// Per-side shared levels (index 0 = BUY, 1 = SELL). Reset when the side is flat.
double g_sideSL[2] = {0.0, 0.0};   // committed side SL (you may only tighten it)
double g_sideSL0[2] = {0.0, 0.0};  // FIRST side SL (grid geometry + TP use this, tightening does not move them)
double g_userTP[2] = {0.0, 0.0};   // TP you set on the oldest leg (0 = none → tier TP)
double g_eaTP[2]   = {0.0, 0.0};   // last tier TP the EA wrote (to detect your edit)

// Daily loss stop (account-wide). Trading day = DayStartHourLao Lao time.
datetime g_dayKey     = 0;      // GMT time the current trading day started
double   g_dayBase    = 0.0;    // min(balance, equity) at day start
bool     g_dayStopped = false;  // DailyLossPercent hit → no trading until next day
datetime g_dayStopAt  = 0;      // server time the stop fired (safety: auto-clear after 24h)
string   g_gvDayKey, g_gvDayBase, g_gvDayStop, g_gvDayStopAt;

struct TicketState {
  ulong ticket;
  bool swingSLSet;
  bool gridDone;
  double protectBoundSL;
  bool addChecked;   // over-trading guards already evaluated for this ticket
};

TicketState g_states[200];
int g_statesCount = 0;


// Forward declarations (helpers defined later in file)
int  CountBundleLegs(const bool buySide);
int  FindStateIndex(const ulong ticket);
bool PendingSlDistanceOkVsOrder(const bool isBuyLimit, const double orderPrice,
                                const double sl);

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double Np(const double p) { return NormalizeDouble(p, DigitsCount()); }
int StopsLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
int SideIdx(const ENUM_POSITION_TYPE side) { return (side == POSITION_TYPE_BUY) ? 0 : 1; }

// Side is flat / closed → forget its shared SL, your TP and the last tier TP.
void ResetSideLevels(const ENUM_POSITION_TYPE side) {
  const int k = SideIdx(side);
  g_sideSL[k] = 0.0;
  g_sideSL0[k] = 0.0;
  g_userTP[k] = 0.0;
  g_eaTP[k]   = 0.0;
}

// Grid legs for an entry→SL distance: full count at >= GridFullDistancePoints,
// proportionally fewer when closer, never below 1.
int GridLegsForDistance(const double distPts) {
  int maxLegs = GridExtraPendingLegs;
  if (maxLegs < 1) return 0;
  if (maxLegs > 50) maxLegs = 50;
  if (GridFullDistancePoints <= 0 || distPts >= (double)GridFullDistancePoints) return maxLegs;
  int legs = (int)MathFloor((double)maxLegs * distPts / (double)GridFullDistancePoints);
  return MathMax(1, legs);
}

bool IsManualPositionTicket(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  return ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber);
}

bool ManualOrderTypeIsBuySide(const ENUM_ORDER_TYPE typ) {
  return (typ == ORDER_TYPE_BUY || typ == ORDER_TYPE_BUY_LIMIT ||
          typ == ORDER_TYPE_BUY_STOP || typ == ORDER_TYPE_BUY_STOP_LIMIT);
}

bool ManualOrderTypeIsSellSide(const ENUM_ORDER_TYPE typ) {
  return (typ == ORDER_TYPE_SELL || typ == ORDER_TYPE_SELL_LIMIT ||
          typ == ORDER_TYPE_SELL_STOP || typ == ORDER_TYPE_SELL_STOP_LIMIT);
}

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
  g_states[g_statesCount].gridDone = false;
  g_states[g_statesCount].protectBoundSL = 0.0;
  g_states[g_statesCount].addChecked = false;
  g_statesCount++;
  return g_statesCount - 1;
}

// Remove ticket states for positions that no longer exist (or are not our manual symbol).
// Without this, g_states fills to 200 and EnsureState() returns -1 — new trades get no SL.
void PruneStaleStates() {
  int write = 0;
  for (int i = 0; i < g_statesCount; i++) {
    const ulong tk = g_states[i].ticket;
    if (tk == 0) continue;
    if (!PositionSelectByTicket(tk)) continue; // closed -> drop
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    if (mag == MagicNumber) continue; // EA-managed, drop from manual table
    g_states[write++] = g_states[i];
  }
  g_statesCount = write;
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

// When TP is edited on a manual position, apply the same TP to every same-side
// market leg (manual + MSSLTP fills) and all pending limits/stops (manual + grid).


// Swing over the last SwingLookbackBars bars INCLUDING the forming bar, so the
// swing is never above (BUY) / below (SELL) the current price.
double SwingLowPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  int idx = iLowest(_Symbol, SwingTF, MODE_LOW, SwingLookbackBars, 0);
  if (idx < 0) return 0.0;
  return iLow(_Symbol, SwingTF, idx);
}

double SwingHighPrice() {
  if (SwingLookbackBars <= 1) return 0.0;
  int idx = iHighest(_Symbol, SwingTF, MODE_HIGH, SwingLookbackBars, 0);
  if (idx < 0) return 0.0;
  return iHigh(_Symbol, SwingTF, idx);
}

// First SL only: if entry→SL is tighter than MinSLDistancePoints, move the SL
// outward so the distance equals MinSLDistancePoints (BUY lower, SELL higher).
double WidenSLToMinDistance(const ENUM_POSITION_TYPE typ, const double entry,
                            double sl, const int digits) {
  if (MinSLDistancePoints <= 0 || sl <= 0.0 || entry <= 0.0) return sl;
  const double pt = Pt();
  if (pt <= 0.0) return sl;
  const double minD = (double)MinSLDistancePoints * pt;
  if (typ == POSITION_TYPE_BUY) {
    if (entry - sl < minD) sl = entry - minD;
  } else {
    if (sl - entry < minD) sl = entry + minD;
  }
  return NormalizeDouble(sl, digits);
}

// Broker stops level: if the swing SL is too close to market, push it out to the
// minimum allowed distance (+1 point) so the first SL is never skipped.
double ClampSLToStopsLevel(const ENUM_POSITION_TYPE typ, double sl, const int digits) {
  const double pt = Pt();
  if (sl <= 0.0 || pt <= 0.0) return sl;
  const double minDist = (double)(StopsLevelPoints() + 1) * pt;
  if (typ == POSITION_TYPE_BUY) {
    const double lim = SymbolInfoDouble(_Symbol, SYMBOL_BID) - minDist;
    if (sl > lim) sl = lim;
  } else {
    const double lim = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + minDist;
    if (sl < lim) sl = lim;
  }
  return NormalizeDouble(sl, digits);
}

double ProfitPointsForPosition(const ENUM_POSITION_TYPE typ, const double open) {
  const double pt = Pt();
  if (pt <= 0.0) return 0.0;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (typ == POSITION_TYPE_BUY) return (bid - open) / pt;
  return (open - ask) / pt;
}

double ReferenceSLFromExistingManual(const ENUM_POSITION_TYPE typ, const ulong excludeTicket) {
  // Find SL from an existing manual position (same symbol & direction).
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || tk == excludeTicket) continue;
    if (!PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

    const long magic = (long)PositionGetInteger(POSITION_MAGIC);
    if (magic == MagicNumber) continue; // skip EA's own positions

    const ENUM_POSITION_TYPE t = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (t != typ) continue;

    const double sl = PositionGetDouble(POSITION_SL);
    if (sl > 0.0) return sl;
  }
  return 0.0;
}

string GridParentTag(const ulong parentTicket) {
  return "MSSLTP" + IntegerToString((long)parentTicket);
}

// Manual (non-EA magic) OR this EA's grid fills (comment MSSLTP…) on _Symbol.
int CountBundleLegs(const bool buySide) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    const ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && pt != POSITION_TYPE_BUY) continue;
    if (!buySide && pt != POSITION_TYPE_SELL) continue;
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    if (mag != MagicNumber && mag != 0) continue;   // another EA
    if (mag != MagicNumber) {
      n++;
      continue;
    }
    const string c = PositionGetString(POSITION_COMMENT);
    if (StringFind(c, "MSSLTP") == 0) n++;
  }
  return n;
}

double NormalizeVolumeLocal(const double lotsIn) {
  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (stepLot <= 0.0) stepLot = 0.01;
  double lots = lotsIn;
  if (lots < minLot) lots = minLot;
  if (lots > maxLot) lots = maxLot;
  if (MaxLotPerLeg > 0.0 && lots > MaxLotPerLeg)
    lots = MaxLotPerLeg;
  lots = MathFloor(lots / stepLot + 1e-7) * stepLot; // epsilon: avoid 0.07→0.06 float floor
  if (lots < minLot) lots = minLot;
  return NormalizeDouble(lots, 2);
}

bool IsBundlePositionLeg(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  const long mag = (long)PositionGetInteger(POSITION_MAGIC);
  if (mag != MagicNumber && mag != 0) return false;   // another EA: never ours
  if (mag != MagicNumber) return true;                 // your click
  const string c = PositionGetString(POSITION_COMMENT);
  return (StringFind(c, "MSSLTP") == 0);
}

bool IsBundleOrderLeg(const ulong ot) {
  if (ot == 0 || !OrderSelect(ot)) return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
  const long mag = (long)OrderGetInteger(ORDER_MAGIC);
  if (mag != MagicNumber && mag != 0) return false;   // another EA: never ours
  if (mag != MagicNumber) return true;
  const string c = OrderGetString(ORDER_COMMENT);
  return (StringFind(c, "MSSLTP") == 0);
}

int CountBundleMarketPositions() {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (IsBundlePositionLeg(tk)) n++;
  }
  return n;
}

// Sum floating profit + swap for manual + MSSLTP legs on this symbol (account currency).
double BundleFloatingProfitMoney() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

// Oldest open bundle leg on side (manual or MSSLTP) — the "first leg" for BE.
ulong OldestBundleLegTicket(const ENUM_POSITION_TYPE side) {
  ulong oldestTk = 0;
  datetime oldestTime = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
    if (oldestTk == 0 || t < oldestTime) {
      oldestTime = t;
      oldestTk = tk;
    }
  }
  return oldestTk;
}

// Was this position opened by a pending order (limit/stop) rather than a market click?
bool OpenedByPendingOrder(const ulong posId) {
  if (posId == 0 || !HistorySelectByPosition((long)posId)) return false;
  const int n = HistoryOrdersTotal();
  for (int i = 0; i < n; i++) {
    const ulong ot = HistoryOrderGetTicket(i);
    if (ot == 0) continue;
    if ((ulong)HistoryOrderGetInteger(ot, ORDER_POSITION_ID) != posId) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(ot, ORDER_TYPE);
    return (typ != ORDER_TYPE_BUY && typ != ORDER_TYPE_SELL);
  }
  return false;
}

// MinOrdersBeforeAdd: a manual market click added while the side is LOSING is
// allowed only when the side already had >= MinOrdersBeforeAdd open legs
// (i.e. grid level 1 has filled); otherwise close it back immediately.
// Side in profit → always allowed. Grid fills and your own pendings are not
// checked. Returns true if the position was closed.
bool CheckMinOrdersBeforeAdd(const ulong tk) {
  if (MinOrdersBeforeAdd <= 0 || tk == 0) return false;
  if (!PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) return false; // grid fill
  if (OpenedByPendingOrder((ulong)PositionGetInteger(POSITION_IDENTIFIER))) return false;
  if (!PositionSelectByTicket(tk)) return false;

  const ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const datetime myTime = (datetime)PositionGetInteger(POSITION_TIME);
  const ulong firstTk = OldestBundleLegTicket(side);
  if (firstTk == 0 || firstTk == tk || !PositionSelectByTicket(firstTk)) return false; // first leg of side
  if ((datetime)PositionGetInteger(POSITION_TIME) > myTime) return false;
  const double firstEntry = PositionGetDouble(POSITION_PRICE_OPEN);

  const double pt = Pt();
  if (pt <= 0.0) return false;
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double lossPts = isBuy ? (firstEntry - price) / pt : (price - firstEntry) / pt;
  if (lossPts <= 0.0) return false;                          // side in profit → allowed
  const int before = CountBundleLegs(isBuy) - 1;             // legs that were open before this click
  if (before >= MinOrdersBeforeAdd) return false;            // grid level 1 filled → allowed

  trade.SetDeviationInPoints(SlippagePoints);
  SetTradeMagicForPositionTicket(tk);
  if (!trade.PositionClose(tk)) {
    Print("[MGridBS] MinOrdersBeforeAdd: close failed tk=", tk, " ret=", trade.ResultRetcode());
    return false;
  }
  const string msg = StringFormat("%s add blocked: side losing with only %d leg(s) open (need %d)",
                                  (isBuy ? "BUY" : "SELL"), before, MinOrdersBeforeAdd);
  Print("[MGridBS] ", msg, " tk=", tk);
  Alert("[MGridBS] ", msg);
  return true;
}

// Sum of open lots of bundle legs on one side.
double SideOpenLots(const ENUM_POSITION_TYPE side) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    sum += PositionGetDouble(POSITION_VOLUME);
  }
  return sum;
}

// Grid (MSSLTP) pendings on one side: count and lots.
void SideGridPendings(const ENUM_POSITION_TYPE side, int &count, double &lots) {
  count = 0;
  lots = 0.0;
  const bool isBuy = (side == POSITION_TYPE_BUY);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if (StringFind(OrderGetString(ORDER_COMMENT), "MSSLTP") != 0) continue;
    const ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (isBuy != ManualOrderTypeIsBuySide(typ)) continue;
    count++;
    lots += OrderGetDouble(ORDER_VOLUME_CURRENT);
  }
}

// May the grid place one more leg of `lots` on this side without breaking
// MaxTotalOrders / MaxTotalLot once every pending fills?
bool GridLegAllowed(const ENUM_POSITION_TYPE side, const double lots) {
  if (MaxTotalOrders <= 0 && MaxTotalLot <= 0.0) return true;
  int pc = 0;
  double pl = 0.0;
  SideGridPendings(side, pc, pl);
  const bool isBuy = (side == POSITION_TYPE_BUY);
  if (MaxTotalOrders > 0 && CountBundleLegs(isBuy) + pc + 1 > MaxTotalOrders) return false;
  if (MaxTotalLot > 0.0 && SideOpenLots(side) + pl + lots > MaxTotalLot + 1e-9) return false;
  return true;
}

// MaxTotalOrders / MaxTotalLot: a manual market click that pushes the side
// over either limit is closed back. Returns true if closed.
bool CheckMaxTotals(const ulong tk) {
  if ((MaxTotalOrders <= 0 && MaxTotalLot <= 0.0) || tk == 0) return false;
  if (!PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) return false; // grid fill
  if (OpenedByPendingOrder((ulong)PositionGetInteger(POSITION_IDENTIFIER))) return false;
  if (!PositionSelectByTicket(tk)) return false;

  const ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const int n = CountBundleLegs(isBuy);      // includes tk
  const double lots = SideOpenLots(side);    // includes tk
  string why = "";
  if (MaxTotalOrders > 0 && n > MaxTotalOrders)
    why = StringFormat("orders %d > max %d", n, MaxTotalOrders);
  else if (MaxTotalLot > 0.0 && lots > MaxTotalLot + 1e-9)
    why = StringFormat("total lot %.2f > max %.2f", lots, MaxTotalLot);
  if (why == "") return false;

  trade.SetDeviationInPoints(SlippagePoints);
  SetTradeMagicForPositionTicket(tk);
  if (!trade.PositionClose(tk)) {
    Print("[MGridBS] MaxTotal: close failed tk=", tk, " ret=", trade.ResultRetcode());
    return false;
  }
  const string msg = (isBuy ? "BUY" : "SELL") + " add blocked: " + why;
  Print("[MGridBS] ", msg, " tk=", tk);
  Alert("[MGridBS] ", msg);
  return true;
}

//--------------------------- Daily loss stop ---------------------------
// Broker server time vs GMT, seconds — from the INPUT only. Never from the
// machine clock / TimeGMT(): a wrong VPS timezone once shifted the day by hours.
int ServerGMTOffsetSec() { return ServerGMTOffsetHours * 3600; }

// What the terminal itself thinks the offset is (live only; depends on the
// machine timezone, so it is used ONLY to warn when it disagrees with the input).
int TerminalServerGMTOffsetSec() {
  if (MQLInfoInteger(MQL_TESTER)) return ServerGMTOffsetSec();
  const double diff = (double)(TimeTradeServer() - TimeGMT());
  return (int)(MathRound(diff / 900.0) * 900.0);
}

// SERVER time at which the current Lao trading day (DayStartHourLao, GMT+7) started.
datetime LaoDayStartGMT() {
  const int shift = ServerGMTOffsetSec() - 7 * 3600;     // server minus Lao
  const datetime lao = TimeCurrent() - shift;             // Lao time now
  const datetime laoMidnight = lao - (lao % 86400);
  datetime start = laoMidnight + (datetime)(DayStartHourLao * 3600);
  if (lao < start) start -= 86400;
  return start + shift;                                   // back to server time
}

// New trading day → new base = min(balance, equity), stop cleared. Saved to
// GlobalVariables so a restart keeps the same base / stop state.
void UpdateTradingDay() {
  const datetime key = LaoDayStartGMT();
  if (key == g_dayKey && g_dayBase > 0.0) return;
  g_dayKey = key;
  g_dayBase = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
  g_dayStopped = false;
  g_dayStopAt = 0;
  GlobalVariableSet(g_gvDayKey, (double)key);
  GlobalVariableSet(g_gvDayBase, g_dayBase);
  GlobalVariableDel(g_gvDayStop);
  GlobalVariableDel(g_gvDayStopAt);
  Print("[MGridBS] New trading day (Lao ", TimeToString(key - (ServerGMTOffsetSec() - 7 * 3600), TIME_DATE | TIME_MINUTES),
        " = server ", TimeToString(key, TIME_DATE | TIME_MINUTES), "). Base = ", DoubleToString(g_dayBase, 2),
        " limit = -", DoubleToString(g_dayBase * DailyLossPercent / 100.0, 2));
}

void RestoreTradingDayFromGV() {
  if (!GlobalVariableCheck(g_gvDayKey) || !GlobalVariableCheck(g_gvDayBase)) return;
  const datetime key = (datetime)GlobalVariableGet(g_gvDayKey);
  if (key != LaoDayStartGMT()) return;          // stale → UpdateTradingDay() starts fresh
  g_dayKey = key;
  g_dayBase = GlobalVariableGet(g_gvDayBase);
  g_dayStopped = GlobalVariableCheck(g_gvDayStop) &&
                 (datetime)GlobalVariableGet(g_gvDayStop) == key;
  g_dayStopAt = GlobalVariableCheck(g_gvDayStopAt) ? (datetime)GlobalVariableGet(g_gvDayStopAt) : 0;
  Print("[MGridBS] Trading day restored. Base = ", DoubleToString(g_dayBase, 2),
        g_dayStopped ? " — STOPPED for today" : "");
}

double DailyPL() { return AccountInfoDouble(ACCOUNT_EQUITY) - g_dayBase; }

// Returns true while trading is stopped for the day (everything closed, nothing opens).
bool CheckDailyLoss() {
  if (DailyLossPercent <= 0.0) return false;
  UpdateTradingDay();
  if (g_dayBase <= 0.0) return false;

  // Safety net: a stop never lasts more than 24h, whatever the day math says.
  if (g_dayStopped && g_dayStopAt > 0 && TimeCurrent() - g_dayStopAt >= 86400) {
    g_dayStopped = false;
    g_dayStopAt = 0;
    GlobalVariableDel(g_gvDayStop);
    GlobalVariableDel(g_gvDayStopAt);
    Print("[MGridBS] Daily stop auto-cleared after 24h");
  }

  if (!g_dayStopped) {
    const double limit = g_dayBase * DailyLossPercent / 100.0;
    const double pl = DailyPL();
    if (pl > -limit) return false;
    g_dayStopped = true;
    g_dayStopAt = TimeCurrent();
    GlobalVariableSet(g_gvDayStop, (double)g_dayKey);
    GlobalVariableSet(g_gvDayStopAt, (double)g_dayStopAt);
    Print("[MGridBS] DAILY LOSS STOP: ", DoubleToString(pl, 2), " <= -", DoubleToString(limit, 2),
          " (", DoubleToString(DailyLossPercent, 1), "% of ", DoubleToString(g_dayBase, 2), ")");
    Alert("[MGridBS] Daily loss ", DoubleToString(DailyLossPercent, 1), "% hit on ", _Symbol,
          " — closed all, stopped until ", IntegerToString(DayStartHourLao), ":00 Lao");
  }
  // Stopped: keep the symbol flat (also closes anything you click).
  if (CountBundleMarketPositions() > 0) {
    Alert("[MGridBS] Daily loss stop active — closing your new order");
    CloseAllBundlePositionsAndOrdersOnSymbol();
  } else {
    for (int j = OrdersTotal() - 1; j >= 0; j--) {
      const ulong ot = OrderGetTicket(j);
      if (!IsBundleOrderLeg(ot)) continue;
      SetTradeMagicForOrderTicket(ot);
      trade.OrderDelete(ot);
    }
  }
  return true;
}

void ShowDailyStatus() {
  if (DailyLossPercent <= 0.0 || g_dayBase <= 0.0) { Comment(""); return; }
  const double pl = DailyPL();
  string s = "MGridBS  day base " + DoubleToString(g_dayBase, 2)
           + "  P/L " + DoubleToString(pl, 2) + " (" + DoubleToString(pl / g_dayBase * 100.0, 2) + "%)"
           + "  limit -" + DoubleToString(DailyLossPercent, 1) + "%";
  const int shift = ServerGMTOffsetSec() - 7 * 3600;
  s += "\nLao time " + TimeToString(TimeCurrent() - shift, TIME_DATE | TIME_MINUTES)
     + "   day started " + TimeToString(g_dayKey - shift, TIME_DATE | TIME_MINUTES) + " Lao"
     + "   next " + TimeToString(g_dayKey - shift + 86400, TIME_DATE | TIME_MINUTES)
     + "   (server GMT" + (ServerGMTOffsetHours >= 0 ? "+" : "") + IntegerToString(ServerGMTOffsetHours) + ")";
  const int termOff = TerminalServerGMTOffsetSec();
  if (MathAbs(termOff - ServerGMTOffsetSec()) >= 3600)
    s += "\n!! terminal thinks server is GMT" + (termOff >= 0 ? "+" : "") + DoubleToString(termOff / 3600.0, 0)
       + " — check ServerGMTOffsetHours (DST change?)";
  if (g_dayStopped) s += "\nSTOPPED until " + IntegerToString(DayStartHourLao) + ":00 Lao";
  Comment(s);
}

// All over-trading guards for a fresh manual click. Returns true if closed.
bool CheckManualAddGuards(const ulong tk) {
  if (CheckMinOrdersBeforeAdd(tk)) return true;
  return CheckMaxTotals(tk);
}

// Side SL: one price for every leg + grid pending on the side.
//  - You may move the OLDEST leg's SL toward price (BUY up / SELL down) → becomes the side SL.
//  - Moved away (more loss) or deleted → restored.
//  - Grid pendings that now sit beyond the SL are deleted.
void EnforceSideSL(const ENUM_POSITION_TYPE side) {
  const int k = SideIdx(side);
  const ulong anchorTk = OldestBundleLegTicket(side);
  if (anchorTk == 0 || !PositionSelectByTicket(anchorTk)) { g_sideSL[k] = 0.0; return; }

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();
  const double eps = pt * 5.0;
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const double cur = PositionGetDouble(POSITION_SL);

  double bound = g_sideSL[k];
  if (bound <= 0.0) {                       // side just started / EA restarted
    if (cur > 0.0) bound = cur;
    else {
      const int st = FindStateIndex(anchorTk);
      if (st >= 0) bound = g_states[st].protectBoundSL;
    }
    if (bound <= 0.0) return;               // swing SL not set yet
    g_sideSL[k] = NormalizeDouble(bound, digits);
    bound = g_sideSL[k];
    if (g_sideSL0[k] <= 0.0) g_sideSL0[k] = bound; // restart: best we know
  }

  // Your tightening on ANY leg or grid pending of the side → new side SL
  // (take the tightest one; a widened/deleted SL is restored below).
  double tight = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const double sl = PositionGetDouble(POSITION_SL);
    if (sl <= 0.0) continue;
    if (isBuy  && sl > bound + eps && (tight == 0.0 || sl > tight)) tight = sl;
    if (!isBuy && sl < bound - eps && (tight == 0.0 || sl < tight)) tight = sl;
  }
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;
    if (isBuy != ManualOrderTypeIsBuySide((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE))) continue;
    const double sl = OrderGetDouble(ORDER_SL);
    if (sl <= 0.0) continue;
    if (isBuy  && sl > bound + eps && (tight == 0.0 || sl > tight)) tight = sl;
    if (!isBuy && sl < bound - eps && (tight == 0.0 || sl < tight)) tight = sl;
  }
  if (tight > 0.0) {
    bound = NormalizeDouble(tight, digits);
    g_sideSL[k] = bound;
    Print("[MGridBS] ", (isBuy ? "BUY" : "SELL"), " side SL tightened by you → ",
          DoubleToString(bound, digits), " (copied to the whole side)");
  }

  trade.SetDeviationInPoints(SlippagePoints);

  // Legs: restore / sync.
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const double sl = PositionGetDouble(POSITION_SL);
    const double tp = PositionGetDouble(POSITION_TP);
    if (sl <= 0.0 && !ProtectSLRestoreIfRemoved) continue;
    if (sl > 0.0 && MathAbs(sl - bound) <= eps) continue;
    if (!RespectStopDistanceSLOnly(isBuy, bound)) continue;
    SetTradeMagicForPositionTicket(tk);
    if (!trade.PositionModify(tk, bound, tp))
      Print("[MGridBS] Side SL modify failed tk=", tk, " ret=", trade.ResultRetcode());
    if ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) {
      const int st = FindStateIndex(tk);
      if (st >= 0) g_states[st].protectBoundSL = bound;
    }
  }

  // Grid pendings: delete beyond SL, else sync SL.
  trade.SetExpertMagicNumber(MagicNumber);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if (StringFind(OrderGetString(ORDER_COMMENT), "MSSLTP") != 0) continue;
    const ENUM_ORDER_TYPE otyp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (otyp != ORDER_TYPE_BUY_LIMIT && otyp != ORDER_TYPE_SELL_LIMIT) continue;
    if (isBuy != (otyp == ORDER_TYPE_BUY_LIMIT)) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    if (!PendingSlDistanceOkVsOrder(isBuy, op, bound)) {
      if (trade.OrderDelete(ot))
        Print("[MGridBS] grid pending ", ot, " at ", DoubleToString(op, digits),
              " deleted — beyond side SL ", DoubleToString(bound, digits));
      continue;
    }
    const double osl = OrderGetDouble(ORDER_SL);
    if (osl > 0.0 && MathAbs(osl - bound) <= eps) continue;
    trade.OrderModify(ot, op, bound, OrderGetDouble(ORDER_TP),
                      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                      (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
  }
}

void SetTradeMagicForPositionTicket(const ulong tk) {
  if (!PositionSelectByTicket(tk)) return;
  if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
    trade.SetExpertMagicNumber(MagicNumber);
  else
    trade.SetExpertMagicNumber(0); // manual: broker needs neutral magic to modify/close
}

void SetTradeMagicForOrderTicket(const ulong ot) {
  if (!OrderSelect(ot)) return;
  if ((long)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
    trade.SetExpertMagicNumber(MagicNumber);
  else
    trade.SetExpertMagicNumber(0);
}

void CloseAllBundlePositionsAndOrdersOnSymbol() {
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    SetTradeMagicForPositionTicket(tk);
    if (!trade.PositionClose(tk))
      Print("[MGridBS] Basket close: position failed tk=", tk,
            " ret=", trade.ResultRetcode());
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;
    SetTradeMagicForOrderTicket(ot);
    if (!trade.OrderDelete(ot))
      Print("[MGridBS] Basket close: order delete failed ot=", ot,
            " ret=", trade.ResultRetcode());
  }

  ResetSideLevels(POSITION_TYPE_BUY);
  ResetSideLevels(POSITION_TYPE_SELL);
}

// Reduce one market position to <= MaxLotPerLeg (e.g. 0.2 → 0.1).
bool ReducePositionVolumeToMaxLot(const ulong tk) {
  if (MaxLotPerLeg <= 0.0 || tk == 0) return false;
  if (!PositionSelectByTicket(tk)) return false;
  if (!IsBundlePositionLeg(tk)) return false;

  const double maxL = NormalizeVolumeLocal(MaxLotPerLeg);
  double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  if (stepLot <= 0.0) stepLot = 0.01;
  const double eps = stepLot * 0.01;

  trade.SetDeviationInPoints(SlippagePoints);
  SetTradeMagicForPositionTicket(tk);

  bool changed = false;
  for (int attempt = 0; attempt < 12; attempt++) {
    if (!PositionSelectByTicket(tk)) break;
    const double vol = PositionGetDouble(POSITION_VOLUME);
    if (vol <= maxL + eps) break;

    double closeVol = vol - maxL;
    if (stepLot > 0.0)
      closeVol = MathFloor(closeVol / stepLot) * stepLot;
    if (closeVol < stepLot)
      closeVol = stepLot;
    if (closeVol <= 0.0 || closeVol >= vol - eps) break;

    if (!trade.PositionClosePartial(tk, closeVol)) {
      Print("[MGridBS] MaxLotPerLeg: partial close failed tk=", tk,
            " vol=", vol, " close=", closeVol, " ret=", trade.ResultRetcode());
      break;
    }
    changed = true;
    Print("[MGridBS] MaxLotPerLeg: reduced tk=", tk, " closed ", closeVol,
          " (target max ", maxL, ")");
  }
  return changed;
}

bool ReducePendingOrderVolumeToMaxLot(const ulong ot) {
  if (MaxLotPerLeg <= 0.0 || ot == 0) return false;
  if (!OrderSelect(ot)) return false;
  if (!IsBundleOrderLeg(ot)) return false;

  const double maxL = NormalizeVolumeLocal(MaxLotPerLeg);
  double ovol = OrderGetDouble(ORDER_VOLUME_CURRENT);
  if (ovol <= 0.0)
    ovol = OrderGetDouble(ORDER_VOLUME_INITIAL);
  const double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double eps = (stepLot > 0.0) ? stepLot * 0.01 : 0.00001;
  if (ovol <= maxL + eps) return false;

  const double price = OrderGetDouble(ORDER_PRICE_OPEN);
  const double osl = OrderGetDouble(ORDER_SL);
  const double otp = OrderGetDouble(ORDER_TP);
  const ENUM_ORDER_TYPE_TIME ttime =
      (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
  const datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

  trade.SetDeviationInPoints(SlippagePoints);
  SetTradeMagicForOrderTicket(ot);

  if (trade.OrderModify(ot, price, osl, otp, ttime, exp, maxL)) {
    Print("[MGridBS] MaxLotPerLeg: pending ot=", ot, " volume ", ovol,
          " -> ", maxL);
    return true;
  }
  Print("[MGridBS] MaxLotPerLeg: order volume modify failed ot=", ot,
        " vol=", ovol, " ret=", trade.ResultRetcode());
  if (!trade.OrderDelete(ot))
    Print("[MGridBS] MaxLotPerLeg: order delete failed ot=", ot);
  return false;
}

// Manual + MSSLTP: ຫ້າມ lot ຕໍ່ໄມ້ເກີນ MaxLotPerLeg (ຕັດ position / ປັບ pending).
void EnforceMaxLotPerLeg() {
  if (MaxLotPerLeg <= 0.0) return;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    ReducePositionVolumeToMaxLot(tk);
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    ReducePendingOrderVolumeToMaxLot(ot);
  }
}

bool HasPendingLimitNear(const bool isBuy, const double price) {
  const double tol = Pt() * 2.0;
  if (tol <= 0.0) return false;
  for (int j = 0; j < OrdersTotal(); j++) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    const long typ = OrderGetInteger(ORDER_TYPE);
    if (isBuy && typ != ORDER_TYPE_BUY_LIMIT) continue;
    if (!isBuy && typ != ORDER_TYPE_SELL_LIMIT) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    if (MathAbs(op - price) <= tol) return true;
  }
  return false;
}

void DeleteGridPendingsForParent(const ulong parentTicket) {
  const string tag = GridParentTag(parentTicket);
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if (OrderGetString(ORDER_COMMENT) != tag) continue;
    if (!trade.OrderDelete(ot))
      Print("[MGridBS] OrderDelete grid failed ticket=", ot, " ret=", trade.ResultRetcode());
  }
}

void CleanupOrphanGridPendings() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const string prefix = "MSSLTP";
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    const string c = OrderGetString(ORDER_COMMENT);
    if (StringFind(c, prefix) != 0) continue;
    const long ptk = (long)StringToInteger(StringSubstr(c, (int)StringLen(prefix)));
    if (ptk <= 0) continue;
    if (!PositionSelectByTicket((ulong)ptk)) {
      if (!trade.OrderDelete(ot))
        Print("[MGridBS] Orphan grid delete failed ", ot);
      continue;
    }
    if (PositionGetString(POSITION_SYMBOL) != _Symbol ||
        (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
      if (!trade.OrderDelete(ot))
        Print("[MGridBS] Orphan grid delete failed ", ot);
    }
  }
}

// Stops distance for pending: SL vs order open price (not bid/ask).
bool PendingSlDistanceOkVsOrder(const bool isBuyLimit, const double orderPrice,
                                 const double sl) {
  if (sl <= 0.0) return false;
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int lvl = (int)MathMax(StopsLevelPoints(), 1);
  const double minD = (double)lvl * pt;
  if (isBuyLimit)
    return (orderPrice - sl) >= minD - 1e-10;
  return (sl - orderPrice) >= minD - 1e-10;
}

void TryPlaceGridPendings(const ulong parentTk, const ENUM_POSITION_TYPE typ,
                          const double entry, const double slBound,
                          const double lotsRaw, const bool fromRefSL, const int st) {
  if (!UseGridPendingOrders || g_states[st].gridDone) return;
  if (fromRefSL && !GridOnRefSLEntries) {
    g_states[st].gridDone = true;
    return;
  }
  const double pt = Pt();
  if (pt <= 0.0) return;
  // Leg count depends on entry→SL distance; legs are spread evenly entry→SL.
  const int legs = (slBound > 0.0) ? GridLegsForDistance(MathAbs(entry - slBound) / pt) : 0;
  if (legs < 1) {
    g_states[st].gridDone = true;
    return;
  }
  const int minPts = (int)MathMax(StopsLevelPoints(), 1);
  const double minDist = (double)minPts * pt;
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const int digits = DigitsCount();
  // Base lot = the parent manual position's lot. Each grid leg steps up by
  // `increaseLot` relative to base: grid leg1=base+increaseLot,
  // leg2=base+2*increaseLot, … (0 = every grid leg equals base).
  double baseLots = lotsRaw;
  if (NormalizeVolumeLocal(baseLots) <= 0.0) {
    g_states[st].gridDone = true;
    return;
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const string tag = GridParentTag(parentTk);
  const double gridSL = NormalizeDouble(slBound, digits);

  int gi = 0;
  double gprice = 0.0;
  double gstep = 0.0;
  double gspan = 0.0;

  if (typ == POSITION_TYPE_BUY) {
    const double floorSL = slBound + minDist;
    gspan = entry - floorSL;
    if (gspan <= pt) {
      g_states[st].gridDone = true;
      return;
    }
    gstep = gspan / (double)(legs + 1);
    for (gi = 1; gi <= legs; gi++) {
      gprice = NormalizeDouble(entry - gstep * (double)gi, digits);
      if (gprice <= floorSL) break;
      if (gprice >= ask - minDist) continue;
      if (HasPendingLimitNear(true, gprice)) continue;
      if (!PendingSlDistanceOkVsOrder(true, gprice, gridSL)) continue;
      double lots = NormalizeVolumeLocal(baseLots + increaseLot * (double)gi);
      if (lots <= 0.0) continue;
      if (!GridLegAllowed(typ, lots)) break;   // MaxTotalOrders / MaxTotalLot
      if (!trade.BuyLimit(lots, gprice, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0,
                          tag)) {
        Print("[MGridBS] BuyLimit grid i=", gi, " ret=", trade.ResultRetcode(),
              " ", trade.ResultRetcodeDescription());
        break;
      }
    }
  } else {
    const double ceilSL = slBound - minDist;
    gspan = ceilSL - entry;
    if (gspan <= pt) {
      g_states[st].gridDone = true;
      return;
    }
    gstep = gspan / (double)(legs + 1);
    for (gi = 1; gi <= legs; gi++) {
      gprice = NormalizeDouble(entry + gstep * (double)gi, digits);
      if (gprice >= ceilSL) break;
      if (gprice <= bid + minDist) continue;
      if (HasPendingLimitNear(false, gprice)) continue;
      if (!PendingSlDistanceOkVsOrder(false, gprice, gridSL)) continue;
      double lots = NormalizeVolumeLocal(baseLots + increaseLot * (double)gi);
      if (lots <= 0.0) continue;
      if (!GridLegAllowed(typ, lots)) break;   // MaxTotalOrders / MaxTotalLot
      if (!trade.SellLimit(lots, gprice, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0,
                           tag)) {
        Print("[MGridBS] SellLimit grid i=", gi, " ret=", trade.ResultRetcode(),
              " ", trade.ResultRetcodeDescription());
        break;
      }
    }
  }
  g_states[st].gridDone = true;
}

// Is a bundle leg still sitting on (or very near) this grid price?
bool HasBundlePositionNear(const ENUM_POSITION_TYPE side, const double price) {
  const double tol = Pt() * 2.0;
  if (tol <= 0.0) return false;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    if (MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tol) return true;
  }
  return false;
}

// RE-ARM: rebuild the ladder each tick. A grid level whose position has been
// closed gets its pending limit back at the same price, lot and SL.
// Geometry (leg count + spacing) comes from the FIRST side SL, so tightening
// the SL never moves the levels; levels beyond the current SL are skipped.
void RearmGridForSide(const ENUM_POSITION_TYPE side) {
  if (!UseGridPendingOrders) return;

  const ulong anchorTk = OldestBundleLegTicket(side);
  if (anchorTk == 0 || !PositionSelectByTicket(anchorTk)) return;
  const double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
  const double baseLots = PositionGetDouble(POSITION_VOLUME);
  double slBound        = PositionGetDouble(POSITION_SL);
  const int stA = FindStateIndex(anchorTk);
  if (slBound <= 0.0 && stA >= 0) slBound = g_states[stA].protectBoundSL;
  if (slBound <= 0.0) return;

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();
  const double minDist = (double)MathMax(StopsLevelPoints(), 1) * pt;
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const string tag = GridParentTag(anchorTk);
  const double gridSL = NormalizeDouble(slBound, digits);

  const int k = SideIdx(side);
  const double sl0 = (g_sideSL0[k] > 0.0) ? g_sideSL0[k] : slBound;
  const int legs = GridLegsForDistance(MathAbs(entry - sl0) / pt);
  if (legs < 1) return;
  const double span0 = isBuy ? (entry - (sl0 + minDist)) : ((sl0 - minDist) - entry);
  if (span0 <= pt) return;
  const double gstep = span0 / (double)(legs + 1);

  const double bound = isBuy ? (slBound + minDist) : (slBound - minDist);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int gi = 1; gi <= legs; gi++) {
    const double gprice = NormalizeDouble(
        isBuy ? (entry - gstep * (double)gi) : (entry + gstep * (double)gi), digits);
    if (isBuy) {
      if (gprice <= bound) break;
      if (gprice >= ask - minDist) continue;
    } else {
      if (gprice >= bound) break;
      if (gprice <= bid + minDist) continue;
    }
    if (HasPendingLimitNear(isBuy, gprice)) continue;   // already armed
    if (HasBundlePositionNear(side, gprice)) continue;  // level still filled
    if (!PendingSlDistanceOkVsOrder(isBuy, gprice, gridSL)) continue;
    const double lots = NormalizeVolumeLocal(baseLots + increaseLot * (double)gi);
    if (lots <= 0.0) continue;
    if (!GridLegAllowed(side, lots)) break;   // MaxTotalOrders / MaxTotalLot

    const bool ok = isBuy
        ? trade.BuyLimit(lots, gprice, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0, tag)
        : trade.SellLimit(lots, gprice, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0, tag);
    if (!ok) {
      Print("[MGridBS] re-arm ", (isBuy ? "BuyLimit" : "SellLimit"), " i=", gi,
            " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      break;
    }
    Print("[MGridBS] re-armed grid level ", gi, " at ",
          DoubleToString(gprice, digits));
  }
}

// One swing/ref SL price on all same-side legs that still have SL=0 (manual +
// MSSLTP fills). Pending grid is placed ONLY from anchorTk (the manual the EA
// is managing in this call), not from every leg.
void ApplySharedSwingSLPrice(const ulong anchorTk, const ENUM_POSITION_TYPE typ,
                             const double sl, const bool usedRefSL,
                             const int digits) {
  if (sl <= 0.0) return;
  const bool isBuy = (typ == POSITION_TYPE_BUY);
  if (!RespectStopsDistanceFromMarket(isBuy, sl, 0.0)) return;

  const int kMax = 220;
  ulong list[220];
  int n = 0;
  int si = 0;
  ulong t2 = 0;
  long mag = 0;
  for (si = PositionsTotal() - 1; si >= 0 && n < kMax; si--) {
    t2 = PositionGetTicket(si);
    if (t2 == 0 || !PositionSelectByTicket(t2)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != typ) continue;
    mag = (long)PositionGetInteger(POSITION_MAGIC);
    const string com = PositionGetString(POSITION_COMMENT);
    if (mag == MagicNumber && StringFind(com, "MSSLTP") != 0) continue;
    if (PositionGetDouble(POSITION_SL) > 0.0) continue;
    list[n++] = t2;
  }
  for (si = 0; si < n; si++) {
    if (list[si] == anchorTk) {
      const ulong tmp = list[0];
      list[0] = list[si];
      list[si] = tmp;
      break;
    }
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (si = 0; si < n; si++) {
    t2 = list[si];
    if (!PositionSelectByTicket(t2)) continue;
    const double otp = PositionGetDouble(POSITION_TP);
    if (!RespectStopsDistanceFromMarket(isBuy, sl, otp)) continue;
    if (!trade.PositionModify(t2, sl, otp)) {
      Print("[MGridBS] Shared SL modify failed tk=", t2,
            " ret=", trade.ResultRetcode());
      continue;
    }
    mag = (long)PositionGetInteger(POSITION_MAGIC);
    if (mag != MagicNumber) {
      const int st2 = EnsureState(t2);
      if (st2 < 0) continue;
      g_states[st2].swingSLSet = true;
      g_states[st2].protectBoundSL = sl;
      if (t2 == anchorTk) {
        const double open2 = PositionGetDouble(POSITION_PRICE_OPEN);
        const double vol2 = PositionGetDouble(POSITION_VOLUME);
        TryPlaceGridPendings(t2, typ, open2, sl, vol2, usedRefSL, st2);
      } else {
        g_states[st2].gridDone = true;
      }
    }
  }
  const int k = isBuy ? 0 : 1;
  if (g_sideSL[k] <= 0.0) g_sideSL[k] = sl;   // first committed SL of the side
  if (g_sideSL0[k] <= 0.0) g_sideSL0[k] = sl;
}

//------------------- Side TP / side risk stop -------------

// Sum floating profit + swap for bundle legs on ONE side (account currency).
double BundleSideFloatingProfitMoney(const ENUM_POSITION_TYPE side) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

// Close all bundle positions AND pendings on ONE side.
void CloseBundleSide(const ENUM_POSITION_TYPE side) {
  const bool isBuy = (side == POSITION_TYPE_BUY);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    SetTradeMagicForPositionTicket(tk);
    if (!trade.PositionClose(tk))
      Print("[MGridBS] Side close position failed tk=", tk,
            " ret=", trade.ResultRetcode());
  }
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;
    const ENUM_ORDER_TYPE otyp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (isBuy != ManualOrderTypeIsBuySide(otyp)) continue;
    SetTradeMagicForOrderTicket(ot);
    if (!trade.OrderDelete(ot))
      Print("[MGridBS] Side close delete pending failed ot=", ot,
            " ret=", trade.ResultRetcode());
  }
  ResetSideLevels(side);
}

// Apply one shared TP price to all bundle positions + pendings on a side.
// tp <= 0 clears TP (used in the >=3 money-mode state).
void ApplySharedTPToSide(const ENUM_POSITION_TYPE side, const double tp,
                         const int digits) {
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const double pt = Pt();
  const double eps = (pt > 0.0) ? pt / 2.0 : 0.0000001;
  const bool clear = (tp <= 0.0);
  const double ntp = clear ? 0.0 : NormalizeDouble(tp, digits);

  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const double csl = PositionGetDouble(POSITION_SL);
    const double ctp = PositionGetDouble(POSITION_TP);
    if (clear) {
      if (ctp <= 0.0) continue;
    } else {
      if (ctp > 0.0 && MathAbs(ctp - ntp) <= eps) continue;
    }
    SetTradeMagicForPositionTicket(tk);
    if (!trade.PositionModify(tk, csl, ntp))
      Print("[MGridBS] Count-TP position modify failed tk=", tk,
            " ret=", trade.ResultRetcode());
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;
    const ENUM_ORDER_TYPE otyp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (isBuy != ManualOrderTypeIsBuySide(otyp)) continue;
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    const double osl = OrderGetDouble(ORDER_SL);
    const double otp = OrderGetDouble(ORDER_TP);
    if (clear) {
      if (otp <= 0.0) continue;
    } else {
      if (otp > 0.0 && MathAbs(otp - ntp) <= eps) continue;
    }
    const ENUM_ORDER_TYPE_TIME ttime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    const datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
    SetTradeMagicForOrderTicket(ot);
    if (!trade.OrderModify(ot, op, osl, ntp, ttime, exp))
      Print("[MGridBS] Count-TP pending modify failed ot=", ot,
            " ret=", trade.ResultRetcode());
  }
}

// SideLossPercent applied PER SIDE: floating P/L+swap of the side vs the day
// base (same base as DailyLossPercent; current balance if that is off).
// Bundle legs already include your own clicks, so they are closed with the side.
bool CheckSideRiskStop() {
  if (SideLossPercent <= 0.0) return false;
  const double base = (g_dayBase > 0.0) ? g_dayBase : AccountInfoDouble(ACCOUNT_BALANCE);
  if (base <= 0.0) return false;
  const double limit = base * SideLossPercent / 100.0;
  bool fired = false;
  for (int k = 0; k < 2; k++) {
    const ENUM_POSITION_TYPE side = (k == 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
    if (CountBundleLegs(k == 0) <= 0) continue;
    const double money = BundleSideFloatingProfitMoney(side);
    if (money > -limit) continue;
    Print("[MGridBS] SIDE RISK STOP ", (k == 0 ? "BUY" : "SELL"),
          ": P/L+swap = ", DoubleToString(money, 2), " <= -", DoubleToString(limit, 2),
          " (", DoubleToString(SideLossPercent, 1), "% of ", DoubleToString(base, 2), ") - closing that side.");
    Alert("[MGridBS] ", (k == 0 ? "BUY" : "SELL"), " side hit -",
          DoubleToString(SideLossPercent, 1), "% (", DoubleToString(limit, 2), ") on ", _Symbol);
    CloseBundleSide(side);
    fired = true;
  }
  return fired;
}

// Side TP = first entry ± TPRiskReward x (first entry→FIRST side SL). Same TP on
// every leg + pending. Tightening the SL later does not move it.
// Your TP override: if the OLDEST leg's TP differs from what the EA last wrote,
// that is your TP → copied to the whole side; the R:R TP is no longer applied
// (until the side is flat). Deleting your TP returns to the R:R TP.
void ProcessSideTP(const ENUM_POSITION_TYPE side) {
  const bool isBuy = (side == POSITION_TYPE_BUY);
  const int k = SideIdx(side);
  const int n = CountBundleLegs(isBuy); // OPEN market positions on this side only
  if (n <= 0) { g_userTP[k] = 0.0; g_eaTP[k] = 0.0; return; }

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();
  const double eps = pt * 2.0;

  const ulong firstTk = OldestBundleLegTicket(side);
  if (firstTk == 0 || !PositionSelectByTicket(firstTk)) return;
  const double firstEntry = PositionGetDouble(POSITION_PRICE_OPEN);
  const double cur = PositionGetDouble(POSITION_TP);

  // R:R TP from the first side SL (0 until the SL exists).
  double rrTP = 0.0;
  if (TPRiskReward > 0.0 && g_sideSL0[k] > 0.0) {
    const double slDist = MathAbs(firstEntry - g_sideSL0[k]);
    rrTP = NormalizeDouble(isBuy ? (firstEntry + TPRiskReward * slDist)
                                 : (firstEntry - TPRiskReward * slDist), digits);
  }

  // Detect your edit on ANY leg of the side: a leg whose TP differs from the
  // side TP the EA last wrote (or from your last TP) is your new TP.
  const double ref = (g_userTP[k] > 0.0) ? g_userTP[k] : g_eaTP[k];
  double edited = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0 && edited <= 0.0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const double tp = PositionGetDouble(POSITION_TP);
    if (tp <= 0.0) continue;                                   // fresh fill, not yet synced
    if (ref > 0.0) { if (MathAbs(tp - ref) > eps) edited = tp; }
    else if (rrTP > 0.0 && MathAbs(tp - rrTP) <= eps) g_eaTP[k] = tp; // first look: ours
    else edited = tp;                                          // first look: yours
  }
  // Same for pendings of the side (on the phone you may grab a pending's TP line).
  for (int j = OrdersTotal() - 1; j >= 0 && edited <= 0.0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;
    if (isBuy != ManualOrderTypeIsBuySide((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE))) continue;
    const double tp = OrderGetDouble(ORDER_TP);
    if (tp <= 0.0) continue;
    const double cmp = (ref > 0.0) ? ref : rrTP;
    if (cmp > 0.0 && MathAbs(tp - cmp) > eps) edited = tp;
  }
  if (edited > 0.0) {
    g_userTP[k] = edited;
    Print("[MGridBS] ", (isBuy ? "BUY" : "SELL"), " TP set by you → ", DoubleToString(edited, digits),
          " (copied to the whole side; R:R TP paused)");
  } else if (cur <= 0.0 && g_userTP[k] > 0.0) {
    // Your TP deleted on the oldest leg → back to the R:R TP.
    g_userTP[k] = 0.0;
    g_eaTP[k] = 0.0;
    Print("[MGridBS] ", (isBuy ? "BUY" : "SELL"), " your TP removed → back to R:R TP");
  }

  if (g_userTP[k] > 0.0) {
    if (RespectStopDistanceTPOnly(isBuy, g_userTP[k]))
      ApplySharedTPToSide(side, g_userTP[k], digits);
    return;
  }

  if (rrTP <= 0.0) return;
  if (!RespectStopDistanceTPOnly(isBuy, rrTP)) return; // too close to market for broker

  ApplySharedTPToSide(side, rrTP, digits);
  // Remember the TP only once it is really on the oldest leg; otherwise a
  // rejected modify would look like your edit on the next tick.
  if (PositionSelectByTicket(firstTk) && MathAbs(PositionGetDouble(POSITION_TP) - rrTP) <= eps)
    g_eaTP[k] = rrTP;
}

//--------------------------- Core logic ------------------------------
void ManageManualPosition(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return;

  const long magic = (long)PositionGetInteger(POSITION_MAGIC);
  if (magic == MagicNumber) return; // skip EA's own positions

  const ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  double workSL = PositionGetDouble(POSITION_SL);
  double workTP = PositionGetDouble(POSITION_TP);

  int st = EnsureState(tk);
  if (st < 0) {
    static datetime s_lastFullWarn = 0;
    if (TimeCurrent() - s_lastFullWarn > 3600) {
      Print("[MGridBS] state table full (200 open manuals?). ticket=", tk, " — cannot track SL.");
      s_lastFullWarn = TimeCurrent();
    }
    return;
  }

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();

  // Fallback over-trading guards if OnTradeTransaction was missed (fresh ticket only).
  if (!g_states[st].addChecked) {
    g_states[st].addChecked = true;
    if (TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME) <= 5 &&
        CheckManualAddGuards(tk))
      return;
    if (!PositionSelectByTicket(tk)) return;
  }

  trade.SetExpertMagicNumber(MagicNumber); // for modifications only
  trade.SetDeviationInPoints(SlippagePoints);

  // SL restore / tighten / sync is done per side in EnforceSideSL() (OnTick).

  // 1) Set SL to swing (only if SL is empty AND not already set by us)
  if (!g_states[st].swingSLSet && workSL <= 0.0) {
    double sl = 0.0;

    // If there is already an open manual position in the same direction,
    // reuse its SL so added entries share the exact same SL as the first one.
    const double refSL = ReferenceSLFromExistingManual(typ, tk);
    const bool usedRefSL = (refSL > 0.0);
    if (refSL > 0.0) {
      sl = refSL;
    } else {
      double sw = 0.0;
      if (typ == POSITION_TYPE_BUY) {
        sw = SwingLowPrice();
        if (sw > 0.0) sl = sw - (double)SwingBufferPoints * pt;
      } else {
        sw = SwingHighPrice();
        if (sw > 0.0) sl = sw + (double)SwingBufferPoints * pt;
      }
      if (sl > 0.0) sl = WidenSLToMinDistance(typ, open, sl, digits);
      if (sl > 0.0) sl = ClampSLToStopsLevel(typ, sl, digits);
    }
    if (sl > 0.0) sl = NormalizeDouble(sl, digits);

    if (sl > 0.0 && RespectStopsDistanceFromMarket(typ == POSITION_TYPE_BUY, sl, 0.0)) {
      if (ShareInitialSLPriceToAllLegs)
        ApplySharedSwingSLPrice(tk, typ, sl, usedRefSL, digits);
      else if (trade.PositionModify(tk, sl, workTP)) {
        g_states[st].swingSLSet = true;
        g_states[st].protectBoundSL = sl;
        if (g_sideSL[SideIdx(typ)] <= 0.0)  g_sideSL[SideIdx(typ)] = sl;
        if (g_sideSL0[SideIdx(typ)] <= 0.0) g_sideSL0[SideIdx(typ)] = sl;
        if (!PositionSelectByTicket(tk)) return;
        const double vol = PositionGetDouble(POSITION_VOLUME);
        TryPlaceGridPendings(tk, typ, open, sl, vol, usedRefSL, st);
      }
      if (!PositionSelectByTicket(tk)) return;
      workSL = PositionGetDouble(POSITION_SL);
      workTP = PositionGetDouble(POSITION_TP);
    }
  }

  // Exit handling: ProcessSideTP() (called from OnTick).
}

//--------------------------- Signal alerts (AutoTF) -------------------------
// BUY  (AutoTF): close > EMA50 AND EMA50 > EMA200 AND Stoch %K crosses DOWN to <= AutoStochBuyLevel.
// SELL (AutoTF): close < EMA50 AND EMA50 < EMA200 AND Stoch %K crosses UP   to >= AutoStochSellLevel.
// "Crosses" = prior closed bar was on the other side of the level → fires once per reach.
bool ReadAutoSignals(bool &buySig, bool &sellSig, double &kOut) {
  buySig = false;
  sellSig = false;
  kOut = 0.0;
  if (g_autoEmaHandle == INVALID_HANDLE || g_autoEmaSlowHandle == INVALID_HANDLE ||
      g_autoStochHandle == INVALID_HANDLE)
    return false;

  double ema[];
  double emaSlow[];
  double kmain[];
  ArraySetAsSeries(ema, true);
  ArraySetAsSeries(emaSlow, true);
  ArraySetAsSeries(kmain, true);
  if (CopyBuffer(g_autoEmaHandle, 0, 0, 3, ema) < 3) return false;
  if (CopyBuffer(g_autoEmaSlowHandle, 0, 0, 3, emaSlow) < 3) return false;
  if (CopyBuffer(g_autoStochHandle, 0, 0, 3, kmain) < 3) return false; // buffer 0 = %K main

  // Evaluate on the last CLOSED bar (index 1); index 2 is the prior closed bar.
  const double closeClosed = iClose(_Symbol, AutoTF, 1);
  if (closeClosed <= 0.0) return false;
  const double emaClosed     = ema[1];
  const double emaSlowClosed = emaSlow[1];
  const double kNow  = kmain[1];
  const double kPrev = kmain[2];
  kOut = kNow;

  buySig  = (closeClosed > emaClosed) && (emaClosed > emaSlowClosed) &&
            (kPrev > AutoStochBuyLevel)  && (kNow <= AutoStochBuyLevel);
  sellSig = (closeClosed < emaClosed) && (emaClosed < emaSlowClosed) &&
            (kPrev < AutoStochSellLevel) && (kNow >= AutoStochSellLevel);
  return true;
}

// Signal → popup / push / sound only. You decide and click BUY/SELL yourself;
// the manager then handles the click like any manual order.
void ProcessSignalAlert() {
  if (!SignalAlertEnabled) return;

  // Fire at most once per new AutoTF bar (signal is computed on closed-bar values).
  const datetime curBar = iTime(_Symbol, AutoTF, 0);
  if (curBar == 0 || curBar == g_autoLastBar) return;

  bool buySig = false, sellSig = false;
  double k = 0.0;
  if (!ReadAutoSignals(buySig, sellSig, k)) return; // indicators not ready yet — retry next tick
  g_autoLastBar = curBar;                             // mark this bar handled
  if (!buySig && !sellSig) return;

  const string msg = StringFormat("MGridBS %s %s: %s signal — %s, Stoch %.1f",
                                  _Symbol, EnumToString(AutoTF),
                                  buySig ? "BUY" : "SELL",
                                  buySig ? "close>EMA50>EMA200" : "close<EMA50<EMA200", k);
  Print("[MGridBS] ", msg);
  Alert(msg);
  if (AlertPush && !SendNotification(msg))
    Print("[MGridBS] push failed (set MetaQuotes ID in Tools→Options→Notifications) err=", GetLastError());
  if (AlertSound) PlaySound("alert.wav");
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // Daily loss stop state survives restarts / re-attach (keyed by magic, account-wide).
  g_gvDayKey  = "MGridBS_DayKey_"  + IntegerToString(MagicNumber);
  g_gvDayBase = "MGridBS_DayBase_" + IntegerToString(MagicNumber);
  g_gvDayStop = "MGridBS_DayStop_" + IntegerToString(MagicNumber);
  g_gvDayStopAt = "MGridBS_DayStopAt_" + IntegerToString(MagicNumber);
  if (DailyLossPercent > 0.0) RestoreTradingDayFromGV();
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)
    trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0)
    trade.SetTypeFilling(ORDER_FILLING_FOK);
  else
    trade.SetTypeFilling(ORDER_FILLING_RETURN);

  // Auto-trade indicators on AutoTF (buffer 0 of Stochastic = %K main line).
  if (SignalAlertEnabled) {
    g_autoEmaHandle = iMA(_Symbol, AutoTF, AutoEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
    g_autoEmaSlowHandle = iMA(_Symbol, AutoTF, AutoEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
    g_autoStochHandle = iStochastic(_Symbol, AutoTF, AutoStochKPeriod,
                                    AutoStochDPeriod, AutoStochSlowing,
                                    MODE_SMA, STO_LOWHIGH);
    if (g_autoEmaHandle == INVALID_HANDLE || g_autoEmaSlowHandle == INVALID_HANDLE ||
        g_autoStochHandle == INVALID_HANDLE) {
      Print("[MGridBS] Failed to create auto-trade indicator handles.");
      return INIT_FAILED;
    }
  }

  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  Comment("");
  if (g_autoEmaHandle != INVALID_HANDLE) IndicatorRelease(g_autoEmaHandle);
  if (g_autoEmaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_autoEmaSlowHandle);
  if (g_autoStochHandle != INVALID_HANDLE) IndicatorRelease(g_autoStochHandle);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  if (trans.deal == 0) return;
  if (!HistoryDealSelect(trans.deal)) return;
  if (HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

  const long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  if (entry != DEAL_ENTRY_IN) return;

  const ulong posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
  int pi = 0;
  ulong tk = 0;

  if (posId > 0) {
    for (pi = PositionsTotal() - 1; pi >= 0; pi--) {
      tk = PositionGetTicket(pi);
      if (tk == 0 || !PositionSelectByTicket(tk)) continue;
      if ((ulong)PositionGetInteger(POSITION_IDENTIFIER) != posId) continue;
      if (!IsBundlePositionLeg(tk)) return;
      if (g_dayStopped) {                      // daily loss stop: nothing may open today
        trade.SetDeviationInPoints(SlippagePoints);
        SetTradeMagicForPositionTicket(tk);
        trade.PositionClose(tk);
        Alert("[MGridBS] Daily loss stop active — your order was closed");
        return;
      }
      // Over-trading guard first: a blocked manual add is closed, nothing else to do.
      const int st = EnsureState(tk);
      if (st >= 0) g_states[st].addChecked = true;
      if (CheckManualAddGuards(tk)) return;
      if (MaxLotPerLeg > 0.0) ReducePositionVolumeToMaxLot(tk);
      return;
    }
  }
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  PruneStaleStates();
  if (CountBundleLegs(true)  == 0) ResetSideLevels(POSITION_TYPE_BUY);
  if (CountBundleLegs(false) == 0) ResetSideLevels(POSITION_TYPE_SELL);
  CleanupOrphanGridPendings();
  EnforceMaxLotPerLeg();

  const bool dayStopped = CheckDailyLoss();   // DailyLossPercent (account-wide, per Lao day)
  ShowDailyStatus();
  if (dayStopped) return;

  if (CheckSideRiskStop()) return;   // SideLossPercent is per side

  // Signal alerts (no orders — you click; the manager loop below handles the click).
  ProcessSignalAlert();

  // Manage all manual positions on this symbol
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0) continue;
    ManageManualPosition(tk);
  }

  // Side SL: accept your tightening, restore widening/removal, sync legs + pendings.
  EnforceSideSL(POSITION_TYPE_BUY);
  EnforceSideSL(POSITION_TYPE_SELL);

  // Re-arm any grid level whose position was closed (never beyond the side SL).
  RearmGridForSide(POSITION_TYPE_BUY);
  RearmGridForSide(POSITION_TYPE_SELL);

  // Side TP (R:R from first SL) / your TP override.
  ProcessSideTP(POSITION_TYPE_BUY);
  ProcessSideTP(POSITION_TYPE_SELL);
}

