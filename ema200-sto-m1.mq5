//+------------------------------------------------------------------+
//|                                   StochTouchEMA200_v3.mq5        |
//| M1, Stoch(9,3,3) & EMA200                                        |
//| Buy:  close[1]>EMA200 && %K cross-down 20 -> SL=EMA-200, TP=+1000
//| Sell: close[1]<EMA200 && %K cross-down 80 -> SL=EMA+200, TP=-1000
//| New: Trailing to BE±20 pts when profit >= 200 pts                 |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs ---------------------------------
input int      MagicNumber       = 20090303;
input double   Lots              = 0.10;
input int      SlippagePoints    = 10;
input bool     OnePositionOnly   = true;

input int      TP_points         = 1000;   // ±1000 points
input int      SL_Offset_points  = 200;    // SL distance from EMA200
input ENUM_TIMEFRAMES SignalTF   = PERIOD_M1;

// Trailing-to-BE settings
input bool     UseTrailingBE     = true;
input int      TrailTriggerPts   = 200;    // trigger when profit >= 200 pts
input int      BE_BufferPts      = 20;     // BE buffer: +20 (buy), -20 (sell)

//--------------------------- Handles/Globals ------------------------
int    hEMA, hStoch;
double point;
int    digits;
datetime lastBarTime = 0;

//--------------------------- Helpers --------------------------------
bool NewBar()
{
   MqlRates r[2];
   if(CopyRates(_Symbol, SignalTF, 0, 2, r) < 2) return false;
   if(r[0].time != lastBarTime){ lastBarTime = r[0].time; return true; }
   return false;
}

int CountMyPositions()
{
   int c=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
   }
   return c;
}

// cross-down through a level (prev > level && curr <= level)
bool CrossDownToLevel(double prevK, double currK, double level)
{
   return (prevK > level && currK <= level && currK < prevK);
}

// Apply trailing to BE±buffer when profit >= trigger
void ApplyTrailingBE()
{
   if(!UseTrailingBE) return;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double price = (type==POSITION_TYPE_BUY)? bid : ask;
      double profitPts = (type==POSITION_TYPE_BUY)? (price - open)/point
                                                   : (open  - price)/point;

      if(profitPts >= TrailTriggerPts)
      {
         double be_sl = (type==POSITION_TYPE_BUY)? (open + BE_BufferPts*point)
                                                 : (open - BE_BufferPts*point);

         // ອັບເດດ SL ເທົ່ານັ້ນເມື່ອດີຂຶ້ນ (ປ້ອງກັນຖອຍ)
         bool needUpdate = (sl==0) ||
                           (type==POSITION_TYPE_BUY ? (be_sl > sl) : (be_sl < sl));

         if(needUpdate)
            trade.PositionModify(tk, be_sl, tp);
      }
   }
}

//------------------------------ Init --------------------------------
int OnInit()
{
   point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   hEMA   = iMA(_Symbol, SignalTF, 200, 0, MODE_EMA, PRICE_CLOSE);
   hStoch = iStochastic(_Symbol, SignalTF, 9, 3, 3, MODE_SMA, STO_LOWHIGH);

   if(hEMA==INVALID_HANDLE || hStoch==INVALID_HANDLE) return INIT_FAILED;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA!=INVALID_HANDLE)   IndicatorRelease(hEMA);
   if(hStoch!=INVALID_HANDLE) IndicatorRelease(hStoch);
}

//------------------------------ Tick --------------------------------
void OnTick()
{
   // Trailing ຄວນເຮັດທຸກ tick (ບໍ່ລໍຖ້າແທ້ງໃໝ່)
   ApplyTrailingBE();

   if(!NewBar()) return;

   double ema[3];  if(CopyBuffer(hEMA,0,0,3,ema)   < 3) return;
   double k[3];    if(CopyBuffer(hStoch,0,0,3,k)   < 3) return; // %K

   double close1 = iClose(_Symbol, SignalTF, 1);
   double ema1   = ema[1];

   bool priceAbove = (close1 > ema1);
   bool priceBelow = (close1 < ema1);

   // triggers:
   bool touch20 = CrossDownToLevel(k[2], k[1], 20.0); // for BUY (above EMA)
   bool touch80 = CrossDownToLevel(k[2], k[1], 80.0); // for SELL (below EMA)

   if(OnePositionOnly && CountMyPositions() > 0) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //----------------------------- BUY --------------------------------
   if(priceAbove && touch20)
   {
      double sl = ema1 - SL_Offset_points * point;   // EMA200 - 200
      double tp = ask  + TP_points        * point;   // +1000
      trade.Buy(Lots, _Symbol, ask, sl, tp);
      return;
   }

   //----------------------------- SELL -------------------------------
   if(priceBelow && touch80)
   {
      double sl = ema1 + SL_Offset_points * point;   // EMA200 + 200
      double tp = bid  - TP_points        * point;   // -1000
      trade.Sell(Lots, _Symbol, bid, sl, tp);
      return;
   }
}
