//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open BUY and/or SELL, EA places a grid per position ticket |
//| (no TP). Grid distance and count are configurable.                 |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: one EA grid stack per BUY/SELL side; per-side TP; combined SL."
#property version "1.05"

#include <Trade/Trade.mqh>

//--- inputs
input int GridCount = 8; // Number of pending orders in grid
input int GridDistancePoints =
    500; // Distance between each pending order (points)
input double GridLotSize =
    0.01; // Fixed lot size for all grid orders (no martingale)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 111222; // Magic for EA grid orders
input double MaxFloatingLossUSD =
    200.0; // Combined BUY+SELL floating on this symbol: if sum(profit+swap) <= -this, close ALL (all pendings)
input double TargetProfitUSD =
    20.0; // Per side: BUY or SELL sum(profit+swap) >= this closes that side only (EA pendings)

//--- trade object
CTrade trade;

// Shared cap for per-ticket arrays (SL/TP sync + grid bookkeeping)
#define MAX_TRACKED_POSITIONS 100

// Remember which position tickets already had their grid placed (each leg
// independently: BUY grid + SELL grid can coexist). Pruned when ticket closes.
#define MAX_GRID_TRACKED_TICKETS MAX_TRACKED_POSITIONS
ulong g_gridDoneTickets[MAX_GRID_TRACKED_TICKETS];
int g_gridDoneCount = 0;

// Track previous SL/TP per position ticket so we can detect
// when the user has manually changed SL/TP on one position
// and then sync all other open positions accordingly.
int g_prevPosCount = 0;
ulong g_prevPosTickets[MAX_TRACKED_POSITIONS];
double g_prevPosTP[MAX_TRACKED_POSITIONS];
double g_prevPosSL[MAX_TRACKED_POSITIONS];

//+------------------------------------------------------------------+
//| Count positions and EA pending orders for symbol                  |
//+------------------------------------------------------------------+
int CountPositionsOnSymbol() {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) == _Symbol)
      n++;
  }
  return n;
}

// Count all pending orders on symbol (any magic) for emergency-close check
int CountPendingOrdersOnSymbol() {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong t = OrderGetTicket(i);
    if (t == 0 || !OrderSelect(t))
      continue;
    if (OrderGetString(ORDER_SYMBOL) == _Symbol)
      n++;
  }
  return n;
}

//+------------------------------------------------------------------+
//| Close all positions and pending orders on this symbol             |
//| Order: close OPEN positions first, then delete ALL pending orders  |
//| (during this, EA must not place any new orders)                  |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrdersOnSymbol() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // 1) Close open orders (positions) first — retry until none left
  for (int retry = 0; retry < 5; retry++) {
    int closed = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t))
        continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol)
        continue;
      double volume = PositionGetDouble(POSITION_VOLUME);
      if (volume <= 0.0)
        continue;
      if (trade.PositionClose(t))
        closed++;
      else
        Print("[SetGridManually] Failed to close position ticket ", t,
              " Error=", GetLastError());
    }
    if (closed == 0)
      break;
  }

  // 2) Then delete ALL pending orders on this symbol at once
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if (!trade.OrderDelete(ot))
      Print("[SetGridManually] Failed to delete order ticket ", ot,
            " Error=", GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Sum floating P/L (profit + swap) for open positions of one type on symbol |
//+------------------------------------------------------------------+
double SumFloatingProfitForSide(const ENUM_POSITION_TYPE posType) {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
      continue;
    sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

//+------------------------------------------------------------------+
//| Combined BUY+SELL floating P/L (profit + swap) on this symbol only |
//+------------------------------------------------------------------+
double SumCombinedFloatingPLAllSidesOnSymbol() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

bool HasOpenPositionOfTypeOnSymbol(const ENUM_POSITION_TYPE posType) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
      continue;
    if (PositionGetDouble(POSITION_VOLUME) > 0.0)
      return true;
  }
  return false;
}

//+------------------------------------------------------------------+
//| Classify pending order type as BUY-market-side vs SELL-market-side |
//+------------------------------------------------------------------+
bool EAPendingOrderTypeIsBuySide(const ENUM_ORDER_TYPE otype) {
  return (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP ||
          otype == ORDER_TYPE_BUY_STOP_LIMIT);
}

