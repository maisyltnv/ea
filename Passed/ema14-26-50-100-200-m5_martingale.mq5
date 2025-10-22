//+------------------------------------------------------------------+
//|                                    ema_martingale_strategy.mq5   |
//|                                    ໃຊ້ໄດ້ຕອນທີກຣາຟເປັນເທຣນ   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- Input parameters
input double InitialLotSize = 0.01;                // Initial lot size
input int EMA14_Period = 14;                       // EMA 14 period
input int EMA26_Period = 26;                       // EMA 26 period
input int EMA50_Period = 50;                       // EMA 50 period
input int EMA100_Period = 100;                     // EMA 100 period
input int EMA200_Period = 200;                     // EMA 200 period
input int SL_Points = 1000;                        // Stop Loss in points
input int TP_Points = 3000;                        // Take Profit in points
input int Max_Daily_SL_Count = 10;                 // Max daily SL count before stopping
input int Magic_Number = 789012;                   // Magic Number

//--- Global handles/buffers
int ema14_handle, ema26_handle, ema50_handle, ema100_handle, ema200_handle;
double ema14_buffer[], ema26_buffer[], ema50_buffer[], ema100_buffer[], ema200_buffer[];

//--- Global variables for Martingale strategy
double current_lot_size = 0.01;                    // Current lot size for martingale
int lot_sequence_index = 0;                        // Index for lot sequence
int daily_sl_count = 0;                            // Daily SL count
datetime last_trade_date = 0;                      // Last trade date
bool trading_allowed_today = true;                 // Trading allowed today flag

