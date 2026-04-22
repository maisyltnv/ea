//+------------------------------------------------------------------+
//|                                                     5EMA.mq5     |
//|  Buy-only: M1 trend start entry with EMA stack + MACD filter.    |
//|  Entry: Price > EMA14 > EMA26 > EMA50 and MACD(main) > threshold |
//|  SL: fixed points. When profit >= TrailStartPoints:              |
//|      trail SL along EMA50 (updates upward only).                 |
//|  Re-entry rule: after a completed cycle, EA must see price go     |
//|      below EMA50 (reset) before allowing a new entry.            |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

//--------------------------- Inputs --------------------------------
input double Lots = 0.01;
input int SlippagePoints = 20;
input int MagicNumber = 505014;

// Signal timeframe (fixed to M1 per requirement)
input ENUM_TIMEFRAMES SignalTF = PERIOD_M1;
input bool UseClosedCandle = true; // true=shift 1, false=shift 0

// EMAs
input int EmaFastPeriod = 14;
input int EmaMidPeriod = 26;
input int EmaSlowPeriod = 50; // used for reset + trailing

// MACD
input int MacdFastEMA = 12;
input int MacdSlowEMA = 26;
input int MacdSignalSMA = 9;
input double MacdMainMin = 3.0; // enter only when MACD(main) > this

// Risk/Management
input int SLPoints = 1000;           // initial SL distance in points
input int TrailStartPoints = 2000;   // when profit >= this, start trailing SL on EMA50

//--------------------------- Globals --------------------------------
CTrade trade;

int g_emaFast = INVALID_HANDLE;
int g_emaMid = INVALID_HANDLE;
int g_emaSlow = INVALID_HANDLE;
int g_macd = INVALID_HANDLE;

bool g_armedForEntry = true; // becomes true only after reset; controls "trend start only"

//--------------------------- Helpers --------------------------------
int CandleShift() { return UseClosedCandle ? 1 : 0; }

bool ReadBuffer1(const int handle, const int bufferIdx, const int shift, double &outVal) {
  if (handle == INVALID_HANDLE) return false;
  double tmp[1];
  if (CopyBuffer(handle, bufferIdx, shift, 1, tmp) != 1) return false;
  outVal = tmp[0];
  return true;
}

bool GetEmaValues(double &emaFast, double &emaMid, double &emaSlow) {
  const int sh = CandleShift();
  if (!ReadBuffer1(g_emaFast, 0, sh, emaFast)) return false;
  if (!ReadBuffer1(g_emaMid, 0, sh, emaMid)) return false;
  if (!ReadBuffer1(g_emaSlow, 0, sh, emaSlow)) return false;
  return true;
}

bool GetMacdMain(double &macdMain) {
  const int sh = CandleShift();
  // MACD buffer 0 = main line
  return ReadBuffer1(g_macd, 0, sh, macdMain);
}

double PointValue() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int DigitsCount() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double NormalizeLot(double lots) {
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if (step > 0.0) lots = MathRound(lots / step) * step;
  if (lots < minv) lots = minv;
  if (maxv > 0.0 && lots > maxv) lots = maxv;
  return lots;
}

bool HasOpenBuyPosition(ulong &ticketOut) {
  ticketOut = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong tk = PositionGetTicket(i);
    if (!PositionSelectByTicket(tk)) continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
    ticketOut = tk;
    return true;
  }
  return false;
}

bool IsBullCondition(double price, double emaFast, double emaMid, double emaSlow, double macdMain) {
  return (price > emaFast && emaFast > emaMid && emaMid > emaSlow && macdMain > MacdMainMin);
}

bool IsResetCondition(double price, double emaSlow) {
  // must see price below EMA50 before allowing the next "trend start" entry
  return (price < emaSlow);
}

