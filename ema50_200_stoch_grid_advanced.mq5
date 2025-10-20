//+------------------------------------------------------------------+
//|                                    EMA50_200_Stoch_Grid_Advanced |
//|                                   by fullScreen & ChatGPT (MT5)  |
//+------------------------------------------------------------------+
#property copyright "fullScreen & ChatGPT"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade Trade;

//---- Inputs
input double   InpInitialLot     = 0.10;     // Initial Lot Size
input int      InpGridDistancePt = 200;      // Grid Distance (points)
input int      InpSLPoints       = 2000;     // Stop Loss (points) - shared
input int      InpTargetPoints   = 5000;     // Target to close all (points)
input int      InpStartHourBKK   = 5;        // Start hour Bangkok (UTC+7)
input int      InpEndHourBKK     = 23;       // End hour Bangkok (UTC+7), exclusive
input int      InpMaxGridLevels  = 20;       // Max pending grid levels (per side)
input long     InpMagic          = 25072025; // Magic number
input bool     InpAllowBothSides = true;     // Allow buy & sell simultaneously

//---- Indicators (handles)
int hEMA50 = INVALID_HANDLE;
int hEMA200 = INVALID_HANDLE;
int hStoch = INVALID_HANDLE;

//---- Day stop flag
datetime g_dayStopped = 0; // store date (00:00) in BKK when stopped

//---- Helpers
bool IsTradingHourBKK()
{
   datetime now_gmt = TimeGMT();
   datetime now_bkk = now_gmt + 7*3600;
   MqlDateTime dt;
   TimeToStruct(now_bkk, dt);
   // also handle daily stop
   datetime day_bkk = now_bkk - (dt.hour*3600 + dt.min*60 + dt.sec); // truncate to 00:00
   if(g_dayStopped == day_bkk) return false; // stopped for today
   if(dt.hour >= InpStartHourBKK && dt.hour < InpEndHourBKK) return true;
   return false;
}

double GetEMA(int handle, int shift)
{
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return EMPTY_VALUE;
   return buf[0];
}

bool GetStoch(int shift, double &k, double &d)
{
   double kbuf[], dbuf[];
   if(CopyBuffer(hStoch, 0, shift, 2, kbuf) < 2) return false; // %K
   if(CopyBuffer(hStoch, 1, shift, 2, dbuf) < 2) return false; // %D
   k = kbuf[0];
   d = dbuf[0];
   return true;
}

int CountPositions(int type=-1)
{
   int cnt=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(type==-1) cnt++;
      else
      {
         int pt = (int)PositionGetInteger(POSITION_TYPE);
         if(pt==type) cnt++;
      }
   }
   return cnt;
}

int CountPendings(int type=-1)
{
   int cnt=0;
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==-1) cnt++;
      else
      {
         if((int)ot==type) cnt++;
      }
   }
   return cnt;
}

double CurrentTotalProfitPoints()
{
   double total_pts = 0.0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
      int pos_type = (int)PositionGetInteger(POSITION_TYPE);
      double price_cur = (pos_type == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int dir = (pos_type == POSITION_TYPE_BUY) ? +1 : -1;
      total_pts += (price_cur - price_open) / _Point * dir;
   }
   return total_pts;
}

void CloseAllAndStopToday()
{
   // close all positions
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int ptype = (int)PositionGetInteger(POSITION_TYPE);
      double lots = PositionGetDouble(POSITION_VOLUME);
      if(ptype==POSITION_TYPE_BUY) Trade.PositionClose(ticket);
      else if(ptype==POSITION_TYPE_SELL) Trade.PositionClose(ticket);
   }
   // delete all pending orders
   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      Trade.OrderDelete(ticket);
   }
   // mark stopped for today (Bangkok date)
   datetime now_gmt = TimeGMT();
   datetime now_bkk = now_gmt + 7*3600;
   MqlDateTime dt; TimeToStruct(now_bkk, dt);
   g_dayStopped = now_bkk - (dt.hour*3600 + dt.min*60 + dt.sec); // 00:00 today BKK
}

// ensure no duplicate pending at price
bool PendingExists(ENUM_ORDER_TYPE type, double price)
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type) continue;
      double p = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(p - price) <= (_Point*0.5)) return true;
   }
   return false;
}

