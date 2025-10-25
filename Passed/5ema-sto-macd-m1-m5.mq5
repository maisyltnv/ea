#property strict
#property version "1.0"
#property description "MTF EMA Pullback + MACD (M5) + Stochastic (M1) Entry"

input long   MagicNumber        = 2501025;
input double RiskFixedLots      = 0.10;      // fixed lot (set >0); set 0 to use risk by SL
input double RiskPercent        = 1.0;       // used only when RiskFixedLots==0
// --- EMAs on M1
input int    EMA_Fast           = 14;
input int    EMA_Med1           = 26;
input int    EMA_Med2           = 50;
input int    EMA_Med3           = 100;
input int    EMA_Slow           = 200;
// --- Stochastic on M1
input int    Sto_K              = 9;
input int    Sto_D              = 3;
input int    Sto_Slowing        = 3;
input double BuyStoZone         = 20.0;      // buy waits until %K <= this (M1)
input double SellStoZone        = 20.0;      // you asked for 20 as well; change to 80 if desired
// --- MACD on M5
input int    MACD_Fast          = 12;
input int    MACD_Slow          = 26;
input int    MACD_Signal        = 9;
input double MACD_LevelPts      = 3.0;       // +/- points threshold on M5 histogram
// --- SL/TP (points)
input int    SL_OffsetPts       = 200;       // distance from EMA200
input int    TP_Points          = 1000;
// --- Trade controls
input bool   OnePositionPerSide = true;      // prevent multiple buys/sells simultaneously
input bool   OneSignalPerBar    = true;      // act once per new M1 bar

// --- Indicator handles
int hEmaFastM1, hEma26M1, hEma50M1, hEma100M1, hEma200M1;
int hStoM1;
int hMacdM5;

// --- state
datetime lastBarM1 = 0;
bool pendingLong = false;
bool pendingShort = false;

bool GetBufferLatest(int handle, int bufIndex, ENUM_TIMEFRAMES tf, double &val)
{
   double b[];
   if(CopyBuffer(handle, bufIndex, 0, 2, b) < 2) return false;
   val = b[0];
   return true;
}

bool GetBufferShifted(int handle, int bufIndex, int shift, double &val)
{
   double b[];
   if(CopyBuffer(handle, bufIndex, shift, 1, b) < 1) return false;
   val = b[0];
   return true;
}

bool TrendUp(double e14, double e26, double e50, double e100, double e200)
{
   return (e14>e26 && e26>e50 && e50>e100 && e100>e200);
}

bool TrendDown(double e14, double e26, double e50, double e100, double e200)
{
   return (e14<e26 && e26<e50 && e50<e100 && e100<e200);
}

// Detect pullback event: for uptrend, price crosses below EMA14 but remains above EMA200 on the last closed bar.
bool PulledBackUp(double close0, double close1, double ema14_0, double ema14_1, double ema200_0)
{
   // Crossed below EMA14 on the just-closed bar while still above EMA200
   bool crossedBelow = (close1 > ema14_1 && close0 < ema14_0);
   return (crossedBelow && close0 > ema200_0);
}

// For downtrend, price crosses above EMA14 but remains below EMA200.
bool PulledBackDown(double close0, double close1, double ema14_0, double ema14_1, double ema200_0)
{
   bool crossedAbove = (close1 < ema14_1 && close0 > ema14_0);
   return (crossedAbove && close0 < ema200_0);
}

bool HasOpenPos(int typeWanted) // POSITION_TYPE_BUY / SELL
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE)==typeWanted) return true;
   }
   return false;
}

double CalcLotsByRisk(double entry, double sl)
{
   if(RiskFixedLots>0) return RiskFixedLots;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent/100.0);
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt        = _Point;

   double slPts = MathMax(1.0, MathAbs(entry - sl)/pt);
   double perLotLoss = slPts * (tickVal/tickSize);
   if(perLotLoss<=0) return 0;

   double lots = riskMoney / perLotLoss;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // floor to step
   lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}

