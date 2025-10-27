//+------------------------------------------------------------------+
//|                                    ema14_200_trailing_strategy.mq5 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- Input parameters
input double LotSize = 0.01;                    // Lot size
input int EMA14_Period = 14;                    // EMA 14 period
input int EMA50_Period = 50;                    // EMA 50 period
input int EMA200_Period = 200;                  // EMA 200 period
input int PriceDistance = 10;                   // Price distance from EMA14 in points
input int SwingBars = 20;                       // Bars to look back for swing high/low
input int TrailingProfit = 100;                 // Profit points to start trailing stop
input int Magic_Number = 111222;                // Magic Number

//--- Global handles/buffers
int ema14_handle, ema50_handle, ema200_handle;
double ema14_buffer[], ema50_buffer[], ema200_buffer[];

//--- Global variables
bool trailing_active = false;                   // Trailing stop active flag

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize EMA handles for M1 timeframe
   ema14_handle = iMA(_Symbol, PERIOD_M1, EMA14_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema50_handle = iMA(_Symbol, PERIOD_M1, EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema200_handle = iMA(_Symbol, PERIOD_M1, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(ema14_handle == INVALID_HANDLE || ema50_handle == INVALID_HANDLE || ema200_handle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return INIT_FAILED;
   }

   // Set array as series
   ArraySetAsSeries(ema14_buffer, true);
   ArraySetAsSeries(ema50_buffer, true);
   ArraySetAsSeries(ema200_buffer, true);

   Print("EMA14-50-200 Trailing Strategy EA initialized successfully");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ema14_handle != INVALID_HANDLE) IndicatorRelease(ema14_handle);
   if(ema50_handle != INVALID_HANDLE) IndicatorRelease(ema50_handle);
   if(ema200_handle != INVALID_HANDLE) IndicatorRelease(ema200_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // If we have a position, manage it
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
      {
         ManagePosition();
         return;
      }
   }

   // No position -> evaluate entry conditions
   if(!UpdateEMA())
      return;

   CheckBuySignal();
   CheckSellSignal();
}

//+------------------------------------------------------------------+
//| Update EMA buffers                                               |
//+------------------------------------------------------------------+
bool UpdateEMA()
{
   if(CopyBuffer(ema14_handle, 0, 0, 1, ema14_buffer) < 1) return false;
   if(CopyBuffer(ema50_handle, 0, 0, 1, ema50_buffer) < 1) return false;
   if(CopyBuffer(ema200_handle, 0, 0, 1, ema200_buffer) < 1) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check buy signal conditions                                      |
//+------------------------------------------------------------------+
void CheckBuySignal()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ema14 = ema14_buffer[0];
   double ema50 = ema50_buffer[0];
   double ema200 = ema200_buffer[0];

   // Buy conditions: EMA14 > EMA50 > EMA200 AND price > EMA14 + 10 points
   bool ema_condition = (ema14 > ema50 && ema50 > ema200);
   bool price_condition = (current_price > ema14 + PriceDistance * _Point);

   // Debug information
   static datetime last_debug_time = 0;
   if(TimeCurrent() - last_debug_time > 30) // Print every 30 seconds
   {
      Print("=== Buy Signal Check ===");
      Print("EMA14: ", DoubleToString(ema14, _Digits), " > EMA50: ", DoubleToString(ema50, _Digits), " > EMA200: ", DoubleToString(ema200, _Digits), " = ", ema_condition);
      Print("Price: ", DoubleToString(current_price, _Digits), " > EMA14+10: ", DoubleToString(ema14 + PriceDistance * _Point, _Digits), " = ", price_condition);
      last_debug_time = TimeCurrent();
   }

   if(ema_condition && price_condition)
   {
      Print("Buy conditions met! Opening BUY order...");
      OpenBuyOrder();
   }
}

//+------------------------------------------------------------------+
//| Check sell signal conditions                                     |
//+------------------------------------------------------------------+
void CheckSellSignal()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double ema14 = ema14_buffer[0];
   double ema50 = ema50_buffer[0];
   double ema200 = ema200_buffer[0];

   // Sell conditions: EMA14 < EMA50 < EMA200 AND price < EMA14 - 10 points
   bool ema_condition = (ema14 < ema50 && ema50 < ema200);
   bool price_condition = (current_price < ema14 - PriceDistance * _Point);

   // Debug information
   static datetime last_debug_time = 0;
   if(TimeCurrent() - last_debug_time > 30) // Print every 30 seconds
   {
      Print("=== Sell Signal Check ===");
      Print("EMA14: ", DoubleToString(ema14, _Digits), " < EMA50: ", DoubleToString(ema50, _Digits), " < EMA200: ", DoubleToString(ema200, _Digits), " = ", ema_condition);
      Print("Price: ", DoubleToString(current_price, _Digits), " < EMA14-10: ", DoubleToString(ema14 - PriceDistance * _Point, _Digits), " = ", price_condition);
      last_debug_time = TimeCurrent();
   }

   if(ema_condition && price_condition)
   {
      Print("Sell conditions met! Opening SELL order...");
      OpenSellOrder();
   }
}

