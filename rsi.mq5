//+------------------------------------------------------------------+
//| RSI Grid Strategy EA                                              |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;           // ຂະໜາດ Lot
input int RSI_Period = 14;           // RSI Period
input double RSI_Oversold = 20.0;    // RSI Oversold Level (BUY)
input double RSI_Overbought = 80.0;  // RSI Overbought Level (SELL)
input int GridDistance = 400;        // ໄລຍະລະຫວ່າງອໍເດີ (ຈຸດ)
input int GridLevels = 4;            // ຈຳນວນ Limit Orders
input int SL_Points = 500;           // Stop Loss (ຈຸດ)
input int TP_Points = 500;           // Take Profit (ຈຸດ)
input int GMT_Offset = 7;            // Timezone Offset (Bangkok GMT+7)
input int StartHour = 5;             // ເວລາເລີ່ມເທຣດ (ຊົ່ວໂມງ)
input int EndHour = 23;              // ເວລາສິ້ນສຸດເທຣດ (ຊົ່ວໂມງ)
input int MaxSL_PerDay = 2;          // ຈຳນວນ SL ສູງສຸດຕໍ່ວັນ
input int MaxTP_PerDay = 2;          // ຈຳນວນ TP ສູງສຸດຕໍ່ວັນ
input ulong Magic = 789123;          // Magic Number

// Global Variables
CTrade trade;
int hRSI;
datetime lastBarTime = 0;
bool buySetupActive = false;
bool sellSetupActive = false;

// Daily counters
int dailySL_Count = 0;
int dailyTP_Count = 0;
int lastTradeDay = 0;
int totalPositionsTracked = 0;  // Track total positions to detect closures

//+------------------------------------------------------------------+
//| Check if new bar formed                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[2];
   if(CopyTime(_Symbol, PERIOD_M1, 0, 2, t) < 2) return false;
   if(t[0] != lastBarTime) 
   { 
      lastBarTime = t[0]; 
      return true; 
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if trading is allowed by time                              |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   // Get current GMT time
   datetime currentGMT = TimeGMT();
   
   // Convert to Bangkok time (GMT+7)
   datetime bangkokTime = currentGMT + (GMT_Offset * 3600);
   
   MqlDateTime timeStruct;
   TimeToStruct(bangkokTime, timeStruct);
   
   int currentHour = timeStruct.hour;
   
   // Check if current hour is within trading hours
   // Trading from StartHour (5:00) to EndHour (23:00)
   if(currentHour >= StartHour && currentHour < EndHour)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get current Bangkok day number                                   |
//+------------------------------------------------------------------+
int GetBangkokDay()
{
   datetime currentGMT = TimeGMT();
   datetime bangkokTime = currentGMT + (GMT_Offset * 3600);
   
   MqlDateTime timeStruct;
   TimeToStruct(bangkokTime, timeStruct);
   
   return timeStruct.day_of_year;
}

//+------------------------------------------------------------------+
//| Reset daily counters if new day                                  |
//+------------------------------------------------------------------+
void CheckAndResetDailyCounters()
{
   int currentDay = GetBangkokDay();
   
   if(lastTradeDay != currentDay)
   {
      if(lastTradeDay != 0) // Not first run
      {
         Print("=================================");
         Print("New Trading Day - Resetting counters");
         Print("Previous Day: SL=", dailySL_Count, ", TP=", dailyTP_Count);
      }
      
      dailySL_Count = 0;
      dailyTP_Count = 0;
      lastTradeDay = currentDay;
      totalPositionsTracked = 0;
      
      Print("Today's Limits: Max SL=", MaxSL_PerDay, ", Max TP=", MaxTP_PerDay);
      Print("=================================");
   }
}

//+------------------------------------------------------------------+
//| Check if daily limit reached                                     |
//+------------------------------------------------------------------+
bool IsDailyLimitReached()
{
   if(dailySL_Count >= MaxSL_PerDay)
   {
      return true;
   }
   
   if(dailyTP_Count >= MaxTP_PerDay)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get RSI value                                                     |
//+------------------------------------------------------------------+
bool GetRSIValue(double &rsi_current, double &rsi_previous)
{
   if(hRSI == INVALID_HANDLE) return false;
   
   double rsi_buf[2];
   if(CopyBuffer(hRSI, 0, 1, 2, rsi_buf) != 2) return false;
   
   rsi_current = rsi_buf[0];   // Bar ທີ່ປິດແລ້ວ
   rsi_previous = rsi_buf[1];  // Bar ກ່ອນໜ້າ
   return true;
}

//+------------------------------------------------------------------+
//| Check if there are any open positions                            |
//+------------------------------------------------------------------+
bool HasOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == Magic)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if there are any pending orders                            |
//+------------------------------------------------------------------+
bool HasPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if there are any open positions or pending orders          |
//+------------------------------------------------------------------+
bool HasOpenPositionsOrOrders()
{
   return HasOpenPositions() || HasPendingOrders();
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                        |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   int deleted = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == Magic)
         {
            if(trade.OrderDelete(ticket))
            {
               deleted++;
               Print("✓ Deleted pending order #", ticket);
            }
            else
            {
               Print("✗ Failed to delete order #", ticket, " - Error: ", trade.ResultRetcode());
            }
         }
      }
   }
   
   if(deleted > 0)
   {
      Print("=== Total ", deleted, " pending orders deleted ===");
   }
}

