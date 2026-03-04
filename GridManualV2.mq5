//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open one BUY or SELL, EA places pending orders in a grid |
//| (no TP). Grid distance and count are configurable.                 |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: one manual position -> add grid of pending orders."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input int GridCount = 4;       // Number of pending orders in grid
input int GridDistancePoints = //
    1000;                      // Distance between each pending order (points)
input double GridLotSize =
    0.01; // Fixed lot size for all grid orders (no martingale)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 111222; // Magic for EA grid orders
input int SLPoints =
    4500; // Stop Loss (points) for grid orders; editable after set
input int TPPoints =
    1000; // Take Profit (points) for grid orders; editable after set
input double MaxFloatingLossUSD =
    180.0; // If total floating loss <= -this, close all

//--- trade object
CTrade trade;
// Remember which position ticket already had its grid placed,
// so if user deletes pending orders manually we don't place grid again
ulong g_lastGridTicket = 0;

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

//+------------------------------------------------------------------+
//| Close all positions and pending orders on this symbol             |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrdersOnSymbol() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // Close all positions on this symbol
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double volume = PositionGetDouble(POSITION_VOLUME);
    if (volume <= 0.0)
      continue;

    if (!trade.PositionClose(t)) {
      Print("[SetGridManually] Failed to close position ticket ", t,
            " Error=", GetLastError());
    }
  }

  // Delete all pending orders on this symbol
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    if (!trade.OrderDelete(ot)) {
      Print("[SetGridManually] Failed to delete order ticket ", ot,
            " Error=", GetLastError());
    }
  }
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
//| Sync SL/TP on all positions to same levels as first (earliest) order |
//+------------------------------------------------------------------+
void SyncSLTPToFirstOrder() {
  if (CountPositionsOnSymbol() <= 0)
    return;
  if (SLPoints <= 0 && TPPoints <= 0)
    return;

  double entry;
  ENUM_POSITION_TYPE type;
  if (!GetReferencePosition(entry, type))
    return;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  if (point <= 0.0)
    return;

  double slPrice = 0.0, tpPrice = 0.0;
  if (type == POSITION_TYPE_BUY) {
    slPrice = (SLPoints > 0) ? NormalizeDouble(entry - SLPoints * point, digits)
                             : 0.0;
    tpPrice = (TPPoints > 0) ? NormalizeDouble(entry + TPPoints * point, digits)
                             : 0.0;
  } else {
    slPrice = (SLPoints > 0) ? NormalizeDouble(entry + SLPoints * point, digits)
                             : 0.0;
    tpPrice = (TPPoints > 0) ? NormalizeDouble(entry - TPPoints * point, digits)
                             : 0.0;
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // If user deleted SL (curSL==0) or TP (curTP==0), never set it again; otherwise sync to first order
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double curSL = PositionGetDouble(POSITION_SL);
    double curTP = PositionGetDouble(POSITION_TP);
    double setSL = (curSL == 0.0) ? 0.0 : slPrice;
    double setTP = (curTP == 0.0) ? 0.0 : tpPrice;

    if (!trade.PositionModify(t, setSL, setTP))
      Print("[SetGridManually] SyncSLTP failed for ticket ", t,
            " Error=", GetLastError());
  }

  // Same for pending orders: if user deleted SL or TP, do not set it again
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    double curSL = OrderGetDouble(ORDER_SL);
    double curTP = OrderGetDouble(ORDER_TP);
    double setSL = (curSL == 0.0) ? 0.0 : slPrice;
    double setTP = (curTP == 0.0) ? 0.0 : tpPrice;

    double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
    ENUM_ORDER_TYPE_TIME typeTime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

    if (!trade.OrderModify(ot, orderPrice, setSL, setTP, typeTime, exp))
      Print("[SetGridManually] SyncSLTP pending failed for order ", ot,
            " Error=", GetLastError());
  }
}

int CountEAPendingOnSymbol() {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong t = OrderGetTicket(i);
    if (t == 0 || !OrderSelect(t))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
      n++;
  }
  return n;
}

