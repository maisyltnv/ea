//+------------------------------------------------------------------+
//|                       ema_multi_timeframe_buy_only.mq5           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.01"   // <- bumped

//--- Input parameters
input double LotSize = 0.01;                    // Lot size
input int M1_EMA14_Period = 14;                 // M1 EMA 14 period
input int M1_EMA26_Period = 26;                 // M1 EMA 26 period
input int M1_EMA50_Period = 50;                 // M1 EMA 50 period
input int M1_EMA100_Period = 100;               // M1 EMA 100 period
input int M1_EMA200_Period = 200;               // M1 EMA 200 period
input int M5_EMA50_Period = 50;                 // M5 EMA 50 period
input int M5_EMA100_Period = 100;               // M5 EMA 100 period
input int M5_EMA200_Period = 200;               // M5 EMA 200 period
input int SwingBars = 30;                       // Bars to look back for swing low
input int SL_Buffer_Points = 100;               // Additional points for SL
input int Profit_500_Points = 500;              // Threshold #1 (points)
input int Profit_1000_Points = 1000;            // Threshold #2 (points -> enable trailing)
input int SL_Move_Buffer = 20;                  // Move-to-BE buffer (points)
input int Magic_Number = 123456;                // Magic

//--- Global handles/buffers
int m1_ema14_handle, m1_ema26_handle, m1_ema50_handle, m1_ema100_handle, m1_ema200_handle;
int m5_ema50_handle, m5_ema100_handle, m5_ema200_handle;

double m1_ema14_buffer[], m1_ema26_buffer[], m1_ema50_buffer[], m1_ema100_buffer[], m1_ema200_buffer[];
double m5_ema50_buffer[], m5_ema100_buffer[], m5_ema200_buffer[];

bool trailing_stop_active = false;
double entry_price = 0.0;

//-------------------------- helpers --------------------------------
bool UpdateEMA_M1()
{
   if(CopyBuffer(m1_ema14_handle,0,0,1,m1_ema14_buffer) < 1) return false;
   if(CopyBuffer(m1_ema26_handle,0,0,1,m1_ema26_buffer) < 1) return false;
   if(CopyBuffer(m1_ema50_handle,0,0,1,m1_ema50_buffer) < 1) return false;
   if(CopyBuffer(m1_ema100_handle,0,0,1,m1_ema100_buffer) < 1) return false;
   if(CopyBuffer(m1_ema200_handle,0,0,1,m1_ema200_buffer) < 1) return false;
   return true;
}
bool UpdateEMA_M5()
{
   if(CopyBuffer(m5_ema50_handle,0,0,1,m5_ema50_buffer) < 1) return false;
   if(CopyBuffer(m5_ema100_handle,0,0,1,m5_ema100_buffer) < 1) return false;
   if(CopyBuffer(m5_ema200_handle,0,0,1,m5_ema200_buffer) < 1) return false;
   return true;
}
int ProfitPointsForBuy(double open_price)
{
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return (int)MathFloor( (bid - open_price) / _Point );
}
int MinStopDistancePoints() // broker stop/freeze guard
{
   int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze     = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stop_level, freeze);
}
double ClampSLForBuy(double desired_sl)
{
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int minDist = MinStopDistancePoints();
   double maxAllowedSL = bid - minDist * _Point; // for BUY SL must be < Bid - stop level
   return MathMin(desired_sl, maxAllowedSL);
}
//-------------------------------------------------------------------

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // M1
   m1_ema14_handle = iMA(_Symbol, PERIOD_M1, M1_EMA14_Period, 0, MODE_EMA, PRICE_CLOSE);
   m1_ema26_handle = iMA(_Symbol, PERIOD_M1, M1_EMA26_Period, 0, MODE_EMA, PRICE_CLOSE);
   m1_ema50_handle = iMA(_Symbol, PERIOD_M1, M1_EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   m1_ema100_handle= iMA(_Symbol, PERIOD_M1, M1_EMA100_Period,0, MODE_EMA, PRICE_CLOSE);
   m1_ema200_handle= iMA(_Symbol, PERIOD_M1, M1_EMA200_Period,0, MODE_EMA, PRICE_CLOSE);
   // M5
   m5_ema50_handle = iMA(_Symbol, PERIOD_M5, M5_EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   m5_ema100_handle= iMA(_Symbol, PERIOD_M5, M5_EMA100_Period,0, MODE_EMA, PRICE_CLOSE);
   m5_ema200_handle= iMA(_Symbol, PERIOD_M5, M5_EMA200_Period,0, MODE_EMA, PRICE_CLOSE);

   if(m1_ema14_handle==INVALID_HANDLE || m1_ema26_handle==INVALID_HANDLE ||
      m1_ema50_handle==INVALID_HANDLE || m1_ema100_handle==INVALID_HANDLE ||
      m1_ema200_handle==INVALID_HANDLE || m5_ema50_handle==INVALID_HANDLE ||
      m5_ema100_handle==INVALID_HANDLE || m5_ema200_handle==INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return INIT_FAILED;
   }

   ArraySetAsSeries(m1_ema14_buffer,true);
   ArraySetAsSeries(m1_ema26_buffer,true);
   ArraySetAsSeries(m1_ema50_buffer,true);
   ArraySetAsSeries(m1_ema100_buffer,true);
   ArraySetAsSeries(m1_ema200_buffer,true);
   ArraySetAsSeries(m5_ema50_buffer,true);
   ArraySetAsSeries(m5_ema100_buffer,true);
   ArraySetAsSeries(m5_ema200_buffer,true);

   Print("Multi-timeframe EMA Buy-Only EA initialized successfully");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(m1_ema14_handle!=INVALID_HANDLE) IndicatorRelease(m1_ema14_handle);
   if(m1_ema26_handle!=INVALID_HANDLE) IndicatorRelease(m1_ema26_handle);
   if(m1_ema50_handle!=INVALID_HANDLE) IndicatorRelease(m1_ema50_handle);
   if(m1_ema100_handle!=INVALID_HANDLE)IndicatorRelease(m1_ema100_handle);
   if(m1_ema200_handle!=INVALID_HANDLE)IndicatorRelease(m1_ema200_handle);
   if(m5_ema50_handle!=INVALID_HANDLE) IndicatorRelease(m5_ema50_handle);
   if(m5_ema100_handle!=INVALID_HANDLE)IndicatorRelease(m5_ema100_handle);
   if(m5_ema200_handle!=INVALID_HANDLE)IndicatorRelease(m5_ema200_handle);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // If we already have a position on this symbol (any magic), manage it
   if(PositionSelect(_Symbol))
   {
      ManagePosition();
      return;
   }

   // No position -> evaluate entry
   if(!UpdateEMA_M1() || !UpdateEMA_M5())
      return;

   CheckBuySignal();
}

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void CheckBuySignal()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double m5_ema50 = m5_ema50_buffer[0];
   double m5_ema100= m5_ema100_buffer[0];
   double m5_ema200= m5_ema200_buffer[0];

   bool m5_price_condition = (current_price > m5_ema50 + 50*_Point);
   bool m5_ema_condition   = (m5_ema50 > m5_ema100 && m5_ema100 > m5_ema200);

   double m1_ema14 = m1_ema14_buffer[0];
   double m1_ema26 = m1_ema26_buffer[0];
   double m1_ema50 = m1_ema50_buffer[0];
   double m1_ema100= m1_ema100_buffer[0];
   double m1_ema200= m1_ema200_buffer[0];

   bool m1_price_condition = (current_price > m1_ema14 + 50*_Point);
   bool m1_ema_condition   = (m1_ema14 > m1_ema26 && m1_ema26 > m1_ema50 &&
                              m1_ema50 > m1_ema100 && m1_ema100 > m1_ema200);

   if(m5_price_condition && m5_ema_condition && m1_price_condition && m1_ema_condition)
      OpenBuyOrder();
}

