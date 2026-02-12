//+------------------------------------------------------------------+
//| HedgingManual EA                                                 |
//| Manual start (user opens first BUY or SELL), EA builds hedge     |
//| ladder of pending stops and closes everything on any TP.         |
//|                                                                  |
//| BUY-START (user manually opens BUY):                             |
//|  - Step 1: manual BUY (any lot, typically 0.1), TP = TPPoints    |
//|            EA places SELL STOP #1 at Distance below entry (lot H1)|
//|  - Step 2: when SELL #1 triggers → place BUY STOP #1 (lot H1)    |
//|            at Distance above SELL #1 price                        |
//|  - Step 3: when BUY #1 triggers → place SELL STOP #2 (lot H2)    |
//|            at Distance below BUY #1 price                         |
//|  - Step 4: when SELL #2 triggers → place BUY STOP #2 (lot H3)    |
//|            at Distance above SELL #2 price                        |
//|  - Then wait: no more hedge orders; any TP closes all & resets   |
//|                                                                  |
//| SELL-START (user manually opens SELL):                           |
//|  - Step 1: manual SELL, TP = TPPoints                            |
//|            EA places BUY STOP #1 at Distance above entry (lot H1)|
//|  - Step 2: when BUY #1 triggers → place SELL STOP #1 (lot H1)    |
//|            at Distance below BUY #1 price                         |
//|  - Step 3: when SELL #1 triggers → place BUY STOP #2 (lot H2)    |
//|            at Distance above SELL #1 price                        |
//|  - Step 4: when BUY #2 triggers → place SELL STOP #2 (lot H3)    |
//|            at Distance below BUY #2 price                         |
//|  - Then wait: any TP closes all & resets                         |
//+------------------------------------------------------------------+

#property strict
#property description "HedgingManual EA: user opens first BUY/SELL"
#property description "EA builds hedge ladder of pending stops"
#property description "Closes all positions on any TP hit."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input double Lots_Hedge1 = 0.3; // Hedge lot #1 (SellStop1 / BuyStop1)
input double Lots_Hedge2 = 0.6; // Hedge lot #2 (SellStop2 / BuyStop2)
input double Lots_Hedge3 = 1.7; // Hedge lot #3 (final)
input int DistancePoints = 500; // Distance between hedge orders (points)
input int TPPoints = 500;       // Take profit distance (points) from each entry
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 987654; // Magic for EA-created orders

//--- trade object
CTrade trade;

//--- mode and step state
enum StartMode {
  MODE_NONE = 0,      // no active cycle, waiting for manual start
  MODE_BUY_START = 1, // cycle started from manual BUY
  MODE_SELL_START = 2 // cycle started from manual SELL
};

enum HedgeStep {
  STEP_IDLE = 0,
  STEP_1 = 1, // after first hedge order placed
  STEP_2 = 2,
  STEP_3 = 3,
  STEP_4 = 4 // final hedge order placed; then wait for TP
};

int g_mode = MODE_NONE;
int g_step = STEP_IDLE;

//+------------------------------------------------------------------+
//| Helper: close all positions and pending orders for this symbol   |
//+------------------------------------------------------------------+
void CloseAllAndReset() {
  string symbol = _Symbol;

  // Close positions (all magics, including manual)
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    trade.PositionClose(ticket);
  }

  // Delete pending orders (all magics, including manual)
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    trade.OrderDelete(ticket);
  }

  g_mode = MODE_NONE;
  g_step = STEP_IDLE;
}

