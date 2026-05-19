//+------------------------------------------------------------------+
//|                                              ManualSwingSLTP.mq5 |
//|                                                                  |
//| ຈຸດປະສົງ (Manual manager):                                       |
//| - ທ່ານເປີດ BUY/SELL ເອງ (manual) ແລ້ວ EA ຈະຊ່ວຍຕັ້ງ SL/TP ອັດຕະໂນມັດ |
//|                                                                  |
//| BUY:                                                             |
//|  - ຕັ້ງ SL ທີ່ swing low (lookback); ຫຼັງຕັ້ງ SL ສຳເລັດ ອາດວາງ BuyLimit grid |
//|    (ຈຳນວນ = GridExtraPendingLegs, ຫ່າງກັນສະເໝີລະຫວ່າງ entry ແລະ SL).        |
//|  - ເມື່ອກຳໄລ points ລວມທຸກໄມ້ຝັ່ງນັ້ນ >= BreakEvenTriggerPoints: BE+ ແລະ TP ຕໍ່ entry |
//|                                                                  |
//| SELL:                                                            |
//|  - ຕັ້ງ SL ທີ່ swing high; ຫຼັງຕັ້ງ SL ສຳເລັດ ອາດວາງ SellLimit grid ຂຶ້ນຈາກ entry |
//|    ຫ່າງກັນສະເໝີຕາມ GridExtraPendingLegs ຈົນບໍ່ເກີນ SL.              |
//|  - ເມື່ອກຳໄລ points ລວມທຸກໄມ້ຝັ່ງນັ້ນ >= BreakEvenTriggerPoints: BE+ ແລະ TP ຕໍ່ entry |
//|                                                                   |
//| ໝາຍເຫດ: EA ຈັດການສະເພາະ manual positions (magic != MagicNumber) |
//| Bugfix v1.01: ລ້າງລາຍການ ticket ທີ່ປິດແລ້ວອອກຈາກ g_states — ບໍ່ດັ່ນຫຼັງມີ ~200 |
//|   ອໍເດີເກົ່າ EnsureState ຈະເຕັມ ແລະ ອໍເດີໃໝ່ຈະບໍ່ຖືກຕັ້ງ SL ອີກ.        |
//| v1.02–1.03: ຫຼັງຕັ້ງ swing SL ວາງ pending grid ຈຳນວນ GridExtraPendingLegs, |
//|   ຫ່າງກັນສະເໝີລະຫວ່າງ entry ແລະ SL (ບໍ່ລະເມີດ SL).              |
//| v1.05: Optional max bundle per side = legs at first SL lock + grid legs; |
//|   excess market positions closed (newest first) — broker cannot block clicks. |
//| v1.06: Protect SL — clamp widen beyond EA swing/ref; restore SL if removed; |
//|   optional: do not override user-moved SL in the break-even step (TP still). |
//| v1.07: When you change TP on a manual position, copy that TP to all same-side |
//|   bundle legs (manual + MSSLTP fills) and EA grid pendings on this symbol.   |
//| v1.09: Shared initial SL = one price on all legs with SL=0; grid only on the |
//|   ticket being managed. Before BE, optional full SL freeze at that price   |
//|   (restore if dragged/removed) to reduce over-trading.                      |
//| v1.10: Grid pendings use the same SL as parent (first) position; freeze      |
//|   pending SL while parent is in swing phase (same as ProtectSLFreezeBeforeBE). |
//| v1.11: BE — ບໍ່ຕັ້ງ beTpSet ຄ້າງວົງ swing ເມື່ອກຳໄລຮອດ trigger ແລ້ວ; ຖ້າ BE+ ຕິດ |
//|   stops level ຈະຂຍັບ SL ໃຫ້ໃກ້ຕະຫຼາດທີ່ broker ຍອມຮັບ (BreakEvenRelaxSLToStopsLevel). |
//| v1.12: MaxLotPerLeg — ຫ້າມ lot ຕໍ່ໄມ້ເກີນຄ່າກຳນົດ (ຕັດ position / ປັບ pending). |
//| v1.13: BE/TP ເມື່ອກຳໄລ points ລວມທຸກໄມ້ຝັ່ງ (manual+MSSLTP) ຮອດ trigger — ບໍ່ແມ່ນແຕ່ໄມ້ດຽວ. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.13"
#property description "Swing SL/TP + bundle-sum BE + grid freeze + MaxLotPerLeg."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input long   MagicNumber              = 909090; // EA will manage positions with magic != this
input ENUM_TIMEFRAMES SwingTF         = PERIOD_M1;
input int    SwingLookbackBars        = 50;     // search range for swing high/low
input int    SwingBufferPoints        = 0;      // extra buffer beyond swing (points)
input int    FirstSLOffsetPoints      = 500;    // apply ONLY to the first SL: BUY subtract, SELL add (points)

input int    BreakEvenTriggerPoints   = 500;    // sum of profit points on side (all legs) >= this → BE+ and TP
input int    BreakEvenPlusPoints      = 20;     // SL to entry +/- this (points)
input bool   BreakEvenRelaxSLToStopsLevel = true; // if ideal BE+ SL too close to bid/ask, use tightest allowed SL
input int    TPPoints                = 1000;   // TP distance from entry (points)

input int    SlippagePoints           = 20;

