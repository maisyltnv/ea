//+------------------------------------------------------------------+
//| EMA50/EMA200 Strategy EA                                         |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.01;
input int SL_Points = 200;
input int EMA9_Period = 9;
input ulong Magic = 123456;

// Lock-after-profit settings
input int ProfitTriggerPoints = 200; // ຍ້າຍ SL ເມື່ອກຳໄລ ≥ 200 ຈຸດ
input int LockPoints = 20;           // ຍ້າຍ SL ໄປ entry ± 20 ຈຸດ
input int TrailingStartPoints = 500; // ເລີ່ມ trailing stop ເມື່ອກຳໄລ ≥ 500 ຈຸດ

// Time filter settings (Bangkok timezone = GMT+7)
input bool UseTimeFilter = true;     // ເປີດ/ປິດການກັ່ນຕອງເວລາ
input int StartHour = 5;             // ເວລາເລີ່ມເທຣດ (ຊົ່ວໂມງ)
input int EndHour = 23;              // ເວລາສິ້ນສຸດເທຣດ (ຊົ່ວໂມງ)
input int BangkokGMTOffset = 7;      // Bangkok = GMT+7

// Daily loss limit settings
input bool UseDailyLossLimit = true; // ເປີດ/ປິດການຈຳກັດການຂາດທຶນຕໍ່ວັນ
input int MaxDailySLHits = 2;        // ຈຳນວນຄັ້ງທີ່ຖືກ SL ສູງສຸດຕໍ່ວັນ

// Global Variables
CTrade trade;
int hEMA9;
datetime lastBarTime = 0;
bool slLocked = false; // ຕິດຕາມວ່າ SL ຖືກຍ້າຍແລ້ວຫຼືຍັງ
bool trailingActive = false; // ຕິດຕາມວ່າ trailing stop ເປີດແລ້ວຫຼືຍັງ

// Daily loss tracking
int dailySLHitCount = 0;      // ນັບຈຳນວນຄັ້ງທີ່ຖືກ SL ໃນວັນນີ້
datetime lastTradeDate = 0;   // ວັນທີ່ເທຣດຄັ້ງສຸດທ້າຍ
ulong lastPositionTicket = 0; // Ticket ຂອງ position ສຸດທ້າຍທີ່ຕິດຕາມ

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
//| Get EMA9 value                                                   |
//+------------------------------------------------------------------+
bool GetEMA9Value(double &ema9)
{
   if(hEMA9 == INVALID_HANDLE) return false;
   
   double ema9_buf[1];
   if(CopyBuffer(hEMA9, 0, 1, 1, ema9_buf) != 1) return false;
   
   ema9 = ema9_buf[0];
   return true;
}


//+------------------------------------------------------------------+
//| Check and reset daily SL hit counter if new day                 |
//+------------------------------------------------------------------+
void CheckAndResetDailyCounter()
{
   if(!UseDailyLossLimit) return;
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dtCurrent, dtLast;
   TimeToStruct(currentTime, dtCurrent);
   TimeToStruct(lastTradeDate, dtLast);
   
   // ຖ້າເປັນວັນໃໝ່, reset counter
   if(dtCurrent.day != dtLast.day || dtCurrent.mon != dtLast.mon || dtCurrent.year != dtLast.year)
   {
      if(dailySLHitCount > 0) // ພິມພຽງເມື່ອມີການ reset
      {
         Print("=== ວັນໃໝ່ເລີ່ມຕົ້ນ - Reset SL counter ===");
         Print("ວັນທີ່ຜ່ານມາ: ", dtLast.year, "-", dtLast.mon, "-", dtLast.day, " ຖືກ SL: ", dailySLHitCount, " ຄັ້ງ");
      }
      dailySLHitCount = 0;
      lastTradeDate = currentTime;
   }
}

