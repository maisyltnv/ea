//+------------------------------------------------------------------+
//| BuySell EA                                                       |
//| Single-position switching EA with SL/TP and martingale lots      |
//|                                                                  |
//| Logic summary:                                                   |
//|  - Start with BUY 0.01, SL=100 pts, TP=200 pts.                  |
//|  - If TP is hit: open NEW trade in SAME direction with 0.01 lot  |
//|    and SL=100 pts, TP=200 pts.                                   |
//|  - If SL is hit:                                                 |
//|       * switch direction (BUY<->SELL)                            |
//|       * double lot (capped at 0.16): 0.01→0.02→0.04→0.08→0.16.   |
//|       * for SELL after SL: SL=200 pts, TP=400 pts.               |
//|       * for BUY after SL:  SL=100 pts, TP=200 pts.               |
//|  - For any SELL TP: continue SELL 0.01 with SL=100, TP=200.      |
//|  - EA always keeps at most one open position on the symbol.      |
//+------------------------------------------------------------------+

#property strict
#property description                                                          \
    "BuySell: SL/TP with direction switch and martingale lots (max 0.16)."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input double LotsInitial = 0.01;  // Starting lot size
input double LotMultiplier = 2.0; // Multiplier after SL (martingale)
input double LotMax = 0.16;       // Maximum lot size
input int SlippagePoints = 20;    // Slippage (points)
input int MagicNumber = 555777;   // Magic number for this EA

//--- next trade SL/TP (in points), decided from history
int g_nextSLPoints = 100;
int g_nextTPPoints = 200;

//--- trade object
CTrade trade;

//--- direction state
enum TradeDirection { DIR_BUY = 0, DIR_SELL = 1 };

TradeDirection g_nextDirection = DIR_BUY; // Start with BUY
double g_nextLot = 0.0;                   // Next lot size to use