//+------------------------------------------------------------------+
//| Open buy order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double swing_low = GetSwingLow();
   
   if(swing_low <= 0)
   {
      Print("Error: Could not calculate swing low for SL");
      return;
   }

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.sl = swing_low;
   request.tp = 0; // No TP, will use trailing stop
   request.deviation = 10;
   request.magic = Magic_Number;
   request.comment = "EMA14-200 Buy";

   if(OrderSend(request, result))
   {
      trailing_active = false;
      Print("Buy order opened successfully:");
      Print("  Ticket: ", result.order);
      Print("  Entry: ", ask);
      Print("  SL (Swing Low): ", swing_low);
   }
   else
   {
      Print("Error opening buy order: ", result.retcode, " - ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Open sell order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double swing_high = GetSwingHigh();
   
   if(swing_high <= 0)
   {
      Print("Error: Could not calculate swing high for SL");
      return;
   }

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = bid;
   request.sl = swing_high;
   request.tp = 0; // No TP, will use trailing stop
   request.deviation = 10;
   request.magic = Magic_Number;
   request.comment = "EMA14-200 Sell";

   if(OrderSend(request, result))
   {
      trailing_active = false;
      Print("Sell order opened successfully:");
      Print("  Ticket: ", result.order);
      Print("  Entry: ", bid);
      Print("  SL (Swing High): ", swing_high);
   }
   else
   {
      Print("Error opening sell order: ", result.retcode, " - ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Get swing low for BUY SL                                         |
//+------------------------------------------------------------------+
double GetSwingLow()
{
   double lows[];
   ArrayResize(lows, SwingBars);
   if(CopyLow(_Symbol, PERIOD_M1, 1, SwingBars, lows) < SwingBars) return 0.0;
   return lows[ArrayMinimum(lows, 0, SwingBars)];
}

//+------------------------------------------------------------------+
//| Get swing high for SELL SL                                       |
//+------------------------------------------------------------------+
double GetSwingHigh()
{
   double highs[];
   ArrayResize(highs, SwingBars);
   if(CopyHigh(_Symbol, PERIOD_M1, 1, SwingBars, highs) < SwingBars) return 0.0;
   return highs[ArrayMaximum(highs, 0, SwingBars)];
}

//+------------------------------------------------------------------+
//| Manage existing position                                         |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!PositionSelect(_Symbol)) return;

   double current_price = 0;
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   
   // Get entry price from position
   double position_entry = PositionGetDouble(POSITION_PRICE_OPEN);

   if(pos_type == POSITION_TYPE_BUY)
   {
      current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      // Calculate profit in points
      int profit_points = (int)MathFloor((current_price - position_entry) / _Point);
      
      // Debug: Print profit information
      static datetime last_profit_debug = 0;
      if(TimeCurrent() - last_profit_debug > 5) // Print every 5 seconds
      {
         double swing_low = GetSwingLow();
         Print("BUY Position - Entry: ", position_entry, ", Current: ", current_price, ", Profit: ", profit_points, " points");
         Print("Trailing Active: ", trailing_active, ", Current SL: ", current_sl, ", Swing Low: ", swing_low);
         last_profit_debug = TimeCurrent();
      }
      
      // Check if we should activate trailing stop
      if(!trailing_active && profit_points >= TrailingProfit)
      {
         trailing_active = true;
         Print("*** TRAILING STOP ACTIVATED at ", profit_points, " points profit ***");
      }
      
      // Apply trailing stop to swing low - continuously follow swing low
      if(trailing_active)
      {
         double swing_low = GetSwingLow();
         double new_sl = swing_low;
         
         // Only move SL up (better for BUY) and only if swing low is higher than current SL
         if(new_sl > current_sl && new_sl > 0)
         {
            Print("Trailing BUY SL from ", current_sl, " to Swing Low: ", new_sl);
            ModifyPosition(ticket, new_sl, current_tp);
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // Calculate profit in points
      int profit_points = (int)MathFloor((position_entry - current_price) / _Point);
      
      // Debug: Print profit information
      static datetime last_profit_debug = 0;
      if(TimeCurrent() - last_profit_debug > 5) // Print every 5 seconds
      {
         double swing_high = GetSwingHigh();
         Print("SELL Position - Entry: ", position_entry, ", Current: ", current_price, ", Profit: ", profit_points, " points");
         Print("Trailing Active: ", trailing_active, ", Current SL: ", current_sl, ", Swing High: ", swing_high);
         last_profit_debug = TimeCurrent();
      }
      
      // Check if we should activate trailing stop
      if(!trailing_active && profit_points >= TrailingProfit)
      {
         trailing_active = true;
         Print("*** TRAILING STOP ACTIVATED at ", profit_points, " points profit ***");
      }
      
      // Apply trailing stop to swing high - continuously follow swing high
      if(trailing_active)
      {
         double swing_high = GetSwingHigh();
         double new_sl = swing_high;
         
         // Only move SL down (better for SELL) and only if swing high is lower than current SL
         if(new_sl < current_sl && new_sl > 0)
         {
            Print("Trailing SELL SL from ", current_sl, " to Swing High: ", new_sl);
            ModifyPosition(ticket, new_sl, current_tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Position modify helper                                           |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double sl, double tp)
{
   MqlTradeRequest req = {};
   MqlTradeResult res = {};

   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.sl = sl;
   req.tp = tp;

   if(OrderSend(req, res))
   {
      Print("Position modified - New SL: ", sl, ", TP: ", tp);
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
   // Reset variables when position is closed
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long deal_magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(deal_magic == Magic_Number)
         {
            ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            
            if(deal_entry == DEAL_ENTRY_OUT)
            {
               double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
               Print("Position closed. Profit: ", DoubleToString(profit, 2));
               
               // Reset variables for next trade
               trailing_active = false;
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
