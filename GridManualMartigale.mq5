//+------------------------------------------------------------------+
//| SetGridManually EA                                               |
//|                                                                  |
//| ການເຮັດວຽກຫຼັກ:                                             |
//| 1) ຜູ້ໃຊ້ກົດເປີດ BUY ຫຼື SELL ໄມ້ທຳອິດດ້ວຍມື.          |
//| 2) EA ຈະວາງ pending grid orders ຕາມ GridCount / GridDistance. |
//| 3) ຫຼັງຈາກ grid ຖືກວາງແລ້ວ, EA ຈະ lock ບໍ່ໃຫ້ຜູ້ໃຊ້       |
//|    ເປີດໄມ້ໃໝ່ດ້ວຍມືເພີ່ມອີກ ເພື່ອກັນ overtrade.        |
//| 4) ຖ້າມີ manual position ຫຼື manual pending order ໃໝ່ເຂົ້າມາ |
//|    ຫຼັງຈາກ grid active, EA ຈະປິດ/ລຶບໃຫ້ອັດຕະໂນມັດ.       |
//| 5) ເມື່ອທຸກ positions ແລະ EA pending orders ຖືກປິດ/ລຶບໝົດ, |
//|    EA ຈະ reset lock ເພື່ອໃຫ້ເລີ່ມ cycle ໃໝ່ໄດ້.            |
//| 6) Sync SL/TP: ຖ້າມີຫລາຍກວ່າ 1 position ຢູ່ → EA sync       |
//|    SL/TP ຂອງທຸກໄມ້ໃຫ້ຄືກັນກັບໄມ້ທຳອິດ. ແຕ່ຖ້າເຫລືອ    |
//|    ພຽງ 1 position ເທົ່ານັ້ນ → EA ບໍ່ sync, ຜູ້ໃຊ້ສາມາດ    |
//|    ຍ້າຍ SL/TP ຂອງໄມ້ນັ້ນຕາມໃຈໄດ້.                         |
//|                                                                  |
//| ເປີດ/ປິດ feature ກັນ overtrade ໄດ້ດ້ວຍ:                    |
//|   BlockManualAddsAfterGrid = true/false                          |
//+------------------------------------------------------------------+

#property strict
#property description "SetGridManually: grid; close all on basket USD TP/SL; optional per-order SL/TP in points; anti-overtrade lock; last-leg SL/TP free."
#property version "1.43"

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
input double GridLotStep =
    0.01; // If > 0: pending lots = first position lots + GridLotStep*i (i=1..GridCount)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 111222; // Magic for EA grid orders
input double TotalUSDSL =
    100.0; // [BASKET, USD] Max total loss: close ALL when sum(floating P/L + swap) <= -this
input double TotalUSDTP =
    100.0; // [BASKET, USD] Take profit: close ALL when sum(floating P/L + swap) >= this
input int GridSLPoints =
    4000; // Optional: per-order Stop Loss (points) from first entry; 0=disable
input int GridTPPoints =
    1000; // Optional: per-order Take Profit (points) from first entry; 0=disable
input ENUM_AGG_TP_MODE AggTPGoal =
    AGG_TP_SUM_LEGS_POSITIVE; // (legacy) How to add "points" before comparing to TP goal
input bool ShowAggDebugOnChart =
    true; // Show combined pts / target on chart (for testing)