input bool   UseGridPendingOrders     = true;   // after swing SL is set
input int    GridExtraPendingLegs     = 3;     // extra BuyLimit/SellLimit count; equal spacing entry↔SL
input double GridLot                  = 0.0;    // 0 = same lot as parent manual position
input double MaxLotPerLeg             = 0.1;    // max lot per position/pending leg (0 = off)
input bool   GridOnRefSLEntries       = false;  // if false, skip grid when SL copied from another manual (stack)

input bool   EnforceInitialBundleMax  = true;   // cap BUY/SELL "legs" to count-at-first-SL + grid legs (see header)
input int    BundleMaxExtraLegsCap    = 0;      // 0 = use GridExtraPendingLegs at lock time; else override max add

input bool   ProtectSLClampNoWiden     = true;  // if ProtectSLFreezeBeforeBE=false: block only widening past commit
input bool   ProtectSLRestoreIfRemoved = true;  // if SL cleared while swing phase, restore committed SL
input bool   ProtectBEDontOverrideUserSL = true; // if SL moved after EA set swing, BE step changes TP only (keeps your SL)

input bool   SyncTPWhenManualChanges = true;  // change TP on one manual → set same TP on same-side bundle + EA pendings
input bool   SyncTPDeletionToAll     = false; // if true, clearing TP on one manual clears TP on same-side bundle

input bool ShareInitialSLPriceToAllLegs = true; // same SL price on every same-side leg with SL=0; grid ONLY on anchor ticket
input bool ProtectSLFreezeBeforeBE    = true;  // before BE: SL must stay at committed price (restore if moved/cleared)
// If freeze is OFF: ProtectSLClampNoWiden only blocks widening past commit; if freeze ON, clamp widen is redundant.

//--------------------------- Globals --------------------------------
CTrade trade;

// Locked once per "wave" when first swing SL succeeds for that direction (0 = not locked).
int g_maxBuyBundlePositions = 0;
int g_maxSellBundlePositions = 0;

struct TicketState {
  ulong ticket;
  bool swingSLSet;
  bool beTpSet;
  bool gridDone;
  double protectBoundSL;
  double lastEaWrittenSL;
  bool userTouchedSL;
};

TicketState g_states[200];
int g_statesCount = 0;

#define MAX_TP_MANUAL_TRACK 200
ulong g_tpManTickets[MAX_TP_MANUAL_TRACK];
double g_tpManPrevTP[MAX_TP_MANUAL_TRACK];
int g_tpManSnapshotCount = 0;

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
  g_states[g_statesCount].gridDone = false;
  g_states[g_statesCount].protectBoundSL = 0.0;
  g_states[g_statesCount].lastEaWrittenSL = 0.0;
  g_states[g_statesCount].userTouchedSL = false;
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

// If ideal break-even SL violates stops level, snap to the tightest valid SL
// (BUY: just below bid; SELL: just above ask) so BE can still run on tight brokers.
double AdjustBreakevenSlForStopsLevel(const bool isBuy, const double idealSl,
                                      const int digits) {
  const double pt = Pt();
  if (pt <= 0.0) return NormalizeDouble(idealSl, digits);
  if (RespectStopDistanceSLOnly(isBuy, idealSl))
    return NormalizeDouble(idealSl, digits);
  const int lvl = (int)MathMax(StopsLevelPoints(), 1);
  const double minDist = (double)lvl * pt;
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  double adj;
  if (isBuy)
    adj = bid - minDist - pt;
  else
    adj = ask + minDist + pt;
  return NormalizeDouble(adj, digits);
}

