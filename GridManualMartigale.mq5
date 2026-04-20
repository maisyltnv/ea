//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open one BUY or SELL, EA places pending orders in a grid|
//| Close all positions + pendings when total floating money >= TP   |
//| SL is handled per order only (no total-loss basket close)        |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: close all when total floating profit money reaches target; SL works per order only."
#property version "1.71"

#include <Trade/Trade.mqh>

//--- inputs
input int GridCount = 8;                 // Number of pending orders in grid
input int GridDistancePoints = 500;      // Distance between each pending order (points)
input double GridLotSize = 0.1;          // Kept for compatibility; first manual order lot is used as base
input double GridLotStep = 0.01;         // Add this lot step to each next pending order
input int SlippagePoints = 20;           // Slippage (points)
input int MagicNumber = 111222;          // Magic for EA grid orders
input int SLPoints = 4500;               // Stop Loss (points) for each order
input double TPPoints = 200.0;           // Total profit target in MONEY (example: 200 = $200)
input bool ShowAggDebugOnChart = true;   // Show total money / target on chart

//--- trade object
CTrade trade;
// Remember which position ticket already had its grid placed
ulong g_lastGridTicket = 0;

//+------------------------------------------------------------------+
//| Total floating profit + swap in account currency (this symbol)   |
//+------------------------------------------------------------------+
double TotalFloatingProfitMoneyOnSymbol() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    sum += PositionGetDouble(POSITION_PROFIT);
    sum += PositionGetDouble(POSITION_SWAP);
  }
  return sum;
}

//+------------------------------------------------------------------+
//| Debug: show total money vs TPPoints on chart                     |
//+------------------------------------------------------------------+
void UpdateAggComment() {
  if (!ShowAggDebugOnChart) {
    Comment("");
    return;
  }
  if (CountPositionsOnSymbol() <= 0) {
    Comment("");
    return;
  }

  const double moneySum = TotalFloatingProfitMoneyOnSymbol();

  Comment("GridManual - close by MONEY target\n",
          "Target profit ($): ", DoubleToString(TPPoints, 2), "\n",
          "Current floating ($+swap): ", DoubleToString(moneySum, 2), "\n",
          "Status: ", (moneySum >= TPPoints ? "TARGET REACHED" : "RUNNING"), "\n",
          "SL Mode: Per-order only");
}

//+------------------------------------------------------------------+
//| Count positions on symbol                                        |
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
//| Close all positions and pending orders on this symbol            |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrdersOnSymbol() {
  trade.SetExpertMagicNumber(0);
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

  g_lastGridTicket = 0;
}