//+------------------------------------------------------------------+
//| Check if position was closed by SL                              |
//+------------------------------------------------------------------+
void CheckForSLHit()
{
   if(!UseDailyLossLimit) return;
   
   // ກວດສອບ position history
   if(HistorySelect(0, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      
      // ກວດສອບ deal ຫຼ້າສຸດ
      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket <= 0) continue;
         
         // ກວດສອບວ່າເປັນ deal ຂອງ symbol ນີ້ແລະ magic number ນີ້ບໍ່
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != Magic) continue;
         
         // ກວດສອບວ່າເປັນ deal ປິດ position ບໍ່
         ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT) continue;
         
         // ກວດສອບວ່າເປັນ deal ທີ່ຍັງບໍ່ໄດ້ນັບບໍ່
         ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         if(positionTicket == lastPositionTicket) break; // ນັບແລ້ວ, ຢຸດຊອກຫາ
         
         // ກວດສອບວ່າຖືກ SL ບໍ່
         ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
         if(reason == DEAL_REASON_SL)
         {
            dailySLHitCount++;
            lastPositionTicket = positionTicket;
            
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            Print("⚠️ ຖືກ SL! ຄັ້ງທີ່ ", dailySLHitCount, " ໃນວັນນີ້ (ຂາດທຶນ: ", profit, ")");
            
            if(dailySLHitCount >= MaxDailySLHits)
            {
               Print("🛑 ຖືກ SL ", dailySLHitCount, " ຄັ້ງແລ້ວ - ຢຸດເທຣດສຳລັບວັນນີ້!");
            }
            
            break; // ພົບແລ້ວ, ຢຸດຊອກຫາ
         }
         
         break; // ກວດສອບພຽງ deal ຫຼ້າສຸດ
      }
   }
}

//+------------------------------------------------------------------+
//| Check if can trade today (not exceeded daily SL limit)          |
//+------------------------------------------------------------------+
bool CanTradeToday()
{
   if(!UseDailyLossLimit) return true;
   
   CheckAndResetDailyCounter();
   
   if(dailySLHitCount >= MaxDailySLHits)
   {
      static datetime lastWarningTime = 0;
      datetime currentTime = TimeCurrent();
      
      // ພິມ warning ທຸກໆ 30 ນາທີ
      if(currentTime - lastWarningTime > 1800)
      {
         Print("⛔ ບໍ່ສາມາດເທຣດໄດ້: ຖືກ SL ", dailySLHitCount, " ຄັ້ງແລ້ວ (ສູງສຸດ: ", MaxDailySLHits, " ຄັ້ງ/ວັນ)");
         Print("   ລໍຖ້າວັນໃໝ່ເພື່ອເທຣດຕໍ່...");
         lastWarningTime = currentTime;
      }
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours (Bangkok time)    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!UseTimeFilter) return true; // ຖ້າບໍ່ໃຊ້ time filter, ອະນຸຍາດເທຣດຕະຫຼອດ
   
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   
   // ແປງເວລາ server ໄປເປັນເວລາ Bangkok (GMT+7)
   // ຖ້າ broker ເປັນ GMT+0, ຕ້ອງບວກ 7 ຊົ່ວໂມງ
   // ຖ້າ broker ເປັນ GMT+2 (ເຊັ່ນ: ຫຼາຍໆ broker), ຕ້ອງບວກ 5 ຊົ່ວໂມງ
   
   // ຫາ GMT offset ຂອງ broker
   int serverGMTOffset = (int)(TimeGMTOffset() / 3600); // ແປງວິນາທີເປັນຊົ່ວໂມງ
   int hoursDiff = BangkokGMTOffset - serverGMTOffset;
   
   // ເວລາ Bangkok
   int bangkokHour = dt.hour + hoursDiff;
   
   // ປັບຖ້າຂ້າມວັນ
   if(bangkokHour >= 24) bangkokHour -= 24;
   if(bangkokHour < 0) bangkokHour += 24;
   
   // ກວດສອບວ່າຢູ່ໃນຊ່ວງເວລາທີ່ອະນຸຍາດບໍ່
   bool withinHours = (bangkokHour >= StartHour && bangkokHour < EndHour);
   
   if(!withinHours)
   {
      static datetime lastPrintTime = 0;
      // Print ທຸກໆ 1 ຊົ່ວໂມງ ເພື່ອບໍ່ໃຫ້ log ເຕັມ
      if(serverTime - lastPrintTime > 3600)
      {
         Print("ນອກຊ່ວງເວລາເທຣດ - Bangkok time: ", bangkokHour, ":00 (ອະນຸຍາດ: ", StartHour, ":00-", EndHour, ":00)");
         lastPrintTime = serverTime;
      }
   }
   
   return withinHours;
}

