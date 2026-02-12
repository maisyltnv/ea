//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open one BUY or SELL position, EA places 10 pending      |
//| orders in a grid: 500 points apart. TP = 1000 points from       |
//| first order entry (same level for all grid orders).               |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: one manual position -> add 10 pending orders, 500 pts apart, TP 1000 pts from first."
#property version   "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input int GridCount = 10;           // Number of pending orders in grid
input int GridDistancePoints = 500; // Distance between each pending order (points)
input int TPPoints = 1000;          // TP distance from first order entry (points)
input double Lots = 0.01;           // Lot size for each grid order
input int SlippagePoints = 20;      // Slippage (points)
input int MagicNumber = 111222;     // Magic for EA grid orders

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Count positions and EA pending orders for symbol                  |
//+------------------------------------------------------------------+
int CountPositionsOnSymbol() {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t)) continue;
    if (PositionGetString(POSITION_SYMBOL) == _Symbol) n++;
  }
  return n;
}

int CountEAPendingOnSymbol() {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong t = OrderGetTicket(i);
    if (t == 0 || !OrderSelect(t)) continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) == MagicNumber) n++;
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
    if (t == 0 || !PositionSelectByTicket(t)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if (ticket != 0) return 0; // more than one
    ticket = t;
  }
  return ticket;
}

//+------------------------------------------------------------------+
//| Place grid of pending orders from first position                  |
//+------------------------------------------------------------------+
void PlaceGrid(ulong firstTicket) {
  if (!PositionSelectByTicket(firstTicket)) return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  double tpPrice;
  if (type == POSITION_TYPE_BUY) {
    tpPrice = NormalizeDouble(entry + TPPoints * point, digits);
  } else {
    tpPrice = NormalizeDouble(entry - TPPoints * point, digits);
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = 1; i <= GridCount; i++) {
    double price;
    if (type == POSITION_TYPE_BUY) {
      // BUY LIMIT below entry (add on pullback)
      price = NormalizeDouble(entry - GridDistancePoints * point * i, digits);
      if (!trade.BuyLimit(Lots, price, symbol, 0.0, tpPrice))
        Print("[SetGridManually] BuyLimit failed #", i, " Error=", GetLastError());
    } else {
      // SELL LIMIT above entry (add on bounce)
      price = NormalizeDouble(entry + GridDistancePoints * point * i, digits);
      if (!trade.SellLimit(Lots, price, symbol, 0.0, tpPrice))
        Print("[SetGridManually] SellLimit failed #", i, " Error=", GetLastError());
    }
  }
  Print("[SetGridManually] Grid placed: ", GridCount, " orders, distance ", GridDistancePoints, " pts, TP ", TPPoints, " pts from first.");
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  Print("SetGridManually EA initialized. Symbol=", _Symbol, " Grid=", GridCount, " Dist=", GridDistancePoints, " TP=", TPPoints);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
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
