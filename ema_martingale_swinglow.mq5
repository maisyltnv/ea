//+------------------------------------------------------------------+
//| ema_mtf_buy_swing_mg.mq5                                         |
//| Buy-only, linear martingale.                                     |
//| Entry: M5 & M1 EMA uptrend filter + (M1) break below swing-low   |
//|        while Stoch<=20, then %K crosses up through 20 -> BUY.    |
//+------------------------------------------------------------------+
#property version   "1.02"
#property strict

//=== Inputs =========================================================
input double LotSizeStart            = 0.01;      // starting lot
input double LotStep                 = 0.01;      // add after SL: 0.01,0.02,0.03...
input double LotMax                  = 5.0;       // safety cap

// EMA periods (both M1 & M5 use 14/26/50/100/200 as requested)
input int EMA14_Period               = 14;
input int EMA26_Period               = 26;
input int EMA50_Period               = 50;
input int EMA100_Period              = 100;
input int EMA200_Period              = 200;

input int Stoch_K                    = 9;
input int Stoch_D                    = 3;
input int Stoch_Slowing              = 3;

input int SwingBars                  = 30;        // bars back to find swing low (M1)
input int SL_Points                  = 500;       // SL in points
input int TP_Points                  = 1000;      // TP in points
input int Max_Daily_SL_Count         = 10;        // stop trading for the day after this many SLs
input int Magic_Number               = 123456;    // magic

//=== Globals: handles/buffers ======================================
int m1_ema14_h, m1_ema26_h, m1_ema50_h, m1_ema100_h, m1_ema200_h;
int m5_ema14_h, m5_ema26_h, m5_ema50_h, m5_ema100_h, m5_ema200_h;
int stoch_m1_h;

double m1_ema14_b[], m1_ema26_b[], m1_ema50_b[], m1_ema100_b[], m1_ema200_b[];
double m5_ema14_b[], m5_ema26_b[], m5_ema50_b[], m5_ema100_b[], m5_ema200_b[];
double stoch_k_b[], stoch_d_b[];

// Trading/day state
int       daily_sl_count      = 0;
datetime  last_trade_date     = 0;
bool      trading_allowed     = true;
double    current_lot_size    = 0.0;

// Break-then-cross state (M1)
bool      armed               = false;
datetime  armed_bar_time      = 0;

//--- helpers to keep your style
int MinStopDistancePoints()
{
  int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  int freeze     = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
  return MathMax(stop_level, freeze);
}

double ClampSLForBuy(double sl_price)
{
  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
  int    mdp = MinStopDistancePoints();
  double maxAllowedSL = bid - mdp * _Point; // for BUY, SL < Bid - stop level
  return MathMin(sl_price, maxAllowedSL);
}

