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
input int GridCount = 20;        // Number of pending orders in grid
input int GridDistancePoints =   //
    100;                         // Distance between each pending order (points)
input double GridLotStep = 0.05; // Increment lot size for each grid order
input int SlippagePoints = 20;   // Slippage (points)
input int MagicNumber = 111222;  // Magic for EA grid orders
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
//| Helpers for per-side counts                                      |
//+------------------------------------------------------------------+
int CountPositionsByType(ENUM_POSITION_TYPE side) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
      continue;
    n++;
  }
  return n;
}

int CountEAPendingBySide(ENUM_POSITION_TYPE side) {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong t = OrderGetTicket(i);
    if (t == 0 || !OrderSelect(t))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;

    ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    bool isBuySide = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT ||
                      otype == ORDER_TYPE_BUY_STOP ||
                      otype == ORDER_TYPE_BUY_STOP_LIMIT);
    bool isSellSide = (otype == ORDER_TYPE_SELL ||
                       otype == ORDER_TYPE_SELL_LIMIT ||
                       otype == ORDER_TYPE_SELL_STOP ||
                       otype == ORDER_TYPE_SELL_STOP_LIMIT);

    if (side == POSITION_TYPE_BUY && isBuySide)
      n++;
    if (side == POSITION_TYPE_SELL && isSellSide)
      n++;
  }
  return n;
}

//+------------------------------------------------------------------+
//| Close all positions and orders for a given side (BUY/SELL)       |
//+------------------------------------------------------------------+
void CloseSidePositionsAndOrders(ENUM_POSITION_TYPE side) {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // Close positions of this side
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
      continue;

    double volume = PositionGetDouble(POSITION_VOLUME);
    if (volume <= 0.0)
      continue;

    if (!trade.PositionClose(t)) {
      Print("[SetGridManually] Failed to close ", (side == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            " position ticket ", t, " Error=", GetLastError());
    }
  }

  // Delete pending orders of this side
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    bool isBuySide = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT ||
                      otype == ORDER_TYPE_BUY_STOP ||
                      otype == ORDER_TYPE_BUY_STOP_LIMIT);
    bool isSellSide = (otype == ORDER_TYPE_SELL ||
                       otype == ORDER_TYPE_SELL_LIMIT ||
                       otype == ORDER_TYPE_SELL_STOP ||
                       otype == ORDER_TYPE_SELL_STOP_LIMIT);

    if (side == POSITION_TYPE_BUY && !isBuySide)
      continue;
    if (side == POSITION_TYPE_SELL && !isSellSide)
      continue;

    if (!trade.OrderDelete(ot)) {
      Print("[SetGridManually] Failed to delete ",
            (side == POSITION_TYPE_BUY ? "BUY-side" : "SELL-side"),
            " order ticket ", ot, " Error=", GetLastError());
    }
  }
}

//+------------------------------------------------------------------+
//| Check if net profit in points for ONE side >= CloseAllProfitPts  |
//+------------------------------------------------------------------+
void CheckCloseSideOnProfit(ENUM_POSITION_TYPE side) {
  if (CloseAllProfitPoints <= 0)
    return;

  if (CountPositionsByType(side) <= 0)
    return;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (point <= 0)
    return;

  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  double totalPoints = 0.0;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
      continue;

    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double posPoints = 0.0;

    if (side == POSITION_TYPE_BUY)
      posPoints = (bid - entry) / point;
    else
      posPoints = (entry - ask) / point;

    totalPoints += posPoints;
  }

  if (totalPoints >= CloseAllProfitPoints) {
    Print("[SetGridManually] CloseAllProfitPoints reached for ",
          (side == POSITION_TYPE_BUY ? "BUY" : "SELL"),
          " side. Total points = ", totalPoints, " >= ", CloseAllProfitPoints,
          ". Closing all positions and orders for that side on symbol ", _Symbol);
    CloseSidePositionsAndOrders(side);
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
//| Find earliest position on symbol for given side, return ticket   |
//+------------------------------------------------------------------+
bool GetReferencePositionBySide(ENUM_POSITION_TYPE side, ulong &ticketOut) {
  datetime earliest = LONG_MAX;
  bool found = false;
  ticketOut = 0;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
      continue;

    datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
    if (!found || openTime < earliest) {
      earliest = openTime;
      ticketOut = t;
      found = true;
    }
  }
  return found;
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
  double baseLots =
      PositionGetDouble(POSITION_VOLUME); // lot size of the first position
  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  // Remove TP from first (manual) position if it had one
  double currentSL = PositionGetDouble(POSITION_SL);
  double currentTP = PositionGetDouble(POSITION_TP);
  if (currentTP > 0.0 && !trade.PositionModify(firstTicket, currentSL, 0.0))
    Print("[SetGridManually] Could not clear TP on first position. Error=",
          GetLastError());

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double volMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double volMax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  for (int i = 1; i <= GridCount; i++) {
    double price;
    // lot size for this grid level: first level = baseLots + GridLotStep
    double lots = baseLots + GridLotStep * i;

    // Normalize lots to broker step and limits
    if (volStep > 0.0)
      lots = MathRound(lots / volStep) * volStep;
    if (volMin > 0.0 && lots < volMin)
      lots = volMin;
    if (volMax > 0.0 && lots > volMax)
      lots = volMax;
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
  Print("[SetGridManually] Grid placed: ", GridCount, " orders, base lot ",
        baseLots, ", lot step ", GridLotStep, ", distance ", GridDistancePoints,
        " pts (no TP).");
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
  // First, check if each side (BUY / SELL) has enough profit to close its grid
  CheckCloseSideOnProfit(POSITION_TYPE_BUY);
  CheckCloseSideOnProfit(POSITION_TYPE_SELL);

  // BUY side: if we have at least one BUY position and no BUY-side EA pendings, place BUY grid
  ulong buyTicket;
  if (GetReferencePositionBySide(POSITION_TYPE_BUY, buyTicket) &&
      CountEAPendingBySide(POSITION_TYPE_BUY) == 0) {
    PlaceGrid(buyTicket);
  }

  // SELL side: if we have at least one SELL position and no SELL-side EA pendings, place SELL grid
  ulong sellTicket;
  if (GetReferencePositionBySide(POSITION_TYPE_SELL, sellTicket) &&
      CountEAPendingBySide(POSITION_TYPE_SELL) == 0) {
    PlaceGrid(sellTicket);
  }
}