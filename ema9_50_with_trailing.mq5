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

// Global Variables
CTrade trade;
int hEMA26, hEMA50, hEMA200, hStoch;
datetime lastBarTime = 0;

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
   // ຖ້າມີ position ເປີດຢູ່, ບໍ່ຕ້ອງກວດສອບສັນຍານໃໝ່
   if(PositionSelect(_Symbol)) return;
   
   if(!IsNewBar()) return;
   
   // Get indicator values
   double ema26, ema50, ema200, stoch_main, stoch_signal;
   if(!GetEMAValues(ema26, ema50, ema200)) return;
   if(!GetStochValues(stoch_main, stoch_signal)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // BUY Signal: ຕາມເງື່ອນໄຂທີ່ແກ້ໄຂ
   // 1. Stochastic ≤ 20 (oversold)
   // 2. EMA50 ຢູ່ເທິງ EMA200 (uptrend)
   // 3. ລາຄາຢູ່ເທິງ EMA200
   if(stoch_main <= 20 && ema50 > ema200 && ask > ema200)
   {
      Print("BUY Signal: Stochastic oversold, EMA50 > EMA200, Price above EMA200");
      Print("EMA26: ", ema26, ", EMA50: ", ema50, ", EMA200: ", ema200);
      Print("Stoch: ", stoch_main, "/", stoch_signal);
      
      double sl = ask - SL_Points * point;
      double tp = ask + TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Buy(Lots, _Symbol, ask, sl, tp, "EMA50/200 + Stoch Buy"))
      {
         Print("BUY order opened - Entry: ", ask, ", SL: ", sl, ", TP: ", tp);
      }
      else
      {
         Print("BUY order failed - Error: ", trade.ResultRetcode());
      }
   }
   // SELL Signal: ຕາມເງື່ອນໄຂທີ່ແກ້ໄຂ
   // 1. Stochastic ≥ 80 (overbought)
   // 2. EMA50 ຢູ່ລຸ່ມ EMA200 (downtrend)
   // 3. ລາຄາຢູ່ລຸ່ມ EMA200
   else if(stoch_main >= 80 && ema50 < ema200 && bid < ema200)
   {
      Print("SELL Signal: Stochastic overbought, EMA50 < EMA200, Price below EMA200");
      Print("EMA26: ", ema26, ", EMA50: ", ema50, ", EMA200: ", ema200);
      Print("Stoch: ", stoch_main, "/", stoch_signal);
      
      double sl = bid + SL_Points * point;
      double tp = bid - TP_Points * point;
      
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      if(trade.Sell(Lots, _Symbol, bid, sl, tp, "EMA50/200 + Stoch Sell"))
      {
         Print("SELL order opened - Entry: ", bid, ", SL: ", sl, ", TP: ", tp);
      }
      else
      {
         Print("SELL order failed - Error: ", trade.ResultRetcode());
      }
   }
}
