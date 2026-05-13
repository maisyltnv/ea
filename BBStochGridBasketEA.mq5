//+------------------------------------------------------------------+
//|                                          BBStochGridBasketEA.mq5 |
//| Bollinger (Typical) + Stochastic grid basket EA — signals on M1 |
//| Chart can be any period; indicators & new-bar logic use M1 data. |
//+------------------------------------------------------------------+
#property copyright "EA"
#property link      ""
#property version   "1.01"

#include <Trade/Trade.mqh>

//--- Inputs (strategy parameters)
input double LotSize                  = 0.01;
input int    GridCount                = 30;
input int    GridDistancePoints       = 500;
input int    BasketTakeProfitPoints   = 300; // total profit points; 0 = basket TP off
input int    BasketStopLossPoints     = 0;    // total loss points; 0 = basket SL off
input long   MagicNumber              = 123456;
input int    MaxSpreadPoints          = 0;
input int    StochasticOverboughtLevel = 90;
input int    StochasticOversoldLevel  = 10;
input int    BollingerPeriod          = 56;
input double BollingerDeviation       = 2.0;
input int    StochasticK              = 65;
input int    StochasticD              = 15;
input int    StochasticSlowing        = 8;
input bool   AllowNewCycle            = true;

//--- Optional execution
input int    SlippagePoints           = 30;

//--- Globals
CTrade       g_trade;
int          g_hBands   = INVALID_HANDLE;
int          g_hStoch  = INVALID_HANDLE;
datetime     g_lastBarTime = 0;

// Last copied values (shift 0) for signals and logging
// Stochastic: buffer 0 = %K (main), buffer 1 = %D (signal) — entries use %D only
double g_stochD = 0.0;
double g_bbUpper   = 0.0;
double g_bbLower   = 0.0;
double g_barHigh0  = 0.0;
double g_barLow0   = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization: create indicators on chart symbol / M1    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
      SymbolSelect(_Symbol, true);

   if(_Period != PERIOD_M1)
      Print("BBStochGridBasketEA: chart is ", EnumToString(_Period),
            " — EA stays attached; signals still use M1 (see indicator handles).");

   g_trade.SetExpertMagicNumber((ulong)MagicNumber);
   g_trade.SetDeviationInPoints(SlippagePoints);
   SetTradeFillingBySymbol();

   g_hBands = iBands(_Symbol, PERIOD_M1, BollingerPeriod, 0, BollingerDeviation, PRICE_TYPICAL);
   g_hStoch = iStochastic(_Symbol, PERIOD_M1, StochasticK, StochasticD, StochasticSlowing,
                          MODE_SMA, STO_LOWHIGH);

   if(g_hBands == INVALID_HANDLE || g_hStoch == INVALID_HANDLE)
     {
      Print("BBStochGridBasketEA: failed to create indicator handles. Bands=", g_hBands, " Stoch=", g_hStoch);
      return(INIT_FAILED);
     }

   if(GridCount < 1 || GridDistancePoints < 1 || LotSize <= 0.0)
     {
      Print("BBStochGridBasketEA: invalid inputs — GridCount>=1, GridDistancePoints>=1, LotSize>0 required.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // 0 so the first closed/open bar after attach can fire IsNewBar() (not stuck on init-time bar)
   g_lastBarTime = 0;
   Print("BBStochGridBasketEA initialized on ", _Symbol, " M1. Magic=", MagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hBands != INVALID_HANDLE)  IndicatorRelease(g_hBands);
   if(g_hStoch != INVALID_HANDLE) IndicatorRelease(g_hStoch);
   Print("BBStochGridBasketEA deinit. reason=", reason);
  }

//+------------------------------------------------------------------+
//| Choose a supported filling mode for the symbol                 |
//+------------------------------------------------------------------+
void SetTradeFillingBySymbol()
  {
   const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fm & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
//| Point size (handles 3- and 5-digit quotes consistently)         |
//+------------------------------------------------------------------+
double PointSize()
  {
   return(SymbolInfoDouble(_Symbol, SYMBOL_POINT));
  }

//+------------------------------------------------------------------+
//| Current spread in points                                         |
//+------------------------------------------------------------------+
int CurrentSpreadPoints()
  {
   const double pt = PointSize();
   if(pt <= 0.0)
      return(0);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return((int)MathRound((ask - bid) / pt));
  }

//+------------------------------------------------------------------+
//| Decimal places implied by SYMBOL_VOLUME_STEP (no SYMBOL_VOLUME_  |
//| DIGITS in standard MQL5 enum)                                    |
//+------------------------------------------------------------------+
int LotDigitsFromStep(const double stepLot)
  {
   if(stepLot <= 0.0)
      return(2);
   if(stepLot >= 1.0 - 1e-12)
      return(0);
   int   digits = 0;
   double x      = stepLot;
   while(digits < 8 && x + 1e-12 < 1.0)
     {
      x *= 10.0;
      digits++;
     }
   return(digits);
  }

//+------------------------------------------------------------------+
//| Normalize lot to symbol constraints                              |
//+------------------------------------------------------------------+
double NormalizeLotVolume(const double lotsIn)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const int lotDigits = LotDigitsFromStep(stepLot);

   if(stepLot <= 0.0)
      stepLot = 0.01;

   double lots = lotsIn;
   if(lots < minLot)
      lots = minLot;
   if(lots > maxLot)
      lots = maxLot;

   lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot)
      lots = minLot;

   return(NormalizeDouble(lots, lotDigits));
  }

