//+------------------------------------------------------------------+
//| EMA9/EMA50 Crossover Strategy (M1, Swing SL, TP 500 points)     |
//| BUY:  EMA9 crosses ABOVE EMA50 -> SL at swing low(50 bars)       |
//| SELL: EMA9 crosses BELOW EMA50 -> SL at swing high(50 bars)      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpTF   = PERIOD_M1;
input double          Lots    = 0.10;
input int             TP_Points = 500;
input int             EMA_Fast  = 9;
input int             EMA_Slow  = 50;
input ulong           Magic     = 123456;
input int             SwingBars = 50;   // swing window for SL
input int             MinExtraPts = 10; // extra buffer over stop level

CTrade trade;
int      hEMA_Fast, hEMA_Slow;
datetime lastBarTime = 0;

// Control flags
bool canTrade = true;     // if false, prevents placing a new order
datetime lastTradeBar = 0; // remember the bar when we last placed a trade

// swing caches (updated each new bar)
double lastLow  = 0.0;
double lastHigh = 0.0;

bool IsNewBar()
{
   datetime t[2];
   if(CopyTime(_Symbol, InpTF, 0, 2, t) < 2) return false;
   if(t[0] != lastBarTime) { lastBarTime = t[0]; return true; }
   return false;
}

bool CopyEMAs(double &fast_curr, double &slow_curr, double &fast_prev, double &slow_prev)
{
   if(hEMA_Fast==INVALID_HANDLE || hEMA_Slow==INVALID_HANDLE) return false;
   double f[2], s[2];
   // Read bars #0 and #1 so we have the "current closed bar" values on new bar event
   // But since we act only on new bars, requesting 1..2 (shift 1) also works
   if(CopyBuffer(hEMA_Fast,0,1,2,f)!=2) return false; // bars #1,#2 (previous closed bar and one before)
   if(CopyBuffer(hEMA_Slow,0,1,2,s)!=2) return false;
   fast_curr = f[0];
   fast_prev = f[1];
   slow_curr = s[0];
   slow_prev = s[1];
   return true;
}

void UpdateSwing()
{
   int sb = MathMax(2, SwingBars);

   // Use dynamic arrays so any SwingBars value works
   double lows[];
   double highs[];
   ArrayResize(lows, sb);
   ArrayResize(highs, sb);

   // Copy from shift=1 to exclude the currently forming bar
   if(CopyLow(_Symbol, InpTF, 1, sb, lows)==sb)
      lastLow = lows[ArrayMinimum(lows,0,sb)];
   if(CopyHigh(_Symbol, InpTF, 1, sb, highs)==sb)
      lastHigh = highs[ArrayMaximum(highs,0,sb)];
}

bool PriceBoundsOK(ENUM_ORDER_TYPE type, double entry, double &sl, double &tp)
{
   int digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = _Point;

   long stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLv  = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = (stopLevel>0 ? stopLevel : 0) * point;
   double freeze  = (freezeLv>0  ? freezeLv  : 0) * point;
   (void)freeze; // (not used, but fetched for completeness)

   // add small safety buffer
   double extra = (MinExtraPts>0 ? MinExtraPts : 0) * point;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type==ORDER_TYPE_BUY)
   {
      // Ensure SL is below Bid by at least minDist+extra
      if(sl<=0 || (bid - sl) < (minDist+extra))
         sl = bid - (minDist + extra);
      // Ensure TP is above Ask by at least minDist+extra
      if(tp<=0 || (tp - ask) < (minDist+extra))
         tp = ask + (minDist + extra);
   }
   else // SELL
   {
      // Ensure SL is above Ask by at least minDist+extra
      if(sl<=0 || (sl - ask) < (minDist+extra))
         sl = ask + (minDist + extra);
      // Ensure TP is below Bid by at least minDist+extra
      if(tp<=0 || (bid - tp) < (minDist+extra))
         tp = bid - (minDist + extra);
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // final sanity
   if(type==ORDER_TYPE_BUY  && !(sl<entry && tp>entry)) return false;
   if(type==ORDER_TYPE_SELL && !(sl>entry && tp<entry)) return false;
   return true;
}

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);

   hEMA_Fast = iMA(_Symbol, InpTF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol, InpTF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA_Fast==INVALID_HANDLE || hEMA_Slow==INVALID_HANDLE)
   { Print("Failed to create EMA handles"); return INIT_FAILED; }

   // prime bar time & swing
   datetime t[1];
   if(CopyTime(_Symbol, InpTF, 0, 1, t)==1) lastBarTime=t[0];
   UpdateSwing();

   Print("EMA9/50 Crossover EA (M1) initialized.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA_Fast!=INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow!=INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
}