//+------------------------------------------------------------------+
//| Manage Lock After Profit and Trailing Stop                      |
//+------------------------------------------------------------------+
void ManageLockAfterProfit()
{
   if(!PositionSelect(_Symbol)) return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   long type = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   // ຄິດໄລ່ກຳໄລເປັນຈຸດ
   double profitPoints = 0.0;
   if(type == POSITION_TYPE_BUY)
      profitPoints = (bid - openPrice) / point;
   else if(type == POSITION_TYPE_SELL)
      profitPoints = (openPrice - ask) / point;
   
   // ຖ້າກຳໄລ ≥ 500 ຈຸດ, ເລີ່ມ trailing stop ທີ່ EMA9
   if(profitPoints >= TrailingStartPoints && !trailingActive)
   {
      double ema9;
      if(GetEMA9Value(ema9))
      {
         double newSL = 0.0;
         
         if(type == POSITION_TYPE_BUY)
         {
            newSL = ema9;
            newSL = NormalizeDouble(newSL, digits);
            
            if(trade.PositionModify(_Symbol, newSL, currentTP))
            {
               Print("BUY: ເລີ່ມ Trailing Stop ທີ່ EMA9 @ ", newSL, " (ກຳໄລ: ", (int)profitPoints, " ຈຸດ)");
               trailingActive = true;
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            newSL = ema9;
            newSL = NormalizeDouble(newSL, digits);
            
            if(trade.PositionModify(_Symbol, newSL, currentTP))
            {
               Print("SELL: ເລີ່ມ Trailing Stop ທີ່ EMA9 @ ", newSL, " (ກຳໄລ: ", (int)profitPoints, " ຈຸດ)");
               trailingActive = true;
            }
         }
      }
   }
   // ຖ້າກຳໄລ ≥ 200 ຈຸດ ແລະ ຍັງບໍ່ໄດ້ trailing, ຍ້າຍ SL ໄປ entry ± 20 ຈຸດ
   else if(profitPoints >= ProfitTriggerPoints && !slLocked && !trailingActive)
   {
      double newSL = 0.0;
      
      if(type == POSITION_TYPE_BUY)
      {
         // BUY: ຍ້າຍ SL ໄປ entry + 20 ຈຸດ
         newSL = openPrice + (LockPoints * point);
         newSL = NormalizeDouble(newSL, digits);
         
         if(trade.PositionModify(_Symbol, newSL, currentTP))
         {
            Print("BUY: SL ຍ້າຍໄປ entry +", LockPoints, " ຈຸດ @ ", newSL, " (ກຳໄລ: ", (int)profitPoints, " ຈຸດ)");
            slLocked = true;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         // SELL: ຍ້າຍ SL ໄປ entry - 20 ຈຸດ
         newSL = openPrice - (LockPoints * point);
         newSL = NormalizeDouble(newSL, digits);
         
         if(trade.PositionModify(_Symbol, newSL, currentTP))
         {
            Print("SELL: SL ຍ້າຍໄປ entry -", LockPoints, " ຈຸດ @ ", newSL, " (ກຳໄລ: ", (int)profitPoints, " ຈຸດ)");
            slLocked = true;
         }
      }
   }
   // ຖ້າ trailing active, ອັບເດດ SL ຕາມ EMA9
   else if(trailingActive)
   {
      double ema9;
      if(GetEMA9Value(ema9))
      {
         double newSL = NormalizeDouble(ema9, digits);
         
         // ກວດສອບວ່າຕ້ອງອັບເດດ SL ບໍ່
         bool needUpdate = false;
         if(type == POSITION_TYPE_BUY && newSL > currentSL)
            needUpdate = true;
         else if(type == POSITION_TYPE_SELL && newSL < currentSL)
            needUpdate = true;
         
         if(needUpdate)
         {
            if(trade.PositionModify(_Symbol, newSL, currentTP))
            {
               Print("Trailing Stop ອັບເດດ: ", newSL, " (EMA9)");
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
   
   // Create EMA9 indicator
   hEMA9 = iMA(_Symbol, PERIOD_CURRENT, EMA9_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(hEMA9 == INVALID_HANDLE)
   {
      Print("Failed to create EMA9 indicator handle");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("EMA9 Strategy EA initialized");
   Print("EMA9: ", EMA9_Period, " periods");
   Print("Lots: ", Lots, ", SL: ", SL_Points, " points");
   Print("Lock SL: ກຳໄລ ≥ ", ProfitTriggerPoints, " ຈຸດ → ຍ້າຍໄປ entry ± ", LockPoints, " ຈຸດ");
   Print("Trailing Stop: ກຳໄລ ≥ ", TrailingStartPoints, " ຈຸດ → trailing ທີ່ EMA9");
   
   if(UseTimeFilter)
      Print("Time Filter: ເທຣດພຽງ ", StartHour, ":00 - ", EndHour, ":00 (Bangkok GMT+7)");
   else
      Print("Time Filter: ປິດ (ເທຣດຕະຫຼອດ 24 ຊົ່ວໂມງ)");
   
   if(UseDailyLossLimit)
      Print("Daily Loss Limit: ຢຸດເທຣດຫຼັງຖືກ SL ", MaxDailySLHits, " ຄັ້ງ/ວັນ");
   else
      Print("Daily Loss Limit: ປິດ (ບໍ່ຈຳກັດຈຳນວນ SL)");
   
   // Initialize date tracking
   lastTradeDate = TimeCurrent();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA9 != INVALID_HANDLE) IndicatorRelease(hEMA9);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ກວດສອບວ່າມີ position ປິດດ້ວຍ SL ບໍ່
   CheckForSLHit();
   
   // ຖ້າມີ position ເປີດຢູ່, ກວດສອບການຍ້າຍ SL (ບໍ່ຂຶ້ນກັບເວລາ)
   if(PositionSelect(_Symbol))
   {
      ManageLockAfterProfit();
      return;
   }
   
   if(!IsNewBar()) return;
   
   // ກວດສອບວ່າຖືກ SL ເກີນກຳນົດແລ້ວບໍ່
   if(!CanTradeToday()) return;
   
   // ກວດສອບເວລາກ່ອນຊອກຫາສັນຍານໃໝ່
   if(!IsWithinTradingHours()) return;
   
   // Get EMA9 value
   double ema9;
   if(!GetEMA9Value(ema9)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // BUY Signal: ລາຄາຢູ່ເທິງ EMA9 ຫຼາຍກວ່າ 20+ ຈຸດ
   double buyDistance = (ask - ema9) / point;
   if(buyDistance > 20)
   {
      Print("BUY Signal: ລາຄາຢູ່ເທິງ EMA9 ", (int)buyDistance, " ຈຸດ");
      Print("Ask: ", ask, ", EMA9: ", ema9);
      
      double sl = ask - SL_Points * point;
      sl = NormalizeDouble(sl, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, 0, "EMA9 Buy"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl);
         slLocked = false; // Reset flags for new position
         trailingActive = false;
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
   // SELL Signal: ລາຄາຢູ່ລຸ່ມ EMA9 ຫຼາຍກວ່າ 20- ຈຸດ
   else if(buyDistance < -20)
   {
      Print("SELL Signal: ລາຄາຢູ່ລຸ່ມ EMA9 ", (int)MathAbs(buyDistance), " ຈຸດ");
      Print("Bid: ", bid, ", EMA9: ", ema9);
      
      double sl = bid + SL_Points * point;
      sl = NormalizeDouble(sl, digits);
      
      if(trade.Sell(Lots, _Symbol, bid, sl, 0, "EMA9 Sell"))
      {
         Print("SELL order opened - Entry: ", bid, ", SL: ", sl);
         slLocked = false; // Reset flags for new position
         trailingActive = false;
      }
      else
      {
         Print("SELL order failed - Error: ", trade.ResultRetcode());
      }
   }
   
}