//+------------------------------------------------------------------+
//| Find single position on symbol (any magic), return ticket          |
//+------------------------------------------------------------------+
ulong GetSinglePositionTicket() {
  ulong ticket = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if (ticket != 0)
      return 0; // more than one
    ticket = t;
  }
  return ticket;
}

//+------------------------------------------------------------------+
//| Place grid of pending orders from first position                  |
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

  // SL/TP from first order's entry (same levels for first position and all grid
  // orders)
  double slPrice = 0.0, tpPrice = 0.0;
  if (SLPoints > 0 || TPPoints > 0) {
    if (type == POSITION_TYPE_BUY) {
      slPrice = (SLPoints > 0)
                    ? NormalizeDouble(entry - SLPoints * point, digits)
                    : 0.0;
      tpPrice = (TPPoints > 0)
                    ? NormalizeDouble(entry + TPPoints * point, digits)
                    : 0.0;
    } else {
      slPrice = (SLPoints > 0)
                    ? NormalizeDouble(entry + SLPoints * point, digits)
                    : 0.0;
      tpPrice = (TPPoints > 0)
                    ? NormalizeDouble(entry - TPPoints * point, digits)
                    : 0.0;
    }
  }

  // Set SL/TP on the first (open) position
  if ((slPrice > 0.0 || tpPrice > 0.0) &&
      !trade.PositionModify(firstTicket, slPrice, tpPrice))
    Print("[SetGridManually] Could not set SL/TP on first position. Error=",
          GetLastError());

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
      // BUY LIMIT below entry; same SL/TP levels as first order
      price = NormalizeDouble(entry - GridDistancePoints * point * i, digits);
      if (!trade.BuyLimit(lots, price, symbol, slPrice, tpPrice))
        Print("[SetGridManually] BuyLimit failed #", i,
              " Error=", GetLastError());
    } else {
      // SELL LIMIT above entry; same SL/TP levels as first order
      price = NormalizeDouble(entry + GridDistancePoints * point * i, digits);
      if (!trade.SellLimit(lots, price, symbol, slPrice, tpPrice))
        Print("[SetGridManually] SellLimit failed #", i,
              " Error=", GetLastError());
    }
  }
  Print("[SetGridManually] Grid placed: ", GridCount, " orders, fixed lot ",
        GridLotSize, "; first order + all grid use same SL/TP (", SLPoints, "/",
        TPPoints, " pts from first entry).");
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  Print("SetGridManually EA initialized. Symbol=", _Symbol, " Grid=", GridCount,
        " Dist=", GridDistancePoints, " SL=", SLPoints, " TP=", TPPoints);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  // Emergency: close everything if floating loss exceeds threshold (in USD)
  if (MaxFloatingLossUSD > 0.0) {
    double totalProfit = 0.0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t))
        continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol)
        continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT);
    }
    if (totalProfit <= -MaxFloatingLossUSD) {
      Print("[SetGridManually] Floating loss reached ",
            DoubleToString(totalProfit, 2), " USD (threshold = -",
            DoubleToString(MaxFloatingLossUSD, 2),
            "). Closing all positions and orders on symbol ", _Symbol);
      CloseAllPositionsAndOrdersOnSymbol();
      return;
    }
  }

  // Always sync SL/TP on all positions to same levels as first order (e.g. when
  // you open another order)
  SyncSLTPToFirstOrder();

  // Only place grid when exactly one position on symbol and no EA pending
  // orders yet, and we have NOT already placed a grid for this position ticket.
  if (CountPositionsOnSymbol() != 1)
    return;
  if (CountEAPendingOnSymbol() > 0)
    return;

  ulong ticket = GetSinglePositionTicket();
  if (ticket == 0)
    return;

  // If we've already placed a grid for this specific ticket, do not place again
  if (g_lastGridTicket == ticket)
    return;

  PlaceGrid(ticket);
  g_lastGridTicket = ticket;
}