//+------------------------------------------------------------------+
//| Normalize price to _Digits                                       |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   return(NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
  }

//+------------------------------------------------------------------+
//| Returns true once per new M1 bar (signal / entry timing)       |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   const datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == 0)
      return(false);
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Copy indicator / OHLC data for bar 0 into globals                |
//+------------------------------------------------------------------+
bool RefreshBarData()
  {
   double stD[1], up[1], lo[1];
   // iBands: buffer 1 = upper band, buffer 2 = lower band (buffer 0 = middle)
   if(CopyBuffer(g_hStoch, 1, 0, 1, stD) != 1)
     {
      Print("BBStochGridBasketEA: CopyBuffer Stochastic signal line (%D) failed. err=", GetLastError());
      return(false);
     }
   if(CopyBuffer(g_hBands, 1, 0, 1, up) != 1)
     {
      Print("BBStochGridBasketEA: CopyBuffer BB upper failed. err=", GetLastError());
      return(false);
     }
   if(CopyBuffer(g_hBands, 2, 0, 1, lo) != 1)
     {
      Print("BBStochGridBasketEA: CopyBuffer BB lower failed. err=", GetLastError());
      return(false);
     }

   g_stochD = stD[0];
   g_bbUpper   = up[0];
   g_bbLower   = lo[0];
   g_barHigh0  = iHigh(_Symbol, PERIOD_M1, 0);
   g_barLow0   = iLow(_Symbol, PERIOD_M1, 0);

   Print("Indicators [bar0]: StochD=", DoubleToString(g_stochD, 2),
         " BB_Upper=", DoubleToString(g_bbUpper, _Digits),
         " BB_Lower=", DoubleToString(g_bbLower, _Digits),
         " High0=", DoubleToString(g_barHigh0, _Digits),
         " Low0=", DoubleToString(g_barLow0, _Digits));
   return(true);
  }

//+------------------------------------------------------------------+
//| Sell setup: stoch overbought + price touches/crosses upper BB   |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   if(g_stochD <= (double)StochasticOverboughtLevel)
      return(false);

   const double highPrev = iHigh(_Symbol, PERIOD_M1, 1);
   double upPrev[1];
   if(CopyBuffer(g_hBands, 1, 1, 1, upPrev) != 1)
      return(false);

   const bool touchOrCross = (g_barHigh0 >= g_bbUpper) ||
                             (highPrev < upPrev[0] && g_barHigh0 >= g_bbUpper);

   if(touchOrCross)
      Print("ENTRY SIGNAL: SELL setup — StochD=", DoubleToString(g_stochD, 2),
            " > ", StochasticOverboughtLevel,
            "; touch/cross upper BB (High0 vs Upper0).");
   return(touchOrCross);
  }

