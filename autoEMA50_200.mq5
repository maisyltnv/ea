//+------------------------------------------------------------------+
//| autoEMA50_200.mq5                                                |
//| M1: EMA50 / EMA200 crossover-style entries, fixed SL/TP (points),|
//|      break-even lock, alternate next entry after TP hit.         |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "M1 EMA50/EMA200: buy/sell on closed bar; SL/TP points; BE at profit; after TP only opposite-side entry until opened."

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- Inputs ----------------------------------
input string InpTradeSymbol   = "";              // Empty = chart symbol
input ENUM_TIMEFRAMES InpTF     = PERIOD_M1;       // Signal TF (M1 per spec)
input ulong  InpMagic           = 502502502;
input double InpLot             = 0.01;
input int    InpSlippagePoints  = 30;
input int    InpMaxSpreadPoints = 500;

input int    InpEMA_Fast        = 50;
input int    InpEMA_Slow        = 200;

input int    InpSL_Points       = 500;
input int    InpTP_Points       = 1000;
input int    InpBE_ProfitPoints = 500;           // Move SL when profit >= this (points)
input int    InpBE_OffsetPoints = 20;            // BUY: SL at entry + offset; SELL: entry - offset

//------------------------- State -----------------------------------
enum ENUM_ALT_PHASE
{
   PHASE_NORMAL = 0,                 // Either side allowed (if flat)
   PHASE_WAIT_SELL_AFTER_BUY_TP,   // After buy TP: only sell entry
   PHASE_WAIT_BUY_AFTER_SELL_TP    // After sell TP: only buy entry
};

int    hEmaFast = INVALID_HANDLE;
int    hEmaSlow = INVALID_HANDLE;
string Sym;
datetime lastBarTime = 0;
ENUM_ALT_PHASE g_phase = PHASE_NORMAL;

ulong    g_lastManagedTicket = 0;
bool     g_beApplied = false;

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t[1];
   if(CopyTime(Sym, InpTF, 0, 1, t) != 1) return false;
   if(t[0] != lastBarTime)
   {
      lastBarTime = t[0];
      return true;
   }
   return false;
}

bool SpreadOK()
{
   long sp = SymbolInfoInteger(Sym, SYMBOL_SPREAD);
   return (sp > 0 && sp <= InpMaxSpreadPoints);
}

int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == Sym &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         n++;
   }
   return n;
}

bool GetClosedBarEMAs(double &emaFast, double &emaSlow, double &close1)
{
   double ef[2], es[2];
   ArraySetAsSeries(ef, true);
   ArraySetAsSeries(es, true);
   if(CopyBuffer(hEmaFast, 0, 0, 2, ef) != 2) return false;
   if(CopyBuffer(hEmaSlow, 0, 0, 2, es) != 2) return false;
   MqlRates r[2];
   ArraySetAsSeries(r, true);
   if(CopyRates(Sym, InpTF, 0, 2, r) != 2) return false;
   emaFast = ef[1];
   emaSlow = es[1];
   close1  = r[1].close;
   return true;
}

