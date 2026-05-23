//+------------------------------------------------------------------+
//|                                                AutoSwingEntry.mq5 |
//|                                                                  |
//| Auto entry bot — designed to run WITH ManualSwingSLTP on chart.  |
//| Opens market BUY/SELL (magic=0) when EMA trend allows;           |
//| ManualSwingSLTP then sets swing SL, grid, BE, basket stop, etc.    |
//|                                                                  |
//| Trend (same idea as ManualSwingSLTP v1.14):                      |
//|   BUY  if M1 OR M5 has EMA fast > EMA slow (when TF enabled)     |
//|   SELL if M1 OR M5 has EMA fast < EMA slow                       |
//|                                                                  |
//| Entry: on new bar of EntryTF, one side at a time, only if flat   |
//| on that side (no open BUY/SELL positions on this symbol).        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Auto EMA trend entries (magic 0) for ManualSwingSLTP manager."

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input double Lots                   = 0.01;
input int    SlippagePoints         = 20;
input int    MaxSpreadPoints        = 0;      // 0 = off

input bool   EnableAutoBuy          = true;
input bool   EnableAutoSell         = true;
input ENUM_TIMEFRAMES EntryTF       = PERIOD_M5; // new-bar signal TF
input bool   UseClosedBar           = true;    // trend read on last closed bar

input bool   UseTrendFilter         = true;
input bool   TrendFilterUseM1       = true;
input bool   TrendFilterUseM5       = true;
input int    TrendEMAFastPeriod     = 50;
input int    TrendEMASlowPeriod     = 200;
input int    TrendEMAShift          = 1;       // 1 = last closed bar on each TF

input int    MinSecondsBetweenEntries = 60;    // cooldown after an open on same side
input bool   AlertOnEntry           = true;

//--------------------------- Globals --------------------------------
CTrade trade;

int g_hTrendEmaFastM1 = INVALID_HANDLE;
int g_hTrendEmaSlowM1 = INVALID_HANDLE;
int g_hTrendEmaFastM5 = INVALID_HANDLE;
int g_hTrendEmaSlowM5 = INVALID_HANDLE;

datetime g_lastEntryBarTime = 0;
datetime g_lastBuyOpenTime  = 0;
datetime g_lastSellOpenTime = 0;

//--------------------------- Helpers --------------------------------
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }

double NormalizeVolumeLocal(const double lotsIn) {
  double lots = lotsIn;
  const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  const double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  const double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step > 0.0) lots = MathFloor(lots / step) * step;
  if (lots < minv) lots = minv;
  if (maxv > 0.0 && lots > maxv) lots = maxv;
  return NormalizeDouble(lots, 2);
}

bool SpreadOK() {
  if (MaxSpreadPoints <= 0) return true;
  const long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  return (sp > 0 && sp <= MaxSpreadPoints);
}

bool GetTrendEMAsFromHandles(const int hFast, const int hSlow,
                             const int shift, double &emaFast, double &emaSlow) {
  emaFast = 0.0;
  emaSlow = 0.0;
  if (hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return false;
  const int sh = (shift < 0) ? 0 : shift;
  double bf[1], bs[1];
  if (CopyBuffer(hFast, 0, sh, 1, bf) != 1) return false;
  if (CopyBuffer(hSlow, 0, sh, 1, bs) != 1) return false;
  emaFast = bf[0];
  emaSlow = bs[0];
  return (emaFast > 0.0 && emaSlow > 0.0);
}

int TrendReadShift() {
  if (!UseClosedBar) return 0;
  return (TrendEMAShift < 0) ? 0 : TrendEMAShift;
}

bool TrendAllowsBuy() {
  if (!UseTrendFilter) return true;
  if (!TrendFilterUseM1 && !TrendFilterUseM5) return true;

  const int sh = TrendReadShift();
  bool checked = false;
  bool allowed = false;

  if (TrendFilterUseM1) {
    double ef = 0.0, es = 0.0;
    if (GetTrendEMAsFromHandles(g_hTrendEmaFastM1, g_hTrendEmaSlowM1, sh, ef, es)) {
      checked = true;
      if (ef > es) allowed = true;
    }
  }
  if (TrendFilterUseM5) {
    double ef = 0.0, es = 0.0;
    if (GetTrendEMAsFromHandles(g_hTrendEmaFastM5, g_hTrendEmaSlowM5, sh, ef, es)) {
      checked = true;
      if (ef > es) allowed = true;
    }
  }
  if (!checked) return true;
  return allowed;
}

bool TrendAllowsSell() {
  if (!UseTrendFilter) return true;
  if (!TrendFilterUseM1 && !TrendFilterUseM5) return true;

  const int sh = TrendReadShift();
  bool checked = false;
  bool allowed = false;

  if (TrendFilterUseM1) {
    double ef = 0.0, es = 0.0;
    if (GetTrendEMAsFromHandles(g_hTrendEmaFastM1, g_hTrendEmaSlowM1, sh, ef, es)) {
      checked = true;
      if (ef < es) allowed = true;
    }
  }
  if (TrendFilterUseM5) {
    double ef = 0.0, es = 0.0;
    if (GetTrendEMAsFromHandles(g_hTrendEmaFastM5, g_hTrendEmaSlowM5, sh, ef, es)) {
      checked = true;
      if (ef < es) allowed = true;
    }
  }
  if (!checked) return true;
  return allowed;
}

bool HasOpenSidePosition(const ENUM_POSITION_TYPE side) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == side)
      return true;
  }
  return false;
}