bool EAPendingOrderTypeIsSellSide(const ENUM_ORDER_TYPE otype) {
  return (otype == ORDER_TYPE_SELL_LIMIT || otype == ORDER_TYPE_SELL_STOP ||
          otype == ORDER_TYPE_SELL_STOP_LIMIT);
}

//+------------------------------------------------------------------+
//| Count this EA's pending orders on one market side (same symbol)    |
//+------------------------------------------------------------------+
int CountEAPendingOrdersForMarketSide(const bool buySide) {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;
    ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (buySide && EAPendingOrderTypeIsBuySide(otype))
      n++;
    else if (!buySide && EAPendingOrderTypeIsSellSide(otype))
      n++;
  }
  return n;
}

//+------------------------------------------------------------------+
//| Delete EA (magic) pending orders on one market side (buy vs sell) |
//+------------------------------------------------------------------+
void DeleteEAPendingOrdersForMarketSide(const bool closeBuySide) {
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;
    ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (closeBuySide && !EAPendingOrderTypeIsBuySide(otype))
      continue;
    if (!closeBuySide && !EAPendingOrderTypeIsSellSide(otype))
      continue;
    if (!trade.OrderDelete(ot))
      Print("[SetGridManually] Failed to delete pending ", ot, " Error=",
            GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Close all BUY or all SELL market positions on symbol; then remove   |
//| this EA's pending orders for that same market side (grid only).   |
//+------------------------------------------------------------------+
void CloseOneMarketSideOnSymbol(const ENUM_POSITION_TYPE posType) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  const bool closeBuys = (posType == POSITION_TYPE_BUY);

  for (int retry = 0; retry < 5; retry++) {
    int closed = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t))
        continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol)
        continue;
      if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType)
        continue;
      if (PositionGetDouble(POSITION_VOLUME) <= 0.0)
        continue;
      if (trade.PositionClose(t))
        closed++;
      else
        Print("[SetGridManually] Failed to close position ticket ", t,
              " Error=", GetLastError());
    }
    if (closed == 0)
      break;
  }

  DeleteEAPendingOrdersForMarketSide(closeBuys);
}

//+------------------------------------------------------------------+
//| Get earliest position on symbol as reference                      |
//+------------------------------------------------------------------+
bool GetReferencePosition(double &entryPrice, ENUM_POSITION_TYPE &type) {
  datetime earliest = LONG_MAX;
  bool found = false;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    datetime openTime =
        (datetime)PositionGetInteger(POSITION_TIME); // time of opening
    if (!found || openTime < earliest) {
      earliest = openTime;
      entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      found = true;
    }
  }

  return found;
}