//=== Init/Deinit ====================================================
int OnInit()
{
  current_lot_size = LotSizeStart;

  // M1 EMAs
  m1_ema14_h  = iMA(_Symbol, PERIOD_M1, EMA14_Period,  0, MODE_EMA, PRICE_CLOSE);
  m1_ema26_h  = iMA(_Symbol, PERIOD_M1, EMA26_Period,  0, MODE_EMA, PRICE_CLOSE);
  m1_ema50_h  = iMA(_Symbol, PERIOD_M1, EMA50_Period,  0, MODE_EMA, PRICE_CLOSE);
  m1_ema100_h = iMA(_Symbol, PERIOD_M1, EMA100_Period, 0, MODE_EMA, PRICE_CLOSE);
  m1_ema200_h = iMA(_Symbol, PERIOD_M1, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);

  // M5 EMAs
  m5_ema14_h  = iMA(_Symbol, PERIOD_M5, EMA14_Period,  0, MODE_EMA, PRICE_CLOSE);
  m5_ema26_h  = iMA(_Symbol, PERIOD_M5, EMA26_Period,  0, MODE_EMA, PRICE_CLOSE);
  m5_ema50_h  = iMA(_Symbol, PERIOD_M5, EMA50_Period,  0, MODE_EMA, PRICE_CLOSE);
  m5_ema100_h = iMA(_Symbol, PERIOD_M5, EMA100_Period, 0, MODE_EMA, PRICE_CLOSE);
  m5_ema200_h = iMA(_Symbol, PERIOD_M5, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);

  // Stochastic on M1
  stoch_m1_h  = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);

  if( m1_ema14_h==INVALID_HANDLE || m1_ema26_h==INVALID_HANDLE || m1_ema50_h==INVALID_HANDLE ||
      m1_ema100_h==INVALID_HANDLE || m1_ema200_h==INVALID_HANDLE ||
      m5_ema14_h==INVALID_HANDLE || m5_ema26_h==INVALID_HANDLE || m5_ema50_h==INVALID_HANDLE ||
      m5_ema100_h==INVALID_HANDLE || m5_ema200_h==INVALID_HANDLE || stoch_m1_h==INVALID_HANDLE )
  {
    Print("Error: failed to create indicator handles");
    return INIT_FAILED;
  }

  // series directions
  ArraySetAsSeries(m1_ema14_b,true);   ArraySetAsSeries(m1_ema26_b,true);
  ArraySetAsSeries(m1_ema50_b,true);   ArraySetAsSeries(m1_ema100_b,true);
  ArraySetAsSeries(m1_ema200_b,true);

  ArraySetAsSeries(m5_ema14_b,true);   ArraySetAsSeries(m5_ema26_b,true);
  ArraySetAsSeries(m5_ema50_b,true);   ArraySetAsSeries(m5_ema100_b,true);
  ArraySetAsSeries(m5_ema200_b,true);

  ArraySetAsSeries(stoch_k_b,true);    ArraySetAsSeries(stoch_d_b,true);

  Print("EA initialized.");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  if(m1_ema14_h!=INVALID_HANDLE)  IndicatorRelease(m1_ema14_h);
  if(m1_ema26_h!=INVALID_HANDLE)  IndicatorRelease(m1_ema26_h);
  if(m1_ema50_h!=INVALID_HANDLE)  IndicatorRelease(m1_ema50_h);
  if(m1_ema100_h!=INVALID_HANDLE) IndicatorRelease(m1_ema100_h);
  if(m1_ema200_h!=INVALID_HANDLE) IndicatorRelease(m1_ema200_h);

  if(m5_ema14_h!=INVALID_HANDLE)  IndicatorRelease(m5_ema14_h);
  if(m5_ema26_h!=INVALID_HANDLE)  IndicatorRelease(m5_ema26_h);
  if(m5_ema50_h!=INVALID_HANDLE)  IndicatorRelease(m5_ema50_h);
  if(m5_ema100_h!=INVALID_HANDLE) IndicatorRelease(m5_ema100_h);
  if(m5_ema200_h!=INVALID_HANDLE) IndicatorRelease(m5_ema200_h);

  if(stoch_m1_h!=INVALID_HANDLE)  IndicatorRelease(stoch_m1_h);
}

//=== Helpers to update buffers =====================================
bool UpdateEMA_M1()
{
  if(CopyBuffer(m1_ema14_h,0,0,1,m1_ema14_b) < 1) return false;
  if(CopyBuffer(m1_ema26_h,0,0,1,m1_ema26_b) < 1) return false;
  if(CopyBuffer(m1_ema50_h,0,0,1,m1_ema50_b) < 1) return false;
  if(CopyBuffer(m1_ema100_h,0,0,1,m1_ema100_b) < 1) return false;
  if(CopyBuffer(m1_ema200_h,0,0,1,m1_ema200_b) < 1) return false;
  return true;
}
bool UpdateEMA_M5()
{
  if(CopyBuffer(m5_ema14_h,0,0,1,m5_ema14_b) < 1) return false;
  if(CopyBuffer(m5_ema26_h,0,0,1,m5_ema26_b) < 1) return false;
  if(CopyBuffer(m5_ema50_h,0,0,1,m5_ema50_b) < 1) return false;
  if(CopyBuffer(m5_ema100_h,0,0,1,m5_ema100_b) < 1) return false;
  if(CopyBuffer(m5_ema200_h,0,0,1,m5_ema200_b) < 1) return false;
  return true;
}
bool UpdateStoch_M1()
{
  // buffer 0 = %K, 1 = %D
  if(CopyBuffer(stoch_m1_h,0,0,2,stoch_k_b) != 2) return false;
  if(CopyBuffer(stoch_m1_h,1,0,2,stoch_d_b) != 2) return false;
  return true;
}

bool EMA_Ascending_M1()
{
  double e14=m1_ema14_b[0], e26=m1_ema26_b[0], e50=m1_ema50_b[0], e100=m1_ema100_b[0], e200=m1_ema200_b[0];
  return (e14>e26 && e26>e50 && e50>e100 && e100>e200);
}
bool EMA_Ascending_M5()
{
  double e14=m5_ema14_b[0], e26=m5_ema26_b[0], e50=m5_ema50_b[0], e100=m5_ema100_b[0], e200=m5_ema200_b[0];
  return (e14>e26 && e26>e50 && e50>e100 && e100>e200);
}