// When TP is edited on a manual position, apply the same TP to every same-side
// market leg (manual + this EA's MSSLTP grid fills) and EA pending limits/stops.
void SyncTPFromManualUserChange() {
  if (!SyncTPWhenManualChanges) return;
  const double pt = Pt();
  if (pt <= 0.0) return;
  const double eps = pt / 2.0;
  const int digits = DigitsCount();

  ulong curTk[MAX_TP_MANUAL_TRACK];
  double curTP[MAX_TP_MANUAL_TRACK];
  ENUM_POSITION_TYPE curSide[MAX_TP_MANUAL_TRACK];
  int nMan = 0;
  for (int i = PositionsTotal() - 1; i >= 0 && nMan < MAX_TP_MANUAL_TRACK; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) continue;
    curTk[nMan] = tk;
    curTP[nMan] = PositionGetDouble(POSITION_TP);
    curSide[nMan] = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    nMan++;
  }

  ulong changedTk = 0;
  double newTP = 0.0;
  ENUM_POSITION_TYPE side = POSITION_TYPE_BUY;
  bool deleteTP = false;

  for (int i = 0; i < nMan; i++) {
    const double tp = curTP[i];
    bool found = false;
    double prev = 0.0;
    for (int j = 0; j < g_tpManSnapshotCount; j++) {
      if (g_tpManTickets[j] == curTk[i]) {
        found = true;
        prev = g_tpManPrevTP[j];
        break;
      }
    }
    if (!found) continue;

    if (SyncTPDeletionToAll && prev > 0.0 && tp <= 0.0) {
      changedTk = curTk[i];
      newTP = 0.0;
      side = curSide[i];
      deleteTP = true;
      break;
    }
    if (tp > 0.0 && MathAbs(prev - tp) > eps) {
      changedTk = curTk[i];
      newTP = NormalizeDouble(tp, digits);
      side = curSide[i];
      deleteTP = false;
      break;
    }
  }

  if (changedTk == 0) return;

  const bool isBuy = (side == POSITION_TYPE_BUY);
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    const ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (pt != side) continue;
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    const string com = PositionGetString(POSITION_COMMENT);
    if (mag == MagicNumber && StringFind(com, "MSSLTP") != 0) continue;

    const double sl = PositionGetDouble(POSITION_SL);
    const double ctp = PositionGetDouble(POSITION_TP);
    if (!deleteTP) {
      if (ctp > 0.0 && MathAbs(ctp - newTP) <= eps) continue;
      if (!RespectStopDistanceTPOnly(isBuy, newTP)) continue;
    } else {
      if (ctp <= 0.0) continue;
    }
    if (!trade.PositionModify(tk, sl, deleteTP ? 0.0 : newTP))
      Print("[ManualSwingSLTP] SyncTP position failed tk=", tk, " ret=",
            trade.ResultRetcode());
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    const ENUM_ORDER_TYPE otyp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (isBuy) {
      if (otyp != ORDER_TYPE_BUY_LIMIT && otyp != ORDER_TYPE_BUY_STOP &&
          otyp != ORDER_TYPE_BUY_STOP_LIMIT)
        continue;
    } else {
      if (otyp != ORDER_TYPE_SELL_LIMIT && otyp != ORDER_TYPE_SELL_STOP &&
          otyp != ORDER_TYPE_SELL_STOP_LIMIT)
        continue;
    }
    const double op = OrderGetDouble(ORDER_PRICE_OPEN);
    const double osl = OrderGetDouble(ORDER_SL);
    const double otp = OrderGetDouble(ORDER_TP);
    const ENUM_ORDER_TYPE_TIME ttime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    const datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
    if (!deleteTP) {
      if (otp > 0.0 && MathAbs(otp - newTP) <= eps) continue;
      if (!RespectStopDistanceTPOnly(isBuy, newTP)) continue;
    } else {
      if (otp <= 0.0) continue;
    }
    if (!trade.OrderModify(ot, op, osl, deleteTP ? 0.0 : newTP, ttime, exp))
      Print("[ManualSwingSLTP] SyncTP pending failed ot=", ot, " ret=",
            trade.ResultRetcode());
  }

  Print("[ManualSwingSLTP] Synced TP from manual ticket ", changedTk,
        " → ", deleteTP ? "removed" : DoubleToString(newTP, digits),
        " (", isBuy ? "BUY" : "SELL", " side)");
}

void UpdateManualTPPrevSnapshot() {
  g_tpManSnapshotCount = 0;
  for (int i = PositionsTotal() - 1; i >= 0 && g_tpManSnapshotCount < MAX_TP_MANUAL_TRACK;
       i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) continue;
    g_tpManTickets[g_tpManSnapshotCount] = tk;
    g_tpManPrevTP[g_tpManSnapshotCount] = PositionGetDouble(POSITION_TP);
    g_tpManSnapshotCount++;
  }
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
    if (mag != MagicNumber) {
      n++;
      continue;
    }
    const string c = PositionGetString(POSITION_COMMENT);
    if (StringFind(c, "MSSLTP") == 0) n++;
  }
  return n;
}

void ResetBundleCapIfSideFlat(const bool buySide) {
  if (buySide) {
    if (CountBundleLegs(true) == 0) g_maxBuyBundlePositions = 0;
  } else {
    if (CountBundleLegs(false) == 0) g_maxSellBundlePositions = 0;
  }
}

int BundleExtraLegsForLock() {
  if (!UseGridPendingOrders) return 0;
  int extra = (BundleMaxExtraLegsCap > 0) ? BundleMaxExtraLegsCap : GridExtraPendingLegs;
  if (extra < 0) extra = 0;
  return extra;
}

void MaybeLockBundleMaxForDirection(const ENUM_POSITION_TYPE typ) {
  if (!EnforceInitialBundleMax) return;
  const int extra = BundleExtraLegsForLock();
  if (typ == POSITION_TYPE_BUY) {
    if (g_maxBuyBundlePositions > 0) return;
    const int n = CountBundleLegs(true);
    g_maxBuyBundlePositions = n + extra;
    if (g_maxBuyBundlePositions < n) g_maxBuyBundlePositions = n;
    Print("[ManualSwingSLTP] BUY bundle max locked = ", g_maxBuyBundlePositions,
          " (open legs ", n, " + extra ", extra, ")");
  } else {
    if (g_maxSellBundlePositions > 0) return;
    const int n = CountBundleLegs(false);
    g_maxSellBundlePositions = n + extra;
    if (g_maxSellBundlePositions < n) g_maxSellBundlePositions = n;
    Print("[ManualSwingSLTP] SELL bundle max locked = ", g_maxSellBundlePositions,
          " (open legs ", n, " + extra ", extra, ")");
  }
}