void PlaceGrid(bool isBuy, double base_price, double sl_price)
{
   // create up to InpMaxGridLevels pending limit orders every GridDistance
   for(int lvl=1; lvl<=InpMaxGridLevels; ++lvl)
   {
      double lot = NormalizeDouble(InpInitialLot * lvl, 2); // 0.1, 0.2, 0.3, ...
      ENUM_ORDER_TYPE t = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      double price = isBuy ? base_price - (InpGridDistancePt * _Point * lvl)
                           : base_price + (InpGridDistancePt * _Point * lvl);
      if(price<=0) break;

      if(PendingExists(t, price)) continue;

      Trade.SetExpertMagicNumber(InpMagic);
      Trade.SetDeviationInPoints(20);
      // No TP; shared SL
      bool ok=false;
      if(isBuy) ok = Trade.BuyLimit(lot, price, _Symbol, sl_price, 0.0, ORDER_TIME_GTC, 0, "Grid BuyLimit");
      else      ok = Trade.SellLimit(lot, price, _Symbol, sl_price, 0.0, ORDER_TIME_GTC, 0, "Grid SellLimit");

      if(!ok) { Print("Grid pending failed at lvl ", lvl, " err=", _LastError); }
   }
}

void MaybeEnterBuy()
{
   // Entry only if condition and (either no sell exposure or allowed both)
   if(!InpAllowBothSides && CountPositions(POSITION_TYPE_SELL)>0) return;

   double ema50 = GetEMA(hEMA50, 0);
   double ema200= GetEMA(hEMA200,0);
   if(ema50==EMPTY_VALUE || ema200==EMPTY_VALUE) return;
   if(!(ema50 > ema200)) return;

   double k0,d0,k1,d1;
   if(!GetStoch(0,k0,d0) || !GetStoch(1,k1,d1)) return;
   // "touch 20": previous >20 and current <=20
   if(!(k1>20.0 && k0<=20.0)) return;

   // Check if already have buy positions to avoid multiple entries
   if(CountPositions(POSITION_TYPE_BUY) > 0) return;

   // Place initial market BUY with shared SL; then grid of BUY LIMITs
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;
   double sl  = ask - InpSLPoints * _Point;
   double lot = InpInitialLot;

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(20);

   if(Trade.Buy(lot, _Symbol, 0, ask, sl, 0.0, "Initial BUY"))
   {
      PlaceGrid(true, ask, sl);
      Print("BUY position opened at ", ask, " SL: ", sl);
   }
   else
   {
      Print("Initial BUY failed, err=", _LastError);
   }
}

void MaybeEnterSell()
{
   if(!InpAllowBothSides && CountPositions(POSITION_TYPE_BUY)>0) return;

   double ema50 = GetEMA(hEMA50, 0);
   double ema200= GetEMA(hEMA200,0);
   if(ema50==EMPTY_VALUE || ema200==EMPTY_VALUE) return;
   if(!(ema50 < ema200)) return;

   double k0,d0,k1,d1;
   if(!GetStoch(0,k0,d0) || !GetStoch(1,k1,d1)) return;
   // "touch 80": previous <80 and current >=80
   if(!(k1<80.0 && k0>=80.0)) return;

   // Check if already have sell positions to avoid multiple entries
   if(CountPositions(POSITION_TYPE_SELL) > 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;
   double sl  = bid + InpSLPoints * _Point;
   double lot = InpInitialLot;

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(20);

   if(Trade.Sell(lot, _Symbol, 0, bid, sl, 0.0, "Initial SELL"))
   {
      PlaceGrid(false, bid, sl);
      Print("SELL position opened at ", bid, " SL: ", sl);
   }
   else
   {
      Print("Initial SELL failed, err=", _LastError);
   }
}

// keep SL shared: if initial is missing but we have others, do nothing (assume all share same SL already)

void CheckTargetAndCloseAll()
{
   // Condition: if more than 2 orders (positions count >=3) AND total profit (points) >= InpTargetPoints
   int total_orders = CountPositions(-1) + CountPendings(-1); // for "more than 2 orders" counting both
   if(total_orders > 2)
   {
      double pts = CurrentTotalProfitPoints();
      if(pts >= InpTargetPoints)
      {
         CloseAllAndStopToday();
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   hEMA50  = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
   hStoch  = iStochastic(_Symbol, PERIOD_M5, 9, 3, 3, MODE_SMA, STO_LOWHIGH);

   if(hEMA50==INVALID_HANDLE || hEMA200==INVALID_HANDLE || hStoch==INVALID_HANDLE)
   {
      Print("Indicator handle error");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // Trading window
   if(!IsTradingHourBKK()) return;

   // Safety: only act on new bar for stability on M5
   static datetime lastbar = 0;
   datetime curbar = iTime(_Symbol, PERIOD_M5, 0);
   if(curbar == lastbar) { CheckTargetAndCloseAll(); return; }
   lastbar = curbar;

   // Enforce M5 only
   if(Period() != PERIOD_M5) return;

   // Check target/close-all first
   CheckTargetAndCloseAll();

   // New entries
   MaybeEnterBuy();
   MaybeEnterSell();
}
