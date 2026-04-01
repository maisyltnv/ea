//+------------------------------------------------------------------+
//|                                                   AutoBuySell.mq5 |
//|  Hedge + Grid EA with independent BUY/SELL sides, daily stops   |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description                                                          \
    "AutoBuySell: Hedge + Grid (3 pending per side), lot +0.01 progression, side reset by points, daily profit/loss stops."

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs --------------------------------
input double InitialLot = 0.01;
input int GridLevelsPerSide = 2;
input int GridDistancePoints = 200;
input double LotIncrement = 0.01;
input int SideTargetProfitPoints = 500;

input double DailyProfitTargetUSD = 10.0;
input double DailyLossLimitUSD = 300.0;

input int SlippagePoints = 20;

input int MagicBuy = 11001;
input int MagicSell = 11002;

//--------------------------- Globals -------------------------------
datetime g_todayStart = 0;
bool g_stopToday = false;

// lot progression trackers (next lot for new pending replacement)
double g_nextBuyLot = 0.0;
double g_nextSellLot = 0.0;

//---------------------- Utility / Helpers -------------------------
double PointValue() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double NormalizeLot(double lots) {
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step > 0)
    lots = MathRound(lots / step) * step;
  if (lots < minv)
    lots = minv;
  if (lots > maxv)
    lots = maxv;
  return lots;
}

void SetTradeContext(int magic) {
  trade.SetExpertMagicNumber(magic);
  trade.SetDeviationInPoints(SlippagePoints);
}

//-------------------- Day Profit / Loss Tracking -------------------
void ResetDayIfNeeded() {
  datetime d = iTime(_Symbol, PERIOD_D1, 0);
  if (g_todayStart == 0) {
    g_todayStart = d;
    g_stopToday = false;
  }
  if (d != g_todayStart) {
    // new day
    g_todayStart = d;
    g_stopToday = false;
  }
}

double CalcTodayProfitUSD() {
  double p = 0.0;
  for (int i = HistoryDealsTotal() - 1; i >= 0; --i) {
    ulong tk = HistoryDealGetTicket(i);
    if (tk == 0)
      continue;
    datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
    if (t < g_todayStart)
      break;
    p += HistoryDealGetDouble(tk, DEAL_PROFIT);
  }
  return p;
}

bool CheckDailyStops() {
  if (g_stopToday)
    return true;

  double todayP = CalcTodayProfitUSD();
  if (todayP >= DailyProfitTargetUSD || todayP <= -DailyLossLimitUSD) {
    Print("[AutoBuySell] Daily stop reached. Profit=", todayP);
    CloseAllPositions();
    DeleteAllPendings();
    g_stopToday = true;
    return true;
  }
  return false;
}

//------------------------- Positions / Orders ----------------------
bool IsBuyPosition(ulong ticket) {
  if (!PositionSelectByTicket(ticket))
    return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol)
    return false;
  if ((int)PositionGetInteger(POSITION_MAGIC) != MagicBuy)
    return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) !=
      POSITION_TYPE_BUY)
    return false;
  return true;
}

bool IsSellPosition(ulong ticket) {
  if (!PositionSelectByTicket(ticket))
    return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol)
    return false;
  if ((int)PositionGetInteger(POSITION_MAGIC) != MagicSell)
    return false;
  if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) !=
      POSITION_TYPE_SELL)
    return false;
  return true;
}

bool IsBuyPending(ulong ticket) {
  if (!OrderSelect(ticket))
    return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol)
    return false;
  if ((int)OrderGetInteger(ORDER_MAGIC) != MagicBuy)
    return false;
  ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  return (t == ORDER_TYPE_BUY_LIMIT);
}

bool IsSellPending(ulong ticket) {
  if (!OrderSelect(ticket))
    return false;
  if (OrderGetString(ORDER_SYMBOL) != _Symbol)
    return false;
  if ((int)OrderGetInteger(ORDER_MAGIC) != MagicSell)
    return false;
  ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
  return (t == ORDER_TYPE_SELL_LIMIT);
}

void CloseAllPositions() {
  SetTradeContext(0);
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    trade.PositionClose(tk);
  }
}

void DeleteAllPendings() {
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    ulong tk = OrderGetTicket(i);
    if (tk == 0 || !OrderSelect(tk))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    trade.OrderDelete(tk);
  }
}

void CloseSidePositions(int magic) {
  SetTradeContext(magic);
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    trade.PositionClose(tk);
  }
}

void DeleteSidePendings(int magic) {
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    ulong tk = OrderGetTicket(i);
    if (tk == 0 || !OrderSelect(tk))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != magic)
      continue;
    trade.OrderDelete(tk);
  }
}

