//+------------------------------------------------------------------+
//| BUY and SELL EMA50 Strategy with Trailing Stop                  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;
input int SL_Points = 500;
input int TP_Points = 1000;
input int EMA_Period = 50;
input ulong Magic = 123456;
input int Move_SL_At_Profit = 500;  // ລາຄາຂຶ້ນໄປກວ່າ entry ກີ່ຈຸດຈຶ່ງຍ້າຍ SL
input int New_SL_Plus = 50;         // ຍ້າຍ SL ໄປຢູ່ເທິງ entry ກີ່ຈຸດ

// Global Variables
CTrade trade;
int hEMA;
datetime lastBarTime = 0;
bool canTrade = true;

// State tracking for post-close conditions
bool waitingForPriceBelowEMA = false;
bool waitingForPriceAboveEMA = false;

//+------------------------------------------------------------------+
//| Check if new bar formed                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[2];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 2, t) < 2) return false;
   if(t[0] != lastBarTime) 
   { 
      lastBarTime = t[0]; 
      return true; 
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get EMA value                                                    |
//+------------------------------------------------------------------+
bool GetEMA(double &ema_value)
{
   if(hEMA == INVALID_HANDLE) return false;
   double ema[1];
   if(CopyBuffer(hEMA, 0, 1, 1, ema) != 1) return false;
   ema_value = ema[0];
   return true;
}

//+------------------------------------------------------------------+
//| Check and update trailing stop                                   |
//+------------------------------------------------------------------+
void CheckTrailingStop()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         long posType = PositionGetInteger(POSITION_TYPE);
         
         double newSL = 0;
         double priceMovePoints = 0;
         
         // BUY Position
         if(posType == POSITION_TYPE_BUY)
         {
            double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            
            // ຄິດໄລ່ວ່າລາຄາຂຶ້ນໄປກວ່າ entry ກີ່ຈຸດ
            priceMovePoints = (currentPrice - openPrice) / point;
            
            // ຄິດໄລ່ stop loss ໃໝ່ (entry + 50 points)
            newSL = openPrice + (New_SL_Plus * point);
            newSL = NormalizeDouble(newSL, digits);
            
            // ເງື່ອນໄຂ: ລາຄາຂຶ້ນໄປຮອດ 500 ຈຸດ ແລະ stop loss ປັດຈຸບັນຍັງຕ່ຳກວ່າ entry + 50 ຈຸດ
            if(priceMovePoints >= Move_SL_At_Profit && currentSL < newSL)
            {
               if(trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               {
                  Print("BUY Trailing stop activated: New SL = ", newSL, " (Entry +", New_SL_Plus, " points)");
                  Print("Entry: ", openPrice, ", Current Price: ", currentPrice, ", Price moved: ", (int)priceMovePoints, " points");
               }
               else
               {
                  Print("Failed to modify BUY position: ", trade.ResultRetcode());
               }
            }
         }
         // SELL Position
         else if(posType == POSITION_TYPE_SELL)
         {
            double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            // ຄິດໄລ່ວ່າລາຄາລົງໄປກວ່າ entry ກີ່ຈຸດ
            priceMovePoints = (openPrice - currentPrice) / point;
            
            // ຄິດໄລ່ stop loss ໃໝ່ (entry - 50 points)
            newSL = openPrice - (New_SL_Plus * point);
            newSL = NormalizeDouble(newSL, digits);
            
            // ເງື່ອນໄຂ: ລາຄາລົງໄປຮອດ 500 ຈຸດ ແລະ stop loss ປັດຈຸບັນຍັງສູງກວ່າ entry - 50 ຈຸດ
            if(priceMovePoints >= Move_SL_At_Profit && currentSL > newSL)
            {
               if(trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               {
                  Print("SELL Trailing stop activated: New SL = ", newSL, " (Entry -", New_SL_Plus, " points)");
                  Print("Entry: ", openPrice, ", Current Price: ", currentPrice, ", Price moved: ", (int)priceMovePoints, " points");
               }
               else
               {
                  Print("Failed to modify SELL position: ", trade.ResultRetcode());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   
   hEMA = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("BUY and SELL EA with Trailing Stop initialized");
   Print("EMA", EMA_Period, ", SL: ", SL_Points, ", TP: ", TP_Points, " points");
   Print("Move SL when profit >= ", Move_SL_At_Profit, " points: BUY to entry+", New_SL_Plus, ", SELL to entry-", New_SL_Plus);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ກວດສອບ trailing stop ທຸກເທື່ອທີ່ມີ position
   if(PositionsTotal() > 0)
   {
      CheckTrailingStop();
   }
   
   // ຖ້າມີ position ເປີດຢູ່, ບໍ່ຕ້ອງກວດສອບສັນຍານໃໝ່
   if(PositionSelect(_Symbol)) return;
   
   // Check if we need to reset after position closed
   if(!canTrade)
   {
      waitingForPriceBelowEMA = true;
      waitingForPriceAboveEMA = false;
      Print("Position closed - Waiting for price to go below EMA50");
      canTrade = true;
   }
   
   if(!IsNewBar()) return;
   
   double ema50;
   if(!GetEMA(ema50)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Post-close conditions: Wait for price to go below then above EMA50
   if(waitingForPriceBelowEMA)
   {
      if(ask < ema50)
      {
         waitingForPriceBelowEMA = false;
         waitingForPriceAboveEMA = true;
         Print("Price went below EMA50 - Now waiting for price to go back above EMA50");
      }
      return;
   }
   
   if(waitingForPriceAboveEMA)
   {
      if(ask > ema50)
      {
         waitingForPriceAboveEMA = false;
         Print("Price back above EMA50 - Ready to trade again");
      }
      else
      {
         return;
      }
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // BUY: Price above EMA50
   if(ask > ema50)
   {
      Print("BUY Signal: Price above EMA50");
      
      double sl = ask - SL_Points * point;
      double tp = ask + TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "Price above EMA50"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl, ", TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
   // SELL: Price below EMA50
   else if(bid < ema50)
   {
      Print("SELL Signal: Price below EMA50");
      
      double sl = bid + SL_Points * point;
      double tp = bid - TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Sell(Lots, _Symbol, bid, sl, tp, "Price below EMA50"))
      {
         Print("SELL order opened - Entry: ", bid, ", SL: ", sl, ", TP: ", tp);
         canTrade = false;
      }
      else
      {
         Print("SELL order failed - Error: ", trade.ResultRetcode());
      }
   }
}