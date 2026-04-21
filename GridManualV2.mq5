//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//| When you open one BUY or SELL, EA places pending orders in a grid |
//| (no TP). Grid distance and count are configurable.                 |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: grid; close all on money TP/SL; optional per-order SL/TP in points."
#property version "1.40"

#include <Trade/Trade.mqh>

enum ENUM_AGG_TP_MODE {
  AGG_TP_BASKET = 0, // volume-weighted avg entry -> one combined P/L in points
  AGG_TP_SUM_LEGS = 1, // signed sum: each leg's points (losers count negative)
  AGG_TP_SUM_LEGS_POSITIVE =
      2 // sum only winning legs' points (ignores losing legs for target; best for grids)
};

//--- inputs
input int GridCount = 8;       // Number of pending orders in grid
input int GridDistancePoints = //
    500;                      // Distance between each pending order (points)
input double GridLotSize =
    0.1; // Fixed lot size for all grid orders (no martingale)
input bool GridUseFirstOrderLotAsBase =
    true; // If true: pending lots start from first position's lot (then +GridLotStep)
input double GridLotStep =
    0.01; // If > 0: pending lots = first position lots + GridLotStep*i (i=1..GridCount)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 111222; // Magic for EA grid orders
input double SLUsd =
    4500.0; // Stop Loss (money, account currency): close ALL when floating P/L <= -this
input double TPUsd =
    1000.0; // Take Profit (money, account currency): close ALL when floating P/L >= this
input int GridSLPoints =
    4000; // Optional: per-order Stop Loss (points) from first entry; 0=disable
input int GridTPPoints =
    1000; // Optional: per-order Take Profit (points) from first entry; 0=disable
input ENUM_AGG_TP_MODE AggTPGoal =
    AGG_TP_SUM_LEGS_POSITIVE; // (legacy) How to add "points" before comparing to TP goal
input bool ShowAggDebugOnChart =
    true; // Show combined pts / target on chart (for testing)

//--- trade object
CTrade trade;
// Remember which position ticket already had its grid placed,
// so if user deletes pending orders manually we don't place grid again
ulong g_lastGridTicket = 0;

//+------------------------------------------------------------------+
//| Floating P/L of one position in price points (that symbol's point) |
//+------------------------------------------------------------------+
double PositionProfitPoints(const ulong ticket) {
  if (ticket == 0 || !PositionSelectByTicket(ticket))
    return 0.0;

  const string sym = PositionGetString(POSITION_SYMBOL);
  if (sym != _Symbol)
    return 0.0;

  if (!SymbolInfoInteger(sym, SYMBOL_SELECT))
    SymbolSelect(sym, true);

  const double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
  if (pt <= 0.0)
    return 0.0;

  const double open = PositionGetDouble(POSITION_PRICE_OPEN);
  const long type = PositionGetInteger(POSITION_TYPE);

  if (type == POSITION_TYPE_BUY) {
    const double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    return (bid - open) / pt;
  }
  if (type == POSITION_TYPE_SELL) {
    const double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    return (open - ask) / pt;
  }
  return 0.0;
}

//+------------------------------------------------------------------+
//| Sum per-leg floating P/L in points (each order vs its own entry) |
//+------------------------------------------------------------------+
double TotalFloatingProfitPointsOnSymbol() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    sum += PositionProfitPoints(t);
  }
  return sum;
}

//+------------------------------------------------------------------+
//| Sum only legs in profit (points > 0). Losing legs not counted.   |
//| Matches "grid: several winners + one small loser" -> target still  |
//| reachable in points. Terminal $ profit is NOT the same as points.  |
//+------------------------------------------------------------------+
double TotalPositiveLegPointsOnSymbol() {
  double sum = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    const double p = PositionProfitPoints(t);
    if (p > 0.0)
      sum += p;
  }
  return sum;
}

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
//| Combined basket P/L in points (volume-weighted average entry).   |
//| Same-direction grid: one number = distance from avg entry to     |
//| current price — matches "3 orders together = TP goal profit".      |
//+------------------------------------------------------------------+
double BasketFloatingProfitPointsOnSymbol() {
  double buyLots = 0.0, sellLots = 0.0;
  double buyWeightedOpen = 0.0, sellWeightedOpen = 0.0;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    const double vol = PositionGetDouble(POSITION_VOLUME);
    const double opn = PositionGetDouble(POSITION_PRICE_OPEN);
    const long typ = PositionGetInteger(POSITION_TYPE);

    if (typ == POSITION_TYPE_BUY) {
      buyLots += vol;
      buyWeightedOpen += opn * vol;
    } else if (typ == POSITION_TYPE_SELL) {
      sellLots += vol;
      sellWeightedOpen += opn * vol;
    }
  }

  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    SymbolSelect(_Symbol, true);

  const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  if (pt <= 0.0)
    return 0.0;

  // Only buys (typical grid): one combined profit in points from average entry
  if (buyLots > 0.0 && sellLots <= 0.0) {
    const double avg = buyWeightedOpen / buyLots;
    const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return (bid - avg) / pt;
  }
  // Only sells
  if (sellLots > 0.0 && buyLots <= 0.0) {
    const double avg = sellWeightedOpen / sellLots;
    const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    return (avg - ask) / pt;
  }
  // Hedge / mixed: fall back to sum of per-leg points
  return TotalFloatingProfitPointsOnSymbol();
}