input bool BlockManualAddsAfterGrid =
    true; // Anti-overtrade: after grid is placed, auto-close any new manual position / pending

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
          "TotalUSDTP (money): ", DoubleToString(TotalUSDTP, 2),
          (TotalUSDTP > 0.0 && moneySum >= TotalUSDTP ? "  >= OK" : ""), "\n",
          "TotalUSDSL (money): ", DoubleToString(TotalUSDSL, 2),
          (TotalUSDSL > 0.0 && moneySum <= -TotalUSDSL ? "  <= -OK" : ""));
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
//|                                                                  |
//| ຂໍ້ຍົກເວັ້ນ: ຖ້າເຫລືອພຽງ 1 position ເທົ່ານັ້ນ → ບໍ່ sync, |
//| ປ່ອຍໃຫ້ຜູ້ໃຊ້ຍ້າຍ SL/TP ຂອງໄມ້ນັ້ນຕາມໃຈໄດ້.            |
//+------------------------------------------------------------------+
void SyncSLTPToFirstOrder() {
  if (CountPositionsOnSymbol() <= 1)
    return; // 0 = nothing to do; 1 = let user freely move SL/TP of last leg
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
//| Anti-overtrade: after grid is placed (g_lastGridTicket != 0),     |
//| auto-close any NEW manual position and delete any NEW manual      |
//| pending order on this symbol, so the user cannot add legs by hand. |
//| The original first manual position (ticket == g_lastGridTicket)   |
//| and EA grid orders (magic == MagicNumber) are NEVER touched here. |
//+------------------------------------------------------------------+
void BlockManualAdditionalTrades() {
  if (!BlockManualAddsAfterGrid)
    return;
  if (g_lastGridTicket == 0)
    return; // Grid not placed yet -> first manual is allowed

  trade.SetExpertMagicNumber(0); // allow closing manual (non-EA) tickets
  trade.SetDeviationInPoints(SlippagePoints);

  // 1) Close any extra manual positions (not the first one, not EA grid fills)
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;

    const long magic = PositionGetInteger(POSITION_MAGIC);
    if (magic == MagicNumber)
      continue; // grid-triggered position -> keep
    if (t == g_lastGridTicket)
      continue; // first manual that started the grid -> keep

    Print("[SetGridManually] Anti-overtrade: closing extra MANUAL position "
          "ticket=", t, " magic=", magic);
    if (!trade.PositionClose(t))
      Print("[SetGridManually] Anti-overtrade: PositionClose failed ticket=", t,
            " Error=", GetLastError());
  }

  // 2) Delete any extra manual pending orders (only EA pendings allowed)
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;

    const long magic = OrderGetInteger(ORDER_MAGIC);
    if (magic == MagicNumber)
      continue; // EA grid pending -> keep

    Print("[SetGridManually] Anti-overtrade: deleting extra MANUAL pending "
          "order=", ot, " magic=", magic);
    if (!trade.OrderDelete(ot))
      Print("[SetGridManually] Anti-overtrade: OrderDelete failed order=", ot,
            " Error=", GetLastError());
  }
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
    if (GridLotStep > 0.0 && baseLotsFromFirst > 0.0)
      lots = baseLotsFromFirst + GridLotStep * i;

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
        (GridLotStep > 0.0 && baseLotsFromFirst > 0.0
             ? (" (step=" + DoubleToString(GridLotStep, 4) +
                ", base=" + DoubleToString(baseLotsFromFirst, 4) + ")")
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
        " Dist=", GridDistancePoints, " TotalUSDSL=", TotalUSDSL,
        " TotalUSDTP=", TotalUSDTP, " GridSLpts=", GridSLPoints,
        " GridTPpts=", GridTPPoints);
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

  // If everything is cleared (no positions, no EA pendings), reset the grid
  // lock so a fresh manual order can start a new cycle.
  if (g_lastGridTicket != 0 && CountPositionsOnSymbol() == 0 &&
      CountEAPendingOnSymbol() == 0) {
    Print("[SetGridManually] All positions + EA pendings cleared. "
          "Releasing grid lock (anti-overtrade reset).");
    g_lastGridTicket = 0;
  }

  // Anti-overtrade: while a grid is active, kill any new manual position /
  // pending the user tries to add by hand.
  BlockManualAdditionalTrades();

  // Close ALL on basket USD TP/SL (account currency), computed on this symbol:
  // sum(POSITION_PROFIT + POSITION_SWAP)
  if (CountPositionsOnSymbol() > 0) {
    const double moneySum = TotalFloatingProfitMoneyOnSymbol();

    if (TotalUSDTP > 0.0 && moneySum >= TotalUSDTP) {
      Print("[SetGridManually] TotalUSDTP reached: floating profit+swap = ",
            DoubleToString(moneySum, 2), " >= ", DoubleToString(TotalUSDTP, 2),
            ". Closing all positions and pending orders.");
      CloseAllPositionsAndOrdersOnSymbol();
      return;
    }

    if (TotalUSDSL > 0.0 && moneySum <= -TotalUSDSL) {
      Print("[SetGridManually] TotalUSDSL reached: floating profit+swap = ",
            DoubleToString(moneySum, 2), " <= -", DoubleToString(TotalUSDSL, 2),
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