//+------------------------------------------------------------------+
//| If user changes SL on one open position, copy/delete SL on all   |
//| other open positions and all pendings on this symbol.            |
//| - If SL moved to a new price  > 0  -> set same SL everywhere.    |
//| - If SL deleted (set to 0)       -> remove SL everywhere.        |
//+------------------------------------------------------------------+
void SyncSLFromUserChange() {
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (point <= 0.0)
    return;
  double eps = point / 2.0; // tolerance for SL comparison

  // Collect current positions for this symbol
  ulong curTickets[MAX_TRACKED_POSITIONS];
  double curSL[MAX_TRACKED_POSITIONS];
  double curTPDummy[MAX_TRACKED_POSITIONS];
  int curCount = 0;

  for (int i = PositionsTotal() - 1; i >= 0 && curCount < MAX_TRACKED_POSITIONS;
       i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double volume = PositionGetDouble(POSITION_VOLUME);
    if (volume <= 0.0)
      continue;

    curTickets[curCount] = t;
    curSL[curCount] = PositionGetDouble(POSITION_SL);
    curTPDummy[curCount] = PositionGetDouble(POSITION_TP);
    curCount++;
  }

  if (curCount == 0)
    return;
  // When curCount >= 1: detect SL change on any position and sync to other
  // positions + all pendings

  // Detect a ticket whose SL changed (including deletion) since last tick
  ulong changedTicket = 0;
  double newSL = 0.0;

  for (int i = 0; i < curCount; i++) {
    double sl = curSL[i];

    bool foundPrev = false;
    double prevSl = 0.0;
    for (int j = 0; j < g_prevPosCount; j++) {
      if (g_prevPosTickets[j] == curTickets[i]) {
        foundPrev = true;
        prevSl = g_prevPosSL[j];
        break;
      }
    }
    if (!foundPrev)
      continue; // new position; no previous SL to compare

    if (MathAbs(prevSl - sl) > eps) {
      changedTicket = curTickets[i];
      newSL = sl; // may be >0 (move) or 0 (delete)
      break;
    }
  }

  if (changedTicket == 0)
    return; // no SL change detected

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // 1) Apply SL change to all other open positions on this symbol
  for (int i = 0; i < curCount; i++) {
    ulong t = curTickets[i];
    if (t == changedTicket)
      continue;

    double curSl = curSL[i];
    double curTp = curTPDummy[i];

    if (newSL > 0.0) {
      if (MathAbs(curSl - newSL) <= eps)
        continue; // already at desired SL
      if (!trade.PositionModify(t, newSL, curTp))
        Print(
            "[SetGridManually] SyncSLFromUserChange (move) failed for ticket ",
            t, " Error=", GetLastError());
    } else { // newSL == 0.0 -> delete SL everywhere
      if (curSl == 0.0)
        continue;
      if (!trade.PositionModify(t, 0.0, curTp))
        Print("[SetGridManually] SyncSLFromUserChange (delete) failed for "
              "ticket ",
              t, " Error=", GetLastError());
    }
  }

  // 2) Apply SL change to all pending orders on this symbol
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
    ENUM_ORDER_TYPE_TIME typeTime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

    double curSl = OrderGetDouble(ORDER_SL);
    double curTp = OrderGetDouble(ORDER_TP);

    if (newSL > 0.0) {
      if (MathAbs(curSl - newSL) <= eps)
        continue;
      if (!trade.OrderModify(ot, orderPrice, newSL, curTp, typeTime, exp))
        Print("[SetGridManually] SyncSLFromUserChange (move) failed for order ",
              ot, " Error=", GetLastError());
    } else { // delete SL
      if (curSl == 0.0)
        continue;
      if (!trade.OrderModify(ot, orderPrice, 0.0, curTp, typeTime, exp))
        Print(
            "[SetGridManually] SyncSLFromUserChange (delete) failed for order ",
            ot, " Error=", GetLastError());
    }
  }
}

//+------------------------------------------------------------------+
//| If user sets TP on one open position, set same TP on all         |
//| positions and all pending orders on this symbol.                  |
//+------------------------------------------------------------------+
void SyncTPFromUserChange() {
  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (point <= 0.0)
    return;
  double eps = point / 2.0; // tolerance for TP comparison

  // Collect current positions for this symbol
  ulong curTickets[MAX_TRACKED_POSITIONS];
  double curTP[MAX_TRACKED_POSITIONS];
  double curSL[MAX_TRACKED_POSITIONS];
  int curCount = 0;

  for (int i = PositionsTotal() - 1; i >= 0 && curCount < MAX_TRACKED_POSITIONS;
       i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double volume = PositionGetDouble(POSITION_VOLUME);
    if (volume <= 0.0)
      continue;

    curTickets[curCount] = t;
    curSL[curCount] = PositionGetDouble(POSITION_SL);
    curTP[curCount] = PositionGetDouble(POSITION_TP);
    curCount++;
  }

  if (curCount == 0) {
    g_prevPosCount = 0;
    return;
  }

  // Detect a ticket whose TP changed (non-zero) since last tick
  // (works for 1 or more positions: set TP on one -> sync to all + pendings)
  ulong changedTicket = 0;
  double newTP = 0.0;

  for (int i = 0; i < curCount; i++) {
    double tp = curTP[i];
    if (tp <= 0.0)
      continue; // we don't propagate deletions (TP=0 means user wants no TP)

    bool foundPrev = false;
    double prevTp = 0.0;
    for (int j = 0; j < g_prevPosCount; j++) {
      if (g_prevPosTickets[j] == curTickets[i]) {
        foundPrev = true;
        prevTp = g_prevPosTP[j];
        break;
      }
    }
    if (!foundPrev)
      continue; // new position; no previous TP to compare

    if (MathAbs(prevTp - tp) > eps) {
      changedTicket = curTickets[i];
      newTP = tp;
      break;
    }
  }

  if (changedTicket != 0 && newTP > 0.0) {
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(SlippagePoints);

    // 1) Set same TP on all other open positions
    for (int i = 0; i < curCount; i++) {
      ulong t = curTickets[i];
      if (t == changedTicket)
        continue;

      double tp = curTP[i];
      if (tp <= 0.0)
        continue; // skip positions where user removed TP

      if (MathAbs(tp - newTP) <= eps)
        continue; // already at desired TP

      double sl = curSL[i];
      if (!trade.PositionModify(t, sl, newTP))
        Print("[SetGridManually] SyncTPFromUserChange failed for ticket ", t,
              " Error=", GetLastError());
    }

    // 2) Set same TP on all pending orders on this symbol
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ot = OrderGetTicket(i);
      if (ot == 0 || !OrderSelect(ot))
        continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol)
        continue;

      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      ENUM_ORDER_TYPE_TIME typeTime =
          (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      double curSl = OrderGetDouble(ORDER_SL);
      double curTp = OrderGetDouble(ORDER_TP);

      if (MathAbs(curTp - newTP) <= eps)
        continue; // already at desired TP

      if (!trade.OrderModify(ot, orderPrice, curSl, newTP, typeTime, exp))
        Print(
            "[SetGridManually] SyncTPFromUserChange pending failed for order ",
            ot, " Error=", GetLastError());
    }
  }
}