//----------------------- Profit in Points per Side -----------------
double CalcBuySidePoints() {
  double pts = 0.0;
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!IsBuyPosition(tk))
      continue;
    double open = PositionGetDouble(POSITION_PRICE_OPEN);
    pts += (bid - open) / PointValue();
  }
  return pts;
}

double CalcSellSidePoints() {
  double pts = 0.0;
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!IsSellPosition(tk))
      continue;
    double open = PositionGetDouble(POSITION_PRICE_OPEN);
    pts += (open - ask) / PointValue();
  }
  return pts;
}

//----------------------- Initial Hedge Orders ----------------------
void OpenInitialHedge() {
  SetTradeContext(MagicBuy);
  trade.Buy(NormalizeLot(InitialLot), _Symbol);

  SetTradeContext(MagicSell);
  trade.Sell(NormalizeLot(InitialLot), _Symbol);

  // initialize lot progression for new pendings
  g_nextBuyLot = InitialLot + LotIncrement;
  g_nextSellLot = InitialLot + LotIncrement;
}

//--------------------------- Grid Placement ------------------------
void PlaceBuyPending(double price, double lots) {
  SetTradeContext(MagicBuy);
  double p = NormalizeDouble(price, DigitsCount());
  trade.BuyLimit(NormalizeLot(lots), p, _Symbol);
}

void PlaceSellPending(double price, double lots) {
  SetTradeContext(MagicSell);
  double p = NormalizeDouble(price, DigitsCount());
  trade.SellLimit(NormalizeLot(lots), p, _Symbol);
}

int CountBuyPendings() {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    ulong tk = OrderGetTicket(i);
    if (IsBuyPending(tk))
      n++;
  }
  return n;
}

int CountSellPendings() {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; --i) {
    ulong tk = OrderGetTicket(i);
    if (IsSellPending(tk))
      n++;
  }
  return n;
}

double ReferenceBuyEntry() {
  // earliest BUY entry as reference
  datetime earliest = LONG_MAX;
  double entry = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!IsBuyPosition(tk))
      continue;
    datetime t = (datetime)PositionGetInteger(POSITION_TIME);
    if (t < earliest) {
      earliest = t;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
    }
  }
  return entry;
}

double ReferenceSellEntry() {
  datetime earliest = LONG_MAX;
  double entry = 0.0;
  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    ulong tk = PositionGetTicket(i);
    if (!IsSellPosition(tk))
      continue;
    datetime t = (datetime)PositionGetInteger(POSITION_TIME);
    if (t < earliest) {
      earliest = t;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
    }
  }
  return entry;
}

// maintain exactly GridLevelsPerSide pendings per side
void MaintainBuyGrid() {
  int need = GridLevelsPerSide - CountBuyPendings();
  if (need <= 0)
    return;

  double ref = ReferenceBuyEntry();
  if (ref <= 0.0)
    ref = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  for (int i = 0; i < need; i++) {
    double price =
        ref - (GridDistancePoints * PointValue()) * (CountBuyPendings() + 1);
    PlaceBuyPending(price, g_nextBuyLot);
    g_nextBuyLot += LotIncrement;
  }
}

void MaintainSellGrid() {
  int need = GridLevelsPerSide - CountSellPendings();
  if (need <= 0)
    return;

  double ref = ReferenceSellEntry();
  if (ref <= 0.0)
    ref = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  for (int i = 0; i < need; i++) {
    double price =
        ref + (GridDistancePoints * PointValue()) * (CountSellPendings() + 1);
    PlaceSellPending(price, g_nextSellLot);
    g_nextSellLot += LotIncrement;
  }
}

//--------------------------- Side Reset ----------------------------
void ResetBuySide() {
  CloseSidePositions(MagicBuy);
  DeleteSidePendings(MagicBuy);

  SetTradeContext(MagicBuy);
  trade.Buy(NormalizeLot(InitialLot), _Symbol);

  g_nextBuyLot = InitialLot + LotIncrement;
}

void ResetSellSide() {
  CloseSidePositions(MagicSell);
  DeleteSidePendings(MagicSell);

  SetTradeContext(MagicSell);
  trade.Sell(NormalizeLot(InitialLot), _Symbol);

  g_nextSellLot = InitialLot + LotIncrement;
}

//------------------------------ MT5 Events -------------------------
int OnInit() {
  ResetDayIfNeeded();
  OpenInitialHedge();
  return (INIT_SUCCEEDED);
}

void OnTick() {
  ResetDayIfNeeded();
  if (CheckDailyStops())
    return;

  // maintain grids
  MaintainBuyGrid();
  MaintainSellGrid();

  // side profit checks
  double buyPts = CalcBuySidePoints();
  double sellPts = CalcSellSidePoints();

  if (buyPts >= SideTargetProfitPoints)
    ResetBuySide();

  if (sellPts >= SideTargetProfitPoints)
    ResetSellSide();
}