// Move SL upward to EMA50 when trailing is active
void TrailStopToEma50(const ulong ticket, const double emaSlow) {
  if (ticket == 0 || !PositionSelectByTicket(ticket)) return;

  const double pt = PointValue();
  if (pt <= 0.0) return;

  const int digits = DigitsCount();
  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  double curSL = PositionGetDouble(POSITION_SL);
  double curTP = PositionGetDouble(POSITION_TP);

  // Desired SL at EMA50
  double newSL = NormalizeDouble(emaSlow, digits);

  // Only move SL up, never down (for buys)
  if (curSL > 0.0 && newSL <= curSL) return;

  // Respect broker minimal stop distance
  const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  const double minDist = stopsLevel * pt;
  if (minDist > 0.0 && (bid - newSL) < minDist) return;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  trade.PositionModify(ticket, newSL, curTP);
}

//--------------------------- MT5 Events -----------------------------
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  g_emaFast = iMA(_Symbol, SignalTF, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_emaMid  = iMA(_Symbol, SignalTF, EmaMidPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_emaSlow = iMA(_Symbol, SignalTF, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
  g_macd    = iMACD(_Symbol, SignalTF, MacdFastEMA, MacdSlowEMA, MacdSignalSMA, PRICE_CLOSE);

  if (g_emaFast == INVALID_HANDLE || g_emaMid == INVALID_HANDLE || g_emaSlow == INVALID_HANDLE || g_macd == INVALID_HANDLE) {
    Print("5EMA init failed: indicator handle invalid. Error=", GetLastError());
    return INIT_FAILED;
  }

  g_armedForEntry = true;
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
  if (g_emaFast != INVALID_HANDLE) IndicatorRelease(g_emaFast);
  if (g_emaMid  != INVALID_HANDLE) IndicatorRelease(g_emaMid);
  if (g_emaSlow != INVALID_HANDLE) IndicatorRelease(g_emaSlow);
  if (g_macd    != INVALID_HANDLE) IndicatorRelease(g_macd);
}

void OnTick() {
  // Ensure symbol selected
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT)) SymbolSelect(_Symbol, true);

  double emaFast = 0.0, emaMid = 0.0, emaSlow = 0.0;
  double macdMain = 0.0;
  if (!GetEmaValues(emaFast, emaMid, emaSlow)) return;
  if (!GetMacdMain(macdMain)) return;

  const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  const double priceForSignal = (UseClosedCandle ? iClose(_Symbol, SignalTF, 1) : ask);

  // Reset arming when price goes below EMA50
  if (IsResetCondition(priceForSignal, emaSlow))
    g_armedForEntry = true;

  // If we already have a position, manage trailing and do not open another
  ulong posTk = 0;
  if (HasOpenBuyPosition(posTk)) {
    // Trailing starts after profit reaches TrailStartPoints
    if (PositionSelectByTicket(posTk)) {
      const double pt = PointValue();
      if (pt > 0.0) {
        const double open = PositionGetDouble(POSITION_PRICE_OPEN);
        const double profitPts = (bid - open) / pt;
        if (profitPts >= (double)TrailStartPoints) {
          TrailStopToEma50(posTk, emaSlow);
        }
      }
    }
    return;
  }

  // No open buy position: check entry ("trend start only")
  if (!g_armedForEntry) return;

  if (IsBullCondition(priceForSignal, emaFast, emaMid, emaSlow, macdMain)) {
    const double pt = PointValue();
    if (pt <= 0.0) return;

    const int digits = DigitsCount();
    double slPrice = 0.0;
    if (SLPoints > 0) slPrice = NormalizeDouble(ask - SLPoints * pt, digits);

    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(SlippagePoints);

    const double lots = NormalizeLot(Lots);
    if (trade.Buy(lots, _Symbol, 0.0, slPrice, 0.0)) {
      g_armedForEntry = false; // disarm until reset happens again
      Print("5EMA BUY opened. price=", DoubleToString(ask, digits),
            " SL=", DoubleToString(slPrice, digits),
            " MACD=", DoubleToString(macdMain, 4),
            " EMA14/26/50=", DoubleToString(emaFast, digits), "/",
            DoubleToString(emaMid, digits), "/", DoubleToString(emaSlow, digits));
    } else {
      Print("5EMA BUY failed. Error=", GetLastError());
    }
  }
}