// Update saved position state for next tick (used by SyncTP and SyncSL to
// detect user changes)
void UpdatePrevPositionState() {
  g_prevPosCount = 0;
  for (int i = PositionsTotal() - 1;
       i >= 0 && g_prevPosCount < MAX_TRACKED_POSITIONS; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if (PositionGetDouble(POSITION_VOLUME) <= 0.0)
      continue;
    g_prevPosTickets[g_prevPosCount] = t;
    g_prevPosTP[g_prevPosCount] = PositionGetDouble(POSITION_TP);
    g_prevPosSL[g_prevPosCount] = PositionGetDouble(POSITION_SL);
    g_prevPosCount++;
  }
}

//+------------------------------------------------------------------+
//| Grid placement bookkeeping (per position ticket)                  |
//+------------------------------------------------------------------+
bool GridAlreadyPlacedForTicket(const ulong ticket) {
  for (int i = 0; i < g_gridDoneCount; i++) {
    if (g_gridDoneTickets[i] == ticket)
      return true;
  }
  return false;
}

void MarkGridPlacedForTicket(const ulong ticket) {
  if (g_gridDoneCount >= MAX_GRID_TRACKED_TICKETS)
    return;
  g_gridDoneTickets[g_gridDoneCount++] = ticket;
}

// Drop closed / foreign-symbol tickets so a new position gets a fresh grid.
void PruneGridDoneTickets() {
  int write = 0;
  for (int i = 0; i < g_gridDoneCount; i++) {
    ulong t = g_gridDoneTickets[i];
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if (PositionGetDouble(POSITION_VOLUME) <= 0.0)
      continue;
    g_gridDoneTickets[write++] = t;
  }
  g_gridDoneCount = write;
}