//+------------------------------------------------------------------+
//| Buy setup: stoch oversold + price touches/crosses lower BB     |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   if(g_stochD >= (double)StochasticOversoldLevel)
      return(false);

   const double lowPrev = iLow(_Symbol, PERIOD_M1, 1);
   double loPrev[1];
   if(CopyBuffer(g_hBands, 2, 1, 1, loPrev) != 1)
      return(false);

   const bool touchOrCross = (g_barLow0 <= g_bbLower) ||
                             (lowPrev > loPrev[0] && g_barLow0 <= g_bbLower);

   if(touchOrCross)
      Print("ENTRY SIGNAL: BUY setup — StochD=", DoubleToString(g_stochD, 2),
            " < ", StochasticOversoldLevel,
            "; touch/cross lower BB (Low0 vs Lower0).");
   return(touchOrCross);
  }

//+------------------------------------------------------------------+
//| Place Sell Limit grid above anchor price                        |
//+------------------------------------------------------------------+
void PlaceSellGrid(const double anchorPrice)
  {
   const double pt    = PointSize();
   const double step  = (double)GridDistancePoints * pt;
   const double lot   = NormalizeLotVolume(LotSize);

   for(int i = 1; i <= GridCount; i++)
     {
      const double price = NormalizePrice(anchorPrice + step * (double)i);

      if(!g_trade.SellLimit(lot, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0.0, "BBStoch SellLimit"))
        {
         Print("FAILED pending SellLimit #", i, " price=", price,
               " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
        }
      else
        {
         Print("Pending SellLimit #", i, " placed ticket=", g_trade.ResultOrder(),
               " price=", DoubleToString(price, _Digits), " lot=", DoubleToString(lot, 2));
        }
     }
  }

//+------------------------------------------------------------------+
//| Place Buy Limit grid below anchor price                         |
//+------------------------------------------------------------------+
void PlaceBuyGrid(const double anchorPrice)
  {
   const double pt    = PointSize();
   const double step  = (double)GridDistancePoints * pt;
   const double lot   = NormalizeLotVolume(LotSize);

   for(int i = 1; i <= GridCount; i++)
     {
      const double price = NormalizePrice(anchorPrice - step * (double)i);

      if(!g_trade.BuyLimit(lot, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0.0, "BBStoch BuyLimit"))
        {
         Print("FAILED pending BuyLimit #", i, " price=", price,
               " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
        }
      else
        {
         Print("Pending BuyLimit #", i, " placed ticket=", g_trade.ResultOrder(),
               " price=", DoubleToString(price, _Digits), " lot=", DoubleToString(lot, 2));
        }
     }
  }

//+------------------------------------------------------------------+
//| Open market SELL + sell-limit grid (one cycle)                  |
//+------------------------------------------------------------------+
void OpenSellCycle()
  {
   const double lot = NormalizeLotVolume(LotSize);
   if(!g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "BBStoch market SELL"))
     {
      Print("FAILED market SELL lot=", lot,
            " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
      return;
     }

   Print("Market SELL opened ticket=", g_trade.ResultDeal(), " lot=", DoubleToString(lot, 2));

   // Anchor grid from price after fill (per spec: distances from current price)
   const double anchor = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   PlaceSellGrid(anchor);
  }

//+------------------------------------------------------------------+
//| Open market BUY + buy-limit grid (one cycle)                    |
//+------------------------------------------------------------------+
void OpenBuyCycle()
  {
   const double lot = NormalizeLotVolume(LotSize);
   if(!g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "BBStoch market BUY"))
     {
      Print("FAILED market BUY lot=", lot,
            " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
      return;
     }

   Print("Market BUY opened ticket=", g_trade.ResultDeal(), " lot=", DoubleToString(lot, 2));

   const double anchor = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   PlaceBuyGrid(anchor);
  }

//+------------------------------------------------------------------+
//| Sum floating profit in points for all EA positions on symbol   |
//+------------------------------------------------------------------+
double GetBasketProfitPoints()
  {
   double totalPts = 0.0;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double pt  = PointSize();
   if(pt <= 0.0)
      return(0.0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const long   type      = PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         totalPts += (bid - openPrice) / pt;
      else if(type == POSITION_TYPE_SELL)
         totalPts += (openPrice - ask) / pt;
     }
   return(totalPts);
  }

//+------------------------------------------------------------------+
//| Close all EA market positions and remove EA pending orders      |
//+------------------------------------------------------------------+
void CloseAllPositionsAndDeletePendings()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(!g_trade.PositionClose(ticket))
        {
         Print("FAILED PositionClose ticket=", ticket,
               " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
        }
      else
         Print("Position closed ticket=", ticket);
     }

   for(int j = OrdersTotal() - 1; j >= 0; j--)
     {
      const ulong ot = OrderGetTicket(j);
      if(ot == 0)
         continue;
      if(!OrderSelect(ot))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      if(!g_trade.OrderDelete(ot))
        {
         Print("FAILED OrderDelete ticket=", ot,
               " retcode=", g_trade.ResultRetcode(), " desc=", g_trade.ResultRetcodeDescription());
        }
      else
         Print("Pending order deleted ticket=", ot);
     }
  }

//+------------------------------------------------------------------+
//| Count positions + pendings for this symbol and magic           |
//+------------------------------------------------------------------+
int CountOpenPositionsAndPendingOrders()
  {
   int count = 0;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
     }

   for(int j = 0; j < OrdersTotal(); j++)
     {
      const ulong ot = OrderGetTicket(j);
      if(ot == 0)
         continue;
      if(!OrderSelect(ot))
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Expert tick: basket management + new-bar entries               |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_trade.SetExpertMagicNumber((ulong)MagicNumber);

   const double basketPts = GetBasketProfitPoints();

   if(BasketTakeProfitPoints > 0 && basketPts >= (double)BasketTakeProfitPoints)
     {
      Print("BASKET TAKE PROFIT: total points=", DoubleToString(basketPts, 2),
            " >= ", BasketTakeProfitPoints, " — closing all and deleting pendings.");
      CloseAllPositionsAndDeletePendings();
      return;
     }

   if(BasketStopLossPoints > 0 && basketPts <= -(double)BasketStopLossPoints)
     {
      Print("BASKET STOP LOSS: total points=", DoubleToString(basketPts, 2),
            " <= -", BasketStopLossPoints, " — closing all and deleting pendings.");
      CloseAllPositionsAndDeletePendings();
      return;
     }

   if(!AllowNewCycle)
      return;

   if(CountOpenPositionsAndPendingOrders() > 0)
      return;

   if(MaxSpreadPoints > 0 && CurrentSpreadPoints() > MaxSpreadPoints)
     {
      static datetime s_lastSpreadLogBar = 0;
      const datetime  barT = iTime(_Symbol, PERIOD_M1, 0);
      if(barT != 0 && barT != s_lastSpreadLogBar)
        {
         s_lastSpreadLogBar = barT;
         Print("Spread filter: ", CurrentSpreadPoints(), " points > MaxSpreadPoints ", MaxSpreadPoints,
               " — skip new cycle this bar.");
        }
      return;
     }

   if(!IsNewBar())
      return;

   if(BarsCalculated(g_hBands) < BollingerPeriod + 5 || BarsCalculated(g_hStoch) < StochasticK + StochasticD + StochasticSlowing + 5)
      return;

   if(!RefreshBarData())
      return;

   if(CheckSellSignal())
      OpenSellCycle();
   else if(CheckBuySignal())
      OpenBuyCycle();
  }

//+------------------------------------------------------------------+