// Optional: detect position close more robustly and immediately reset canTrade
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest      &request,
                        const MqlTradeResult       &result)
{
   // If a position on this symbol was closed (by TP/SL/manual), re-enable trading
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(HistorySelect(0, TimeCurrent()))
      {
         long   deal_type   = (long)HistoryDealGetInteger(deal, DEAL_TYPE);
         string deal_symbol = (string)HistoryDealGetString(deal, DEAL_SYMBOL);
         if(deal_symbol==_Symbol && (deal_type==DEAL_TP || deal_type==DEAL_SL || deal_type==DEAL_CLOSE))
         {
            canTrade = true;
         }
      }
   }
}

void OnTick()
{
   // If a position exists on this symbol, do nothing until it closes.
   if(PositionSelect(_Symbol))
      return;

   // If we reach here, there is no open position.
   // Ensure we are allowed to trade again (no waiting for opposite cross).
   if(!canTrade)
      canTrade = true;

   // only act on new bar to avoid duplicate signals
   if(!IsNewBar()) return;

   // update swing once per bar
   UpdateSwing();

   // read EMA values for crossover detection
   double f_cur,s_cur,f_prev,s_prev;
   if(!CopyEMAs(f_cur,s_cur,f_prev,s_prev)) return;

   // STRICT cross definitions (fixed):
   bool bullishCross = (f_prev < s_prev) && (f_cur > s_cur); // EMA9 crosses above EMA50
   bool bearishCross = (f_prev > s_prev) && (f_cur < s_cur); // EMA9 crosses below EMA50

   if(!canTrade) return;

   int digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = _Point;

   datetime thisBar = lastBarTime; // new bar time

   if(bullishCross)
   {
      if(lastLow<=0) { Print("Skip BUY: lastLow not ready"); return; }

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = lastLow - 5*point;           // small buffer under swing
      double tp  = ask + TP_Points*point;

      if(!PriceBoundsOK(ORDER_TYPE_BUY, ask, sl, tp))
      { Print("Skip BUY: bounds invalid"); return; }

      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "EMA9>EMA50 Cross"))
      {
         Print("✅ BUY: ", DoubleToString(ask,digits), " SL=", DoubleToString(sl,digits), " TP=", DoubleToString(tp,digits));
         canTrade = false;          // lock until position closes (OnTick will see PositionSelect==true anyway)
         lastTradeBar = thisBar;    // remember when we traded
      }
      else
      {
         Print("❌ BUY failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
   else if(bearishCross)
   {
      if(lastHigh<=0) { Print("Skip SELL: lastHigh not ready"); return; }

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = lastHigh + 5*point;          // small buffer above swing
      double tp  = bid - TP_Points*point;

      if(!PriceBoundsOK(ORDER_TYPE_SELL, bid, sl, tp))
      { Print("Skip SELL: bounds invalid"); return; }

      if(trade.Sell(Lots, _Symbol, bid, sl, tp, "EMA9<EMA50 Cross"))
      {
         Print("✅ SELL: ", DoubleToString(bid,digits), " SL=", DoubleToString(sl,digits), " TP=", DoubleToString(tp,digits));
         canTrade = false;
         lastTradeBar = thisBar;
      }
      else
      {
         Print("❌ SELL failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
}
