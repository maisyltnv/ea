//+------------------------------------------------------------------+
//| Hedging EA                                                       |
//| Step-based hedge sequence with reset on any TP hit               |
//|                                                                  |
//| Step 1:                                                          |
//|   - Open BUY 0.01 (market)                                       |
//|   - Place SELL STOP #1 0.02 at 200 points below BUY price        |
//|     TP for SELL #1: 200 points (profit)                          |
//|                                                                  |
//| Step 2 (when SELL STOP #1 triggers):                             |
//|   - Place BUY STOP #1 0.02 at 200 points above SELL #1 price     |
//|     TP for BUY #1: 200 points                                    |
//|                                                                  |
//| Step 3 (when BUY STOP #1 triggers):                              |
//|   - Place SELL STOP #2 0.03 at 200 points below BUY #1 price     |
//|     TP for SELL #2: 200 points                                   |
//|                                                                  |
//| Step 4 (when SELL STOP #2 triggers):                             |
//|   - Place BUY STOP #2 0.05 at 200 points above SELL #2 price     |
//|     TP for BUY #2: 200 points                                    |
//|                                                                  |
//| Step 5 (any TP hit):                                             |
//|   - Close all positions and pending orders                       |
//|   - Reset and start again from Step 1                            |
//+------------------------------------------------------------------+

#property strict
#property description "Hedging EA with fixed sequence of hedge orders and reset on TP."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input double Lots_Initial = 0.01; // Step 1 BUY lot, Total Buy:0.01
input double Lots_Sell1 = 0.03;   // SELL STOP #1 lot, Total Sell:0.02
input double Lots_Buy1 = 0.06;    // BUY STOP #1 lot, Total Buy:0.03
input double Lots_Sell2 = 0.17;   // SELL STOP #2 lot, Total Sell:0.05
input double Lots_Buy2 = 0.4;     // BUY STOP #2 lot, Total Buy:0.08

input int DistancePoints = 100; // Distance between hedge orders (points)
input int TPPoints = 200;       // Take profit distance (points)
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 246810; // Magic number for this EA

input double DailyProfitPercent = 10.0; // Daily profit target (% of balance) -
                                        // stop trading for the day when reached
input double DailyLossPercent = 40.0; // Daily loss limit (% of balance) - stop
                                      // trading for the day when reached
input bool UseDailyLimits = true;     // Enable daily profit/loss stop

input bool   UseMacdFilter   = true;  // Only open when MACD > threshold high or < threshold low
input int    MacdFast        = 12;    // MACD fast EMA
input int    MacdSlow        = 26;    // MACD slow EMA
input int    MacdSignal      = 9;     // MACD signal period
input double MacdThresholdHigh = 2.0;  // Open allowed when MACD line > this (e.g. 0.0002 for forex)
input double MacdThresholdLow  = -2.0; // Open allowed when MACD line < this (e.g. -0.0002 for forex)

//--- trade object
CTrade trade;

//--- MACD indicator handle
int g_handleMACD = INVALID_HANDLE;

//--- step state
enum HedgeStep {
  STEP_NONE = 0, // nothing active, need to (re)start
  STEP_1 = 1,    // initial BUY + SELL STOP #1 placed
  STEP_2 = 2,    // SELL #1 triggered, BUY STOP #1 placed
  STEP_3 = 3,    // BUY #1 triggered, SELL STOP #2 placed
  STEP_4 = 4     // SELL #2 triggered, BUY STOP #2 placed
};

int g_step = STEP_NONE;

//--- daily limits state
double g_startOfDayBalance = 0.0; // Balance at start of current trading day
int g_lastDay = 0;                // Last day we updated (TimeCurrent()/86400)
bool g_stoppedForDay = false; // true when daily profit target or loss limit hit

//+------------------------------------------------------------------+
//| Helper: approximate comparison of lots                           |
//+------------------------------------------------------------------+
bool LotEquals(double v, double t) { return (MathAbs(v - t) < 1e-8); }

//+------------------------------------------------------------------+
//| Helper: true if MACD(12,26,9) > threshold high or < threshold low |
//| Only open new cycle when this is true (at start and after TP).   |
//+------------------------------------------------------------------+
bool MacdAllowed() {
  if (!UseMacdFilter)
    return (true);
  if (g_handleMACD == INVALID_HANDLE)
    return (false);

  double macdBuf[];
  ArraySetAsSeries(macdBuf, true);
  if (CopyBuffer(g_handleMACD, 0, 1, 1, macdBuf) <= 0)  // buffer 0 = MACD line, bar 1 = last closed
    return (false);

  double macd = macdBuf[0];
  if (macd > MacdThresholdHigh || macd < MacdThresholdLow)
    return (true);
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: close all EA positions and pending orders                |
//+------------------------------------------------------------------+
void CloseAllAndReset() {
  string symbol = _Symbol;

  // Close positions
  int totalPos = PositionsTotal();
  for (int i = totalPos - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;

    trade.PositionClose(ticket);
  }

  // Delete pending orders
  int totalOrd = OrdersTotal();
  for (int i = totalOrd - 1; i >= 0; i--) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;

    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;

    trade.OrderDelete(ticket);
  }

  g_step = STEP_NONE;
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

    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;

    ENUM_POSITION_TYPE type =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double tp = PositionGetDouble(POSITION_TP);
    if (tp <= 0.0)
      continue;

    // Small tolerance of 0.1 point
    double tol = point * 0.1;

    if (type == POSITION_TYPE_BUY && bid >= tp - tol)
      return (true);
    if (type == POSITION_TYPE_SELL && ask <= tp + tol)
      return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: count EA positions by type                               |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE type) {
  string symbol = _Symbol;
  int totalPos = PositionsTotal();
  int count = 0;

  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;

    ENUM_POSITION_TYPE ptype =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (ptype == type)
      count++;
  }
  return (count);
}

