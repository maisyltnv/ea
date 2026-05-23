//+------------------------------------------------------------------+
//|                                                     TestNoti.mq5 |
//| Test alerts: notify when price crosses above/below EMA10 on chart TF. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Test push/Alert: price > EMA10 or price < EMA10."

//--------------------------- Inputs --------------------------------
input int    EMAPeriod              = 10;
input ENUM_TIMEFRAMES SignalTF      = PERIOD_M1;
input ENUM_APPLIED_PRICE EMAPrice   = PRICE_CLOSE;
input bool   UseTerminalAlert       = true;
input bool   UsePushNotification    = true;
input bool   CheckOnNewBarOnly      = true;    // check on new bar of SignalTF

//--------------------------- Globals --------------------------------
int      g_hEma     = INVALID_HANDLE;
datetime g_lastBar  = 0;
bool     g_canAlertAbove = true;
bool     g_canAlertBelow = true;

//--------------------------- Helpers --------------------------------
bool IsNewBar() {
  datetime t[1];
  if (CopyTime(_Symbol, SignalTF, 0, 1, t) != 1) return false;
  if (t[0] == g_lastBar) return false;
  g_lastBar = t[0];
  return true;
}

void Notify(const string msg) {
  Print("[TestNoti] ", msg);
  if (UseTerminalAlert) Alert(msg);
  if (UsePushNotification) {
    if (!SendNotification(msg))
      Print("[TestNoti] SendNotification failed err=", GetLastError());
  }
}

void CheckPriceVsEma() {
  if (g_hEma == INVALID_HANDLE) return;

  double emaBuf[1];
  if (CopyBuffer(g_hEma, 0, 0, 1, emaBuf) != 1) return;
  const double ema = emaBuf[0];
  if (ema <= 0.0) return;

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double px = (bid + ask) * 0.5;

  const string sym = _Symbol;
  const string tf  = EnumToString(SignalTF);

  if (px > ema) {
    if (g_canAlertAbove) {
      Notify("TestNoti ABOVE: " + sym + " " + tf +
             " price=" + DoubleToString(px, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
             " > EMA" + IntegerToString(EMAPeriod) + "=" + DoubleToString(ema, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      g_canAlertAbove = false;
    }
    g_canAlertBelow = true;
  } else if (px < ema) {
    if (g_canAlertBelow) {
      Notify("TestNoti BELOW: " + sym + " " + tf +
             " price=" + DoubleToString(px, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
             " < EMA" + IntegerToString(EMAPeriod) + "=" + DoubleToString(ema, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      g_canAlertBelow = false;
    }
    g_canAlertAbove = true;
  } else {
    g_canAlertAbove = true;
    g_canAlertBelow = true;
  }
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  g_hEma = iMA(_Symbol, SignalTF, EMAPeriod, 0, MODE_EMA, EMAPrice);
  if (g_hEma == INVALID_HANDLE) {
    Print("[TestNoti] iMA failed.");
    return INIT_FAILED;
  }

  datetime t[1];
  if (CopyTime(_Symbol, SignalTF, 0, 1, t) == 1) g_lastBar = t[0];

  Print("[TestNoti] Ready on ", _Symbol, " ", EnumToString(SignalTF),
        " — alert when price > or < EMA", EMAPeriod);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_hEma != INVALID_HANDLE) IndicatorRelease(g_hEma);
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);
  if (CheckOnNewBarOnly && !IsNewBar()) return;
  CheckPriceVsEma();
}