double NormalizeVolumeLocal(double lot)
{
   double minLot  = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(Sym, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(Sym, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(lot, maxLot));
   lot = MathFloor(lot / stepLot) * stepLot;
   return NormalizeDouble(lot, 2);
}

bool OpenBuy()
{
   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);
   double ask   = SymbolInfoDouble(Sym, SYMBOL_ASK);
   double lot   = NormalizeVolumeLocal(InpLot);

   double sl = NormalizeDouble(ask - InpSL_Points * point, digits);
   double tp = NormalizeDouble(ask + InpTP_Points * point, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   if(!trade.Buy(lot, Sym, ask, sl, tp, "autoEMA50_200 BUY"))
      return false;
   g_beApplied = false;
   g_lastManagedTicket = 0;
   return true;
}

bool OpenSell()
{
   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);
   double bid   = SymbolInfoDouble(Sym, SYMBOL_BID);
   double lot   = NormalizeVolumeLocal(InpLot);

   double sl = NormalizeDouble(bid + InpSL_Points * point, digits);
   double tp = NormalizeDouble(bid - InpTP_Points * point, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   if(!trade.Sell(lot, Sym, bid, sl, tp, "autoEMA50_200 SELL"))
      return false;
   g_beApplied = false;
   g_lastManagedTicket = 0;
   return true;
}

void ManageBreakEven()
{
   double point = SymbolInfoDouble(Sym, SYMBOL_POINT);
   if(point <= 0.0) return;
   int digits = (int)SymbolInfoInteger(Sym, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != Sym ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      ENUM_POSITION_TYPE typ = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      if(g_lastManagedTicket != ticket)
      {
         g_lastManagedTicket = ticket;
         g_beApplied = false;
      }

      if(g_beApplied) continue;

      if(typ == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice) / point;
         if(profitPts >= (double)InpBE_ProfitPoints)
         {
            double newSL = NormalizeDouble(openPrice + InpBE_OffsetPoints * point, digits);
            if(newSL < bid && (sl == 0.0 || newSL > sl))
            {
               if(trade.PositionModify(ticket, newSL, tp))
                  g_beApplied = true;
            }
         }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask) / point;
         if(profitPts >= (double)InpBE_ProfitPoints)
         {
            double newSL = NormalizeDouble(openPrice - InpBE_OffsetPoints * point, digits);
            if(newSL > ask && (sl == 0.0 || newSL < sl))
            {
               if(trade.PositionModify(ticket, newSL, tp))
                  g_beApplied = true;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| After BUY TP  -> only SELL entry until sell opens.              |
//| After SELL TP -> only BUY entry until buy opens.                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   HistorySelect(0, TimeCurrent());
   if(!HistoryDealSelect(trans.deal)) return;

   string dealSym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(dealSym != Sym) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT) return;

   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(reason != DEAL_REASON_TP) return;

   // Close long -> outbound deal SELL; close short -> outbound deal BUY
   ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype == DEAL_TYPE_SELL)
   {
      g_phase = PHASE_WAIT_SELL_AFTER_BUY_TP;
      Print("autoEMA50_200: BUY closed at TP -> next entry must be SELL.");
   }
   else if(dtype == DEAL_TYPE_BUY)
   {
      g_phase = PHASE_WAIT_BUY_AFTER_SELL_TP;
      Print("autoEMA50_200: SELL closed at TP -> next entry must be BUY.");
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   Sym = (InpTradeSymbol == "") ? _Symbol : InpTradeSymbol;
   if(!SymbolSelect(Sym, true))
   {
      Print("Cannot select symbol: ", Sym);
      return INIT_FAILED;
   }

   hEmaFast = iMA(Sym, InpTF, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(Sym, InpTF, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE)
   {
      Print("Indicator create failed");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   Print("autoEMA50_200 initialized ", Sym, " ", EnumToString(InpTF));

   datetime t0[1];
   if(CopyTime(Sym, InpTF, 0, 1, t0) == 1)
      lastBarTime = t0[0];

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Sym == "") return;

   ManageBreakEven();

   if(CountOurPositions() > 0) return;
   if(!IsNewBar()) return;
   if(!SpreadOK()) return;

   double emaF, emaS, c1;
   if(!GetClosedBarEMAs(emaF, emaS, c1)) return;

   bool buySignal  = (c1 > emaF && emaF > emaS);
   bool sellSignal = (c1 < emaF && emaF < emaS);

   if(g_phase == PHASE_WAIT_SELL_AFTER_BUY_TP)
   {
      if(sellSignal)
      {
         if(OpenSell())
            g_phase = PHASE_NORMAL;
      }
      return;
   }

   if(g_phase == PHASE_WAIT_BUY_AFTER_SELL_TP)
   {
      if(buySignal)
      {
         if(OpenBuy())
            g_phase = PHASE_NORMAL;
      }
      return;
   }

   // PHASE_NORMAL
   if(buySignal)
      OpenBuy();
   else if(sellSignal)
      OpenSell();
}

//+------------------------------------------------------------------+