//+------------------------------------------------------------------+
//| Check and count closed positions (TP/SL)                         |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
   // Count current positions
   int currentPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == Magic)
         {
            currentPositions++;
         }
      }
   }
   
   // If positions decreased, check history for the closed position
   if(currentPositions < totalPositionsTracked && totalPositionsTracked > 0)
   {
      // Look at recent history
      HistorySelect(TimeCurrent() - 60, TimeCurrent()); // Last 60 seconds
      
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0)
         {
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(ticket, DEAL_MAGIC) == Magic &&
               HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               
               // Check if TP or SL
               if(profit > 0)
               {
                  dailyTP_Count++;
                  Print("=================================");
                  Print("✅ TP Hit! Daily TP Count: ", dailyTP_Count, "/", MaxTP_PerDay);
                  Print("=================================");
                  
                  if(dailyTP_Count >= MaxTP_PerDay)
                  {
                     Print("⚠️ Daily TP limit reached! No more trades today.");
                  }
               }
               else if(profit < 0)
               {
                  dailySL_Count++;
                  Print("=================================");
                  Print("❌ SL Hit! Daily SL Count: ", dailySL_Count, "/", MaxSL_PerDay);
                  Print("=================================");
                  
                  if(dailySL_Count >= MaxSL_PerDay)
                  {
                     Print("⚠️ Daily SL limit reached! No more trades today.");
                  }
               }
               
               break; // Found the closed position
            }
         }
      }
   }
   
   totalPositionsTracked = currentPositions;
}