//+------------------------------------------------------------------+
//| Helper: check if any TP has been hit (price reached TP)          |
//+------------------------------------------------------------------+
bool AnyTPHit() {
  string symbol = _Symbol;
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

  int totalPos = PositionsTotal();
  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    ENUM_POSITION_TYPE type =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double tp = PositionGetDouble(POSITION_TP);
    if (tp <= 0.0)
      continue;

    double tol = point * 0.5; // small tolerance

    if (type == POSITION_TYPE_BUY && bid >= tp - tol)
      return (true);
    if (type == POSITION_TYPE_SELL && ask <= tp + tol)
      return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: find first manual position (magic != MagicNumber)        |
//+------------------------------------------------------------------+
bool FindManualPosition(ENUM_POSITION_TYPE type, ulong &ticketOut) {
  string symbol = _Symbol;
  ticketOut = 0;

  int totalPos = PositionsTotal();
  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    int magic = (int)PositionGetInteger(POSITION_MAGIC);
    if (magic == MagicNumber) // skip EA positions
      continue;

    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
      continue;

    ticketOut = ticket;
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: get EA position (by type and lot), returns entry price   |
//+------------------------------------------------------------------+
bool GetEAPosition(ENUM_POSITION_TYPE type, double lot, double &priceOpen) {
  string symbol = _Symbol;
  int totalPos = PositionsTotal();

  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    int magic = (int)PositionGetInteger(POSITION_MAGIC);
    if (magic != MagicNumber)
      continue;

    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
      continue;

    double vol = PositionGetDouble(POSITION_VOLUME);
    if (MathAbs(vol - lot) > 1e-8)
      continue;

    priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: check if EA pending order of type & lot exists           |
//+------------------------------------------------------------------+
bool HasEAPending(ENUM_ORDER_TYPE type, double lot) {
  string symbol = _Symbol;
  int totalOrd = OrdersTotal();

  for (int i = 0; i < totalOrd; i++) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    int magic = (int)OrderGetInteger(ORDER_MAGIC);
    if (magic != MagicNumber)
      continue;

    if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
      continue;

    double vol = OrderGetDouble(ORDER_VOLUME_INITIAL);
    if (MathAbs(vol - lot) > 1e-8)
      continue;

    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Start BUY-based hedge cycle from manual BUY position             |
//+------------------------------------------------------------------+
void StartBuyCycle(ulong manualTicket) {
  if (!PositionSelectByTicket(manualTicket))
    return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = PositionGetDouble(POSITION_SL);
  double tp = entry + TPPoints * point;
  tp = NormalizeDouble(tp, digits);

  // Set TP for manual BUY
  trade.PositionModify(manualTicket, sl, tp);

  // Place SELL STOP #1 (lot = Lots_Hedge1)
  double sellPrice = entry - DistancePoints * point;
  double sellTP = sellPrice - TPPoints * point;
  sellPrice = NormalizeDouble(sellPrice, digits);
  sellTP = NormalizeDouble(sellTP, digits);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (trade.SellStop(Lots_Hedge1, sellPrice, symbol, 0.0, sellTP)) {
    Print("[HedgingManual] BUY-start: SELL STOP #1 placed at ", sellPrice,
          " TP=", sellTP);
    g_mode = MODE_BUY_START;
    g_step = STEP_1;
  } else {
    Print("[HedgingManual] BUY-start: failed to place SELL STOP #1. Error=",
          GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Start SELL-based hedge cycle from manual SELL position           |
//+------------------------------------------------------------------+
void StartSellCycle(ulong manualTicket) {
  if (!PositionSelectByTicket(manualTicket))
    return;

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = PositionGetDouble(POSITION_SL);
  double tp = entry - TPPoints * point;
  tp = NormalizeDouble(tp, digits);

  // Set TP for manual SELL
  trade.PositionModify(manualTicket, sl, tp);

  // Place BUY STOP #1 (lot = Lots_Hedge1)
  double buyPrice = entry + DistancePoints * point;
  double buyTP = buyPrice + TPPoints * point;
  buyPrice = NormalizeDouble(buyPrice, digits);
  buyTP = NormalizeDouble(buyTP, digits);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (trade.BuyStop(Lots_Hedge1, buyPrice, symbol, 0.0, buyTP)) {
    Print("[HedgingManual] SELL-start: BUY STOP #1 placed at ", buyPrice,
          " TP=", buyTP);
    g_mode = MODE_SELL_START;
    g_step = STEP_1;
  } else {
    Print("[HedgingManual] SELL-start: failed to place BUY STOP #1. Error=",
          GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  g_mode = MODE_NONE;
  g_step = STEP_IDLE;
  Print("HedgingManual EA initialized on symbol ", _Symbol);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  // 1) If any TP is hit -> close everything and reset (both modes)
  if (AnyTPHit()) {
    Print("[HedgingManual] TP reached. Closing all positions and orders, "
          "resetting state.");
    CloseAllAndReset();
    return;
  }

  // 1b) If user closed all positions/orders manually -> reset so next manual
  // open starts a new cycle
  if (g_mode != MODE_NONE) {
    int posCount = 0, ordCount = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t))
        continue;
      if (PositionGetString(POSITION_SYMBOL) == symbol)
        posCount++;
    }
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if (t == 0 || !OrderSelect(t))
        continue;
      if (OrderGetString(ORDER_SYMBOL) == symbol)
        ordCount++;
    }
    if (posCount == 0 && ordCount == 0) {
      g_mode = MODE_NONE;
      g_step = STEP_IDLE;
      Print("[HedgingManual] All closed manually. Reset. Ready for new manual "
            "open.");
    }
  }

  // 2) If no active cycle, check for manual start
  if (g_mode == MODE_NONE) {
    ulong buyTicket = 0;
    ulong sellTicket = 0;
    bool hasManualBuy = FindManualPosition(POSITION_TYPE_BUY, buyTicket);
    bool hasManualSell = FindManualPosition(POSITION_TYPE_SELL, sellTicket);

    // If exactly one side exists, start the corresponding cycle
    if (hasManualBuy && !hasManualSell) {
      StartBuyCycle(buyTicket);
    } else if (hasManualSell && !hasManualBuy) {
      StartSellCycle(sellTicket);
    }

    // If both exist or none, do nothing
    return;
  }

  // 3) Hedge sequence for active mode
  double entryPrice;

  trade.SetDeviationInPoints(SlippagePoints);
  trade.SetExpertMagicNumber(MagicNumber);

  if (g_mode == MODE_BUY_START) {
    // BUY-based cycle: initial manual BUY, then SELL/BUY/SELL/BUY...

    if (g_step == STEP_1) {
      // SELL STOP #1 triggered -> we have SELL H1; place BUY STOP #1 H1 above
      bool hasSell1 =
          GetEAPosition(POSITION_TYPE_SELL, Lots_Hedge1, entryPrice);
      bool hasBuyStop1 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Hedge1);

      if (hasSell1 && !hasBuyStop1) {
        double buyPrice = entryPrice + DistancePoints * point;
        double buyTP = buyPrice + TPPoints * point;
        buyPrice = NormalizeDouble(buyPrice, digits);
        buyTP = NormalizeDouble(buyTP, digits);

        if (trade.BuyStop(Lots_Hedge1, buyPrice, symbol, 0.0, buyTP)) {
          Print("[HedgingManual] BUY-start: BUY STOP #1 placed at ", buyPrice,
                " TP=", buyTP);
          g_step = STEP_2;
        } else
          Print(
              "[HedgingManual] BUY-start: failed to place BUY STOP #1. Error=",
              GetLastError());
      }
    } else if (g_step == STEP_2) {
      // BUY STOP #1 triggered -> we have BUY H1; place SELL STOP #2 H2 below
      bool hasBuy1 = GetEAPosition(POSITION_TYPE_BUY, Lots_Hedge1, entryPrice);
      bool hasSellStop2 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Hedge2);

      if (hasBuy1 && !hasSellStop2) {
        double sellPrice = entryPrice - DistancePoints * point;
        double sellTP = sellPrice - TPPoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        sellTP = NormalizeDouble(sellTP, digits);

        if (trade.SellStop(Lots_Hedge2, sellPrice, symbol, 0.0, sellTP)) {
          Print("[HedgingManual] BUY-start: SELL STOP #2 placed at ", sellPrice,
                " TP=", sellTP);
          g_step = STEP_3;
        } else
          Print(
              "[HedgingManual] BUY-start: failed to place SELL STOP #2. Error=",
              GetLastError());
      }
    } else if (g_step == STEP_3) {
      // SELL STOP #2 triggered -> we have SELL H2; place BUY STOP #2 H3 above
      bool hasSell2 =
          GetEAPosition(POSITION_TYPE_SELL, Lots_Hedge2, entryPrice);
      bool hasBuyStop2 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Hedge3);

      if (hasSell2 && !hasBuyStop2) {
        double buyPrice = entryPrice + DistancePoints * point;
        double buyTP = buyPrice + TPPoints * point;

        buyPrice = NormalizeDouble(buyPrice, digits);
        buyTP = NormalizeDouble(buyTP, digits);

        if (trade.BuyStop(Lots_Hedge3, buyPrice, symbol, 0.0, buyTP)) {
          Print("[HedgingManual] BUY-start: BUY STOP #2 placed at ", buyPrice,
                " TP=", buyTP);
          g_step = STEP_4; // final
        } else
          Print(
              "[HedgingManual] BUY-start: failed to place BUY STOP #2. Error=",
              GetLastError());
      }
    } else if (g_step == STEP_4) {
      // Final step: all hedges placed; wait for TP (handled at top)
    }
  } else if (g_mode == MODE_SELL_START) {
    // SELL-based cycle: initial manual SELL, then BUY/SELL/BUY/SELL...

    if (g_step == STEP_1) {
      // BUY STOP #1 triggered -> we have BUY H1; place SELL STOP #1 H1 below
      bool hasBuy1 = GetEAPosition(POSITION_TYPE_BUY, Lots_Hedge1, entryPrice);
      bool hasSellStop1 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Hedge1);

      if (hasBuy1 && !hasSellStop1) {
        double sellPrice = entryPrice - DistancePoints * point;
        double sellTP = sellPrice - TPPoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        sellTP = NormalizeDouble(sellTP, digits);

        if (trade.SellStop(Lots_Hedge1, sellPrice, symbol, 0.0, sellTP)) {
          Print("[HedgingManual] SELL-start: SELL STOP #1 placed at ",
                sellPrice, " TP=", sellTP);
          g_step = STEP_2;
        } else
          Print("[HedgingManual] SELL-start: failed to place SELL STOP #1. "
                "Error=",
                GetLastError());
      }
    } else if (g_step == STEP_2) {
      // SELL STOP #1 triggered -> we have SELL H1; place BUY STOP #2 H2 above
      bool hasSell1 =
          GetEAPosition(POSITION_TYPE_SELL, Lots_Hedge1, entryPrice);
      bool hasBuyStop2 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Hedge2);

      if (hasSell1 && !hasBuyStop2) {
        double buyPrice = entryPrice + DistancePoints * point;
        double buyTP = buyPrice + TPPoints * point;
        buyPrice = NormalizeDouble(buyPrice, digits);
        buyTP = NormalizeDouble(buyTP, digits);

        if (trade.BuyStop(Lots_Hedge2, buyPrice, symbol, 0.0, buyTP)) {
          Print("[HedgingManual] SELL-start: BUY STOP #2 placed at ", buyPrice,
                " TP=", buyTP);
          g_step = STEP_3;
        } else
          Print(
              "[HedgingManual] SELL-start: failed to place BUY STOP #2. Error=",
              GetLastError());
      }
    } else if (g_step == STEP_3) {
      // BUY STOP #2 triggered -> we have BUY H2; place SELL STOP #2 H3 below
      bool hasBuy2 = GetEAPosition(POSITION_TYPE_BUY, Lots_Hedge2, entryPrice);
      bool hasSellStop2 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Hedge3);

      if (hasBuy2 && !hasSellStop2) {
        double sellPrice = entryPrice - DistancePoints * point;
        double sellTP = sellPrice - TPPoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        sellTP = NormalizeDouble(sellTP, digits);

        if (trade.SellStop(Lots_Hedge3, sellPrice, symbol, 0.0, sellTP)) {
          Print("[HedgingManual] SELL-start: SELL STOP #2 placed at ",
                sellPrice, " TP=", sellTP);
          g_step = STEP_4; // final
        } else
          Print("[HedgingManual] SELL-start: failed to place SELL STOP #2. "
                "Error=",
                GetLastError());
      }
    } else if (g_step == STEP_4) {
      // Final step: all hedges placed; wait for TP (handled at top)
    }
  }
}