//+------------------------------------------------------------------+
//| Get earliest position on symbol as reference                     |
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

    datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
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
//| Sync SL on all positions/orders to first order level             |
//| No TP is set at broker side because EA closes by money target    |
//+------------------------------------------------------------------+
void SyncSLTPToFirstOrder() {
  if (CountPositionsOnSymbol() <= 0)
    return;
  if (SLPoints <= 0)
    return;

  double entry;
  ENUM_POSITION_TYPE type;
  if (!GetReferencePosition(entry, type))
    return;

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
  if (point <= 0.0)
    return;

  double slPrice = 0.0;
  if (type == POSITION_TYPE_BUY) {
    slPrice = NormalizeDouble(entry - SLPoints * point, digits);
  } else {
    slPrice = NormalizeDouble(entry + SLPoints * point, digits);
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // Sync positions
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    double curSL = PositionGetDouble(POSITION_SL);
    double setSL = (curSL == 0.0) ? 0.0 : slPrice;
    double setTP = 0.0;

    if (!trade.PositionModify(t, setSL, setTP))
      Print("[SetGridManually] SyncSLTP failed for ticket ", t,
            " Error=", GetLastError());
  }

  // Sync pending orders
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    double curSL = OrderGetDouble(ORDER_SL);
    double setSL = (curSL == 0.0) ? 0.0 : slPrice;
    double setTP = 0.0;

    double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
    ENUM_ORDER_TYPE_TIME typeTime =
        (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
    datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

    if (!trade.OrderModify(ot, orderPrice, setSL, setTP, typeTime, exp))
      Print("[SetGridManually] SyncSLTP pending failed for order ", ot,
            " Error=", GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Count EA pending orders on symbol                                |
//+------------------------------------------------------------------+
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
//| Find single position on symbol                                   |
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
      return 0;
    ticket = t;
  }
  return ticket;
}

//+------------------------------------------------------------------+
//| Normalize lot to broker rules                                    |
//+------------------------------------------------------------------+
double NormalizeLot(double lots, double volStep, double volMin, double volMax) {
  if (volStep > 0.0)
    lots = MathRound(lots / volStep) * volStep;

  if (volMin > 0.0 && lots < volMin)
    lots = volMin;

  if (volMax > 0.0 && lots > volMax)
    lots = volMax;

  int lotDigits = 2;
  if (volStep == 1.0) lotDigits = 0;
  else if (volStep == 0.1) lotDigits = 1;
  else if (volStep == 0.01) lotDigits = 2;
  else if (volStep == 0.001) lotDigits = 3;

  return NormalizeDouble(lots, lotDigits);
}

//+------------------------------------------------------------------+
//| Place grid of pending orders from first position                 |
//+------------------------------------------------------------------+
void PlaceGrid(ulong firstTicket) {
  if (!PositionSelectByTicket(firstTicket))
    return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double firstLot = PositionGetDouble(POSITION_VOLUME);
  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  double slPrice = 0.0;
  if (SLPoints > 0) {
    if (type == POSITION_TYPE_BUY) {
      slPrice = NormalizeDouble(entry - SLPoints * point, digits);
    } else {
      slPrice = NormalizeDouble(entry + SLPoints * point, digits);
    }
  }

  // Set SL on the first position, no TP because EA closes by money target
  if (slPrice > 0.0 && !trade.PositionModify(firstTicket, slPrice, 0.0))
    Print("[SetGridManually] Could not set SL on first position. Error=",
          GetLastError());

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  double volStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  double volMin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
  double volMax = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

  for (int i = 1; i <= GridCount; i++) {
    double price;
    double lots = firstLot + (GridLotStep * i);
    lots = NormalizeLot(lots, volStep, volMin, volMax);

    if (type == POSITION_TYPE_BUY) {
      price = NormalizeDouble(entry - GridDistancePoints * point * i, digits);
      if (!trade.BuyLimit(lots, price, symbol, slPrice, 0.0))
        Print("[SetGridManually] BuyLimit failed #", i,
              " lot=", DoubleToString(lots, 2),
              " Error=", GetLastError());
    } else {
      price = NormalizeDouble(entry + GridDistancePoints * point * i, digits);
      if (!trade.SellLimit(lots, price, symbol, slPrice, 0.0))
        Print("[SetGridManually] SellLimit failed #", i,
              " lot=", DoubleToString(lots, 2),
              " Error=", GetLastError());
    }
  }

  Print("[SetGridManually] Grid placed: ", GridCount,
        " orders, first lot=", DoubleToString(firstLot, 2),
        ", step=", DoubleToString(GridLotStep, 2),
        "; close target by MONEY=", DoubleToString(TPPoints, 2),
        "; SL works per order only.");
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  Print("SetGridManually EA initialized. Symbol=", _Symbol,
        " Grid=", GridCount,
        " Dist=", GridDistancePoints,
        " SL=", SLPoints,
        " MoneyTP=", DoubleToString(TPPoints, 2),
        " LotStep=", DoubleToString(GridLotStep, 2));

  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  Comment("");
  Print("SetGridManually EA stopped. Reason=", reason);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick() {
  UpdateAggComment();

  // Close all when total floating profit reaches money target
  if (TPPoints > 0.0 && CountPositionsOnSymbol() > 0) {
    const double moneySum = TotalFloatingProfitMoneyOnSymbol();

    if (moneySum >= TPPoints) {
      Print("[SetGridManually] Total floating profit+swap = ",
            DoubleToString(moneySum, 2), " >= target ",
            DoubleToString(TPPoints, 2),
            ". Closing all positions and pending orders.");
      CloseAllPositionsAndOrdersOnSymbol();
      return;
    }
  }

  // Sync SL to first order, TP disabled because close by money target
  SyncSLTPToFirstOrder();

  // Only place grid when exactly one position on symbol and no EA pending yet
  if (CountPositionsOnSymbol() != 1)
    return;
  if (CountEAPendingOnSymbol() > 0)
    return;

  ulong ticket = GetSinglePositionTicket();
  if (ticket == 0)
    return;

  if (g_lastGridTicket == ticket)
    return;

  PlaceGrid(ticket);
  g_lastGridTicket = ticket;
}