bool SendOrder(int orderType, double sl, double tp)
{
   MqlTradeRequest r; MqlTradeResult s;
   ZeroMemory(r); ZeroMemory(s);

   double price = (orderType==ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lots = CalcLotsByRisk(price, sl);
   if(lots <= 0.0) { Print("Lot calc <=0"); return false; }

   r.action   = TRADE_ACTION_DEAL;
   r.symbol   = _Symbol;
   r.magic    = MagicNumber;
   r.type     = (ENUM_ORDER_TYPE)orderType;
   r.volume   = lots;
   r.price    = price;
   r.sl       = sl;
   r.tp       = tp;
   r.deviation= 10;

   if(!OrderSend(r, s))
   {
      Print("OrderSend failed: ", s.retcode);
      return false;
   }
   return true;
}

int OnInit()
{
   hEmaFastM1  = iMA(_Symbol, PERIOD_M1, EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   hEma26M1    = iMA(_Symbol, PERIOD_M1, EMA_Med1,  0, MODE_EMA, PRICE_CLOSE);
   hEma50M1    = iMA(_Symbol, PERIOD_M1, EMA_Med2,  0, MODE_EMA, PRICE_CLOSE);
   hEma100M1   = iMA(_Symbol, PERIOD_M1, EMA_Med3,  0, MODE_EMA, PRICE_CLOSE);
   hEma200M1   = iMA(_Symbol, PERIOD_M1, EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);

   hStoM1      = iStochastic(_Symbol, PERIOD_M1, Sto_K, Sto_D, Sto_Slowing, MODE_SMA, STO_LOWHIGH);
   hMacdM5     = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);

   if(hEmaFastM1==INVALID_HANDLE || hEma26M1==INVALID_HANDLE || hEma50M1==INVALID_HANDLE ||
      hEma100M1==INVALID_HANDLE || hEma200M1==INVALID_HANDLE || hStoM1==INVALID_HANDLE ||
      hMacdM5==INVALID_HANDLE)
   {
      Print("Indicator handle error");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFastM1!=INVALID_HANDLE)  IndicatorRelease(hEmaFastM1);
   if(hEma26M1  !=INVALID_HANDLE)  IndicatorRelease(hEma26M1);
   if(hEma50M1  !=INVALID_HANDLE)  IndicatorRelease(hEma50M1);
   if(hEma100M1 !=INVALID_HANDLE)  IndicatorRelease(hEma100M1);
   if(hEma200M1 !=INVALID_HANDLE)  IndicatorRelease(hEma200M1);
   if(hStoM1    !=INVALID_HANDLE)  IndicatorRelease(hStoM1);
   if(hMacdM5   !=INVALID_HANDLE)  IndicatorRelease(hMacdM5);
}

void OnTick()
{
   // operate once per new M1 bar (avoids repeated triggers in same candle)
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(OneSignalPerBar && barTime==lastBarM1) return;
   lastBarM1 = barTime;

   // --- read M1 values (bar 0 and bar 1)
   double ema14_0, ema26_0, ema50_0, ema100_0, ema200_0;
   double ema14_1, ema26_1;
   if(!GetBufferLatest(hEmaFastM1, 0, PERIOD_M1, ema14_0)) return;
   if(!GetBufferLatest(hEma26M1,   0, PERIOD_M1, ema26_0)) return;
   if(!GetBufferLatest(hEma50M1,   0, PERIOD_M1, ema50_0)) return;
   if(!GetBufferLatest(hEma100M1,  0, PERIOD_M1, ema100_0)) return;
   if(!GetBufferLatest(hEma200M1,  0, PERIOD_M1, ema200_0)) return;
   if(!GetBufferShifted(hEmaFastM1, 0, 1, ema14_1)) return;
   if(!GetBufferShifted(hEma26M1,   0, 1, ema26_1)) return;

   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   double close1 = iClose(_Symbol, PERIOD_M1, 1);

   // --- read Stochastic %K on M1
   double stoK_0;
   if(!GetBufferLatest(hStoM1, 0, PERIOD_M1, stoK_0)) return;

   // --- read MACD histogram on M5 (main - signal)
   double macdMain_M5, macdSignal_M5;
   if(!GetBufferLatest(hMacdM5, 0, PERIOD_M5, macdMain_M5))   return; // main
   if(!GetBufferLatest(hMacdM5, 1, PERIOD_M5, macdSignal_M5)) return; // signal
   double macdHistPts = (macdMain_M5 - macdSignal_M5)/_Point;

   // --- trend checks
   bool up = TrendUp(ema14_0, ema26_0, ema50_0, ema100_0, ema200_0);
   bool dn = TrendDown(ema14_0, ema26_0, ema50_0, ema100_0, ema200_0);

   // --- detect fresh pullback events (set pending)
   if(up && PulledBackUp(close0, close1, ema14_0, ema14_1, ema200_0))
      pendingLong = true;
   if(dn && PulledBackDown(close0, close1, ema14_0, ema14_1, ema200_0))
      pendingShort = true;

   // --- Buy logic:
   // 1) MACD(M5) >= +3 points
   // 2) EMA14>26>50>100>200 && price pullback above EMA200 recorded (pendingLong)
   // 3) Wait until Sto(M1) %K <= 20 then Buy
   if(pendingLong)
   {
      bool macdOK = (macdHistPts >= MACD_LevelPts);
      bool envOK  = up && (close0 > ema200_0);
      bool stochOK= (stoK_0 <= BuyStoZone);

      bool allowEntry = macdOK && envOK && stochOK;

      if(allowEntry)
      {
         // SL = EMA200 - 200 pts ; TP = +1000 pts
         double sl = ema200_0 - SL_OffsetPts*_Point;
         double tp = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + TP_Points*_Point;

         if(!OnePositionPerSide || !HasOpenPos(POSITION_TYPE_BUY))
         {
            if(SendOrder(ORDER_TYPE_BUY, sl, tp))
               pendingLong = false; // consumed
         }
         else
         {
            pendingLong = false; // skip but clear to avoid loops
         }
      }
      // if trend invalidates, clear the pending
      if(!up || close0 <= ema200_0) pendingLong = false;
   }

   // --- Sell logic:
   // 1) MACD(M5) <= -3 points
   // 2) EMA14<26<50<100<200 && pullback below EMA200 (pendingShort)
   // 3) Wait until Sto(M1) %K <= SellStoZone (you asked 20) then Sell
   if(pendingShort)
   {
      bool macdOK = (macdHistPts <= -MACD_LevelPts);
      bool envOK  = dn && (close0 < ema200_0);
      bool stochOK= (stoK_0 <= SellStoZone);

      bool allowEntry = macdOK && envOK && stochOK;

      if(allowEntry)
      {
         // SL = EMA200 + 200 pts ; TP = -1000 pts
         double sl = ema200_0 + SL_OffsetPts*_Point;
         double tp = SymbolInfoDouble(_Symbol, SYMBOL_BID) - TP_Points*_Point;

         if(!OnePositionPerSide || !HasOpenPos(POSITION_TYPE_SELL))
         {
            if(SendOrder(ORDER_TYPE_SELL, sl, tp))
               pendingShort = false;
         }
         else
         {
            pendingShort = false;
         }
      }
      if(!dn || close0 >= ema200_0) pendingShort = false;
   }
}