bool CloseNewestBundleExcessOne(const bool buySide) {
  const int cap = buySide ? g_maxBuyBundlePositions : g_maxSellBundlePositions;
  if (cap <= 0) return false;
  if (CountBundleLegs(buySide) <= cap) return false;

  ulong newestTk = 0;
  datetime newestTime = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    const ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (buySide && pt != POSITION_TYPE_BUY) continue;
    if (!buySide && pt != POSITION_TYPE_SELL) continue;
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    bool leg = false;
    if (mag != MagicNumber) leg = true;
    else {
      const string c = PositionGetString(POSITION_COMMENT);
      if (StringFind(c, "MSSLTP") == 0) leg = true;
    }
    if (!leg) continue;
    const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
    if (newestTk == 0 || t >= newestTime) {
      newestTime = t;
      newestTk = tk;
    }
  }
  if (newestTk == 0) return false;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  if (trade.PositionClose(newestTk)) {
    Print("[ManualSwingSLTP] Bundle cap: closed newest excess ticket ", newestTk,
          " (", (buySide ? "BUY" : "SELL"), " side)");
    return true;
  }
  Print("[ManualSwingSLTP] Bundle cap: failed to close excess ticket ", newestTk,
        " ret=", trade.ResultRetcode());
  return false;
}

void EnforceBundleMaxPositions() {
  if (!EnforceInitialBundleMax) return;
  for (int k = 0; k < 24; k++) {
    bool progressed = false;
    if (g_maxBuyBundlePositions > 0 && CountBundleLegs(true) > g_maxBuyBundlePositions)
      progressed = CloseNewestBundleExcessOne(true) || progressed;
    if (g_maxSellBundlePositions > 0 && CountBundleLegs(false) > g_maxSellBundlePositions)
      progressed = CloseNewestBundleExcessOne(false) || progressed;
    if (!progressed) break;
  }
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
  lots = MathFloor(lots / stepLot) * stepLot;
  if (lots < minLot) lots = minLot;
  return NormalizeDouble(lots, 2);
}

bool IsBundlePositionLeg(const ulong tk) {
  if (tk == 0 || !PositionSelectByTicket(tk)) return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
  const long mag = (long)PositionGetInteger(POSITION_MAGIC);
  if (mag != MagicNumber) return true;
  const string c = PositionGetString(POSITION_COMMENT);
  return (StringFind(c, "MSSLTP") == 0);
}

bool IsBundleOrderLeg(const ulong ot) {
  if (ot == 0 || !OrderSelect(ot)) return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
  const long mag = (long)OrderGetInteger(ORDER_MAGIC);
  if (mag != MagicNumber) return true;
  const string c = OrderGetString(ORDER_COMMENT);
  return (StringFind(c, "MSSLTP") == 0);
}

// Combined floating profit in points for all bundle legs on one side (manual + MSSLTP fills).
double BundleProfitPointsSum(const ENUM_POSITION_TYPE side) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
    const double open = PositionGetDouble(POSITION_PRICE_OPEN);
    sum += ProfitPointsForPosition(side, open);
  }
  return sum;
}

bool BundleReadyForBreakEven(const ENUM_POSITION_TYPE side) {
  if (BreakEvenTriggerPoints <= 0) return false;
  if (CountBundleLegs(side == POSITION_TYPE_BUY) <= 0) return false;
  return BundleProfitPointsSum(side) >= (double)BreakEvenTriggerPoints;
}

int StateIndexForBreakEvenLeg(const ulong tk) {
  if (!PositionSelectByTicket(tk)) return -1;
  const long mag = (long)PositionGetInteger(POSITION_MAGIC);
  if (mag != MagicNumber) return FindStateIndex(tk);
  const string c = PositionGetString(POSITION_COMMENT);
  const string prefix = "MSSLTP";
  if (StringFind(c, prefix) != 0) return -1;
  const ulong parentTk =
      (ulong)StringToInteger(StringSubstr(c, (int)StringLen(prefix)));
  if (parentTk == 0) return -1;
  return FindStateIndex(parentTk);
}

// Manual + MSSLTP: ຫ້າມ lot ຕໍ່ໄມ້ເກີນຄ່າກຳນົດ (ຕັດ position / ປັບ pending).
void EnforceMaxLotPerLeg() {
  if (MaxLotPerLeg <= 0.0) return;

  const double maxL = NormalizeVolumeLocal(MaxLotPerLeg);
  const double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double eps = (stepLot > 0.0) ? stepLot * 0.01 : 0.00001;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    const double vol = PositionGetDouble(POSITION_VOLUME);
    if (vol <= maxL + eps) continue;

    double closeVol = vol - maxL;
    if (stepLot > 0.0)
      closeVol = MathFloor(closeVol / stepLot) * stepLot;
    if (closeVol < stepLot) continue;

    if (!trade.PositionClosePartial(tk, closeVol)) {
      Print("[ManualSwingSLTP] MaxLotPerLeg: partial close failed tk=", tk,
            " vol=", vol, " close=", closeVol, " ret=", trade.ResultRetcode());
    } else {
      Print("[ManualSwingSLTP] MaxLotPerLeg: reduced position tk=", tk,
            " from ", vol, " toward max ", maxL);
    }
  }

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (!IsBundleOrderLeg(ot)) continue;

    double ovol = OrderGetDouble(ORDER_VOLUME_CURRENT);
    if (ovol <= 0.0)
      ovol = OrderGetDouble(ORDER_VOLUME_INITIAL);
    if (ovol <= maxL + eps) continue;

    const double newVol = maxL;
    const double price = OrderGetDouble(ORDER_PRICE_OPEN);
    const double osl = OrderGetDouble(ORDER_SL);
    const double otp = OrderGetDouble(ORDER_TP);
    const ENUM_ORDER_TYPE_TIME ttime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    const datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

    if (!trade.OrderModify(ot, price, osl, otp, ttime, exp, newVol)) {
      Print("[ManualSwingSLTP] MaxLotPerLeg: order volume modify failed ot=", ot,
            " vol=", ovol, " ret=", trade.ResultRetcode());
      if (!trade.OrderDelete(ot))
        Print("[ManualSwingSLTP] MaxLotPerLeg: order delete failed ot=", ot);
    } else {
      Print("[ManualSwingSLTP] MaxLotPerLeg: pending ot=", ot,
            " volume ", ovol, " -> ", newVol);
    }
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
      Print("[ManualSwingSLTP] OrderDelete grid failed ticket=", ot, " ret=", trade.ResultRetcode());
  }
}