//+------------------------------------------------------------------+
//| Helper: get first position of type & lot, returns entry price    |
//+------------------------------------------------------------------+
bool GetPosition(ENUM_POSITION_TYPE type, double lot, double &priceOpen) {
  string symbol = _Symbol;
  int totalPos = PositionsTotal();
  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;

    ENUM_POSITION_TYPE ptype =
        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    if (ptype != type)
      continue;

    double vol = PositionGetDouble(POSITION_VOLUME);
    if (!LotEquals(vol, lot))
      continue;

    priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: check if a pending order of type & lot exists            |
//+------------------------------------------------------------------+
bool HasPending(ENUM_ORDER_TYPE type, double lot) {
  string symbol = _Symbol;
  int totalOrd = OrdersTotal();

  for (int i = 0; i < totalOrd; i++) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;

    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;

    ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if (otype != type)
      continue;

    double vol = OrderGetDouble(ORDER_VOLUME_INITIAL);
    if (!LotEquals(vol, lot))
      continue;

    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: place initial BUY and SELL STOP #1                       |
//+------------------------------------------------------------------+
void DoInitialSetup() {
  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  // Open initial BUY
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double buyPrice = ask;
  double buyTP = buyPrice + TPPoints * point;
  buyPrice = NormalizeDouble(buyPrice, digits);
  buyTP = NormalizeDouble(buyTP, digits);

  if (trade.Buy(Lots_Initial, symbol, buyPrice, 0.0, buyTP, "Hedge BUY #0")) {
    Print("Initial BUY opened at ", buyPrice, " TP=", buyTP);

    // Place SELL STOP #1
    double sellPrice = buyPrice - DistancePoints * point;
    double sellTP = sellPrice - TPPoints * point;
    sellPrice = NormalizeDouble(sellPrice, digits);
    sellTP = NormalizeDouble(sellTP, digits);

    if (trade.SellStop(Lots_Sell1, sellPrice, symbol, 0.0, sellTP,
                       ORDER_TIME_GTC, 0, "Hedge SELL STOP #1")) {
      Print("SELL STOP #1 placed at ", sellPrice, " TP=", sellTP);
      g_step = STEP_1;
    } else {
      Print("Failed to place SELL STOP #1. Error=", GetLastError());
    }
  } else {
    Print("Failed to open initial BUY. Error=", GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  if (_Period != PERIOD_M1) {
    Print("Hedging EA works on M1 only. Please switch chart to M1 timeframe.");
    return (INIT_FAILED);
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  g_step = STEP_NONE;
  g_startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  g_lastDay = (int)(TimeCurrent() / 86400);
  g_stoppedForDay = false;

  if (UseMacdFilter) {
    g_handleMACD = iMACD(_Symbol, PERIOD_M1, MacdFast, MacdSlow, MacdSignal, PRICE_CLOSE);
    if (g_handleMACD == INVALID_HANDLE) {
      Print("MACD indicator create failed. Error=", GetLastError());
      return (INIT_FAILED);
    }
  }

  Print("Hedging EA initialized on symbol ", _Symbol,
        " | Start-of-day balance: ", g_startOfDayBalance);
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  if (g_handleMACD != INVALID_HANDLE) {
    IndicatorRelease(g_handleMACD);
    g_handleMACD = INVALID_HANDLE;
  }
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  string symbol = _Symbol;

  // 0) Daily limits: new day reset, then check profit/loss stop
  if (UseDailyLimits) {
    int today = (int)(TimeCurrent() / 86400);
    if (today != g_lastDay) {
      g_lastDay = today;
      g_startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_stoppedForDay = false;
      Print("New trading day. Start-of-day balance: ", g_startOfDayBalance);
    }

    if (g_stoppedForDay)
      return;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if (g_startOfDayBalance > 0.0) {
      double dailyPL = balance - g_startOfDayBalance;
      double profitPct = 100.0 * dailyPL / g_startOfDayBalance;

      if (profitPct >= DailyProfitPercent) {
        Print("Daily profit target reached (", DoubleToString(profitPct, 2),
              "% >= ", DailyProfitPercent,
              "%). Closing all and stopping for the day.");
        CloseAllAndReset();
        g_stoppedForDay = true;
        return;
      }
      if (profitPct <= -DailyLossPercent) {
        Print("Daily loss limit reached (", DoubleToString(profitPct, 2),
              "% <= -", DailyLossPercent,
              "%). Closing all and stopping for the day.");
        CloseAllAndReset();
        g_stoppedForDay = true;
        return;
      }
    }
  }

  // 1) If any TP is hit -> close everything and reset
  if (AnyTPHit()) {
    Print("TP reached for one of the positions. Closing all and resetting.");
    CloseAllAndReset();
    return;
  }

  // Re-count after possible reset
  int totalPos = 0;
  int totalOrd = 0;
  // Count EA positions
  for (int i = 0; i < PositionsTotal(); i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue;
    totalPos++;
  }
  // Count EA pending orders
  for (int i = 0; i < OrdersTotal(); i++) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;
    if ((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      continue;
    totalOrd++;
  }

  // 2) If nothing exists -> start Step 1 (only when MACD allows)
  if (totalPos == 0 && totalOrd == 0 && g_step == STEP_NONE) {
    if (MacdAllowed()) {
      DoInitialSetup();
    }
    return;
  }

  double entryPrice;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  trade.SetDeviationInPoints(SlippagePoints);

  // 3) State machine for hedge sequence
  if (g_step == STEP_1) {
    // SELL STOP #1 should have triggered if there is a SELL 0.02 and
    // no BUY STOP #1 yet
    bool hasSell1 = GetPosition(POSITION_TYPE_SELL, Lots_Sell1, entryPrice);
    bool hasBuyStop1 = HasPending(ORDER_TYPE_BUY_STOP, Lots_Buy1);

    if (hasSell1 && !hasBuyStop1) {
      double buyStopPrice = entryPrice + DistancePoints * point;
      double buyTP = buyStopPrice + TPPoints * point;
      buyStopPrice = NormalizeDouble(buyStopPrice, digits);
      buyTP = NormalizeDouble(buyTP, digits);

      if (trade.BuyStop(Lots_Buy1, buyStopPrice, symbol, 0.0, buyTP,
                        ORDER_TIME_GTC, 0, "Hedge BUY STOP #1")) {
        Print("BUY STOP #1 placed at ", buyStopPrice, " TP=", buyTP);
        g_step = STEP_2;
      } else {
        Print("Failed to place BUY STOP #1. Error=", GetLastError());
      }
    }
  } else if (g_step == STEP_2) {
    // BUY STOP #1 should have triggered if there is a BUY 0.02 and
    // no SELL STOP #2 yet
    bool hasBuy1 = GetPosition(POSITION_TYPE_BUY, Lots_Buy1, entryPrice);
    bool hasSellStop2 = HasPending(ORDER_TYPE_SELL_STOP, Lots_Sell2);

    if (hasBuy1 && !hasSellStop2) {
      double sellStopPrice = entryPrice - DistancePoints * point;
      double sellTP = sellStopPrice - TPPoints * point;
      sellStopPrice = NormalizeDouble(sellStopPrice, digits);
      sellTP = NormalizeDouble(sellTP, digits);

      if (trade.SellStop(Lots_Sell2, sellStopPrice, symbol, 0.0, sellTP,
                         ORDER_TIME_GTC, 0, "Hedge SELL STOP #2")) {
        Print("SELL STOP #2 placed at ", sellStopPrice, " TP=", sellTP);
        g_step = STEP_3;
      } else {
        Print("Failed to place SELL STOP #2. Error=", GetLastError());
      }
    }
  } else if (g_step == STEP_3) {
    // SELL STOP #2 should have triggered if there is a SELL 0.03 and
    // no BUY STOP #2 yet
    bool hasSell2 = GetPosition(POSITION_TYPE_SELL, Lots_Sell2, entryPrice);
    bool hasBuyStop2 = HasPending(ORDER_TYPE_BUY_STOP, Lots_Buy2);

    if (hasSell2 && !hasBuyStop2) {
      double buyStopPrice = entryPrice + DistancePoints * point;
      double buyTP = buyStopPrice + TPPoints * point;
      buyStopPrice = NormalizeDouble(buyStopPrice, digits);
      buyTP = NormalizeDouble(buyTP, digits);

      if (trade.BuyStop(Lots_Buy2, buyStopPrice, symbol, 0.0, buyTP,
                        ORDER_TIME_GTC, 0, "Hedge BUY STOP #2")) {
        Print("BUY STOP #2 placed at ", buyStopPrice, " TP=", buyTP);
        g_step = STEP_4;
      } else {
        Print("Failed to place BUY STOP #2. Error=", GetLastError());
      }
    }
  } else if (g_step == STEP_4) {
    // In step 4 we just wait for any TP to be hit (handled at top)
    // No further hedge steps defined in the specification.
  }
}
 