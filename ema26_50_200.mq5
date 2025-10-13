//+------------------------------------------------------------------+
//| EMA26/EMA50/EMA200 + Stochastic Strategy EA                      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input Parameters
input double Lots = 0.10;
input int SL_Points = 500;
input int TP_Points = 1000;
input int EMA26_Period = 26;
input int EMA50_Period = 50;
input int EMA200_Period = 200;
input int Stoch_K = 9;
input int Stoch_D = 3;
input int Stoch_Slowing = 3;
input ulong Magic = 123456;

// Lock-after-profit settings
input int ProfitTriggerPoints = 200; // ຍ້າຍ SL ເມື່ອກຳໄລ ≥ 200 ຈຸດ
input int LockPoints = 20;           // ຍ້າຍ SL ໄປ entry ± 20 ຈຸດ

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
int hEMA26, hEMA50, hEMA200, hStoch;
datetime lastBarTime = 0;
bool slLocked = false; // ຕິດຕາມວ່າ SL ຖືກຍ້າຍແລ້ວຫຼືຍັງ

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
//| Get EMA values                                                   |
//+------------------------------------------------------------------+
bool GetEMAValues(double &ema26, double &ema50, double &ema200)
{
   if(hEMA26 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE || hEMA200 == INVALID_HANDLE) return false;
   
   double ema26_buf[1], ema50_buf[1], ema200_buf[1];
   if(CopyBuffer(hEMA26, 0, 1, 1, ema26_buf) != 1) return false;
   if(CopyBuffer(hEMA50, 0, 1, 1, ema50_buf) != 1) return false;
   if(CopyBuffer(hEMA200, 0, 1, 1, ema200_buf) != 1) return false;
   
   ema26 = ema26_buf[0];
   ema50 = ema50_buf[0];
   ema200 = ema200_buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Get Stochastic values                                            |
//+------------------------------------------------------------------+
bool GetStochValues(double &stoch_main, double &stoch_signal)
{
   if(hStoch == INVALID_HANDLE) return false;
   
   double stoch_main_buf[1], stoch_signal_buf[1];
   if(CopyBuffer(hStoch, 0, 1, 1, stoch_main_buf) != 1) return false;
   if(CopyBuffer(hStoch, 1, 1, 1, stoch_signal_buf) != 1) return false;
   
   stoch_main = stoch_main_buf[0];
   stoch_signal = stoch_signal_buf[0];
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
//| Manage Lock After Profit                                         |
//+------------------------------------------------------------------+
void ManageLockAfterProfit()
{
   if(!PositionSelect(_Symbol)) return;
   
   // ຖ້າ SL ຖືກຍ້າຍແລ້ວ, ບໍ່ຕ້ອງກວດອີກ
   if(slLocked) return;
   
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
   
   // ຖ້າກຳໄລ ≥ 200 ຈຸດ, ຍ້າຍ SL
   if(profitPoints >= ProfitTriggerPoints)
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
         else
         {
            Print("BUY: ຍ້າຍ SL ບໍ່ສຳເລັດ. Retcode=", trade.ResultRetcode());
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
         else
         {
            Print("SELL: ຍ້າຍ SL ບໍ່ສຳເລັດ. Retcode=", trade.ResultRetcode());
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
   
   // Create EMA indicators
   hEMA26 = iMA(_Symbol, PERIOD_CURRENT, EMA26_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_CURRENT, EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200 = iMA(_Symbol, PERIOD_CURRENT, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   // Create Stochastic indicator
   hStoch = iStochastic(_Symbol, PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   
   if(hEMA26 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE || hEMA200 == INVALID_HANDLE || hStoch == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }
   
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) == 1) lastBarTime = t[0];
   
   Print("EMA26/EMA50/EMA200 + Stochastic EA initialized");
   Print("EMA26: ", EMA26_Period, ", EMA50: ", EMA50_Period, ", EMA200: ", EMA200_Period);
   Print("Stochastic: ", Stoch_K, ",", Stoch_D, ",", Stoch_Slowing);
   Print("SL: ", SL_Points, ", TP: ", TP_Points, " points");
   Print("Lock SL: ກຳໄລ ≥ ", ProfitTriggerPoints, " ຈຸດ → ຍ້າຍໄປ entry ± ", LockPoints, " ຈຸດ");
   
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
   if(hEMA26 != INVALID_HANDLE) IndicatorRelease(hEMA26);
   if(hEMA50 != INVALID_HANDLE) IndicatorRelease(hEMA50);
   if(hEMA200 != INVALID_HANDLE) IndicatorRelease(hEMA200);
   if(hStoch != INVALID_HANDLE) IndicatorRelease(hStoch);
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
   
   // Get indicator values
   double ema26, ema50, ema200, stoch_main, stoch_signal;
   if(!GetEMAValues(ema26, ema50, ema200)) return;
   if(!GetStochValues(stoch_main, stoch_signal)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // BUY Signal: ເງື່ອນໄຂທີ່ຖືກຕ້ອງ
   // 1. Stochastic ≤ 20 (oversold)
   // 2. ລາຄາ > EMA26 > EMA50 > EMA200 (ກວດສອບ trend ກ່ອນ)
   if(stoch_main <= 20 && ask > ema200 && ask > ema26 && ema26 > ema50 && ema50 > ema200)
   {
      Print("BUY Signal: Stochastic oversold, Price > EMA26 > EMA50 > EMA200");
      Print("Price: ", ask, " > EMA26: ", ema26, " > EMA50: ", ema50, " > EMA200: ", ema200);
      Print("Stoch: ", stoch_main, "/", stoch_signal);
      
      double sl = ask - SL_Points * point;
      double tp = ask + TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "EMA26>50>200 + Stoch Buy"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl, ", TP: ", tp);
         slLocked = false; // Reset flag for new position
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
   // SELL Signal: ເງື່ອນໄຂທີ່ຖືກຕ້ອງ
   // 1. Stochastic ≥ 80 (overbought)
   // 2. ລາຄາ < EMA26 < EMA50 < EMA200 (ກວດສອບ trend ກ່ອນ)
   else if(stoch_main >= 80 && bid < ema200 && bid < ema26 && ema26 < ema50 && ema50 < ema200)
   {
      Print("SELL Signal: Stochastic overbought, Price < EMA26 < EMA50 < EMA200");
      Print("Price: ", bid, " < EMA26: ", ema26, " < EMA50: ", ema50, " < EMA200: ", ema200);
      Print("Stoch: ", stoch_main, "/", stoch_signal);
      
      double sl = bid + SL_Points * point;
      double tp = bid - TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Sell(Lots, _Symbol, bid, sl, tp, "EMA26<50<200 + Stoch Sell"))
      {
         Print("SELL order opened - Entry: ", bid, ", SL: ", sl, ", TP: ", tp);
         slLocked = false; // Reset flag for new position
      }
      else
      {
         Print("SELL order failed - Error: ", trade.ResultRetcode());
      }
   }
}
