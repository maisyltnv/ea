//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open one BUY or SELL, EA places pending orders in a grid |
//| (no TP). Grid distance and count are configurable.                 |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: one manual position -> add grid of pending orders (no TP)."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input int GridCount = 10; // Number of pending orders in grid
input int GridDistancePoints =
    100;                        // Distance between each pending order (points)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 111222; // Magic for EA grid orders
input int CloseAllProfitPoints =
    500; // If price moves this many points in favor, close all positions/orders

//--- trade object
CTrade trade;

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
//| Check if TOTAL net profit in points >= CloseAllProfitPoints      |
//| (sum of all open positions on this symbol, in points)            |
//+------------------------------------------------------------------+
void CheckCloseAllOnProfit() {
  if (CloseAllProfitPoints <= 0)
    return;

  if (CountPositionsOnSymbol() <= 0)
    return;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (point <= 0)
    return;

  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  double totalPoints = 0.0;

  // Sum net profit in points over all positions on this symbol
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    ENUM_POSITION_TYPE type =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    double posPoints = 0.0;
    if (type == POSITION_TYPE_BUY) {
      posPoints = (bid - entry) / point;
    } else if (type == POSITION_TYPE_SELL) {
      posPoints = (entry - ask) / point;
    } else {
      continue;
    }

    totalPoints += posPoints;
  }

  if (totalPoints >= CloseAllProfitPoints) {
    Print("[SetGridManually] CloseAllProfitPoints reached. Total points = ",
          totalPoints, " >= ", CloseAllProfitPoints,
          ". Closing all positions and orders on symbol ", _Symbol);
    CloseAllPositionsAndOrdersOnSymbol();
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
  double lots =
      PositionGetDouble(POSITION_VOLUME); // same lot as first position
  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  // Remove TP from first (manual) position if it had one
  double currentSL = PositionGetDouble(POSITION_SL);
  double currentTP = PositionGetDouble(POSITION_TP);
  if (currentTP > 0.0 && !trade.PositionModify(firstTicket, currentSL, 0.0))
    Print("[SetGridManually] Could not clear TP on first position. Error=", GetLastError());

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = 1; i <= GridCount; i++) {
    double price;
    if (type == POSITION_TYPE_BUY) {
      // BUY LIMIT below entry (add on pullback), no TP
      price = NormalizeDouble(entry - GridDistancePoints * point * i, digits);
      if (!trade.BuyLimit(lots, price, symbol, 0.0, 0.0))
        Print("[SetGridManually] BuyLimit failed #", i,
              " Error=", GetLastError());
    } else {
      // SELL LIMIT above entry (add on bounce), no TP
      price = NormalizeDouble(entry + GridDistancePoints * point * i, digits);
      if (!trade.SellLimit(lots, price, symbol, 0.0, 0.0))
        Print("[SetGridManually] SellLimit failed #", i,
              " Error=", GetLastError());
    }
  }
  Print("[SetGridManually] Grid placed: ", GridCount, " orders, lot ", lots,
        ", distance ", GridDistancePoints, " pts (no TP).");
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  Print("SetGridManually EA initialized. Symbol=", _Symbol, " Grid=", GridCount,
        " Dist=", GridDistancePoints, " (no TP)");
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  // First, check if overall move is in profit enough to close everything
  CheckCloseAllOnProfit();

  // Only act when exactly one position on symbol and no EA pending orders yet
  if (CountPositionsOnSymbol() != 1)
    return;
  if (CountEAPendingOnSymbol() > 0)
    return;

  ulong ticket = GetSinglePositionTicket();
  if (ticket == 0)
    return;

  PlaceGrid(ticket);
}