double GetSwingLow_M1()
{
  if(SwingBars<3) return 0.0;
  double lows[];
  ArraySetAsSeries(lows,true);
  if(CopyLow(_Symbol, PERIOD_M1, 1, SwingBars, lows) < SwingBars) return 0.0;
  int idx = ArrayMinimum(lows,0,SwingBars);
  return lows[idx];
}

//=== Day reset ======================================================
void CheckNewDay()
{
  MqlDateTime dt;
  TimeToStruct(TimeCurrent(), dt);
  datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
  if(today != last_trade_date)
  {
    last_trade_date = today;
    daily_sl_count  = 0;
    trading_allowed = true;
    Print("New day: trading reset.");
  }
}

//=== Position mgmt (no trailing; TP/SL handle exits) ===============
void ManagePosition()
{
  // nothing—the position is left to TP/SL
}

//=== Main ===========================================================
void OnTick()
{
  CheckNewDay();

  if(!trading_allowed) return;

  // One position per symbol (for this EA)
  if(PositionSelect(_Symbol))
  {
    if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
      ManagePosition();
    return;
  }

  // Update all inputs
  if(!UpdateEMA_M1() || !UpdateEMA_M5() || !UpdateStoch_M1()) return;

  // 1) Trend filters (M5 & M1)
  if(!EMA_Ascending_M5()) return;
  if(!EMA_Ascending_M1()) return;

  // 2) Swing low & break condition (M1)
  double swingLow = GetSwingLow_M1();
  if(swingLow<=0.0) return;

  double lowBuf[1];
  if(CopyLow(_Symbol, PERIOD_M1, 0, 1, lowBuf)!=1) return;
  double low0 = lowBuf[0];

  double k_curr = stoch_k_b[0];
  double k_prev = stoch_k_b[1];

  // Arm when price breaks below swing low while Stoch<=20
  if(!armed && low0 < swingLow && k_curr <= 20.0)
  {
    armed = true;
    armed_bar_time = iTime(_Symbol, PERIOD_M1, 0);
  }

  // 3) Trigger: %K crosses up through 20 AFTER being armed
  bool crossUp20 = (k_prev <= 20.0 && k_curr > 20.0);

  if(armed && crossUp20)
  {
    PlaceBuy();
    armed = false; // reset after attempt
  }
}

//=== Order placement ===============================================
void PlaceBuy()
{
  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  // SL/TP
  double sl = ask - SL_Points*_Point;
  sl = ClampSLForBuy(sl);
  double tp = ask + TP_Points*_Point;

  // lot (capped)
  double lot = MathMin(MathMax(current_lot_size, LotSizeStart), LotMax);

  MqlTradeRequest req={};
  MqlTradeResult  res={};

  req.action    = TRADE_ACTION_DEAL;
  req.symbol    = _Symbol;
  req.volume    = lot;
  req.type      = ORDER_TYPE_BUY;
  req.price     = ask;
  req.sl        = sl;
  req.tp        = tp;
  req.deviation = 10;
  req.magic     = Magic_Number;
  req.comment   = "EMA_MTF_Buy_Swing_MG";

  if(OrderSend(req,res))
    Print("BUY opened. lot=", lot, " sl=", sl, " tp=", tp, " order=", res.order);
  else
    Print("OrderSend BUY failed. retcode=", res.retcode);
}

//=== Trade events: update martingale & day counters =================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
  if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
  if(!HistoryDealSelect(trans.deal)) return;

  // only our EA
  if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != Magic_Number) return;

  ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  if(entry != DEAL_ENTRY_OUT) return; // only when a position closes

  double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);

  if(profit < 0.0) // SL hit
  {
    daily_sl_count++;
    current_lot_size = MathMin(current_lot_size + LotStep, LotMax); // linear martingale
    Print("SL hit. Daily SLs=", daily_sl_count, " next lot=", current_lot_size);

    if(daily_sl_count >= Max_Daily_SL_Count)
    {
      trading_allowed = false;
      Print("Trading paused for today (SL limit).");
    }
  }
  else if(profit > 0.0) // TP hit
  {
    current_lot_size = LotSizeStart; // reset
    Print("TP hit. Lot reset to ", current_lot_size);
  }
}
