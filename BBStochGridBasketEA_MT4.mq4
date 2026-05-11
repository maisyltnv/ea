//+------------------------------------------------------------------+
//|                                   BBStochGridBasketEA_MT4.mq4   |
//| Bollinger (Typical) + Stochastic grid basket EA — M1 only (MT4) |
//+------------------------------------------------------------------+
#property copyright "EA"
#property link      ""
#property version   "1.00"
#property strict

//--- Inputs required
extern double LotSize                   = 0.01;
extern int    GridCount                 = 5;
extern int    GridDistancePoints        = 1000;
extern int    BasketTakeProfitPoints    = 1000; // total profit points; 0 = basket TP off
extern int    BasketStopLossPoints      = 0;    // total loss points; 0 = basket SL off
extern int    MagicNumber               = 123456;
extern int    MaxSpreadPoints           = 0;
extern int    StochasticOverboughtLevel = 90;
extern int    StochasticOversoldLevel   = 10;
extern int    BollingerPeriod           = 56;
extern double BollingerDeviation        = 2.0;
extern int    StochasticK               = 65;
extern int    StochasticD               = 15;
extern int    StochasticSlowing         = 8;
extern bool   AllowNewCycle             = true;
extern int    SlippagePoints            = 30;

//--- Globals
datetime g_lastBarTime = 0;

double g_stochMain = 0.0;
double g_bbUpper   = 0.0;
double g_bbLower   = 0.0;
double g_barHigh0  = 0.0;
double g_barLow0   = 0.0;

//+------------------------------------------------------------------+
//| Helpers                                                         |
//+------------------------------------------------------------------+
double NormalizePrice(const double price) { return(NormalizeDouble(price, Digits)); }

int CurrentSpreadPoints()
{
   // In MT4, MODE_SPREAD is returned in points (not price)
   return((int)MarketInfo(Symbol(), MODE_SPREAD));
}

int LotDigitsFromStep(const double stepLot)
{
   if(stepLot <= 0.0) return(2);
   if(stepLot >= 1.0 - 1e-12) return(0);
   int digits = 0;
   double x = stepLot;
   while(digits < 8 && x + 1e-12 < 1.0)
   {
      x *= 10.0;
      digits++;
   }
   return(digits);
}

double NormalizeLotVolume(const double lotsIn)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double stepLot = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(stepLot <= 0.0) stepLot = 0.01;

   int lotDigits = LotDigitsFromStep(stepLot);

   double lots = lotsIn;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot) lots = minLot;

   return(NormalizeDouble(lots, lotDigits));
}

//+------------------------------------------------------------------+
//| New bar detection (M1)                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(Symbol(), PERIOD_M1, 0);
   if(t == 0) return(false);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Count open positions + pending orders for this symbol/magic     |
//+------------------------------------------------------------------+
int CountOpenPositionsAndPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      // market + pending are all MODE_TRADES
      count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Basket profit points (floating)                                 |
//+------------------------------------------------------------------+
double GetBasketProfitPoints()
{
   double totalPts = 0.0;
   double bid = Bid;
   double ask = Ask;
   if(Point <= 0) return(0.0);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      if(type == OP_BUY)
         totalPts += (bid - OrderOpenPrice()) / Point;
      else if(type == OP_SELL)
         totalPts += (OrderOpenPrice() - ask) / Point;
   }
   return(totalPts);
}