//+------------------------------------------------------------------+
//| Helper: find current EA position on this symbol (0 or 1)         |
//+------------------------------------------------------------------+
bool GetCurrentPosition(ulong &ticket) {
  ticket = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;

    // We expect at most one; if more, take the latest one
    ticket = t;
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: determine last closed position for this EA & symbol       |
//+------------------------------------------------------------------+
bool GetLastClosed(ENUM_POSITION_TYPE &type, double &volume, bool &wasTP,
                   bool &wasSL) {
  datetime fromTime = 0;
  datetime toTime = TimeCurrent();

  if (!HistorySelect(fromTime, toTime))
    return (false);

  ulong lastDealTicket = 0;
  datetime lastTime = 0;
  wasTP = false;
  wasSL = false;

  int deals = HistoryDealsTotal();
  for (int i = deals - 1; i >= 0; i--) {
    ulong dealTicket = HistoryDealGetTicket(i);
    if (dealTicket == 0)
      continue;

    long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
    if ((int)dealMagic != MagicNumber || dealSymbol != _Symbol)
      continue;

    ENUM_DEAL_ENTRY entry =
        (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if (entry != DEAL_ENTRY_OUT) // closing deal
      continue;

    datetime dTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
    if (dTime <= lastTime)
      continue;

    lastTime = dTime;
    lastDealTicket = dealTicket;
  }

  if (lastDealTicket == 0)
    return (false);

  // Extract info from last closing deal
  ENUM_DEAL_TYPE dealType =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(lastDealTicket, DEAL_TYPE);
  double vol = HistoryDealGetDouble(lastDealTicket, DEAL_VOLUME);
  double profit = HistoryDealGetDouble(lastDealTicket, DEAL_PROFIT);
  ENUM_DEAL_REASON reason =
      (ENUM_DEAL_REASON)HistoryDealGetInteger(lastDealTicket, DEAL_REASON);

  if (dealType == DEAL_TYPE_BUY)
    type = POSITION_TYPE_BUY;
  else if (dealType == DEAL_TYPE_SELL)
    type = POSITION_TYPE_SELL;
  else
    return (false);

  volume = vol;

  // Prefer explicit SL/TP reasons; fall back to profit sign
  wasTP = (reason == DEAL_REASON_TP);
  wasSL = (reason == DEAL_REASON_SL);

  if (!wasTP && !wasSL) {
    if (profit >= 0.0)
      wasTP = true;
    else
      wasSL = true;
  }

  return (true);
}

//+------------------------------------------------------------------+
//| Helper: open new position with given direction & lot             |
//+------------------------------------------------------------------+
bool OpenPosition(TradeDirection dir, double lots, int slPoints, int tpPoints) {
  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  if (point <= 0.0)
    return (false);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  double price = 0.0;
  double sl = 0.0;
  double tp = 0.0;

  if (dir == DIR_BUY) {
    price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    sl = price - slPoints * point;
    tp = price + tpPoints * point;
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if (!trade.Buy(lots, symbol, price, sl, tp)) {
      Print("BuySell: Buy open failed. Error=", GetLastError());
      return (false);
    }
  } else {
    price = SymbolInfoDouble(symbol, SYMBOL_BID);
    sl = price + slPoints * point;
    tp = price - tpPoints * point;
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    if (!trade.Sell(lots, symbol, price, sl, tp)) {
      Print("BuySell: Sell open failed. Error=", GetLastError());
      return (false);
    }
  }

  Print("BuySell: Opened ", (dir == DIR_BUY ? "BUY " : "SELL "), "lot=", lots,
        " SL=", sl, " TP=", tp);

  return (true);
}

//+------------------------------------------------------------------+
//| Decide next direction and lot based on last closed trade         |
//+------------------------------------------------------------------+
void UpdateNextFromHistory() {
  ENUM_POSITION_TYPE lastType;
  double lastVol;
  bool wasTP;
  bool wasSL;

  if (!GetLastClosed(lastType, lastVol, wasTP, wasSL)) {
    // No history -> start with BUY 0.01
    g_nextDirection = DIR_BUY;
    g_nextLot = LotsInitial;
    g_nextSLPoints = 100;
    g_nextTPPoints = 200;
    return;
  }

  if (wasTP) {
    // After TP: keep same direction, reset lot to initial 0.01
    g_nextDirection = (lastType == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
    g_nextLot = LotsInitial;
    // After any TP, always use 100/200
    g_nextSLPoints = 100;
    g_nextTPPoints = 200;
  } else if (wasSL) {
    // After SL: switch direction and double lot (capped at LotMax)
    g_nextDirection = (lastType == POSITION_TYPE_BUY ? DIR_SELL : DIR_BUY);
    double newLot = lastVol * LotMultiplier;
    if (newLot > LotMax)
      newLot = LotMax;
    g_nextLot = newLot;
    // After SL:
    // - if next is BUY:  SL=100, TP=200
    // - if next is SELL: SL=200, TP=400
    if (g_nextDirection == DIR_BUY) {
      g_nextSLPoints = 100;
      g_nextTPPoints = 200;
    } else { // DIR_SELL
      g_nextSLPoints = 200;
      g_nextTPPoints = 400;
    }
  } else {
    // Fallback: reset
    g_nextDirection = DIR_BUY;
    g_nextLot = LotsInitial;
    g_nextSLPoints = 100;
    g_nextTPPoints = 200;
  }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  g_nextDirection = DIR_BUY;
  g_nextLot = LotsInitial;
  g_nextSLPoints = 100;
  g_nextTPPoints = 200;

  Print("BuySell EA initialized on ", _Symbol, " | LotsInitial=", LotsInitial,
        " LotMax=", LotMax);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  // 1) If we have an open position, do nothing (wait for SL/TP)
  ulong ticket;
  if (GetCurrentPosition(ticket)) {
    return;
  }

  // 2) No open position -> decide what to open next using history
  UpdateNextFromHistory();

  // 3) Open the decided trade
  if (g_nextLot <= 0.0)
    g_nextLot = LotsInitial;

  // Respect broker min/max and step
  double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double volMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double volMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  double lots = g_nextLot;

  if (volStep > 0.0)
    lots = MathRound(lots / volStep) * volStep;
  if (volMin > 0.0 && lots < volMin)
    lots = volMin;
  if (volMax > 0.0 && lots > volMax)
    lots = volMax;

  OpenPosition(g_nextDirection, lots, g_nextSLPoints, g_nextTPPoints);
}