//+------------------------------------------------------------------+
//| Debug: show combined pts vs money goals on chart                   |
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

  const double legSigned = TotalFloatingProfitPointsOnSymbol();
  const double legPositive = TotalPositiveLegPointsOnSymbol();
  const double basket = BasketFloatingProfitPointsOnSymbol();
  double usePts = basket;
  string modeStr = "BASKET";
  if (AggTPGoal == AGG_TP_SUM_LEGS) {
    usePts = legSigned;
    modeStr = "SUM signed (winners-losers)";
  } else if (AggTPGoal == AGG_TP_SUM_LEGS_POSITIVE) {
    usePts = legPositive;
    modeStr = "SUM winners only (losers ignored)";
  }

  const double ptSz = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
  const double moneySum = TotalFloatingProfitMoneyOnSymbol();

  Comment("GridManualV2 - close: MONEY SL/TP (close ALL)\n",
          "SYMBOL_POINT=", DoubleToString(ptSz, (_Digits <= 3 ? 3 : _Digits)),
          "  Digits=", IntegerToString(_Digits), "\n",
          "Mode: ", modeStr, "\n",
          "Pts signed (all legs): ", DoubleToString(legSigned, 2), "\n",
          "Pts positive legs only: ", DoubleToString(legPositive, 2), "\n",
          "Basket pts: ", DoubleToString(basket, 2), "\n",
          "Floating $+swap: ", DoubleToString(moneySum, 2), "\n",
          "TPUsd (money): ", DoubleToString(TPUsd, 2),
          (TPUsd > 0.0 && moneySum >= TPUsd ? "  >= OK" : ""), "\n",
          "SLUsd (money): ", DoubleToString(SLUsd, 2),
          (SLUsd > 0.0 && moneySum <= -SLUsd ? "  <= -OK" : ""));
}

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
  // 0 = allow closing manual + any magic on this account
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
  if (GridSLPoints <= 0 && GridTPPoints <= 0)
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
    slPrice = (GridSLPoints > 0)
                  ? NormalizeDouble(entry - GridSLPoints * point, digits)
                  : 0.0;
    tpPrice = (GridTPPoints > 0)
                  ? NormalizeDouble(entry + GridTPPoints * point, digits)
                  : 0.0;
  } else {
    slPrice = (GridSLPoints > 0)
                  ? NormalizeDouble(entry + GridSLPoints * point, digits)
                  : 0.0;
    tpPrice = (GridTPPoints > 0)
                  ? NormalizeDouble(entry - GridTPPoints * point, digits)
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
  const double baseLotsFromFirst = PositionGetDouble(POSITION_VOLUME);
  ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  // SL/TP from first order's entry (same levels for first position and all grid
  // orders)
  double slPrice = 0.0, tpPrice = 0.0;
  if (GridSLPoints > 0 || GridTPPoints > 0) {
    if (type == POSITION_TYPE_BUY) {
      slPrice = (GridSLPoints > 0)
                    ? NormalizeDouble(entry - GridSLPoints * point, digits)
                    : 0.0;
      tpPrice = (GridTPPoints > 0)
                    ? NormalizeDouble(entry + GridTPPoints * point, digits)
                    : 0.0;
    } else {
      slPrice = (GridSLPoints > 0)
                    ? NormalizeDouble(entry + GridSLPoints * point, digits)
                    : 0.0;
      tpPrice = (GridTPPoints > 0)
                    ? NormalizeDouble(entry - GridTPPoints * point, digits)
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
    double lots = GridLotSize;
    if (GridUseFirstOrderLotAsBase && baseLotsFromFirst > 0.0)
      lots = baseLotsFromFirst + (GridLotStep > 0.0 ? GridLotStep * i : 0.0);

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
        GridLotSize,
        (GridUseFirstOrderLotAsBase && baseLotsFromFirst > 0.0
             ? (" (base=" + DoubleToString(baseLotsFromFirst, 4) +
                ", step=" + DoubleToString(GridLotStep, 4) + ")")
             : ""),
        "; first order + all grid use same SL/TP (", GridSLPoints, "/",
        GridTPPoints, " pts from first entry).");
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  Print("SetGridManually EA initialized. Symbol=", _Symbol, " Grid=", GridCount,
        " Dist=", GridDistancePoints, " MoneySL=", SLUsd, " MoneyTP=", TPUsd,
        " GridSLpts=", GridSLPoints, " GridTPpts=", GridTPPoints);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  Comment("");
  Print("SetGridManually EA stopped. Reason=", reason);
}

//+------------------------------------------------------------------+
//| When any position closes at Take Profit, close all + pendings     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD)
    return;
  if (trans.deal == 0)
    return;

  if (!HistoryDealSelect(trans.deal))
    return;

  if (HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
    return;

  const long entryDeal = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  if (entryDeal != DEAL_ENTRY_OUT && entryDeal != DEAL_ENTRY_OUT_BY)
    return;

  const long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
  if (reason != DEAL_REASON_TP)
    return;

  Print("[SetGridManually] Take Profit hit (deal ", trans.deal,
        "). Closing all positions and pending orders on ", _Symbol, ".");
  CloseAllPositionsAndOrdersOnSymbol();
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  UpdateAggComment();

  // Close ALL on money TP/SL (account currency), computed on this symbol:
  // sum(POSITION_PROFIT + POSITION_SWAP)
  if (CountPositionsOnSymbol() > 0) {
    const double moneySum = TotalFloatingProfitMoneyOnSymbol();

    if (TPUsd > 0.0 && moneySum >= TPUsd) {
      Print("[SetGridManually] Money TP reached: floating profit+swap = ",
            DoubleToString(moneySum, 2), " >= ", DoubleToString(TPUsd, 2),
            ". Closing all positions and pending orders.");
      CloseAllPositionsAndOrdersOnSymbol();
      return;
    }

    if (SLUsd > 0.0 && moneySum <= -SLUsd) {
      Print("[SetGridManually] Money SL reached: floating profit+swap = ",
            DoubleToString(moneySum, 2), " <= -", DoubleToString(SLUsd, 2),
            ". Closing all positions and pending orders.");
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