bool IsNewEntryBar() {
  datetime t[1];
  if (CopyTime(_Symbol, EntryTF, 0, 1, t) != 1) return false;
  if (t[0] == g_lastEntryBarTime) return false;
  g_lastEntryBarTime = t[0];
  return true;
}

bool CooldownOK(const bool isBuy) {
  if (MinSecondsBetweenEntries <= 0) return true;
  const datetime last = isBuy ? g_lastBuyOpenTime : g_lastSellOpenTime;
  if (last <= 0) return true;
  return (TimeCurrent() - last >= MinSecondsBetweenEntries);
}

bool OpenMarket(const bool isBuy) {
  if (!SpreadOK()) return false;

  const double lot = NormalizeVolumeLocal(Lots);
  if (lot <= 0.0) return false;

  trade.SetExpertMagicNumber(0);
  trade.SetDeviationInPoints(SlippagePoints);

  bool ok = false;
  if (isBuy)
    ok = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "AutoSwingEntry BUY");
  else
    ok = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "AutoSwingEntry SELL");

  if (!ok) {
    Print("[AutoSwingEntry] open failed side=", isBuy ? "BUY" : "SELL",
          " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
    return false;
  }

  const datetime now = TimeCurrent();
  if (isBuy) g_lastBuyOpenTime = now;
  else g_lastSellOpenTime = now;

  const string msg = "[AutoSwingEntry] Opened " + (isBuy ? "BUY" : "SELL") +
                     " lot=" + DoubleToString(lot, 2);
  Print(msg);
  if (AlertOnEntry) Alert(msg);
  return true;
}

void TryAutoEntries() {
  if (!IsNewEntryBar()) return;

  if (EnableAutoBuy && !HasOpenSidePosition(POSITION_TYPE_BUY) &&
      TrendAllowsBuy() && CooldownOK(true)) {
    OpenMarket(true);
  }

  if (EnableAutoSell && !HasOpenSidePosition(POSITION_TYPE_SELL) &&
      TrendAllowsSell() && CooldownOK(false)) {
    OpenMarket(false);
  }
}

//--------------------------- MT5 Events ------------------------------
int OnInit() {
  trade.SetExpertMagicNumber(0);
  trade.SetDeviationInPoints(SlippagePoints);
  const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
  if ((fm & SYMBOL_FILLING_IOC) != 0)
    trade.SetTypeFilling(ORDER_FILLING_IOC);
  else if ((fm & SYMBOL_FILLING_FOK) != 0)
    trade.SetTypeFilling(ORDER_FILLING_FOK);
  else
    trade.SetTypeFilling(ORDER_FILLING_RETURN);

  if (UseTrendFilter) {
    if (TrendFilterUseM1) {
      g_hTrendEmaFastM1 = iMA(_Symbol, PERIOD_M1, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_hTrendEmaSlowM1 = iMA(_Symbol, PERIOD_M1, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
    }
    if (TrendFilterUseM5) {
      g_hTrendEmaFastM5 = iMA(_Symbol, PERIOD_M5, TrendEMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_hTrendEmaSlowM5 = iMA(_Symbol, PERIOD_M5, TrendEMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
    }
  }

  Print("[AutoSwingEntry] Ready. Run ManualSwingSLTP on same chart to manage SL/grid/BE.");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_hTrendEmaFastM1 != INVALID_HANDLE) IndicatorRelease(g_hTrendEmaFastM1);
  if (g_hTrendEmaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_hTrendEmaSlowM1);
  if (g_hTrendEmaFastM5 != INVALID_HANDLE) IndicatorRelease(g_hTrendEmaFastM5);
  if (g_hTrendEmaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_hTrendEmaSlowM5);
}

void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);
  TryAutoEntries();
}
