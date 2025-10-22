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
input int SL_Points = 500;                      // Stop Loss in points
// Removed trailing stop parameters - no longer needed
input int TP_Points = 2000;                     // Take Profit in points
input int Max_Daily_SL_Count = 10;              // Max daily SL count before stopping
input int Magic_Number = 123456;                // Magic

//--- Global handles/buffers
int m1_ema14_handle, m1_ema26_handle, m1_ema50_handle, m1_ema100_handle, m1_ema200_handle;
int m5_ema50_handle, m5_ema100_handle, m5_ema200_handle;

double m1_ema14_buffer[], m1_ema26_buffer[], m1_ema50_buffer[], m1_ema100_buffer[], m1_ema200_buffer[];
double m5_ema50_buffer[], m5_ema100_buffer[], m5_ema200_buffer[];

// Removed entry_price - no longer needed for trailing stop
int daily_sl_count = 0;
datetime last_trade_date = 0;
bool trading_allowed_today = true;
double current_lot_size = LotSize;  // Current lot size for martingale
int lot_sequence_index = 0;  // Index for Fibonacci lot sequence

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
   // Check if new day started
   CheckNewDay();
   
   // Debug: Print current status
   static datetime last_debug_time = 0;
   if(TimeCurrent() - last_debug_time > 60) // Print every minute
   {
      Print("=== EA Status ===");
      Print("Trading allowed today: ", trading_allowed_today);
      Print("Daily SL count: ", daily_sl_count, "/", Max_Daily_SL_Count);
      Print("Current lot size: ", current_lot_size);
      Print("Lot sequence index: ", lot_sequence_index);
      last_debug_time = TimeCurrent();
   }
   
   // Check if trading is allowed today
   if(!trading_allowed_today)
      return;
   
   // Check if daily SL count limit reached
   if(daily_sl_count >= Max_Daily_SL_Count)
   {
      trading_allowed_today = false;
      Print("Daily SL limit reached: ", daily_sl_count, " SL hits");
      return;
   }
   

   // If we already have a position on this symbol with our magic number, manage it
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
      {
         ManagePosition();
         return;
      }
      // If position exists but not our magic number, don't trade
      Print("Position exists with different magic number. Skipping...");
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

   // Debug: Print all conditions for verification
   Print("=== Entry Conditions Check ===");
   Print("M5 Price > EMA50+50: ", m5_price_condition, " (Price: ", current_price, " vs EMA50+50: ", m5_ema50 + 50*_Point, ")");
   Print("M5 EMA Alignment: ", m5_ema_condition, " (EMA50: ", m5_ema50, " > EMA100: ", m5_ema100, " > EMA200: ", m5_ema200, ")");
   Print("M1 Price > EMA14+50: ", m1_price_condition, " (Price: ", current_price, " vs EMA14+50: ", m1_ema14 + 50*_Point, ")");
   Print("M1 EMA Alignment: ", m1_ema_condition, " (EMA14: ", m1_ema14, " > EMA26: ", m1_ema26, " > EMA50: ", m1_ema50, " > EMA100: ", m1_ema100, " > EMA200: ", m1_ema200, ")");
   
   if(m5_price_condition && m5_ema_condition && m1_price_condition && m1_ema_condition)
   {
      Print("All conditions met! Opening BUY order...");
      OpenBuyOrder();
   }
   else
   {
      Print("Entry conditions not met. Waiting...");
   }
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

   double sl = ask - SL_Points * _Point;  // Fixed SL distance from entry price

   MqlTradeRequest request={};
   MqlTradeResult  result={};

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = current_lot_size;
   request.type     = ORDER_TYPE_BUY;
   request.price    = ask;
    request.sl       = sl;
    request.tp       = ask + TP_Points * _Point;
    request.deviation= 10;
    request.magic    = Magic_Number;
    request.comment  = "Multi-EMA Buy Only";

   if(OrderSend(request,result))
   {
      Print("Buy order opened: ", result.order);
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
   // make sure we're working with the current position
   if(!PositionSelect(_Symbol)) return;

   // No trailing stop logic - just monitor position
   // Position will be closed by TP or SL automatically
}

//+------------------------------------------------------------------+
//| Check if new day started                                         |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime current_time = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(current_time, dt);
   
   datetime current_date = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   if(current_date != last_trade_date)
   {
      last_trade_date = current_date;
      daily_sl_count = 0;
      trading_allowed_today = true;
      Print("New trading day started: ", TimeToString(current_time, TIME_DATE));
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
//| Trade transaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                       const MqlTradeRequest& request,
                       const MqlTradeResult& result)
{
   //--- Check if position was closed
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         // Only process deals from this EA (check magic number)
         long deal_magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(deal_magic != Magic_Number)
            return;
            
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         
         if(deal_entry == DEAL_ENTRY_OUT)
         {
            Print("Position closed. Profit: ", profit);
            
            // Check if it was a loss (SL hit)
            if(profit < 0)
            {
               daily_sl_count++;
               // Fibonacci lot sequence: 0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.11, 0.14, 0.19, 0.26
               double fib_lots[] = {0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.11, 0.14, 0.19, 0.26};
               lot_sequence_index++;
               if(lot_sequence_index < ArraySize(fib_lots))
                  current_lot_size = fib_lots[lot_sequence_index];
               else
                  current_lot_size = fib_lots[ArraySize(fib_lots)-1];  // Use last value if exceeded
               Print("SL hit! Daily SL count: ", daily_sl_count, " Next lot size: ", current_lot_size);
               
               // Stop trading if SL limit reached
               if(daily_sl_count >= Max_Daily_SL_Count)
               {
                  trading_allowed_today = false;
                  Print("Trading stopped for today due to SL limit reached: ", daily_sl_count, " SL hits");
               }
            }
            // If it was a profit (TP hit), reset lot sequence and continue trading
            else if(profit > 0)
            {
               lot_sequence_index = 0;  // Reset lot sequence index to start from 0.01
               current_lot_size = LotSize;  // Reset lot size to 0.01
               Print("TP hit! Lot sequence reset to 0.01. Continuing trading...");
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