//--- Martingale lot sequence as specified
double martingale_lots[] = {0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.11, 0.14, 0.19, 0.26};

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize EMA handles for M5 timeframe
   ema14_handle = iMA(_Symbol, PERIOD_M5, EMA14_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema26_handle = iMA(_Symbol, PERIOD_M5, EMA26_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema50_handle = iMA(_Symbol, PERIOD_M5, EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema100_handle = iMA(_Symbol, PERIOD_M5, EMA100_Period, 0, MODE_EMA, PRICE_CLOSE);
   ema200_handle = iMA(_Symbol, PERIOD_M5, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(ema14_handle == INVALID_HANDLE || ema26_handle == INVALID_HANDLE ||
      ema50_handle == INVALID_HANDLE || ema100_handle == INVALID_HANDLE ||
      ema200_handle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return INIT_FAILED;
   }

   // Set array as series
   ArraySetAsSeries(ema14_buffer, true);
   ArraySetAsSeries(ema26_buffer, true);
   ArraySetAsSeries(ema50_buffer, true);
   ArraySetAsSeries(ema100_buffer, true);
   ArraySetAsSeries(ema200_buffer, true);

   // Initialize current lot size
   current_lot_size = InitialLotSize;
   lot_sequence_index = 0;

   Print("EMA Martingale Strategy EA initialized successfully");
   string lot_sequence_str = "";
   for(int i = 0; i < ArraySize(martingale_lots); i++)
   {
      if(i > 0) lot_sequence_str += ", ";
      lot_sequence_str += DoubleToString(martingale_lots[i], 2);
   }
   Print("Martingale lot sequence: [", lot_sequence_str, "]");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ema14_handle != INVALID_HANDLE) IndicatorRelease(ema14_handle);
   if(ema26_handle != INVALID_HANDLE) IndicatorRelease(ema26_handle);
   if(ema50_handle != INVALID_HANDLE) IndicatorRelease(ema50_handle);
   if(ema100_handle != INVALID_HANDLE) IndicatorRelease(ema100_handle);
   if(ema200_handle != INVALID_HANDLE) IndicatorRelease(ema200_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if new day started
   CheckNewDay();
   
   // Check if trading is allowed today
   if(!trading_allowed_today)
   {
      Print("Trading not allowed today. Daily SL limit reached: ", daily_sl_count, "/", Max_Daily_SL_Count);
      return;
   }
   
   // Check if daily SL count limit reached
   if(daily_sl_count >= Max_Daily_SL_Count)
   {
      trading_allowed_today = false;
      Print("Daily SL limit reached: ", daily_sl_count, " SL hits. Trading stopped for today.");
      return;
   }
   
   // If we already have a position, don't open new ones
   if(PositionSelect(_Symbol))
   {
      if(PositionGetInteger(POSITION_MAGIC) == Magic_Number)
      {
         // Position exists, just wait for it to close
         return;
      }
   }

   // No position -> evaluate entry conditions
   if(!UpdateEMA())
      return;

   CheckBuySignal();
}

//+------------------------------------------------------------------+
//| Update EMA buffers                                               |
//+------------------------------------------------------------------+
bool UpdateEMA()
{
   if(CopyBuffer(ema14_handle, 0, 0, 1, ema14_buffer) < 1) return false;
   if(CopyBuffer(ema26_handle, 0, 0, 1, ema26_buffer) < 1) return false;
   if(CopyBuffer(ema50_handle, 0, 0, 1, ema50_buffer) < 1) return false;
   if(CopyBuffer(ema100_handle, 0, 0, 1, ema100_buffer) < 1) return false;
   if(CopyBuffer(ema200_handle, 0, 0, 1, ema200_buffer) < 1) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check buy signal conditions                                      |
//+------------------------------------------------------------------+
void CheckBuySignal()
{
   // Get current EMA values
   double ema14 = ema14_buffer[0];
   double ema26 = ema26_buffer[0];
   double ema50 = ema50_buffer[0];
   double ema100 = ema100_buffer[0];
   double ema200 = ema200_buffer[0];

   // Check EMA alignment condition: EMA14 > EMA26 > EMA50 > EMA100 > EMA200
   bool ema_alignment = (ema14 > ema26 && ema26 > ema50 && ema50 > ema100 && ema100 > ema200);

   // Debug information
   static datetime last_debug_time = 0;
   if(TimeCurrent() - last_debug_time > 60) // Print every minute
   {
      Print("=== EMA Values Check ===");
      Print("EMA14: ", DoubleToString(ema14, _Digits), " > EMA26: ", DoubleToString(ema26, _Digits), " = ", (ema14 > ema26));
      Print("EMA26: ", DoubleToString(ema26, _Digits), " > EMA50: ", DoubleToString(ema50, _Digits), " = ", (ema26 > ema50));
      Print("EMA50: ", DoubleToString(ema50, _Digits), " > EMA100: ", DoubleToString(ema100, _Digits), " = ", (ema50 > ema100));
      Print("EMA100: ", DoubleToString(ema100, _Digits), " > EMA200: ", DoubleToString(ema200, _Digits), " = ", (ema100 > ema200));
      Print("EMA Alignment: ", ema_alignment);
      Print("Current lot size: ", current_lot_size, " (Index: ", lot_sequence_index, ")");
      Print("Daily SL count: ", daily_sl_count, "/", Max_Daily_SL_Count);
      last_debug_time = TimeCurrent();
   }

   if(ema_alignment)
   {
      Print("All EMA conditions met! Opening BUY order with lot size: ", current_lot_size);
      OpenBuyOrder();
   }
}

//+------------------------------------------------------------------+
//| Open buy order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = ask - SL_Points * _Point;
   double tp = ask + TP_Points * _Point;

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = current_lot_size;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = Magic_Number;
   request.comment = "EMA Martingale Strategy";

   if(OrderSend(request, result))
   {
      Print("Buy order opened successfully:");
      Print("  Ticket: ", result.order);
      Print("  Lot size: ", current_lot_size);
      Print("  Entry: ", ask);
      Print("  SL: ", sl);
      Print("  TP: ", tp);
   }
   else
   {
      Print("Error opening buy order: ", result.retcode, " - ", result.comment);
   }
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
      Print("Reset daily SL count and trading permissions");
   }
}

//+------------------------------------------------------------------+
//| Trade transaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                       const MqlTradeRequest& request,
                       const MqlTradeResult& result)
{
   // Check if position was closed
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
            Print("Position closed. Profit: ", DoubleToString(profit, 2));
            
            // Check if it was a loss (SL hit)
            if(profit < 0)
            {
               daily_sl_count++;
               Print("SL hit! Daily SL count: ", daily_sl_count, "/", Max_Daily_SL_Count);
               
               // Move to next lot size in martingale sequence
               lot_sequence_index++;
               
               if(lot_sequence_index < ArraySize(martingale_lots))
               {
                  current_lot_size = martingale_lots[lot_sequence_index];
                  Print("Next lot size: ", current_lot_size, " (Index: ", lot_sequence_index, ")");
               }
               else
               {
                  // Reset to first lot size after reaching the end of sequence
                  lot_sequence_index = 0;
                  current_lot_size = martingale_lots[0];
                  Print("Reached end of martingale sequence. Reset to first lot size: ", current_lot_size);
               }
               
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
               current_lot_size = InitialLotSize;  // Reset lot size to 0.01
               Print("TP hit! Lot sequence reset to initial size: ", current_lot_size, ". Continuing trading...");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
