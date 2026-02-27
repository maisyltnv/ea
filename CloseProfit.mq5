//+------------------------------------------------------------------+
//| CloseProfit EA                                                   |
//| Closes all positions and pending orders when account profit      |
//| (floating) reaches a target in USD.                              |
//+------------------------------------------------------------------+

#property strict
#property description "CloseProfit: close all trades when profit >= target."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs
input double TargetProfitUSD = 5.0; // Close all when profit >= this (USD)
input int SlippagePoints = 20;      // Slippage for closing (points)

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Close all positions and pending orders on the account            |
//+------------------------------------------------------------------+
void CloseAllTrades() {
  string logPrefix = "[CloseProfit] ";

  // Close all open positions (all symbols, all magics)
  int totalPos = PositionsTotal();
  for (int i = totalPos - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    string symbol = PositionGetString(POSITION_SYMBOL);
    trade.SetDeviationInPoints(SlippagePoints);

    if (!trade.PositionClose(ticket)) {
      Print(logPrefix, "Failed to close position ticket ", ticket, " on ",
            symbol, "  Error=", GetLastError());
    }
  }

  // Delete all pending orders (all symbols, all magics)
  int totalOrd = OrdersTotal();
  for (int i = totalOrd - 1; i >= 0; i--) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;

    string symbol = OrderGetString(ORDER_SYMBOL);
    if (!trade.OrderDelete(ticket)) {
      Print(logPrefix, "Failed to delete pending order ticket ", ticket, " on ",
            symbol, "  Error=", GetLastError());
    }
  }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetDeviationInPoints(SlippagePoints);
  Print("[CloseProfit] EA initialized. Target profit = ",
        DoubleToString(TargetProfitUSD, 2), " USD.");
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  Print("[CloseProfit] EA deinitialized. Reason = ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  if (TargetProfitUSD <= 0.0)
    return;

  // Sum floating profit of all open positions (in account currency)
  double totalProfit = 0.0;
  int totalPos = PositionsTotal();
  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;

    totalProfit += PositionGetDouble(POSITION_PROFIT);
  }

  // If total profit reached or exceeded target, close everything
  if (totalProfit >= TargetProfitUSD) {
    Print("[CloseProfit] Target reached. Floating profit = ",
          DoubleToString(totalProfit, 2),
          " USD  (target = ", DoubleToString(TargetProfitUSD, 2),
          "). Closing all positions and pending orders.");
    CloseAllTrades();
  }
}
