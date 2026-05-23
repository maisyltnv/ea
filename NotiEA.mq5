//+------------------------------------------------------------------+
//|                                                       NotiEA.mq5 |
//| Alert / push notification when EMA + Stochastic conditions align.  |
//|                                                                  |
//| BUY:  M5 EMA50>200 AND M1 EMA50>200 AND M1 Stoch 9,3,3 %K < 20   |
//| SELL: M5 EMA50<200 AND M1 EMA50<200 AND M1 Stoch 9,3,3 %K > 80   |
//| Alerts once per signal (re-arms after conditions clear).         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA M1+M5 + M1 Stoch alerts (Alert + optional push)."

//--------------------------- Inputs --------------------------------
input int    TrendEMAFastPeriod     = 50;
input int    TrendEMASlowPeriod     = 200;
input int    TrendEMAShift          = 1;       // 1 = last closed bar

input int    StochKPeriod           = 9;
input int    StochDPeriod           = 3;
input int    StochSlowing           = 3;
input int    StochBuyMaxLevel       = 20;      // BUY when M1 %K < this
input int    StochSellMinLevel      = 80;      // SELL when M1 %K > this
input int    StochShift             = 1;       // bar shift on M1

input bool   UseTerminalAlert       = true;    // Alert() popup in MT5
input bool   UsePushNotification    = true;    // SendNotification() to mobile
input bool   CheckOnNewM1BarOnly    = true;    // false = check every tick

//--------------------------- Globals --------------------------------
int g_hEmaFastM1 = INVALID_HANDLE;
int g_hEmaSlowM1 = INVALID_HANDLE;
int g_hEmaFastM5 = INVALID_HANDLE;
int g_hEmaSlowM5 = INVALID_HANDLE;
int g_hStochM1   = INVALID_HANDLE;

datetime g_lastM1BarTime = 0;
bool     g_buyCanAlert   = true;
bool     g_sellCanAlert  = true;

//--------------------------- Helpers --------------------------------
int EmaShift() {
  return (TrendEMAShift < 0) ? 0 : TrendEMAShift;
}

int StochBarShift() {
  return (StochShift < 0) ? 0 : StochShift;
}

bool ReadEma(const int h, const int shift, double &v) {
  v = 0.0;
  if (h == INVALID_HANDLE) return false;
  double b[1];
  const int sh = (shift < 0) ? 0 : shift;
  if (CopyBuffer(h, 0, sh, 1, b) != 1) return false;
  v = b[0];
  return (v > 0.0);
}

bool GetStochMainK(const int shift, double &k) {
  k = 0.0;
  if (g_hStochM1 == INVALID_HANDLE) return false;
  double b[1];
  const int sh = (shift < 0) ? 0 : shift;
  if (CopyBuffer(g_hStochM1, 0, sh, 1, b) != 1) return false;
  k = b[0];
  return true;
}

bool IsNewM1Bar() {
  datetime t[1];
  if (CopyTime(_Symbol, PERIOD_M1, 0, 1, t) != 1) return false;
  if (t[0] == g_lastM1BarTime) return false;
  g_lastM1BarTime = t[0];
  return true;
}

bool BuyConditionsMet() {
  const int esh = EmaShift();
  const int ssh = StochBarShift();

  double f1 = 0.0, s1 = 0.0, f5 = 0.0, s5 = 0.0, k = 0.0;
  if (!ReadEma(g_hEmaFastM1, esh, f1) || !ReadEma(g_hEmaSlowM1, esh, s1)) return false;
  if (!ReadEma(g_hEmaFastM5, esh, f5) || !ReadEma(g_hEmaSlowM5, esh, s5)) return false;
  if (!GetStochMainK(ssh, k)) return false;

  return (f5 > s5 && f1 > s1 && k < (double)StochBuyMaxLevel);
}

bool SellConditionsMet() {
  const int esh = EmaShift();
  const int ssh = StochBarShift();

  double f1 = 0.0, s1 = 0.0, f5 = 0.0, s5 = 0.0, k = 0.0;
  if (!ReadEma(g_hEmaFastM1, esh, f1) || !ReadEma(g_hEmaSlowM1, esh, s1)) return false;
  if (!ReadEma(g_hEmaFastM5, esh, f5) || !ReadEma(g_hEmaSlowM5, esh, s5)) return false;
  if (!GetStochMainK(ssh, k)) return false;

  return (f5 < s5 && f1 < s1 && k > (double)StochSellMinLevel);
}

void DispatchNotification(const string title, const string body) {
  const string msg = title + " | " + _Symbol + " — " + body;
  Print("[NotiEA] ", msg);
  if (UseTerminalAlert) Alert(msg);
  if (UsePushNotification) {
    if (!SendNotification(msg))
      Print("[NotiEA] SendNotification failed err=", GetLastError());
  }
}

void CheckAndNotify() {
  const bool buyOk = BuyConditionsMet();
  const bool sellOk = SellConditionsMet();

  if (!buyOk) g_buyCanAlert = true;
  if (!sellOk) g_sellCanAlert = true;

  if (buyOk && g_buyCanAlert) {
    double k = 0.0;
    GetStochMainK(StochBarShift(), k);
    DispatchNotification("BUY signal",
      "M5&M1 EMA50>200, M1 Stoch%K=" + DoubleToString(k, 1) +
      " < " + IntegerToString(StochBuyMaxLevel));
    g_buyCanAlert = false;
  }

  if (sellOk && g_sellCanAlert) {
    double k = 0.0;
    GetStochMainK(StochBarShift(), k);
    DispatchNotification("SELL signal",
      "M5&M1 EMA50<200, M1 Stoch%K=" + DoubleToString(k, 1) +
      " > " + IntegerToString(StochSellMinLevel));
    g_sellCanAlert = false;
  }
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  g_hEmaFastM1 = iMA(_Symbol, PERIOD_M1, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaSlowM1 = iMA(_Symbol, PERIOD_M1, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaFastM5 = iMA(_Symbol, PERIOD_M5, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hEmaSlowM5 = iMA(_Symbol, PERIOD_M5, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_hStochM1 = iStochastic(_Symbol, PERIOD_M1, StochKPeriod, StochDPeriod, StochSlowing,
                           MODE_SMA, STO_LOWHIGH);

  if (g_hEmaFastM1 == INVALID_HANDLE || g_hEmaSlowM1 == INVALID_HANDLE ||
      g_hEmaFastM5 == INVALID_HANDLE || g_hEmaSlowM5 == INVALID_HANDLE ||
      g_hStochM1 == INVALID_HANDLE) {
    Print("[NotiEA] Indicator init failed.");
    return INIT_FAILED;
  }

  datetime t[1];
  if (CopyTime(_Symbol, PERIOD_M1, 0, 1, t) == 1) g_lastM1BarTime = t[0];

  Print("[NotiEA] Ready. BUY: M5&M1 EMA bull + M1 Stoch<", StochBuyMaxLevel,
        "; SELL: EMA bear + Stoch>", StochSellMinLevel);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_hEmaFastM1 != INVALID_HANDLE) IndicatorRelease(g_hEmaFastM1);
  if (g_hEmaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowM1);
  if (g_hEmaFastM5 != INVALID_HANDLE) IndicatorRelease(g_hEmaFastM5);
  if (g_hEmaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowM5);
  if (g_hStochM1 != INVALID_HANDLE) IndicatorRelease(g_hStochM1);
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  if (CheckOnNewM1BarOnly) {
    if (!IsNewM1Bar()) return;
  }
  CheckAndNotify();
}