//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double swing_low = GetSwingLow();
   if(swing_low <= 0)
   {
      Print("Error: Could not calculate swing low");
      return;
   }

   double raw_sl = swing_low + SL_Buffer_Points*_Point; // keep your logic
   double sl = ClampSLForBuy(raw_sl);

   MqlTradeRequest request={};
   MqlTradeResult  result={};

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = LotSize;
   request.type     = ORDER_TYPE_BUY;
   request.price    = ask;
   request.sl       = sl;
   request.deviation= 10;
   request.magic    = Magic_Number;
   request.comment  = "Multi-EMA Buy Only";

   if(OrderSend(request,result))
   {
      Print("Buy order opened: ", result.order);
      // cache entry price for faster point math
      if(PositionSelect(_Symbol))
         entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      else
         entry_price = ask;
      trailing_stop_active = false;
   }
   else
   {
      Print("Error opening buy order: ", result.retcode);
   }
}

//+------------------------------------------------------------------+
double GetSwingLow()
{
   double lows[];
   ArrayResize(lows, SwingBars);
   if(CopyLow(_Symbol, PERIOD_M1, 1, SwingBars, lows) < SwingBars) return 0.0;
   return lows[ArrayMinimum(lows,0,SwingBars)];
}

//+------------------------------------------------------------------+
//| Manage existing BUY position                                     |
//+------------------------------------------------------------------+
void ManagePosition()
{
   // make sure we’re working with the current position
   if(!PositionSelect(_Symbol)) return;
   if(!UpdateEMA_M1()) return; // refresh M1 EMA14 for trailing

   ulong  ticket      = (ulong)PositionGetInteger(POSITION_TICKET);
   double sl_current  = PositionGetDouble(POSITION_SL);
   double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // keep local entry cache up to date
   if(entry_price <= 0.0) entry_price = open_price;

   // compute profit in POINTS (not money!)
   int profit_pts = ProfitPointsForBuy(open_price);

   // when profit >= 1000 points -> enable trailing by M1 EMA50
   if(profit_pts >= Profit_1000_Points)
   {
      if(!trailing_stop_active)
      {
         trailing_stop_active = true;
         Print("Trailing stop ACTIVATED (M1 EMA50).");
      }

      double ema50 = m1_ema50_buffer[0];

      // SL follows EMA50, but must satisfy broker stop level and be < Bid
      double desired_sl = ema50;
      desired_sl = ClampSLForBuy(desired_sl);

      // improve only
      if(desired_sl > sl_current + (_Point*0.5))
      {
         if(ModifyPosition(ticket, desired_sl, 0.0))
            Print("Trailing SL -> M1 EMA50: ", desired_sl, " (Bid=", bid, ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Position modify helper                                           |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double sl, double tp)
{
   MqlTradeRequest req={};
   MqlTradeResult  res={};

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.sl       = sl;
   req.tp       = tp;

   if(OrderSend(req,res))
   {
      // success
      return true;
   }
   else
   {
      Print("Error modifying position: ", res.retcode, " (sl=", sl, ", tp=", tp, ")");
      return false;
   }
}
//+------------------------------------------------------------------+
