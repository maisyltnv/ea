//+------------------------------------------------------------------+
//| SetSLTP EA                                                       |
//| First position: set TP = TPPoints, SL = SLPoints from its entry. |
//| Next positions: set TP and SL at the same PRICE as first position.|
//| Sets only when position has no SL/TP yet; after that you can     |
//| remove or change SL/TP manually and EA will not overwrite.        |
//+------------------------------------------------------------------+

#property strict
#property description "SetSLTP: sets SL/TP once when position has none; then you can edit manually."
#property version   "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input int TPPoints = 1000;   // Take profit (points) from first position entry
input int SLPoints = 2000;   // Stop loss (points) from first position entry
input int MagicNumber = 0;   // 0 = all positions on symbol; else only this magic

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Check if position belongs to our symbol (and magic if set)        |
//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket) {
  if (!PositionSelectByTicket(ticket))
    return false;
  if (PositionGetString(POSITION_SYMBOL) != _Symbol)
    return false;
  if (MagicNumber != 0 && (int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
    return false;
  return true;
}

//+------------------------------------------------------------------+
//| Find oldest position (first opened) for this symbol               |
//+------------------------------------------------------------------+
ulong FindOldestPosition() {
  ulong oldestTicket = 0;
  datetime oldestTime = D'2099.12.31';

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !IsOurPosition(ticket))
      continue;
    datetime t = (datetime)PositionGetInteger(POSITION_TIME);
    if (t < oldestTime) {
      oldestTime = t;
      oldestTicket = ticket;
    }
  }
  return oldestTicket;
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  Print("SetSLTP EA initialized. Symbol=", _Symbol, " TP=", TPPoints, " pts SL=", SLPoints, " pts");
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  ulong refTicket = FindOldestPosition();
  if (refTicket == 0)
    return;

  if (!PositionSelectByTicket(refTicket))
    return;

  double refEntry = PositionGetDouble(POSITION_PRICE_OPEN);
  ENUM_POSITION_TYPE refType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

  // Reference (first) position: SL/TP from its entry
  double refSL, refTP;
  if (refType == POSITION_TYPE_BUY) {
    refSL = NormalizeDouble(refEntry - SLPoints * point, digits);
    refTP = NormalizeDouble(refEntry + TPPoints * point, digits);
  } else {
    refSL = NormalizeDouble(refEntry + SLPoints * point, digits);
    refTP = NormalizeDouble(refEntry - TPPoints * point, digits);
  }

  // Ensure we have lower price = one level, higher = other (refSL can be > refTP for SELL)
  double priceLow = MathMin(refSL, refTP);
  double priceHigh = MathMax(refSL, refTP);

  // Set reference position only when it has no SL/TP yet (so you can change them later)
  double refCurSL = PositionGetDouble(POSITION_SL);
  double refCurTP = PositionGetDouble(POSITION_TP);
  if (refCurSL <= 0.0 && refCurTP <= 0.0) {
    if (trade.PositionModify(refTicket, refSL, refTP))
      Print("[SetSLTP] First position ", refTicket, " set SL=", refSL, " TP=", refTP);
  }

  // All other positions: set same price levels only when they have no SL/TP yet
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !IsOurPosition(ticket))
      continue;
    if (ticket == refTicket)
      continue;

    if (!PositionSelectByTicket(ticket))
      continue;

    double curSL = PositionGetDouble(POSITION_SL);
    double curTP = PositionGetDouble(POSITION_TP);
    if (curSL > 0.0 || curTP > 0.0)
      continue; // already has SL or TP - do not overwrite (user may have set/customized)

    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double sl, tp;
    if (type == POSITION_TYPE_BUY) {
      sl = priceLow;
      tp = priceHigh;
    } else {
      sl = priceHigh;
      tp = priceLow;
    }

    if (trade.PositionModify(ticket, sl, tp))
      Print("[SetSLTP] Position ", ticket, " set same levels SL=", sl, " TP=", tp);
    else
      Print("[SetSLTP] PositionModify failed. Ticket=", ticket, " Error=", GetLastError());
  }
}