//+------------------------------------------------------------------+
//| Place BUY orders (1 market + 4 buy limits)                       |
//+------------------------------------------------------------------+
void PlaceBuyOrders()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // ຄິດໄລ່ລາຄາສຳລັບອໍເດີທັງໝົດ
   // ອໍເດີທີ່ 1 (Market): ask
   // ອໍເດີທີ່ 2 (Limit): ask - 400 points
   // ອໍເດີທີ່ 3 (Limit): ask - 800 points
   // ອໍເດີທີ່ 4 (Limit): ask - 1200 points
   // ອໍເດີທີ່ 5 (Limit): ask - 1600 points
   
   double firstOrderPrice = ask;
   double lastOrderPrice = ask - (GridLevels * GridDistance * point);
   
   // SL: 500 ຈຸດຈາກອໍເດີສຸດທ້າຍ
   double sl = lastOrderPrice - (SL_Points * point);
   // TP: 500 ຈຸດຈາກອໍເດີທຳອິດ
   double tp = firstOrderPrice + (TP_Points * point);
   
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   Print("=== Placing BUY Orders ===");
   Print("First Order: ", firstOrderPrice, ", Last Order: ", lastOrderPrice);
   Print("SL: ", sl, ", TP: ", tp);
   
   // ເປີດ Market BUY Order
   if(trade.Buy(Lots, _Symbol, ask, sl, tp, "RSI BUY Market"))
   {
      Print("✓ BUY Market Order opened @ ", ask);
   }
   else
   {
      Print("✗ BUY Market Order failed - Error: ", trade.ResultRetcode());
      return; // ຖ້າ market order ບໍ່ສຳເລັດ ກໍ່ຢຸດ
   }
   
   // ວາງ Buy Limit Orders 4 ອໍເດີ
   for(int i = 1; i <= GridLevels; i++)
   {
      double limitPrice = ask - (i * GridDistance * point);
      limitPrice = NormalizeDouble(limitPrice, digits);
      
      if(trade.BuyLimit(Lots, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RSI BUY Limit " + IntegerToString(i)))
      {
         Print("✓ BUY Limit Order #", i, " placed @ ", limitPrice);
      }
      else
      {
         Print("✗ BUY Limit Order #", i, " failed - Error: ", trade.ResultRetcode());
      }
   }
   
   buySetupActive = false;
}

//+------------------------------------------------------------------+
//| Place SELL orders (1 market + 4 sell limits)                     |
//+------------------------------------------------------------------+
void PlaceSellOrders()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // ຄິດໄລ່ລາຄາສຳລັບອໍເດີທັງໝົດ
   // ອໍເດີທີ່ 1 (Market): bid
   // ອໍເດີທີ່ 2 (Limit): bid + 400 points
   // ອໍເດີທີ່ 3 (Limit): bid + 800 points
   // ອໍເດີທີ່ 4 (Limit): bid + 1200 points
   // ອໍເດີທີ່ 5 (Limit): bid + 1600 points
   
   double firstOrderPrice = bid;
   double lastOrderPrice = bid + (GridLevels * GridDistance * point);
   
   // SL: 500 ຈຸດຈາກອໍເດີສຸດທ້າຍ
   double sl = lastOrderPrice + (SL_Points * point);
   // TP: 500 ຈຸດຈາກອໍເດີທຳອິດ
   double tp = firstOrderPrice - (TP_Points * point);
   
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   Print("=== Placing SELL Orders ===");
   Print("First Order: ", firstOrderPrice, ", Last Order: ", lastOrderPrice);
   Print("SL: ", sl, ", TP: ", tp);
   
   // ເປີດ Market SELL Order
   if(trade.Sell(Lots, _Symbol, bid, sl, tp, "RSI SELL Market"))
   {
      Print("✓ SELL Market Order opened @ ", bid);
   }
   else
   {
      Print("✗ SELL Market Order failed - Error: ", trade.ResultRetcode());
      return; // ຟ້າ market order ບໍ່ສຳເລັດ ກໍ່ຢຸດ
   }
   
   // ວາງ Sell Limit Orders 4 ອໍເດີ
   for(int i = 1; i <= GridLevels; i++)
   {
      double limitPrice = bid + (i * GridDistance * point);
      limitPrice = NormalizeDouble(limitPrice, digits);
      
      if(trade.SellLimit(Lots, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RSI SELL Limit " + IntegerToString(i)))
      {
         Print("✓ SELL Limit Order #", i, " placed @ ", limitPrice);
      }
      else
      {
         Print("✗ SELL Limit Order #", i, " failed - Error: ", trade.ResultRetcode());
      }
   }
   
   sellSetupActive = false;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   
   // Create RSI indicator
   hRSI = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   
   if(hRSI == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_M1, 0, 1, t) == 1) lastBarTime = t[0];
   
   // Initialize daily counters
   lastTradeDay = GetBangkokDay();
   dailySL_Count = 0;
   dailyTP_Count = 0;
   totalPositionsTracked = 0;
   
   Print("=== RSI Grid Strategy EA Initialized ===");
   Print("RSI Period: ", RSI_Period);
   Print("Oversold Level: ", RSI_Oversold);
   Print("Overbought Level: ", RSI_Overbought);
   Print("Grid Distance: ", GridDistance, " points");
   Print("Grid Levels: ", GridLevels);
   Print("Lots: ", Lots);
   Print("SL: ", SL_Points, " points, TP: ", TP_Points, " points");
   Print("Trading Time: ", StartHour, ":00 - ", EndHour, ":00 (Bangkok GMT+", GMT_Offset, ")");
   Print("Daily Limits: Max SL=", MaxSL_PerDay, ", Max TP=", MaxTP_PerDay);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ກວດສອບແລະ reset counters ຖ້າເປັນມື້ໃໝ່
   CheckAndResetDailyCounters();
   
   // ກວດສອບ position ທີ່ປິດ ແລະນັບ SL/TP
   CheckClosedPositions();
   
   // ກວດສອບວ່າມີ pending orders ຢູ່ ແຕ່ບໍ່ມີ position
   // ນີ້ໝາຍຄວາມວ່າ position ຖືກ TP ຫຼື SL ແລ້ວ → ປິດທຸກ pending orders
   if(HasPendingOrders() && !HasOpenPositions())
   {
      Print("=================================");
      Print("Position closed (TP/SL hit) - Deleting all pending orders...");
      DeleteAllPendingOrders();
      Print("=================================");
   }
   
   // ຖ້າມີອໍເດີເປີດຢູ່ແລ້ວ ບໍ່ຕ້ອງຊອກ signal ໃໝ່
   if(HasOpenPositionsOrOrders()) return;
   
   // ກວດສອບຂີດຈຳກັດຕໍ່ວັນ
   if(IsDailyLimitReached())
   {
      return; // ຮອດຂີດຈຳກັດແລ້ວ, ບໍ່ເທຣດຕໍ່
   }
   
   // ກວດສອບເວລາການເທຣດ
   if(!IsTradingTime())
   {
      return; // ນອກເວລາເທຣດ, ບໍ່ຊອກ signal
   }
   
   if(!IsNewBar()) return;
   
   // Get RSI values
   double rsi_current, rsi_previous;
   if(!GetRSIValue(rsi_current, rsi_previous)) return;
   
   // BUY Signal: RSI ຂ້າມຈາກເທິງ 20 ລົງມາແຕະ 20 ຫຼືຕ່ຳກວ່າ
   if(rsi_previous > RSI_Oversold && rsi_current <= RSI_Oversold)
   {
      Print("=================================");
      Print("BUY Signal Detected!");
      Print("RSI Previous: ", rsi_previous, ", RSI Current: ", rsi_current);
      Print("Today: SL=", dailySL_Count, "/", MaxSL_PerDay, ", TP=", dailyTP_Count, "/", MaxTP_PerDay);
      PlaceBuyOrders();
   }
   // SELL Signal: RSI ຂ້າມຈາກລຸ່ມ 80 ຂຶ້ນໄປແຕະ 80 ຫຼືສູງກວ່າ
   else if(rsi_previous < RSI_Overbought && rsi_current >= RSI_Overbought)
   {
      Print("=================================");
      Print("SELL Signal Detected!");
      Print("RSI Previous: ", rsi_previous, ", RSI Current: ", rsi_current);
      Print("Today: SL=", dailySL_Count, "/", MaxSL_PerDay, ", TP=", dailyTP_Count, "/", MaxTP_PerDay);
      PlaceSellOrders();
   }
}
//+------------------------------------------------------------------+