//+------------------------------------------------------------------+
//| Close all positions and delete all pendings (symbol/magic)       |
//+------------------------------------------------------------------+
void CloseAllPositionsAndDeletePendings()
{
   // delete pendings first, then close market orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      if(type == OP_BUYLIMIT || type == OP_SELLLIMIT || type == OP_BUYSTOP || type == OP_SELLSTOP)
      {
         if(!OrderDelete(OrderTicket()))
            Print("FAILED OrderDelete ticket=", OrderTicket(), " err=", GetLastError());
         else
            Print("Pending deleted ticket=", OrderTicket());
      }
   }

   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      int ticket = OrderTicket();

      if(type == OP_BUY)
      {
         if(!OrderClose(ticket, OrderLots(), Bid, SlippagePoints, clrNONE))
            Print("FAILED OrderClose BUY ticket=", ticket, " err=", GetLastError());
         else
            Print("Closed BUY ticket=", ticket);
      }
      else if(type == OP_SELL)
      {
         if(!OrderClose(ticket, OrderLots(), Ask, SlippagePoints, clrNONE))
            Print("FAILED OrderClose SELL ticket=", ticket, " err=", GetLastError());
         else
            Print("Closed SELL ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Refresh indicator values for bar 0                              |
//+------------------------------------------------------------------+
bool RefreshBarData()
{
   // Stochastic main line = MODE_MAIN
   g_stochMain = iStochastic(Symbol(), PERIOD_M1, StochasticK, StochasticD, StochasticSlowing,
                             MODE_SMA, 0, MODE_MAIN, 0);
   // Bollinger Bands on Typical price
   g_bbUpper  = iBands(Symbol(), PERIOD_M1, BollingerPeriod, BollingerDeviation, 0, PRICE_TYPICAL, MODE_UPPER, 0);
   g_bbLower  = iBands(Symbol(), PERIOD_M1, BollingerPeriod, BollingerDeviation, 0, PRICE_TYPICAL, MODE_LOWER, 0);
   g_barHigh0 = iHigh(Symbol(), PERIOD_M1, 0);
   g_barLow0  = iLow(Symbol(), PERIOD_M1, 0);

   Print("Indicators [bar0]: StochMain=", DoubleToString(g_stochMain, 2),
         " BB_Upper=", DoubleToString(g_bbUpper, Digits),
         " BB_Lower=", DoubleToString(g_bbLower, Digits),
         " High0=", DoubleToString(g_barHigh0, Digits),
         " Low0=", DoubleToString(g_barLow0, Digits));
   return(true);
}

//+------------------------------------------------------------------+
//| Entry conditions                                                |
//+------------------------------------------------------------------+
bool CheckSellSignal()
{
   if(g_stochMain <= (double)StochasticOverboughtLevel) return(false);

   double highPrev = iHigh(Symbol(), PERIOD_M1, 1);
   double upperPrev = iBands(Symbol(), PERIOD_M1, BollingerPeriod, BollingerDeviation, 0, PRICE_TYPICAL, MODE_UPPER, 1);

   bool touchOrCross = (g_barHigh0 >= g_bbUpper) || (highPrev < upperPrev && g_barHigh0 >= g_bbUpper);
   if(touchOrCross)
      Print("ENTRY SIGNAL: SELL — StochMain=", DoubleToString(g_stochMain, 2), " > ", StochasticOverboughtLevel,
            "; touch/cross upper BB.");
   return(touchOrCross);
}

bool CheckBuySignal()
{
   if(g_stochMain >= (double)StochasticOversoldLevel) return(false);

   double lowPrev = iLow(Symbol(), PERIOD_M1, 1);
   double lowerPrev = iBands(Symbol(), PERIOD_M1, BollingerPeriod, BollingerDeviation, 0, PRICE_TYPICAL, MODE_LOWER, 1);

   bool touchOrCross = (g_barLow0 <= g_bbLower) || (lowPrev > lowerPrev && g_barLow0 <= g_bbLower);
   if(touchOrCross)
      Print("ENTRY SIGNAL: BUY — StochMain=", DoubleToString(g_stochMain, 2), " < ", StochasticOversoldLevel,
            "; touch/cross lower BB.");
   return(touchOrCross);
}

//+------------------------------------------------------------------+
//| Grid placement                                                  |
//+------------------------------------------------------------------+
void PlaceSellGrid(const double anchorPrice)
{
   double lot = NormalizeLotVolume(LotSize);
   double step = (double)GridDistancePoints * Point;

   for(int i=1; i<=GridCount; i++)
   {
      double price = NormalizePrice(anchorPrice + step * i);
      int ticket = OrderSend(Symbol(), OP_SELLLIMIT, lot, price, SlippagePoints, 0, 0,
                             "BBStoch SellLimit", MagicNumber, 0, clrNONE);
      if(ticket < 0)
         Print("FAILED SellLimit #", i, " price=", DoubleToString(price, Digits), " err=", GetLastError());
      else
         Print("Placed SellLimit #", i, " ticket=", ticket, " price=", DoubleToString(price, Digits),
               " lot=", DoubleToString(lot, 2));
   }
}

void PlaceBuyGrid(const double anchorPrice)
{
   double lot = NormalizeLotVolume(LotSize);
   double step = (double)GridDistancePoints * Point;

   for(int i=1; i<=GridCount; i++)
   {
      double price = NormalizePrice(anchorPrice - step * i);
      int ticket = OrderSend(Symbol(), OP_BUYLIMIT, lot, price, SlippagePoints, 0, 0,
                             "BBStoch BuyLimit", MagicNumber, 0, clrNONE);
      if(ticket < 0)
         Print("FAILED BuyLimit #", i, " price=", DoubleToString(price, Digits), " err=", GetLastError());
      else
         Print("Placed BuyLimit #", i, " ticket=", ticket, " price=", DoubleToString(price, Digits),
               " lot=", DoubleToString(lot, 2));
   }
}

//+------------------------------------------------------------------+
//| Open cycles                                                     |
//+------------------------------------------------------------------+
void OpenSellCycle()
{
   double lot = NormalizeLotVolume(LotSize);
   int ticket = OrderSend(Symbol(), OP_SELL, lot, Bid, SlippagePoints, 0, 0, "BBStoch market SELL", MagicNumber, 0, clrNONE);
   if(ticket < 0)
   {
      Print("FAILED market SELL lot=", DoubleToString(lot,2), " err=", GetLastError());
      return;
   }
   Print("Market SELL opened ticket=", ticket, " lot=", DoubleToString(lot, 2));

   double anchor = Bid; // per spec: grid above current price
   PlaceSellGrid(anchor);
}

void OpenBuyCycle()
{
   double lot = NormalizeLotVolume(LotSize);
   int ticket = OrderSend(Symbol(), OP_BUY, lot, Ask, SlippagePoints, 0, 0, "BBStoch market BUY", MagicNumber, 0, clrNONE);
   if(ticket < 0)
   {
      Print("FAILED market BUY lot=", DoubleToString(lot,2), " err=", GetLastError());
      return;
   }
   Print("Market BUY opened ticket=", ticket, " lot=", DoubleToString(lot, 2));

   double anchor = Ask; // per spec: grid below current price
   PlaceBuyGrid(anchor);
}

//+------------------------------------------------------------------+
//| MT4 lifecycle                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(Period() != PERIOD_M1)
   {
      Print("BBStochGridBasketEA_MT4: attach this EA only on M1. Current period=", Period());
      return(INIT_FAILED);
   }
   if(GridCount < 1 || GridDistancePoints < 1 || LotSize <= 0.0)
   {
      Print("BBStochGridBasketEA_MT4: invalid inputs — GridCount>=1, GridDistancePoints>=1, LotSize>0 required.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   g_lastBarTime = 0;
   Print("BBStochGridBasketEA_MT4 initialized on ", Symbol(), " M1. Magic=", MagicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("BBStochGridBasketEA_MT4 deinit. reason=", reason);
}

void OnTick()
{
   if(Period() != PERIOD_M1) return;

   // basket checks always run
   double basketPts = GetBasketProfitPoints();

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

   if(!AllowNewCycle) return;

   // one cycle at a time: must have no open/pending
   if(CountOpenPositionsAndPendingOrders() > 0) return;

   // spread filter before new entry
   if(MaxSpreadPoints > 0 && CurrentSpreadPoints() > MaxSpreadPoints)
   {
      // one log per bar
      static datetime s_lastSpreadLogBar = 0;
      datetime barT = iTime(Symbol(), PERIOD_M1, 0);
      if(barT != 0 && barT != s_lastSpreadLogBar)
      {
         s_lastSpreadLogBar = barT;
         Print("Spread filter: ", CurrentSpreadPoints(), " points > MaxSpreadPoints ", MaxSpreadPoints,
               " — skip new cycle this bar.");
      }
      return;
   }

   // new-bar gate to avoid repeated entries
   if(!IsNewBar()) return;

   if(!RefreshBarData()) return;

   if(CheckSellSignal())
      OpenSellCycle();
   else if(CheckBuySignal())
      OpenBuyCycle();
}