//+------------------------------------------------------------------+
//| Place grid of pending orders from the given position ticket       |
//+------------------------------------------------------------------+
void PlaceGrid(ulong firstTicket) {
  if (!PositionSelectByTicket(firstTicket))
    return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  // We do NOT set any SL/TP automatically. All positions and grid orders are
  // opened without SL/TP; exit is controlled only by TargetProfitUSD and
  // MaxFloatingLossUSD.
  double slPrice = 0.0, tpPrice = 0.0;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double volMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double volMax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  for (int i = 1; i <= GridCount; i++) {
    double price;
    // Fixed lot size for all grid orders (no martingale)
    double lots = GridLotSize;

    // Normalize lots to broker step and limits
    if (volStep > 0.0)
      lots = MathRound(lots / volStep) * volStep;
    if (volMin > 0.0 && lots < volMin)
      lots = volMin;
    if (volMax > 0.0 && lots > volMax)
      lots = volMax;
    if (type == POSITION_TYPE_BUY) {
      // BUY LIMIT below entry; no SL/TP
      price = NormalizeDouble(entry - GridDistancePoints * point * i, digits);
      if (!trade.BuyLimit(lots, price, symbol, slPrice, tpPrice))
        Print("[SetGridManually] BuyLimit failed #", i,
              " Error=", GetLastError());
    } else {
      // SELL LIMIT above entry; no SL/TP
      price = NormalizeDouble(entry + GridDistancePoints * point * i, digits);
      if (!trade.SellLimit(lots, price, symbol, slPrice, tpPrice))
        Print("[SetGridManually] SellLimit failed #", i,
              " Error=", GetLastError());
    }
  }
  Print("[SetGridManually] Grid placed: ", GridCount, " orders, fixed lot ",
        GridLotSize, " (no SL/TP on grid orders).");
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  Print("SetGridManually EA initialized. Symbol=", _Symbol, " Grid=", GridCount,
        " Dist=", GridDistancePoints,
        " (no SL/TP; TargetProfitUSD per side; MaxFloatingLossUSD = combined BUY+SELL then close ALL).");
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  double combinedFloatingPL = SumCombinedFloatingPLAllSidesOnSymbol();

  bool hasPosOrOrders =
      (CountPositionsOnSymbol() > 0 || CountPendingOrdersOnSymbol() > 0);

  // Emergency first: combined BUY+SELL floating P/L (profit+swap) on this symbol.
  // If drawdown reaches -MaxFloatingLossUSD, flatten EVERYTHING on this symbol
  // (all positions + all pendings) to reduce margin / blow-up risk.
  if (MaxFloatingLossUSD > 0.0 && hasPosOrOrders &&
      combinedFloatingPL <= -MaxFloatingLossUSD) {
    Print("[SetGridManually] Combined BUY+SELL floating P/L ",
          DoubleToString(combinedFloatingPL, 2),
          " USD (profit+swap; threshold = -",
          DoubleToString(MaxFloatingLossUSD, 2),
          "). Closing ALL positions and ALL pending orders on ", _Symbol);
    CloseAllPositionsAndOrdersOnSymbol();
    return; // Do not place new grid or take partial profit this tick
  }

  // Take-profit by money: each market side (BUY vs SELL) is evaluated
  // separately. Only that side's positions + this EA's pendings on that side
  // are closed when that side's floating P/L (profit+swap) reaches TargetProfitUSD.
  if (TargetProfitUSD > 0.0) {
    if (HasOpenPositionOfTypeOnSymbol(POSITION_TYPE_BUY)) {
      double buyP = SumFloatingProfitForSide(POSITION_TYPE_BUY);
      if (buyP >= TargetProfitUSD) {
        Print("[SetGridManually] BUY side target profit ",
              DoubleToString(buyP, 2), " USD (target = ",
              DoubleToString(TargetProfitUSD, 2),
              "). Closing BUY positions + BUY pendings (EA magic) on ", _Symbol);
        CloseOneMarketSideOnSymbol(POSITION_TYPE_BUY);
      }
    }
    if (HasOpenPositionOfTypeOnSymbol(POSITION_TYPE_SELL)) {
      double sellP = SumFloatingProfitForSide(POSITION_TYPE_SELL);
      if (sellP >= TargetProfitUSD) {
        Print("[SetGridManually] SELL side target profit ",
              DoubleToString(sellP, 2), " USD (target = ",
              DoubleToString(TargetProfitUSD, 2),
              "). Closing SELL positions + SELL pendings (EA magic) on ", _Symbol);
        CloseOneMarketSideOnSymbol(POSITION_TYPE_SELL);
      }
    }
  }

  // When you set TP on one position, sync same TP to all positions and pendings
  SyncTPFromUserChange();
  // When you set SL on one position, sync same SL to all positions and pendings
  SyncSLFromUserChange();
  // Save current SL/TP so next tick we can detect user changes
  UpdatePrevPositionState();

  // Place a grid for each open position that has not had a grid yet, but only
  // one active grid stack per market side: if EA already has BUY (or SELL)
  // pendings on this symbol, skip placing another full grid for additional
  // positions of that side until those pendings are gone (filled/deleted).
  PruneGridDoneTickets();

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if (PositionGetDouble(POSITION_VOLUME) <= 0.0)
      continue;

    if (GridAlreadyPlacedForTicket(ticket))
      continue;

    const ENUM_POSITION_TYPE pt =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    const bool isBuy = (pt == POSITION_TYPE_BUY);
    if (isBuy) {
      if (CountEAPendingOrdersForMarketSide(true) > 0)
        continue;
    } else {
      if (CountEAPendingOrdersForMarketSide(false) > 0)
        continue;
    }

    PlaceGrid(ticket);
    MarkGridPlacedForTicket(ticket);
  }
}