void DeleteAllGridPendingsOnSide(const ENUM_POSITION_TYPE side) {
  const string prefix = "MSSLTP";
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    const string c = OrderGetString(ORDER_COMMENT);
    if (StringFind(c, prefix) != 0) continue;
    const ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    const bool isBuySide =
        (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT ||
         otype == ORDER_TYPE_BUY_STOP || otype == ORDER_TYPE_BUY_STOP_LIMIT);
    const bool isSellSide =
        (otype == ORDER_TYPE_SELL || otype == ORDER_TYPE_SELL_LIMIT ||
         otype == ORDER_TYPE_SELL_STOP || otype == ORDER_TYPE_SELL_STOP_LIMIT);
    if (side == POSITION_TYPE_BUY && !isBuySide) continue;
    if (side == POSITION_TYPE_SELL && !isSellSide) continue;
    if (!trade.OrderDelete(ot))
      Print("[ManualSwingSLTP] OrderDelete grid side failed ot=", ot,
            " ret=", trade.ResultRetcode());
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
        Print("[ManualSwingSLTP] Orphan grid delete failed ", ot);
      continue;
    }
    if (PositionGetString(POSITION_SYMBOL) != _Symbol ||
        (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
      if (!trade.OrderDelete(ot))
        Print("[ManualSwingSLTP] Orphan grid delete failed ", ot);
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
  int legs = GridExtraPendingLegs;
  if (legs < 1 || slBound <= 0.0) {
    g_states[st].gridDone = true;
    return;
  }
  if (legs > 50) legs = 50;

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int minPts = (int)MathMax(StopsLevelPoints(), 1);
  const double minDist = (double)minPts * pt;
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const int digits = DigitsCount();
  double lots = lotsRaw;
  if (GridLot > 0.0) lots = GridLot;
  lots = NormalizeVolumeLocal(lots);
  if (lots <= 0.0) {
    g_states[st].gridDone = true;
    return;
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const string tag = GridParentTag(parentTk);
  const double gridSL = NormalizeDouble(slBound, digits);

  if (typ == POSITION_TYPE_BUY) {
    const double floorSL = slBound + minDist;
    const double span = entry - floorSL;
    if (span <= pt) {
      g_states[st].gridDone = true;
      return;
    }
    const double step = span / (double)(legs + 1);
    for (int i = 1; i <= legs; i++) {
      const double price = NormalizeDouble(entry - step * (double)i, digits);
      if (price <= floorSL) break;
      if (price >= ask - minDist) continue;
      if (HasPendingLimitNear(true, price)) continue;
      if (!PendingSlDistanceOkVsOrder(true, price, gridSL)) continue;
      if (!trade.BuyLimit(lots, price, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0,
                          tag)) {
        Print("[ManualSwingSLTP] BuyLimit grid i=", i, " ret=", trade.ResultRetcode(),
              " ", trade.ResultRetcodeDescription());
        break;
      }
    }
  } else {
    const double ceilSL = slBound - minDist;
    const double span = ceilSL - entry;
    if (span <= pt) {
      g_states[st].gridDone = true;
      return;
    }
    const double step = span / (double)(legs + 1);
    for (int i = 1; i <= legs; i++) {
      const double price = NormalizeDouble(entry + step * (double)i, digits);
      if (price >= ceilSL) break;
      if (price <= bid + minDist) continue;
      if (HasPendingLimitNear(false, price)) continue;
      if (!PendingSlDistanceOkVsOrder(false, price, gridSL)) continue;
      if (!trade.SellLimit(lots, price, _Symbol, gridSL, 0.0, ORDER_TIME_GTC, 0,
                           tag)) {
        Print("[ManualSwingSLTP] SellLimit grid i=", i, " ret=", trade.ResultRetcode(),
              " ", trade.ResultRetcodeDescription());
        break;
      }
    }
  }
  g_states[st].gridDone = true;
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
  for (int i = PositionsTotal() - 1; i >= 0 && n < kMax; i--) {
    const ulong t2 = PositionGetTicket(i);
    if (t2 == 0 || !PositionSelectByTicket(t2)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != typ) continue;
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    const string com = PositionGetString(POSITION_COMMENT);
    if (mag == MagicNumber && StringFind(com, "MSSLTP") != 0) continue;
    if (PositionGetDouble(POSITION_SL) > 0.0) continue;
    list[n++] = t2;
  }
  for (int i = 0; i < n; i++) {
    if (list[i] == anchorTk) {
      const ulong tmp = list[0];
      list[0] = list[i];
      list[i] = tmp;
      break;
    }
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = 0; i < n; i++) {
    const ulong t2 = list[i];
    if (!PositionSelectByTicket(t2)) continue;
    const double otp = PositionGetDouble(POSITION_TP);
    if (!RespectStopsDistanceFromMarket(isBuy, sl, otp)) continue;
    if (!trade.PositionModify(t2, sl, otp)) {
      Print("[ManualSwingSLTP] Shared SL modify failed tk=", t2,
            " ret=", trade.ResultRetcode());
      continue;
    }
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    if (mag != MagicNumber) {
      const int st2 = EnsureState(t2);
      if (st2 < 0) continue;
      g_states[st2].swingSLSet = true;
      g_states[st2].protectBoundSL = sl;
      g_states[st2].lastEaWrittenSL = sl;
      g_states[st2].userTouchedSL = false;
      if (t2 == anchorTk) {
        const double open2 = PositionGetDouble(POSITION_PRICE_OPEN);
        const double vol2 = PositionGetDouble(POSITION_VOLUME);
        TryPlaceGridPendings(t2, typ, open2, sl, vol2, usedRefSL, st2);
      } else {
        g_states[st2].gridDone = true;
      }
    }
    MaybeLockBundleMaxForDirection(typ);
  }
}

// Keep MSSLTP grid fills on parent's committed SL while parent is in swing phase.
void EnforceGridLegSLFreeze() {
  if (!ProtectSLFreezeBeforeBE) return;
  const double pt = Pt();
  if (pt <= 0.0) return;
  const double eps = pt * 5.0;
  const int digits = DigitsCount();
  const string prefix = "MSSLTP";
  const int plen = (int)StringLen(prefix);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    const string c = PositionGetString(POSITION_COMMENT);
    if (StringFind(c, prefix) != 0) continue;
    const ulong parentTk = (ulong)StringToInteger(StringSubstr(c, plen));
    if (parentTk == 0) continue;
    const int stp = FindStateIndex(parentTk);
    if (stp < 0) continue;
    if (!g_states[stp].swingSLSet || g_states[stp].beTpSet) continue;
    const double bound = g_states[stp].protectBoundSL;
    if (bound <= 0.0) continue;

    const ENUM_POSITION_TYPE typ =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    const bool isBuy = (typ == POSITION_TYPE_BUY);
    const double curSL = PositionGetDouble(POSITION_SL);
    const double curTP = PositionGetDouble(POSITION_TP);

    if (ProtectSLRestoreIfRemoved && curSL <= 0.0) {
      if (RespectStopDistanceSLOnly(isBuy, bound))
        trade.PositionModify(tk, bound, curTP);
      continue;
    }

    const double nbound = NormalizeDouble(bound, digits);
    const double ncur = NormalizeDouble(curSL, digits);
    if (MathAbs(ncur - nbound) > eps && RespectStopDistanceSLOnly(isBuy, nbound))
      trade.PositionModify(tk, nbound, curTP);
  }
}

// Grid pending orders: keep SL equal to parent manual's committed SL (same as
// first position) while parent is in swing phase before BE.
void EnforceGridPendingSLFreeze() {
  if (!ProtectSLFreezeBeforeBE) return;
  const double pt = Pt();
  if (pt <= 0.0) return;
  const double eps = pt * 5.0;
  const int digits = DigitsCount();
  const string prefix = "MSSLTP";
  const int plen = (int)StringLen(prefix);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int j = OrdersTotal() - 1; j >= 0; j--) {
    const ulong ot = OrderGetTicket(j);
    if (ot == 0 || !OrderSelect(ot)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    const string c = OrderGetString(ORDER_COMMENT);
    if (StringFind(c, prefix) != 0) continue;
    const ulong parentTk = (ulong)StringToInteger(StringSubstr(c, plen));
    if (parentTk == 0) continue;
    const int stp = FindStateIndex(parentTk);
    if (stp < 0) continue;
    if (!g_states[stp].swingSLSet || g_states[stp].beTpSet) continue;
    const double bound = g_states[stp].protectBoundSL;
    if (bound <= 0.0) continue;

    const ENUM_ORDER_TYPE otyp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (otyp != ORDER_TYPE_BUY_LIMIT && otyp != ORDER_TYPE_SELL_LIMIT) continue;

    const bool isBuyLim = (otyp == ORDER_TYPE_BUY_LIMIT);
    const double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
    const double curSL = OrderGetDouble(ORDER_SL);
    const double curTP = OrderGetDouble(ORDER_TP);
    const double nbound = NormalizeDouble(bound, digits);

    if (ProtectSLRestoreIfRemoved && curSL <= 0.0) {
      if (PendingSlDistanceOkVsOrder(isBuyLim, orderPrice, nbound))
        trade.OrderModify(ot, orderPrice, nbound, curTP,
                          (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                          (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
      continue;
    }

    const double ncur = NormalizeDouble(curSL, digits);
    if (MathAbs(ncur - nbound) > eps &&
        PendingSlDistanceOkVsOrder(isBuyLim, orderPrice, nbound)) {
      trade.OrderModify(ot, orderPrice, nbound, curTP,
                        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                        (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION));
    }
  }
}

//--------------------------- SL protection ---------------------------
void DetectUserSlDrag(const int st, const ENUM_POSITION_TYPE typ,
                      const double curSL, const double pt) {
  if (!ProtectBEDontOverrideUserSL) return;
  if (!g_states[st].swingSLSet || g_states[st].beTpSet) return;
  if (g_states[st].userTouchedSL) return;
  if (g_states[st].lastEaWrittenSL <= 0.0 || curSL <= 0.0) return;
  const double eps = pt * 8.0;
  if (MathAbs(curSL - g_states[st].lastEaWrittenSL) > eps)
    g_states[st].userTouchedSL = true;
}

// Returns true if position was modified (caller should refresh SL/TP from market).
bool ProtectRestoreOrClampSL(const ulong tk, const int st,
                             const ENUM_POSITION_TYPE typ, const double curSL,
                             const double curTP, const int digits) {
  if (!g_states[st].swingSLSet || g_states[st].beTpSet) return false;
  const double bound = g_states[st].protectBoundSL;
  if (bound <= 0.0) return false;
  const double pt = Pt();
  if (pt <= 0.0) return false;
  const double eps = pt * 5.0;
  const bool isBuy = (typ == POSITION_TYPE_BUY);

  if (ProtectSLRestoreIfRemoved && curSL <= 0.0) {
    if (!RespectStopDistanceSLOnly(isBuy, bound)) return false;
    if (trade.PositionModify(tk, bound, curTP)) {
      g_states[st].lastEaWrittenSL = bound;
      Print("[ManualSwingSLTP] Restored removed SL ticket=", tk);
      return true;
    }
    return false;
  }

  if (ProtectSLFreezeBeforeBE && curSL > 0.0) {
    const double nbound = NormalizeDouble(bound, digits);
    const double ncur = NormalizeDouble(curSL, digits);
    if (MathAbs(ncur - nbound) > eps) {
      if (!RespectStopDistanceSLOnly(isBuy, nbound)) return false;
      if (trade.PositionModify(tk, nbound, curTP)) {
        g_states[st].lastEaWrittenSL = nbound;
        Print("[ManualSwingSLTP] SL frozen to committed price ticket=", tk);
        return true;
      }
    }
    return false;
  }

  if (!ProtectSLClampNoWiden) return false;

  if (isBuy && curSL + eps < bound) {
    const double nsl = NormalizeDouble(bound, digits);
    if (!RespectStopDistanceSLOnly(true, nsl)) return false;
    if (trade.PositionModify(tk, nsl, curTP)) {
      g_states[st].lastEaWrittenSL = nsl;
      Print("[ManualSwingSLTP] BUY SL clamped to committed bound ticket=", tk);
      return true;
    }
  } else if (!isBuy && curSL > bound + eps) {
    const double nsl = NormalizeDouble(bound, digits);
    if (!RespectStopDistanceSLOnly(false, nsl)) return false;
    if (trade.PositionModify(tk, nsl, curTP)) {
      g_states[st].lastEaWrittenSL = nsl;
      Print("[ManualSwingSLTP] SELL SL clamped to committed bound ticket=", tk);
      return true;
    }
  }
  return false;
}

// Apply BE+TP to one bundle leg when combined side profit points >= trigger.
bool ApplyBreakEvenToLeg(const ulong tk, const int st, const double bundlePts) {
  if (!PositionSelectByTicket(tk)) return false;

  const ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  double workSL = PositionGetDouble(POSITION_SL);
  double workTP = PositionGetDouble(POSITION_TP);

  const double pt = Pt();
  if (pt <= 0.0) return false;
  const int digits = DigitsCount();

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

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

  if (st >= 0 && ProtectBEDontOverrideUserSL && g_states[st].userTouchedSL)
    wantSL = workSL;

  if (workSL > 0.0) {
    if (typ == POSITION_TYPE_BUY && wantSL <= workSL) wantSL = workSL;
    if (typ == POSITION_TYPE_SELL && wantSL >= workSL) wantSL = workSL;
  }
  if (workTP > 0.0) wantTP = workTP;

  const bool isBuy = (typ == POSITION_TYPE_BUY);

  if (wantSL > 0.0 && !RespectStopDistanceSLOnly(isBuy, wantSL)) {
    if (BreakEvenRelaxSLToStopsLevel)
      wantSL = AdjustBreakevenSlForStopsLevel(isBuy, wantSL, digits);
    if (wantSL > 0.0 && !RespectStopDistanceSLOnly(isBuy, wantSL))
      wantSL = workSL;
  }
  if (workSL > 0.0) {
    if (typ == POSITION_TYPE_BUY && wantSL > 0.0 && wantSL <= workSL) wantSL = workSL;
    if (typ == POSITION_TYPE_SELL && wantSL > 0.0 && wantSL >= workSL) wantSL = workSL;
  }
  if (wantTP > 0.0 && !RespectStopDistanceTPOnly(isBuy, wantTP))
    wantTP = workTP;

  const double nCurSL = (workSL > 0.0) ? NormalizeDouble(workSL, digits) : 0.0;
  const double nCurTP = (workTP > 0.0) ? NormalizeDouble(workTP, digits) : 0.0;
  const double nWantSL = (wantSL > 0.0) ? NormalizeDouble(wantSL, digits) : 0.0;
  const double nWantTP = (wantTP > 0.0) ? NormalizeDouble(wantTP, digits) : 0.0;

  if (nCurSL == nWantSL && nCurTP == nWantTP) {
    if (st >= 0) {
      const bool userKeptSlForBe =
          (ProtectBEDontOverrideUserSL && g_states[st].userTouchedSL);
      const double bound = g_states[st].protectBoundSL;
      const double epsSwing = pt * 10.0;
      const bool stillOnSwingFreeze =
          (!userKeptSlForBe && bound > 0.0 && workSL > 0.0 &&
           MathAbs(NormalizeDouble(workSL, digits) - NormalizeDouble(bound, digits)) <=
               epsSwing);
      if (!(bundlePts >= (double)BreakEvenTriggerPoints && stillOnSwingFreeze))
        g_states[st].beTpSet = true;
    }
    return true;
  }

  if (trade.PositionModify(tk, nWantSL, nWantTP)) {
    if (st >= 0) {
      g_states[st].beTpSet = true;
      g_states[st].lastEaWrittenSL = nWantSL;
    }
    return true;
  }

  Print("[ManualSwingSLTP] Modify BE/TP failed. ticket=", tk,
        " bundlePts=", DoubleToString(bundlePts, 1),
        " wantSL=", DoubleToString(nWantSL, digits),
        " wantTP=", DoubleToString(nWantTP, digits),
        " err=", GetLastError());
  return false;
}

void ProcessBundleBreakEvenForSide(const ENUM_POSITION_TYPE side) {
  if (!BundleReadyForBreakEven(side)) return;

  const double bundlePts = BundleProfitPointsSum(side);
  DeleteAllGridPendingsOnSide(side);

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (!IsBundlePositionLeg(tk)) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;

    int st = StateIndexForBreakEvenLeg(tk);
    const long mag = (long)PositionGetInteger(POSITION_MAGIC);
    if (mag != MagicNumber) {
      st = EnsureState(tk);
      if (st < 0) continue;
    }

    ApplyBreakEvenToLeg(tk, st, bundlePts);
  }
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
      Print("[ManualSwingSLTP] state table full (200 open manuals?). ticket=", tk, " — cannot track SL.");
      s_lastFullWarn = TimeCurrent();
    }
    return;
  }

  const double pt = Pt();
  if (pt <= 0.0) return;
  const int digits = DigitsCount();

  trade.SetExpertMagicNumber(MagicNumber); // for modifications only
  trade.SetDeviationInPoints(SlippagePoints);

  if (g_states[st].swingSLSet && g_states[st].protectBoundSL > 0.0) {
    if (ProtectRestoreOrClampSL(tk, st, typ, workSL, workTP, digits)) {
      if (!PositionSelectByTicket(tk)) return;
      workSL = PositionGetDouble(POSITION_SL);
      workTP = PositionGetDouble(POSITION_TP);
    }
  }
  DetectUserSlDrag(st, typ, workSL, pt);

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
      if (typ == POSITION_TYPE_BUY) {
        double sw = SwingLowPrice();
        if (sw > 0.0) sl = sw - (double)SwingBufferPoints * pt;
      } else {
        double sw = SwingHighPrice();
        if (sw > 0.0) sl = sw + (double)SwingBufferPoints * pt;
      }

      // Apply offset ONLY when creating the first SL (i.e., not copying refSL).
      if (sl > 0.0 && FirstSLOffsetPoints != 0) {
        if (typ == POSITION_TYPE_BUY) sl -= (double)FirstSLOffsetPoints * pt;
        else sl += (double)FirstSLOffsetPoints * pt;
      }
    }
    if (sl > 0.0) sl = NormalizeDouble(sl, digits);

    if (sl > 0.0 && RespectStopsDistanceFromMarket(typ == POSITION_TYPE_BUY, sl, 0.0)) {
      if (ShareInitialSLPriceToAllLegs)
        ApplySharedSwingSLPrice(tk, typ, sl, usedRefSL, digits);
      else if (trade.PositionModify(tk, sl, workTP)) {
        g_states[st].swingSLSet = true;
        g_states[st].protectBoundSL = sl;
        g_states[st].lastEaWrittenSL = sl;
        g_states[st].userTouchedSL = false;
        MaybeLockBundleMaxForDirection(typ);
        if (!PositionSelectByTicket(tk)) return;
        const double vol = PositionGetDouble(POSITION_VOLUME);
        TryPlaceGridPendings(tk, typ, open, sl, vol, usedRefSL, st);
      }
      if (!PositionSelectByTicket(tk)) return;
      workSL = PositionGetDouble(POSITION_SL);
      workTP = PositionGetDouble(POSITION_TP);
    }
  }

  // Break-even + TP: handled in ProcessBundleBreakEvenForSide() when sum(points) on side >= trigger.
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)
    trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0)
    trade.SetTypeFilling(ORDER_FILLING_FOK);
  else
    trade.SetTypeFilling(ORDER_FILLING_RETURN);
  return INIT_SUCCEEDED;
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  PruneStaleStates();
  ResetBundleCapIfSideFlat(true);
  ResetBundleCapIfSideFlat(false);
  CleanupOrphanGridPendings();
  EnforceBundleMaxPositions();
  EnforceMaxLotPerLeg();

  // Manage all manual positions on this symbol
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0) continue;
    ManageManualPosition(tk);
  }

  ProcessBundleBreakEvenForSide(POSITION_TYPE_BUY);
  ProcessBundleBreakEvenForSide(POSITION_TYPE_SELL);

  EnforceGridLegSLFreeze();
  EnforceGridPendingSLFreeze();
  SyncTPFromManualUserChange();
  EnforceBundleMaxPositions();
  UpdateManualTPPrevSnapshot();
}

